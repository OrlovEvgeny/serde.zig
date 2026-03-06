const std = @import("std");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");

pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;
pub const Options = serializer_mod.Options;

/// Serialize a value to a JSON byte slice. Caller owns the returned memory.
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

/// Serialize with explicit options.
pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    var ser = Serializer.init(&aw.writer, opts);
    try core_serialize.serialize(@TypeOf(value), value, &ser);
    return aw.toOwnedSlice();
}

/// Deserialize a value of type T from a JSON byte slice.
/// Allocates copies of all strings. Use an ArenaAllocator for easy bulk cleanup.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    var deser = Deserializer.init(input);
    return core_deserialize.deserialize(T, allocator, &deser);
}

// Tests.

const testing = std.testing;

test "roundtrip bool" {
    const bytes = try toSlice(testing.allocator, true);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("true", bytes);
    const val = try fromSlice(bool, testing.allocator, bytes);
    try testing.expectEqual(true, val);
}

test "roundtrip int" {
    const bytes = try toSlice(testing.allocator, @as(i32, -42));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i32, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, -42), val);
}

test "roundtrip string" {
    const bytes = try toSlice(testing.allocator, @as([]const u8, "hello world"));
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello world", val);
}

test "roundtrip string with escapes" {
    const original: []const u8 = "line1\nline2\ttab\"quote";
    const bytes = try toSlice(testing.allocator, original);
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings(original, val);
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

test "roundtrip slice" {
    const data: []const i32 = &.{ 1, 2, 3 };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const i32, arena.allocator(), bytes);
    try testing.expectEqualDeep(data, val);
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
    try testing.expect(std.mem.indexOf(u8, bytes, "\"user_id\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"firstName\"") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 1), val.id);
    try testing.expectEqualStrings("Alice", val.first_name);
}

test "roundtrip struct with default" {
    const Config = struct {
        name: []const u8,
        retries: i32 = 3,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Config, arena.allocator(), "{\"name\":\"app\"}");
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(i32, 3), val.retries);
}

test "struct with skip" {
    const opts = @import("../../core/options.zig");
    const Secret = struct {
        name: []const u8,
        token: []const u8,

        pub const serde = .{
            .skip = .{
                .token = opts.SkipMode.always,
            },
        };
    };

    const bytes = try toSlice(testing.allocator, Secret{ .name = "test", .token = "secret123" });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "token") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "secret123") == null);
}

test "pretty print" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSliceWith(testing.allocator, Point{ .x = 1, .y = 2 }, .{ .pretty = true });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\n  \"x\": 1,\n  \"y\": 2\n}", bytes);
}

test "empty struct" {
    const Empty = struct {};
    const bytes = try toSlice(testing.allocator, Empty{});
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{}", bytes);
    const val = try fromSlice(Empty, testing.allocator, bytes);
    _ = val;
}

test "empty array" {
    const data: []const i32 = &.{};
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("[]", bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const i32, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 0), val.len);
}

test "deeply nested" {
    const Level3 = struct { val: i32 };
    const Level2 = struct { inner: Level3 };
    const Level1 = struct { inner: Level2 };

    const data = Level1{ .inner = .{ .inner = .{ .val = 7 } } };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(Level1, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 7), val.inner.inner.val);
}

test "struct with all optional fields missing" {
    const AllOpt = struct {
        a: ?i32 = null,
        b: ?[]const u8 = null,
    };
    const val = try fromSlice(AllOpt, testing.allocator, "{}");
    try testing.expectEqual(@as(?i32, null), val.a);
    try testing.expectEqual(@as(?[]const u8, null), val.b);
}

test "deserialize error: missing required field" {
    const Req = struct { a: i32, b: i32 };
    const result = fromSlice(Req, testing.allocator, "{\"a\":1}");
    try testing.expectError(error.MissingField, result);
}

test "deserialize error: wrong type" {
    const result = fromSlice(bool, testing.allocator, "42");
    try testing.expectError(error.WrongType, result);
}

test "slice of structs roundtrip" {
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
