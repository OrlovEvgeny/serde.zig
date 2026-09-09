//! MessagePack serialization and deserialization.
//!
//! Compact binary format. Serialize with `toSlice` / `toWriter`, and
//! deserialize with `fromSlice` / `fromReader`.

const std = @import("std");
const compat = @import("compat");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");

pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;

/// Serialize a value to a MessagePack byte slice. Caller owns the returned memory.
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var ser = Serializer.init(&aw.writer, allocator);
    try core_serialize.serialize(@TypeOf(value), value, &ser, .{});
    return aw.toOwnedSlice();
}

/// Serialize a value to a null-terminated MessagePack byte slice. Caller owns the returned memory.
pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    const bytes = try toSlice(allocator, value);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

/// Serialize a value to a writer in MessagePack format.
///
/// Containers whose length is known up front are streamed straight to `writer`
/// rather than staged in memory, so a serialization error can leave a partially
/// written value behind. Write into a buffer first if the sink must only ever
/// see complete documents.
pub fn toWriter(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype) !void {
    var ser = Serializer.init(writer, allocator);
    try core_serialize.serialize(@TypeOf(value), value, &ser, .{});
}

// Schema-aware API.

/// Serialize a value to a MessagePack byte slice with an external schema.
pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var ser = Serializer.init(&aw.writer, allocator);
    try core_serialize.serializeSchema(@TypeOf(value), value, &ser, schema, .{});
    return aw.toOwnedSlice();
}

/// Serialize a value to a writer in MessagePack format with an external schema.
/// Streams like `toWriter`, with the same partial-write caveat.
pub fn toWriterSchema(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, comptime schema: anytype) !void {
    var ser = Serializer.init(writer, allocator);
    try core_serialize.serializeSchema(@TypeOf(value), value, &ser, schema, .{});
}

/// Deserialize a value of type T from a MessagePack byte slice with an external schema.
pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    var deser = Deserializer.init(input);
    const result = try core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
    errdefer core_deserialize.freeAllocatedSchema(T, result, allocator, schema);
    if (deser.pos != deser.input.len) return error.TrailingData;
    return result;
}

/// Deserialize from a reader with an external schema.
pub fn fromReaderSchema(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, comptime schema: anytype) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceSchema(T, allocator, buf, schema);
}

/// Deserialize a value of type T from a MessagePack byte slice.
/// Allocates copies of all strings and slices. Use an ArenaAllocator for easy cleanup.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    var deser = Deserializer.init(input);
    const result = try core_deserialize.deserialize(T, allocator, &deser, .{});
    errdefer core_deserialize.freeAllocated(T, result, allocator);
    if (deser.pos != deser.input.len) return error.TrailingData;
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

/// Parse into a result that owns a separate arena. Release it with `.deinit()`.
pub fn fromSliceManaged(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !@import("../../core/parsed.zig").Parsed(T) {
    return fromSliceManagedSchema(T, allocator, input, {});
}

/// Parse with an external schema into an owning result.
pub fn fromSliceManagedSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !@import("../../core/parsed.zig").Parsed(T) {
    return @import("../../core/parsed.zig").parse(T, allocator, input, schema, @This());
}

// Tests.

const testing = std.testing;

test "roundtrip bool" {
    const bytes = try toSlice(testing.allocator, true);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(bool, testing.allocator, bytes);
    try testing.expectEqual(true, val);
}

test "roundtrip int" {
    const bytes = try toSlice(testing.allocator, @as(i32, -42));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i32, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, -42), val);
}

test "roundtrip u8" {
    const bytes = try toSlice(testing.allocator, @as(u8, 200));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(u8, testing.allocator, bytes);
    try testing.expectEqual(@as(u8, 200), val);
}

test "roundtrip u64 large" {
    const v: u64 = 0xdeadbeefcafe1234;
    const bytes = try toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(u64, testing.allocator, bytes);
    try testing.expectEqual(v, val);
}

test "roundtrip zero" {
    const bytes = try toSlice(testing.allocator, @as(i32, 0));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i32, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 0), val);
}

test "roundtrip string" {
    const bytes = try toSlice(testing.allocator, @as([]const u8, "hello world"));
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello world", val);
}

test "roundtrip empty string" {
    const bytes = try toSlice(testing.allocator, @as([]const u8, ""));
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings("", val);
}

test "roundtrip float32" {
    const bytes = try toSlice(testing.allocator, @as(f32, 1.5));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(f32, testing.allocator, bytes);
    try testing.expect(@abs(val - 1.5) < 0.001);
}

test "roundtrip float64" {
    const bytes = try toSlice(testing.allocator, @as(f64, 3.14));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(f64, testing.allocator, bytes);
    try testing.expect(@abs(val - 3.14) < 0.001);
}

test "roundtrip optional present" {
    const bytes = try toSlice(testing.allocator, @as(?i32, 42));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(?i32, testing.allocator, bytes);
    try testing.expectEqual(@as(?i32, 42), val);
}

test "roundtrip optional null" {
    const bytes = try toSlice(testing.allocator, @as(?i32, null));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(?i32, testing.allocator, bytes);
    try testing.expectEqual(@as(?i32, null), val);
}

test "roundtrip struct" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSlice(testing.allocator, Point{ .x = 10, .y = 20 });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Point, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 10), val.x);
    try testing.expectEqual(@as(i32, 20), val.y);
}

test "roundtrip nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };

    const bytes = try toSlice(testing.allocator, Outer{ .name = "test", .inner = .{ .val = 42 } });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqual(@as(i32, 42), val.inner.val);
}

test "known-length nested containers" {
    const Entry = struct {
        name: []const u8,
        values: []const u16,
    };
    const Document = struct {
        entries: []const Entry,
    };
    const document = Document{ .entries = &.{
        .{ .name = "first", .values = &.{ 1, 2, 3 } },
        .{ .name = "second", .values = &.{ 4, 5 } },
    } };

    const bytes = try toSlice(testing.allocator, document);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{
        0x81, 0xa7, 'e',  'n',  't',  'r', 'i',  'e',  's',
        0x92, 0x82, 0xa4, 'n',  'a',  'm', 'e',  0xa5, 'f',
        'i',  'r',  's',  't',  0xa6, 'v', 'a',  'l',  'u',
        'e',  's',  0x93, 1,    2,    3,   0x82, 0xa4, 'n',
        'a',  'm',  'e',  0xa6, 's',  'e', 'c',  'o',  'n',
        'd',  0xa6, 'v',  'a',  'l',  'u', 'e',  's',  0x92,
        4,    5,
    }, bytes);
}

test "roundtrip nested containers" {
    const Entry = struct {
        name: []const u8,
        values: []const i32,
    };
    const Document = struct {
        entries: []const Entry,
    };
    const document = Document{ .entries = &.{
        .{ .name = "first", .values = &.{ 1, 2, 3 } },
        .{ .name = "second", .values = &.{ 4, 5 } },
    } };

    const bytes = try toSlice(testing.allocator, document);
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try fromSlice(Document, arena.allocator(), bytes);
    try testing.expectEqualDeep(document, decoded);
}

test "known-length array16" {
    const values: [16]u8 = @splat(0);
    const bytes = try toSlice(testing.allocator, values);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0xdc, 0, 16 }, bytes[0..3]);
}

test "roundtrip struct with optional field" {
    const Config = struct {
        name: []const u8,
        retries: ?i32 = null,
    };

    const bytes = try toSlice(testing.allocator, Config{ .name = "app", .retries = null });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Config, arena.allocator(), bytes);
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(?i32, null), val.retries);
}

test "roundtrip slice of ints" {
    const data: []const i32 = &.{ 1, 2, 3, 4 };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const i32, arena.allocator(), bytes);
    try testing.expectEqualDeep(data, val);
}

test "roundtrip empty slice" {
    const data: []const i32 = &.{};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const i32, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 0), val.len);
}

test "roundtrip array" {
    const bytes = try toSlice(testing.allocator, [3]i32{ 10, 20, 30 });
    defer testing.allocator.free(bytes);
    const val = try fromSlice([3]i32, testing.allocator, bytes);
    try testing.expectEqual([3]i32{ 10, 20, 30 }, val);
}

test "roundtrip enum" {
    const Color = enum { red, green, blue };
    const bytes = try toSlice(testing.allocator, Color.blue);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Color, testing.allocator, bytes);
    try testing.expectEqual(Color.blue, val);
}

test "roundtrip union void variant" {
    const Cmd = union(enum) { ping: void, quit: void };
    const bytes = try toSlice(testing.allocator, Cmd.ping);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Cmd, testing.allocator, bytes);
    try testing.expectEqual(Cmd.ping, val);
}

test "roundtrip union with payload" {
    const Cmd = union(enum) { set: i32, ping: void };
    const bytes = try toSlice(testing.allocator, Cmd{ .set = 99 });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Cmd, testing.allocator, bytes);
    try testing.expectEqual(Cmd{ .set = 99 }, val);
}

test "roundtrip struct with serde rename" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        const opts = @import("../../core/options.zig");
        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = opts.NamingConvention.camel_case,
        };
    };

    const bytes = try toSlice(testing.allocator, User{ .id = 1, .first_name = "Alice" });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 1), val.id);
    try testing.expectEqualStrings("Alice", val.first_name);
}

test "roundtrip struct with skip" {
    const opts = @import("../../core/options.zig");
    const Secret = struct {
        name: []const u8,
        token: []const u8 = "",

        pub const serde = .{
            .skip = .{
                .token = opts.SkipMode.always,
            },
        };
    };

    const bytes = try toSlice(testing.allocator, Secret{ .name = "test", .token = "secret123" });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Secret, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqualStrings("", val.token);
}

test "roundtrip struct with default" {
    const Config = struct {
        name: []const u8,
        retries: i32 = 3,
    };

    // Serialize only the name field by encoding manually
    // (the default won't be serialized if we use a struct with both fields).
    // Actually, both fields serialize. On deser, if retries is present, it's read.
    const bytes = try toSlice(testing.allocator, Config{ .name = "app", .retries = 5 });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Config, arena.allocator(), bytes);
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(i32, 5), val.retries);
}

test "roundtrip empty struct" {
    const Empty = struct {};
    const bytes = try toSlice(testing.allocator, Empty{});
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Empty, testing.allocator, bytes);
    _ = val;
}

test "roundtrip slice of structs" {
    const Item = struct { id: i32 };
    const items: []const Item = &.{ .{ .id = 1 }, .{ .id = 2 } };
    const bytes = try toSlice(testing.allocator, items);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const Item, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), val.len);
    try testing.expectEqual(@as(i32, 1), val[0].id);
    try testing.expectEqual(@as(i32, 2), val[1].id);
}

test "roundtrip max int values" {
    const max_u64 = std.math.maxInt(u64);
    const bytes = try toSlice(testing.allocator, max_u64);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(u64, testing.allocator, bytes);
    try testing.expectEqual(max_u64, val);
}

test "roundtrip min int values" {
    const min_i64 = std.math.minInt(i64);
    const bytes = try toSlice(testing.allocator, @as(i64, min_i64));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i64, testing.allocator, bytes);
    try testing.expectEqual(@as(i64, min_i64), val);
}

test "roundtrip nan float" {
    const bytes = try toSlice(testing.allocator, std.math.nan(f64));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(f64, testing.allocator, bytes);
    try testing.expect(std.math.isNan(val));
}

test "roundtrip inf float" {
    const bytes = try toSlice(testing.allocator, std.math.inf(f64));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(f64, testing.allocator, bytes);
    try testing.expect(std.math.isInf(val));
}

test "toWriter API" {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    try toWriter(testing.allocator, &aw.writer, @as(i32, 42));
    const bytes = aw.toOwnedSlice() catch unreachable;
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i32, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 42), val);
}

test "binary data roundtrip" {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    var ser = serializer_mod.Serializer.init(&aw.writer, testing.allocator);
    try ser.serializeBytes("binary\x00data");
    const bytes = aw.toOwnedSlice() catch unreachable;
    defer testing.allocator.free(bytes);

    var deser = deserializer_mod.Deserializer.init(bytes);
    const result = try deser.deserializeBytes(testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("binary\x00data", result);
}

test "deeply nested struct" {
    const Level3 = struct { val: i32 };
    const Level2 = struct { inner: Level3 };
    const Level1 = struct { inner: Level2 };

    const data = Level1{ .inner = .{ .inner = .{ .val = 7 } } };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Level1, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 7), val.inner.inner.val);
}

test "toSliceAlloc null-terminated" {
    const bytes = try toSliceAlloc(testing.allocator, @as(i32, 42));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u8, 0), bytes.ptr[bytes.len]);
    const val = try fromSlice(i32, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 42), val);
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
    const bytes = try toSlice(testing.allocator, @as(i32, 42));
    defer testing.allocator.free(bytes);
    var reader: compat.Io.Reader = .fixed(bytes);
    const val = try fromReader(i32, testing.allocator, &reader);
    try testing.expectEqual(@as(i32, 42), val);
}

test "known-length union headers" {
    const opts = @import("../../core/options.zig");

    const External = union(enum) { ping: void, set: i32 };
    const ext = try toSlice(testing.allocator, External{ .set = 5 });
    defer testing.allocator.free(ext);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xa3, 's', 'e', 't', 5 }, ext);

    const Internal = union(enum) {
        ping: void,
        pair: struct { a: u8, b: u8 },

        pub const serde = .{ .tag = opts.UnionTag.internal, .tag_field = "type" };
    };
    const internal_ping: Internal = .ping;
    const int_void = try toSlice(testing.allocator, internal_ping);
    defer testing.allocator.free(int_void);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xa4, 't', 'y', 'p', 'e', 0xa4, 'p', 'i', 'n', 'g' }, int_void);

    const int_pair = try toSlice(testing.allocator, Internal{ .pair = .{ .a = 1, .b = 2 } });
    defer testing.allocator.free(int_pair);
    try testing.expectEqual(@as(u8, 0x83), int_pair[0]);

    const Adjacent = union(enum) {
        ping: void,
        data: i32,

        pub const serde = .{ .tag = opts.UnionTag.adjacent, .tag_field = "t", .content_field = "c" };
    };
    const adjacent_ping: Adjacent = .ping;
    const adj_void = try toSlice(testing.allocator, adjacent_ping);
    defer testing.allocator.free(adj_void);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xa1, 't', 0xa4, 'p', 'i', 'n', 'g' }, adj_void);

    const adj_data = try toSlice(testing.allocator, Adjacent{ .data = 42 });
    defer testing.allocator.free(adj_data);
    try testing.expectEqualSlices(u8, &.{ 0x82, 0xa1, 't', 0xa4, 'd', 'a', 't', 'a', 0xa1, 'c', 42 }, adj_data);
}

test "known-length map header" {
    var map = std.StringHashMap(u8).init(testing.allocator);
    defer map.deinit();
    try map.put("k", 1);

    const bytes = try toSlice(testing.allocator, map);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xa1, 'k', 1 }, bytes);

    var empty = std.StringHashMap(u8).init(testing.allocator);
    defer empty.deinit();
    const empty_bytes = try toSlice(testing.allocator, empty);
    defer testing.allocator.free(empty_bytes);
    try testing.expectEqualSlices(u8, &.{0x80}, empty_bytes);
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
    const bytes1 = try toSlice(testing.allocator, ping);
    defer testing.allocator.free(bytes1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deser1 = try fromSlice(Command, arena.allocator(), bytes1);
    try testing.expectEqual(Command.ping, deser1);

    const exec: Command = .{ .execute = .{ .query = "SELECT 1" } };
    const bytes2 = try toSlice(testing.allocator, exec);
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
    const bytes1 = try toSlice(testing.allocator, ping);
    defer testing.allocator.free(bytes1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deser1 = try fromSlice(Msg, arena.allocator(), bytes1);
    try testing.expectEqual(Msg.ping, deser1);

    const data: Msg = .{ .data = 42 };
    const bytes2 = try toSlice(testing.allocator, data);
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
    const bytes1 = try toSlice(testing.allocator, n);
    defer testing.allocator.free(bytes1);
    const deser1 = try fromSlice(Val, testing.allocator, bytes1);
    try testing.expectEqual(Val{ .num = 42 }, deser1);

    const s: Val = .{ .str = "hello" };
    const bytes2 = try toSlice(testing.allocator, s);
    defer testing.allocator.free(bytes2);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deser2 = try fromSlice(Val, arena.allocator(), bytes2);
    try testing.expectEqualStrings("hello", deser2.str);
}

test "roundtrip StringHashMap" {
    var map = std.StringHashMap(i32).init(testing.allocator);
    defer map.deinit();
    try map.put("a", 1);
    try map.put("b", 2);

    const bytes = try toSlice(testing.allocator, map);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var result = try fromSlice(std.StringHashMap(i32), arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 1), result.get("a").?);
    try testing.expectEqual(@as(i32, 2), result.get("b").?);
}

test "roundtrip tuple" {
    const Tuple = struct { i32, []const u8 };
    const bytes = try toSlice(testing.allocator, Tuple{ 42, "hello" });
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
    const bytes = try toSlice(testing.allocator, user);
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
    const bytes = try toSlice(testing.allocator, event);
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
    const bytes = try toSlice(testing.allocator, status);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Status, testing.allocator, bytes);
    try testing.expectEqual(Status.inactive, val);
}

test "roundtrip pointer" {
    const val: i32 = 42;
    const ptr: *const i32 = &val;
    const bytes = try toSlice(testing.allocator, ptr);
    defer testing.allocator.free(bytes);

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
            return .{ .inner = std.fmt.parseInt(u64, str, 10) catch return error.WrongType };
        }
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const original = StringWrappedU64{ .inner = 12345 };
    const bytes = try toSlice(testing.allocator, original);
    defer testing.allocator.free(bytes);
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
    const bytes = try toSlice(testing.allocator, Strict{ .x = 10 });
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Strict, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 10), val.x);
}

test "skip nested unknown field" {
    const Document = struct { id: u8 };
    const bytes = [_]u8{
        0x82,
        0xa2,
        'i',
        'd',
        1,
        0xa5,
        'e',
        'x',
        't',
        'r',
        'a',
        0x91,
        0x81,
        0xa1,
        'x',
        0x92,
        2,
        3,
    };
    const value = try fromSlice(Document, testing.allocator, &bytes);
    try testing.expectEqual(@as(u8, 1), value.id);
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

    const bytes1 = try toSlice(testing.allocator, Partial{ .name = "Alice", .email = null });
    defer testing.allocator.free(bytes1);
    const bytes2 = try toSlice(testing.allocator, Partial{ .name = "Alice", .email = "a@b.c" });
    defer testing.allocator.free(bytes2);

    // Verify the non-null version is longer (contains the email field).
    try testing.expect(bytes2.len > bytes1.len);
}

test "skip null map count" {
    const serde_opts = @import("../../core/options.zig");
    const Partial = struct {
        name: []const u8,
        email: ?[]const u8,

        pub const serde = .{
            .skip = .{ .email = serde_opts.SkipMode.null },
        };
    };

    const bytes = try toSlice(testing.allocator, Partial{ .name = "alice", .email = null });
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xa4, 'n', 'a', 'm', 'e', 0xa5, 'a', 'l', 'i', 'c', 'e' }, bytes);
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

    const bytes1 = try toSlice(testing.allocator, Tagged{ .id = 1, .tags = &.{} });
    defer testing.allocator.free(bytes1);
    const tags: []const []const u8 = &.{"a"};
    const bytes2 = try toSlice(testing.allocator, Tagged{ .id = 1, .tags = tags });
    defer testing.allocator.free(bytes2);
    try testing.expect(bytes2.len > bytes1.len);
}

test "roundtrip unicode string" {
    const emoji: []const u8 = "hello 🌍";
    const bytes = try toSlice(testing.allocator, emoji);
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings(emoji, val);
}

test "struct with combined serde options" {
    const serde_opts = @import("../../core/options.zig");
    const Record = struct {
        record_id: u64,
        display_name: []const u8,
        secret_key: []const u8 = "",
        opt_note: ?[]const u8,
        retry_count: i32 = 5,

        pub const serde = .{
            .rename = .{ .record_id = "id" },
            .rename_all = serde_opts.NamingConvention.camel_case,
            .skip = .{
                .secret_key = serde_opts.SkipMode.always,
                .opt_note = serde_opts.SkipMode.null,
            },
        };
    };

    const bytes = try toSlice(testing.allocator, Record{
        .record_id = 42,
        .display_name = "test",
        .secret_key = "s3cret",
        .opt_note = null,
        .retry_count = 3,
    });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Record, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 42), val.record_id);
    try testing.expectEqualStrings("test", val.display_name);
    try testing.expectEqual(@as(i32, 3), val.retry_count);
    try testing.expectEqual(@as(?[]const u8, null), val.opt_note);
}

test "roundtrip i128 within i64 range" {
    const v: i128 = 123456;
    const bytes = try toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i128, testing.allocator, bytes);
    try testing.expectEqual(v, val);
}

test "deserialize error: truncated input" {
    const result = fromSlice(i32, testing.allocator, &.{ 0xce, 0x12 });
    try testing.expectError(error.UnexpectedEof, result);
}

test "deserialize error: oversized array length" {
    const input = [_]u8{ 0xdd, 0xff, 0xff, 0xff, 0xff, 0x01 };
    const result = fromSlice([]const i32, testing.allocator, &input);
    try testing.expectError(error.UnexpectedEof, result);
}

test "deserialize error: oversized map length" {
    const Partial = struct { a: i32 };
    const input = [_]u8{ 0xdf, 0xff, 0xff, 0xff, 0xff };
    const result = fromSlice(Partial, testing.allocator, &input);
    try testing.expectError(error.UnexpectedEof, result);
}

test "deserialize error: missing required field" {
    // Encode a map with only one key, deserialize into struct with two required fields.
    const Partial = struct { a: i32 };
    const bytes = try toSlice(testing.allocator, Partial{ .a = 1 });
    defer testing.allocator.free(bytes);

    const Full = struct { a: i32, b: i32 };
    const result = fromSlice(Full, testing.allocator, bytes);
    try testing.expectError(error.MissingField, result);
}

test "deserialize error: type mismatch" {
    // Encode a bool, try to deserialize as struct.
    const bytes = try toSlice(testing.allocator, true);
    defer testing.allocator.free(bytes);
    const Point = struct { x: i32 };
    const result = fromSlice(Point, testing.allocator, bytes);
    try testing.expectError(error.WrongType, result);
}
