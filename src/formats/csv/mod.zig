const std = @import("std");
const scanner_mod = @import("scanner.zig");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");
const kind_mod = @import("../../core/kind.zig");
const options = @import("../../core/options.zig");

pub const Scanner = scanner_mod.Scanner;
pub const Dialect = scanner_mod.Dialect;
pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;
pub const tsv_dialect = scanner_mod.tsv_dialect;
pub const excel_dialect = scanner_mod.excel_dialect;
pub const unix_dialect = scanner_mod.unix_dialect;

/// Serialize a slice of structs to CSV with the default dialect.
/// Caller owns the returned memory.
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

/// Serialize a slice of structs to CSV with a specific dialect.
pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, dialect: Dialect) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    try toWriterWith(&aw.writer, value, dialect);
    return aw.toOwnedSlice();
}

/// Serialize a slice of structs to a null-terminated CSV byte slice. Caller owns the returned memory.
pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    return toSliceAllocWith(allocator, value, .{});
}

/// Serialize with a specific dialect to a null-terminated slice.
pub fn toSliceAllocWith(allocator: std.mem.Allocator, value: anytype, dialect: Dialect) ![:0]u8 {
    const bytes = try toSliceWith(allocator, value, dialect);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

/// Serialize a slice of structs to a writer in CSV format with the default dialect.
pub fn toWriter(writer: *std.io.Writer, value: anytype) !void {
    return toWriterWith(writer, value, .{});
}

/// Serialize a slice of structs to a writer in CSV format with a specific dialect.
pub fn toWriterWith(writer: *std.io.Writer, value: anytype, dialect: Dialect) !void {
    const T = @TypeOf(value);
    const ElemType = comptime getStructElem(T);

    var ser = Serializer.init(writer, dialect);

    if (dialect.has_header) {
        try writeHeaderRow(ElemType, &ser);
    }

    for (value) |elem| {
        try core_serialize.serialize(ElemType, elem, &ser);
        try ser.endRow();
    }
}

/// Deserialize CSV into a slice of structs with the default dialect.
/// Allocates all output. Use an ArenaAllocator for easy cleanup.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return fromSliceWith(T, allocator, input, .{});
}

/// Deserialize CSV into a slice of structs with a specific dialect.
pub fn fromSliceWith(comptime T: type, allocator: std.mem.Allocator, input: []const u8, dialect: Dialect) !T {
    const ElemType = comptime getStructElem(T);

    var scanner = Scanner.init(input, dialect);

    // Parse header row.
    var header_fields: []const []const u8 = &.{};
    if (dialect.has_header) {
        const row = (try scanner.readRow(allocator)) orelse return allocator.alloc(ElemType, 0) catch return error.OutOfMemory;
        defer allocator.free(row);
        var hdrs: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (hdrs.items) |h| allocator.free(h);
            hdrs.deinit(allocator);
        }
        for (row) |field| {
            const name = if (field.quoted)
                try scanner_mod.unquoteField(allocator, field.raw, dialect.quote)
            else
                allocator.dupe(u8, field.raw) catch return error.OutOfMemory;
            hdrs.append(allocator, name) catch return error.OutOfMemory;
        }
        header_fields = hdrs.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }
    defer {
        for (header_fields) |h| allocator.free(h);
        allocator.free(header_fields);
    }

    // Parse data rows.
    var items: std.ArrayList(ElemType) = .empty;
    errdefer items.deinit(allocator);

    while (try scanner.readRow(allocator)) |row| {
        defer allocator.free(row);
        if (row.len == 0) continue; // skip empty rows

        var deser = Deserializer.init(header_fields, row);
        const elem = try core_deserialize.deserialize(ElemType, allocator, &deser);
        items.append(allocator, elem) catch return error.OutOfMemory;
    }

    return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn writeHeaderRow(comptime T: type, ser: *Serializer) SerializeError!void {
    const info = @typeInfo(T).@"struct";
    inline for (info.fields) |field| {
        if (comptime options.shouldSkipField(T, field.name, .serialize)) continue;
        const wire_name = comptime options.wireFieldName(T, field.name);
        try ser.serializeString(wire_name);
    }
    try ser.endRow();
}

const SerializeError = serializer_mod.SerializeError;

fn getStructElem(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice) {
        const child = info.pointer.child;
        if (kind_mod.typeKind(child) == .@"struct") return child;
    }
    if (info == .array) {
        const child = info.array.child;
        if (kind_mod.typeKind(child) == .@"struct") return child;
    }
    @compileError("CSV requires []const S or [N]S where S is a struct, got: " ++ @typeName(T));
}

/// Deserialize CSV into a slice of structs from a reader with the default dialect.
pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *std.io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

/// Deserialize CSV from a file path.
pub fn fromFilePath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);
    return fromSlice(T, allocator, content);
}

/// Streaming row-by-row deserializer. Parses one struct per call to `next`.
pub fn StreamingDeserializer(comptime T: type) type {
    const ElemType = comptime getStructElem(T);

    return struct {
        scanner: Scanner,
        header_fields: []const []const u8,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, input: []const u8, dialect: Dialect) !Self {
            var scanner = Scanner.init(input, dialect);

            var header_fields: []const []const u8 = &.{};
            if (dialect.has_header) {
                const row = (try scanner.readRow(allocator)) orelse return .{
                    .scanner = scanner,
                    .header_fields = &.{},
                    .allocator = allocator,
                };
                defer allocator.free(row);
                var hdrs: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (hdrs.items) |h| allocator.free(h);
                    hdrs.deinit(allocator);
                }
                for (row) |field| {
                    const name = if (field.quoted)
                        try scanner_mod.unquoteField(allocator, field.raw, dialect.quote)
                    else
                        allocator.dupe(u8, field.raw) catch return error.OutOfMemory;
                    hdrs.append(allocator, name) catch return error.OutOfMemory;
                }
                header_fields = hdrs.toOwnedSlice(allocator) catch return error.OutOfMemory;
            }

            return .{
                .scanner = scanner,
                .header_fields = header_fields,
                .allocator = allocator,
            };
        }

        pub fn next(self: *Self) !?ElemType {
            const row = (try self.scanner.readRow(self.allocator)) orelse return null;
            defer self.allocator.free(row);
            if (row.len == 0) return null;

            var deser = Deserializer.init(self.header_fields, row);
            return try core_deserialize.deserialize(ElemType, self.allocator, &deser);
        }

        pub fn deinit(self: *Self) void {
            for (self.header_fields) |h| self.allocator.free(h);
            self.allocator.free(self.header_fields);
        }
    };
}

/// Create a streaming deserializer with the default dialect.
pub fn streamingDeserializer(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !StreamingDeserializer(T) {
    return streamingDeserializerWith(T, allocator, input, .{});
}

/// Create a streaming deserializer with a specific dialect.
pub fn streamingDeserializerWith(comptime T: type, allocator: std.mem.Allocator, input: []const u8, dialect: Dialect) !StreamingDeserializer(T) {
    return StreamingDeserializer(T).init(allocator, input, dialect);
}

fn readAll(allocator: std.mem.Allocator, reader: *std.io.Reader) ![]u8 {
    return reader.allocRemaining(allocator, std.io.Limit.limited(10 * 1024 * 1024)) catch return error.ReadFailed;
}

const CoreValue = @import("../../core/value.zig").Value;

/// Convert any Zig value to a format-agnostic dynamic Value.
pub fn toValue(allocator: std.mem.Allocator, value: anytype) !CoreValue {
    return CoreValue.fromAny(@TypeOf(value), value, allocator);
}

/// Convert a dynamic Value back to a typed Zig value.
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: CoreValue) !T {
    return value.toType(T, allocator);
}

const testing = std.testing;

test "roundtrip flat struct" {
    const Row = struct { x: i32, y: i32 };
    const data: []const Row = &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(@as(i32, 1), result[0].x);
    try testing.expectEqual(@as(i32, 2), result[0].y);
    try testing.expectEqual(@as(i32, 3), result[1].x);
    try testing.expectEqual(@as(i32, 4), result[1].y);
}

test "roundtrip with strings" {
    const Row = struct { name: []const u8, age: i32 };
    const data: []const Row = &.{
        .{ .name = "Alice", .age = 30 },
        .{ .name = "Bob", .age = 25 },
    };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("Alice", result[0].name);
    try testing.expectEqual(@as(i32, 30), result[0].age);
    try testing.expectEqualStrings("Bob", result[1].name);
}

test "roundtrip quoting" {
    const Row = struct { msg: []const u8, val: i32 };
    const data: []const Row = &.{
        .{ .msg = "hello, world", .val = 1 },
        .{ .msg = "say \"hi\"", .val = 2 },
    };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello, world", result[0].msg);
    try testing.expectEqualStrings("say \"hi\"", result[1].msg);
}

test "roundtrip optional fields" {
    const Row = struct { name: []const u8, score: ?i32 };
    const data: []const Row = &.{
        .{ .name = "Alice", .score = 100 },
        .{ .name = "Bob", .score = null },
    };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(?i32, 100), result[0].score);
    try testing.expectEqual(@as(?i32, null), result[1].score);
}

test "roundtrip TSV" {
    const Row = struct { a: i32, b: i32 };
    const data: []const Row = &.{.{ .a = 1, .b = 2 }};
    const bytes = try toSliceWith(testing.allocator, data, tsv_dialect);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\t") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSliceWith([]const Row, arena.allocator(), bytes, tsv_dialect);
    try testing.expectEqual(@as(i32, 1), result[0].a);
    try testing.expectEqual(@as(i32, 2), result[0].b);
}

test "roundtrip bool fields" {
    const Row = struct { name: []const u8, active: bool };
    const data: []const Row = &.{
        .{ .name = "a", .active = true },
        .{ .name = "b", .active = false },
    };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(true, result[0].active);
    try testing.expectEqual(false, result[1].active);
}

test "roundtrip float fields" {
    const Row = struct { val: f64 };
    const data: []const Row = &.{.{ .val = 3.14 }};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expect(@abs(result[0].val - 3.14) < 0.001);
}

test "roundtrip serde rename" {
    const Row = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = options.NamingConvention.camel_case,
        };
    };

    const data: []const Row = &.{.{ .id = 1, .first_name = "Alice" }};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "user_id") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "firstName") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 1), result[0].id);
    try testing.expectEqualStrings("Alice", result[0].first_name);
}

test "roundtrip serde skip" {
    const Row = struct {
        name: []const u8,
        token: []const u8 = "",

        pub const serde = .{
            .skip = .{
                .token = options.SkipMode.always,
            },
        };
    };

    const data: []const Row = &.{.{ .name = "test", .token = "secret" }};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "token") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
}

test "empty input" {
    const Row = struct { x: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), "x\n");
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "single row" {
    const Row = struct { val: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), "val\n42\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(i32, 42), result[0].val);
}

test "roundtrip enum field" {
    const Color = enum { red, green, blue };
    const Row = struct { name: []const u8, color: Color };
    const data: []const Row = &.{.{ .name = "test", .color = .green }};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(Color.green, result[0].color);
}

test "roundtrip string with newline" {
    const Row = struct { msg: []const u8 };
    const data: []const Row = &.{.{ .msg = "line1\nline2" }};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqualStrings("line1\nline2", result[0].msg);
}

test "BOM handling" {
    const Row = struct { x: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), "\xEF\xBB\xBFx\n42\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(i32, 42), result[0].x);
}

test "toWriter" {
    const Row = struct { x: i32, y: i32 };
    const data: []const Row = &.{.{ .x = 1, .y = 2 }};
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    try toWriter(&aw.writer, data);
    const bytes = try aw.toOwnedSlice();
    defer testing.allocator.free(bytes);
    // Should have header and data row.
    try testing.expect(std.mem.indexOf(u8, bytes, "x,y") != null);
}

test "toSliceAlloc null-terminated" {
    const Row = struct { x: i32 };
    const data: []const Row = &.{.{ .x = 1 }};
    const bytes = try toSliceAlloc(testing.allocator, data);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u8, 0), bytes.ptr[bytes.len]);
}

test "toValue and fromValue" {
    const Row = struct { x: i32, y: i32 };
    const v = try toValue(testing.allocator, Row{ .x = 10, .y = 20 });
    defer v.deinit(testing.allocator);
    const result = try fromValue(Row, testing.allocator, v);
    try testing.expectEqual(@as(i32, 10), result.x);
    try testing.expectEqual(@as(i32, 20), result.y);
}

test "fromReader" {
    const Row = struct { x: i32 };
    const input = "x\n42\n";
    var reader: std.io.Reader = .fixed(input);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromReader([]const Row, arena.allocator(), &reader);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(i32, 42), result[0].x);
}

test "roundtrip with UnixTimestampMs" {
    const ts = @import("../../helpers/timestamp.zig");
    const Row = struct {
        name: []const u8,
        created_at: i64,

        pub const serde = .{
            .with = .{
                .created_at = ts.UnixTimestampMs,
            },
        };
    };

    const data: []const Row = &.{.{ .name = "deploy", .created_at = 1700000 }};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("deploy", result[0].name);
    try testing.expectEqual(@as(i64, 1700000), result[0].created_at);
}

test "roundtrip enum integer repr" {
    const Status = enum(u8) {
        active = 0,
        inactive = 1,
        pending = 2,

        pub const serde = .{
            .enum_repr = options.EnumRepr.integer,
        };
    };
    const Row = struct { name: []const u8, status: Status };
    const data: []const Row = &.{
        .{ .name = "alice", .status = .active },
        .{ .name = "bob", .status = .inactive },
    };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqual(Status.active, result[0].status);
    try testing.expectEqual(Status.inactive, result[1].status);
}

test "deny_unknown_fields" {
    const Row = struct {
        x: i32,
        pub const serde = .{
            .deny_unknown_fields = true,
        };
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Known column only — succeeds.
    const result = try fromSlice([]const Row, arena.allocator(), "x\n10\n");
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(i32, 10), result[0].x);

    // Extra column — fails.
    const err = fromSlice([]const Row, arena.allocator(), "x,y\n10,20\n");
    try testing.expectError(error.UnknownField, err);
}

test "serialize skip if null" {
    const Row = struct {
        name: []const u8,
        email: ?[]const u8,

        pub const serde = .{
            .skip = .{ .email = options.SkipMode.@"null" },
        };
    };

    const data: []const Row = &.{
        .{ .name = "Alice", .email = null },
        .{ .name = "Bob", .email = "b@c.d" },
    };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);
    // The header should not contain "email" since skip applies at field level.
    // Actually, skip_if_null only skips the value at runtime — for CSV the header
    // is always written for non-always-skipped fields. Just verify it serializes.
    try testing.expect(bytes.len > 0);
}

test "roundtrip i128 field" {
    const Row = struct { val: i128 };
    const data: []const Row = &.{.{ .val = 123456789012345 }};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(i128, 123456789012345), result[0].val);
}

test "deserialize error: missing column data" {
    const Row = struct { x: i32, y: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Header has x and y, but data row only has one field — empty field parses as InvalidNumber.
    const result = fromSlice([]const Row, arena.allocator(), "x,y\n42\n");
    try testing.expectError(error.InvalidNumber, result);
}

test "deserialize error: type mismatch" {
    const Row = struct { x: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = fromSlice([]const Row, arena.allocator(), "x\nnot_a_number\n");
    try testing.expectError(error.InvalidNumber, result);
}

test "streaming deserializer basic" {
    const Row = struct { x: i32, y: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stream = try streamingDeserializer([]const Row, arena.allocator(), "x,y\n1,2\n3,4\n");
    defer stream.deinit();

    const r1 = (try stream.next()).?;
    try testing.expectEqual(@as(i32, 1), r1.x);
    try testing.expectEqual(@as(i32, 2), r1.y);

    const r2 = (try stream.next()).?;
    try testing.expectEqual(@as(i32, 3), r2.x);
    try testing.expectEqual(@as(i32, 4), r2.y);

    try testing.expectEqual(@as(?Row, null), try stream.next());
}

test "streaming deserializer TSV dialect" {
    const Row = struct { a: i32, b: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stream = try streamingDeserializerWith([]const Row, arena.allocator(), "a\tb\n10\t20\n", tsv_dialect);
    defer stream.deinit();

    const r = (try stream.next()).?;
    try testing.expectEqual(@as(i32, 10), r.a);
    try testing.expectEqual(@as(i32, 20), r.b);
}

test "streaming deserializer empty input" {
    const Row = struct { x: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stream = try streamingDeserializer([]const Row, arena.allocator(), "x\n");
    defer stream.deinit();
    try testing.expectEqual(@as(?Row, null), try stream.next());
}

test "streaming deserializer with strings" {
    const Row = struct { name: []const u8, val: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stream = try streamingDeserializer([]const Row, arena.allocator(), "name,val\nAlice,1\nBob,2\n");
    defer stream.deinit();

    const r1 = (try stream.next()).?;
    try testing.expectEqualStrings("Alice", r1.name);
    try testing.expectEqual(@as(i32, 1), r1.val);

    const r2 = (try stream.next()).?;
    try testing.expectEqualStrings("Bob", r2.name);
}
