//! ZON (Zig Object Notation) serialization and deserialization.
//!
//! Serialize any Zig type to ZON with `toSlice` / `toWriter`, and
//! deserialize with `fromSlice` / `fromReader`. Pretty-printed by default
//! with indent of 4 spaces.

const std = @import("std");
const compat = @import("compat");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");

pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;
pub const Options = serializer_mod.Options;

/// Serialize a value to a ZON byte slice. Caller owns the returned memory.
/// Pretty-printed by default (indent=4).
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

/// Serialize with explicit options.
pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try toWriterWith(&aw.writer, value, opts);
    return aw.toOwnedSlice();
}

/// Serialize a value to a null-terminated ZON byte slice. Caller owns the returned memory.
pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    return toSliceAllocWith(allocator, value, .{});
}

/// Serialize with explicit options to a null-terminated slice.
pub fn toSliceAllocWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![:0]u8 {
    const bytes = try toSliceWith(allocator, value, opts);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

/// Serialize a value to a writer in ZON format.
pub fn toWriter(writer: *compat.Io.Writer, value: anytype) !void {
    return toWriterWith(writer, value, .{});
}

/// Serialize with explicit options to a writer.
pub fn toWriterWith(writer: *compat.Io.Writer, value: anytype, opts: Options) !void {
    var ser = Serializer.init(writer, opts);
    try core_serialize.serialize(@TypeOf(value), value, &ser, .{});
}

pub const PrettyOptions = struct { indent: u8 = 4 };

/// Serialize a value as pretty-printed ZON to a writer.
pub fn toPrettyWriter(writer: *compat.Io.Writer, value: anytype, opts: PrettyOptions) !void {
    return toWriterWith(writer, value, .{ .pretty = true, .indent = opts.indent });
}

// Schema-aware API.

/// Serialize a value to a ZON byte slice with an external schema.
pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    return toSliceWithSchema(allocator, value, .{}, schema);
}

/// Serialize with options and an external schema.
pub fn toSliceWithSchema(allocator: std.mem.Allocator, value: anytype, opt: Options, comptime schema: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try toWriterWithSchema(&aw.writer, value, opt, schema);
    return aw.toOwnedSlice();
}

/// Serialize a value to a writer in ZON format with an external schema.
pub fn toWriterSchema(writer: *compat.Io.Writer, value: anytype, comptime schema: anytype) !void {
    return toWriterWithSchema(writer, value, .{}, schema);
}

/// Serialize with options to a writer with an external schema.
pub fn toWriterWithSchema(writer: *compat.Io.Writer, value: anytype, opt: Options, comptime schema: anytype) !void {
    var ser = Serializer.init(writer, opt);
    try core_serialize.serializeSchema(@TypeOf(value), value, &ser, schema, .{});
}

/// Deserialize a value of type T from a ZON byte slice with an external schema.
pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    var deser = Deserializer.init(input);
    const result = try core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
    try checkTrailingData(&deser);
    return result;
}

/// Deserialize with zero-copy borrowing and an external schema.
pub fn fromSliceBorrowedSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    var deser = Deserializer.initBorrowed(input);
    const result = try core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
    try checkTrailingData(&deser);
    return result;
}

/// Deserialize a value of type T from a ZON byte slice.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    var deser = Deserializer.init(input);
    const result = try core_deserialize.deserialize(T, allocator, &deser, .{});
    try checkTrailingData(&deser);
    return result;
}

/// Deserialize a value of type T from a ZON byte slice, borrowing strings from the input.
/// String fields will point directly into the input buffer — the input must outlive the result.
/// Falls back to error.InvalidEscape if any string contains escape sequences.
/// Still requires an allocator for structs, slices, and other heap-allocated structures.
pub fn fromSliceBorrowed(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    var deser = Deserializer.initBorrowed(input);
    const result = try core_deserialize.deserialize(T, allocator, &deser, .{});
    try checkTrailingData(&deser);
    return result;
}

/// Deserialize a value of type T from a reader.
pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

/// Deserialize a value of type T from a file path.
pub fn fromFilePath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const content = try compat.readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(content);
    return fromSlice(T, allocator, content);
}

fn checkTrailingData(deser: *Deserializer) !void {
    deser.skipWhitespace();
    if (deser.pos != deser.input.len) return error.TrailingData;
}

fn readAll(allocator: std.mem.Allocator, reader: *compat.Io.Reader) ![]u8 {
    return reader.allocRemaining(allocator, compat.Io.Limit.limited(10 * 1024 * 1024)) catch return error.ReadFailed;
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

// Tests.

const testing = std.testing;

test "roundtrip bool" {
    const bytes = try toSliceWith(testing.allocator, true, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("true", bytes);
    const val = try fromSlice(bool, testing.allocator, bytes);
    try testing.expectEqual(true, val);
}

test "roundtrip int" {
    const bytes = try toSliceWith(testing.allocator, @as(i32, -42), .{ .pretty = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("-42", bytes);
    const val = try fromSlice(i32, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, -42), val);
}

test "roundtrip string" {
    const bytes = try toSliceWith(testing.allocator, @as([]const u8, "hello"), .{ .pretty = false });
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello", val);
}

test "roundtrip string with escapes" {
    const original: []const u8 = "line1\nline2\t\"quote";
    const bytes = try toSliceWith(testing.allocator, original, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings(original, val);
}

test "roundtrip struct compact" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSliceWith(testing.allocator, Point{ .x = 10, .y = 20 }, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Point, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 10), val.x);
    try testing.expectEqual(@as(i32, 20), val.y);
}

test "roundtrip struct pretty" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSlice(testing.allocator, Point{ .x = 1, .y = 2 });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Point, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 1), val.x);
    try testing.expectEqual(@as(i32, 2), val.y);
}

test "roundtrip nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const bytes = try toSliceWith(testing.allocator, Outer{ .name = "test", .inner = .{ .val = 42 } }, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqual(@as(i32, 42), val.inner.val);
}

test "roundtrip optional present" {
    const bytes = try toSliceWith(testing.allocator, @as(?i32, 42), .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(?i32, testing.allocator, bytes);
    try testing.expectEqual(@as(?i32, 42), val);
}

test "roundtrip optional null" {
    const bytes = try toSliceWith(testing.allocator, @as(?i32, null), .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(?i32, testing.allocator, bytes);
    try testing.expectEqual(@as(?i32, null), val);
}

test "roundtrip slice" {
    const data: []const i32 = &.{ 1, 2, 3 };
    const bytes = try toSliceWith(testing.allocator, data, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const i32, arena.allocator(), bytes);
    try testing.expectEqualDeep(data, val);
}

test "roundtrip empty slice" {
    const data: []const i32 = &.{};
    const bytes = try toSliceWith(testing.allocator, data, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const i32, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 0), val.len);
}

test "roundtrip enum" {
    const Color = enum { red, green, blue };
    // Enum serializes as string, deserializer handles quoted strings.
    const bytes = try toSliceWith(testing.allocator, Color.blue, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Color, testing.allocator, bytes);
    try testing.expectEqual(Color.blue, val);
}

test "roundtrip struct with all optional fields" {
    const AllOpt = struct {
        a: ?i32 = null,
        b: ?i32 = null,
    };
    const bytes = try toSliceWith(testing.allocator, AllOpt{ .a = null, .b = null }, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(AllOpt, testing.allocator, bytes);
    try testing.expectEqual(@as(?i32, null), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deeply nested struct" {
    const Level3 = struct { val: i32 };
    const Level2 = struct { inner: Level3 };
    const Level1 = struct { inner: Level2 };
    const data = Level1{ .inner = .{ .inner = .{ .val = 7 } } };
    const bytes = try toSliceWith(testing.allocator, data, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Level1, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 7), val.inner.inner.val);
}

test "slice of structs roundtrip" {
    const Item = struct { id: i32 };
    const items: []const Item = &.{ .{ .id = 1 }, .{ .id = 2 } };
    const bytes = try toSliceWith(testing.allocator, items, .{ .pretty = false });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const Item, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), val.len);
    try testing.expectEqual(@as(i32, 1), val[0].id);
    try testing.expectEqual(@as(i32, 2), val[1].id);
}

test "toWriter" {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    try toWriter(&aw.writer, @as(i32, 42));
    const bytes = try aw.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("42", bytes);
}

test "toPrettyWriter" {
    const Point = struct { x: i32, y: i32 };
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    try toPrettyWriter(&aw.writer, Point{ .x = 1, .y = 2 }, .{});
    const bytes = try aw.toOwnedSlice();
    defer testing.allocator.free(bytes);
    // Pretty output should contain newlines.
    try testing.expect(std.mem.indexOf(u8, bytes, "\n") != null);
    const val = try fromSlice(Point, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 1), val.x);
    try testing.expectEqual(@as(i32, 2), val.y);
}

test "toSliceAlloc null-terminated" {
    const bytes = try toSliceAllocWith(testing.allocator, @as(i32, 42), .{ .pretty = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("42", bytes);
    try testing.expectEqual(@as(u8, 0), bytes.ptr[bytes.len]);
}

test "toValue and fromValue" {
    const Point = struct { x: i32, y: i32 };
    const v = try toValue(testing.allocator, Point{ .x = 10, .y = 20 });
    defer v.deinit(testing.allocator);
    const result = try fromValue(Point, testing.allocator, v);
    try testing.expectEqual(@as(i32, 10), result.x);
    try testing.expectEqual(@as(i32, 20), result.y);
}

test "fromReader" {
    const input = ".{.x = 1,.y = 2}";
    var reader: compat.Io.Reader = .fixed(input);
    const Point = struct { x: i32, y: i32 };
    const val = try fromReader(Point, testing.allocator, &reader);
    try testing.expectEqual(@as(i32, 1), val.x);
    try testing.expectEqual(@as(i32, 2), val.y);
}

test "fromSliceBorrowed" {
    const Msg = struct { name: []const u8, id: i32 };
    const input = ".{.name = \"alice\",.id = 1}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSliceBorrowed(Msg, arena.allocator(), input);
    try testing.expectEqualStrings("alice", val.name);
    try testing.expectEqual(@as(i32, 1), val.id);
    // Verify borrowing: pointer falls within input range.
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    const name_ptr = @intFromPtr(val.name.ptr);
    try testing.expect(name_ptr >= input_start and name_ptr < input_end);
}

test "roundtrip union internal tagging" {
    const opts = @import("../../core/options.zig");
    const Command = union(enum) {
        ping: void,
        execute: struct { query: []const u8 },

        pub const serde = .{
            .tag = opts.UnionTag.internal,
            .tag_field = "type",
        };
    };

    const ping: Command = .ping;
    const bytes1 = try toSliceWith(testing.allocator, ping, .{ .pretty = false });
    defer testing.allocator.free(bytes1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deser1 = try fromSlice(Command, arena.allocator(), bytes1);
    try testing.expectEqual(Command.ping, deser1);

    const exec: Command = .{ .execute = .{ .query = "SELECT 1" } };
    const bytes2 = try toSliceWith(testing.allocator, exec, .{ .pretty = false });
    defer testing.allocator.free(bytes2);
    const deser2 = try fromSlice(Command, arena.allocator(), bytes2);
    try testing.expectEqualStrings("SELECT 1", deser2.execute.query);
}

test "roundtrip union adjacent tagging" {
    const opts = @import("../../core/options.zig");
    const Msg = union(enum) {
        ping: void,
        data: i32,

        pub const serde = .{
            .tag = opts.UnionTag.adjacent,
            .tag_field = "t",
            .content_field = "c",
        };
    };

    const ping: Msg = .ping;
    const bytes1 = try toSliceWith(testing.allocator, ping, .{ .pretty = false });
    defer testing.allocator.free(bytes1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deser1 = try fromSlice(Msg, arena.allocator(), bytes1);
    try testing.expectEqual(Msg.ping, deser1);

    const data: Msg = .{ .data = 42 };
    const bytes2 = try toSliceWith(testing.allocator, data, .{ .pretty = false });
    defer testing.allocator.free(bytes2);
    const deser2 = try fromSlice(Msg, arena.allocator(), bytes2);
    try testing.expectEqual(Msg{ .data = 42 }, deser2);
}

test "roundtrip union untagged" {
    const opts = @import("../../core/options.zig");
    const Val = union(enum) {
        num: i32,
        str: []const u8,

        pub const serde = .{
            .tag = opts.UnionTag.untagged,
        };
    };

    const n: Val = .{ .num = 42 };
    const bytes1 = try toSliceWith(testing.allocator, n, .{ .pretty = false });
    defer testing.allocator.free(bytes1);
    const deser1 = try fromSlice(Val, testing.allocator, bytes1);
    try testing.expectEqual(Val{ .num = 42 }, deser1);

    const s: Val = .{ .str = "hello" };
    const bytes2 = try toSliceWith(testing.allocator, s, .{ .pretty = false });
    defer testing.allocator.free(bytes2);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deser2 = try fromSlice(Val, arena.allocator(), bytes2);
    try testing.expectEqualStrings("hello", deser2.str);
}

test "roundtrip tuple" {
    const Tuple = struct { i32, []const u8 };
    const bytes = try toSliceWith(testing.allocator, Tuple{ 42, "hello" }, .{ .pretty = false });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Tuple, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), result[0]);
    try testing.expectEqualStrings("hello", result[1]);
}

test "roundtrip flatten" {
    const Metadata = struct {
        created_by: []const u8,
        version: i32 = 1,
    };
    const User = struct {
        name: []const u8,
        meta: Metadata,

        pub const serde = .{
            .flatten = &[_][]const u8{"meta"},
        };
    };

    const user: User = .{ .name = "Alice", .meta = .{ .created_by = "admin", .version = 2 } };
    const bytes = try toSliceWith(testing.allocator, user, .{ .pretty = false });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqualStrings("Alice", val.name);
    try testing.expectEqualStrings("admin", val.meta.created_by);
    try testing.expectEqual(@as(i32, 2), val.meta.version);
}

test "roundtrip with UnixTimestampMs" {
    const ts = @import("../../helpers/timestamp.zig");
    const Event = struct {
        name: []const u8,
        created_at: i64,

        pub const serde = .{
            .with = .{
                .created_at = ts.UnixTimestampMs,
            },
        };
    };

    const event: Event = .{ .name = "deploy", .created_at = 1700000 };
    const bytes = try toSliceWith(testing.allocator, event, .{ .pretty = false });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Event, arena.allocator(), bytes);
    try testing.expectEqualStrings("deploy", val.name);
    try testing.expectEqual(@as(i64, 1700000), val.created_at);
}

test "roundtrip enum integer repr" {
    const opts = @import("../../core/options.zig");
    const Status = enum(u8) {
        active = 0,
        inactive = 1,
        pending = 2,

        pub const serde = .{
            .enum_repr = opts.EnumRepr.integer,
        };
    };
    const status: Status = .inactive;
    const bytes = try toSliceWith(testing.allocator, status, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("1", bytes);
    const val = try fromSlice(Status, testing.allocator, bytes);
    try testing.expectEqual(Status.inactive, val);
}

test "roundtrip pointer" {
    const val: i32 = 42;
    const ptr: *const i32 = &val;
    const bytes = try toSliceWith(testing.allocator, ptr, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("42", bytes);

    const result = try fromSlice(*const i32, testing.allocator, bytes);
    defer testing.allocator.destroy(result);
    try testing.expectEqual(@as(i32, 42), result.*);
}

test "roundtrip custom zerdeSerialize/zerdeDeserialize" {
    const StringWrappedU64 = struct {
        inner: u64,

        pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{self.inner}) catch unreachable;
            try serializer.serializeString(s);
        }

        pub fn zerdeDeserialize(comptime _: type, allocator: std.mem.Allocator, deserializer: anytype) @TypeOf(deserializer.*).Error!@This() {
            const str = try deserializer.deserializeString(allocator);
            defer allocator.free(str);
            return .{ .inner = std.fmt.parseInt(u64, str, 10) catch return error.InvalidNumber };
        }
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = StringWrappedU64{ .inner = 12345 };
    const bytes = try toSliceWith(testing.allocator, original, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\"12345\"", bytes);

    const result = try fromSlice(StringWrappedU64, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 12345), result.inner);
}

test "deny_unknown_fields" {
    const Strict = struct {
        x: i32,
        pub const serde = .{
            .deny_unknown_fields = true,
        };
    };
    const val = try fromSlice(Strict, testing.allocator, ".{.x = 10}");
    try testing.expectEqual(@as(i32, 10), val.x);

    const result = fromSlice(Strict, testing.allocator, ".{.x = 10,.y = 20}");
    try testing.expectError(error.UnknownField, result);
}

test "serialize skip if null" {
    const serde_opts = @import("../../core/options.zig");
    const Partial = struct {
        name: []const u8,
        email: ?[]const u8,

        pub const serde = .{
            .skip = .{ .email = serde_opts.SkipMode.null },
        };
    };

    const bytes1 = try toSliceWith(testing.allocator, Partial{ .name = "Alice", .email = null }, .{ .pretty = false });
    defer testing.allocator.free(bytes1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "email") == null);

    const bytes2 = try toSliceWith(testing.allocator, Partial{ .name = "Alice", .email = "a@b.c" }, .{ .pretty = false });
    defer testing.allocator.free(bytes2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "email") != null);
}

test "serialize skip if empty" {
    const serde_opts = @import("../../core/options.zig");
    const Tagged = struct {
        id: i32,
        tags: []const []const u8,

        pub const serde = .{
            .skip = .{ .tags = serde_opts.SkipMode.empty },
        };
    };

    const bytes1 = try toSliceWith(testing.allocator, Tagged{ .id = 1, .tags = &.{} }, .{ .pretty = false });
    defer testing.allocator.free(bytes1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "tags") == null);

    const tags: []const []const u8 = &.{"a"};
    const bytes2 = try toSliceWith(testing.allocator, Tagged{ .id = 1, .tags = tags }, .{ .pretty = false });
    defer testing.allocator.free(bytes2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "tags") != null);
}

test "roundtrip fixed array" {
    const arr = [3]i32{ 10, 20, 30 };
    const bytes = try toSliceWith(testing.allocator, arr, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice([3]i32, testing.allocator, bytes);
    try testing.expectEqual(arr, val);
}

test "roundtrip i128" {
    const v: i128 = @as(i128, std.math.maxInt(i64)) + 1;
    const bytes = try toSliceWith(testing.allocator, v, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i128, testing.allocator, bytes);
    try testing.expectEqual(v, val);
}

test "roundtrip u128" {
    const v: u128 = @as(u128, std.math.maxInt(u64)) + 1;
    const bytes = try toSliceWith(testing.allocator, v, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(u128, testing.allocator, bytes);
    try testing.expectEqual(v, val);
}

test "deserialize error: malformed input" {
    const result = fromSlice(i32, testing.allocator, "not_a_number");
    try testing.expectError(error.WrongType, result);
}

test "deserialize error: missing required field" {
    const Req = struct { a: i32, b: i32 };
    const result = fromSlice(Req, testing.allocator, ".{.a = 1}");
    try testing.expectError(error.MissingField, result);
}

test "deserialize error: type mismatch" {
    const result = fromSlice(bool, testing.allocator, "42");
    try testing.expectError(error.WrongType, result);
}
