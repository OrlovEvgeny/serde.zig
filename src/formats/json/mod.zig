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

/// Serialize a value to a writer in JSON format.
pub fn toWriter(writer: *std.io.Writer, value: anytype) !void {
    return toWriterWith(writer, value, .{});
}

/// Serialize with explicit options to a writer.
pub fn toWriterWith(writer: *std.io.Writer, value: anytype, opts: Options) !void {
    var ser = Serializer.init(writer, opts);
    try core_serialize.serialize(@TypeOf(value), value, &ser);
}

/// Serialize a value to a null-terminated JSON byte slice. Caller owns the returned memory.
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

pub const PrettyOptions = struct { indent: u8 = 2 };

/// Serialize a value as pretty-printed JSON to a writer.
pub fn toPrettyWriter(writer: *std.io.Writer, value: anytype, opts: PrettyOptions) !void {
    return toWriterWith(writer, value, .{ .pretty = true, .indent = opts.indent });
}

/// Deserialize a value of type T from a JSON byte slice.
/// Allocates copies of all strings. Use an ArenaAllocator for easy bulk cleanup.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    var deser = Deserializer.init(input);
    return core_deserialize.deserialize(T, allocator, &deser);
}

/// Deserialize a value of type T from a JSON byte slice, borrowing strings from the input.
/// String fields will point directly into the input buffer — the input must outlive the result.
/// Falls back to error.InvalidEscape if any string contains escape sequences.
/// Still requires an allocator for structs, slices, and other heap-allocated structures.
pub fn fromSliceBorrowed(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    var deser = Deserializer.initBorrowed(input);
    return core_deserialize.deserialize(T, allocator, &deser);
}

/// Deserialize a value of type T from a reader.
/// Reads all input into a buffer, then deserializes. Use an ArenaAllocator for easy cleanup.
pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *std.io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

/// Deserialize a value of type T from a file path.
pub fn fromFilePath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);
    return fromSlice(T, allocator, content);
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
    try testing.expectEqualStrings("{\"type\":\"ping\"}", bytes1);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deser1 = try fromSlice(Command, arena.allocator(), bytes1);
    try testing.expectEqual(Command.ping, deser1);

    // Struct variant.
    const exec: Command = .{ .execute = .{ .query = "SELECT 1" } };
    const bytes2 = try toSlice(testing.allocator, exec);
    defer testing.allocator.free(bytes2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "\"type\":\"execute\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2, "\"query\":\"SELECT 1\"") != null);

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
    try testing.expectEqualStrings("{\"t\":\"ping\"}", bytes1);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const deser1 = try fromSlice(Msg, arena.allocator(), bytes1);
    try testing.expectEqual(Msg.ping, deser1);

    const data: Msg = .{ .data = 42 };
    const bytes2 = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes2);
    try testing.expectEqualStrings("{\"t\":\"data\",\"c\":42}", bytes2);

    const deser2 = try fromSlice(Msg, arena.allocator(), bytes2);
    try testing.expectEqual(Msg{ .data = 42 }, deser2);
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
    try testing.expectEqualStrings("1", bytes);
    const val = try fromSlice(Status, testing.allocator, bytes);
    try testing.expectEqual(Status.inactive, val);
}

test "roundtrip struct with 'with' module (UnixTimestampMs)" {
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
    // On the wire, created_at should be in milliseconds.
    try testing.expect(std.mem.indexOf(u8, bytes, "1700000000") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Event, arena.allocator(), bytes);
    try testing.expectEqualStrings("deploy", val.name);
    try testing.expectEqual(@as(i64, 1700000), val.created_at);
}

test "toWriter API" {
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    try toWriter(&aw.writer, @as(i32, 42));
    const bytes = aw.toOwnedSlice() catch unreachable;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("42", bytes);
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

test "roundtrip flatten struct" {
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

    // Flattened: created_by and version appear at top level, not nested.
    try testing.expect(std.mem.indexOf(u8, bytes, "\"created_by\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"version\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"meta\"") == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqualStrings("Alice", val.name);
    try testing.expectEqualStrings("admin", val.meta.created_by);
    try testing.expectEqual(@as(i32, 2), val.meta.version);
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

test "roundtrip empty map" {
    var map = std.StringHashMap(i32).init(testing.allocator);
    defer map.deinit();

    const bytes = try toSlice(testing.allocator, map);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{}", bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var result = try fromSlice(std.StringHashMap(i32), arena.allocator(), bytes);
    try testing.expectEqual(@as(u32, 0), result.count());
}

test "roundtrip untagged union" {
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
    try testing.expectEqualStrings("42", bytes1);
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

test "flatten with defaults" {
    const Extra = struct {
        tag: []const u8 = "",
    };
    const Item = struct {
        id: i32,
        extra: Extra,

        pub const serde = .{
            .flatten = &[_][]const u8{"extra"},
        };
    };

    // Deserialize without the flattened field present.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Item, arena.allocator(), "{\"id\":1}");
    try testing.expectEqual(@as(i32, 1), val.id);
    try testing.expectEqualStrings("", val.extra.tag);
}

test "toSliceAlloc null-terminated" {
    const bytes = try toSliceAlloc(testing.allocator, @as(i32, 42));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("42", bytes);
    try testing.expectEqual(@as(u8, 0), bytes.ptr[bytes.len]);
}

test "toPrettyWriter" {
    const Point = struct { x: i32, y: i32 };
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    try toPrettyWriter(&aw.writer, Point{ .x = 1, .y = 2 }, .{});
    const bytes = try aw.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("{\n  \"x\": 1,\n  \"y\": 2\n}", bytes);
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
    const Point = struct { x: i32, y: i32 };
    const input = "{\"x\":1,\"y\":2}";
    var reader: std.io.Reader = .fixed(input);
    const val = try fromReader(Point, testing.allocator, &reader);
    try testing.expectEqual(@as(i32, 1), val.x);
    try testing.expectEqual(@as(i32, 2), val.y);
}

test "fromSliceBorrowed" {
    const Msg = struct { name: []const u8, id: i32 };
    const input = "{\"name\":\"alice\",\"id\":1}";
    const val = try fromSliceBorrowed(Msg, testing.allocator, input);
    try testing.expectEqualStrings("alice", val.name);
    try testing.expectEqual(@as(i32, 1), val.id);
    // Verify the string borrows from input — pointer falls within input range.
    const input_start = @intFromPtr(input.ptr);
    const input_end = input_start + input.len;
    const name_ptr = @intFromPtr(val.name.ptr);
    try testing.expect(name_ptr >= input_start and name_ptr < input_end);
}

// Scalar type breadth.

test "roundtrip u8" {
    const bytes = try toSlice(testing.allocator, @as(u8, 255));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("255", bytes);
    const val = try fromSlice(u8, testing.allocator, bytes);
    try testing.expectEqual(@as(u8, 255), val);
}

test "roundtrip u64 max" {
    const max = std.math.maxInt(u64);
    const bytes = try toSlice(testing.allocator, max);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(u64, testing.allocator, bytes);
    try testing.expectEqual(max, val);
}

test "roundtrip i64 min and max" {
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |v| {
        const bytes = try toSlice(testing.allocator, v);
        defer testing.allocator.free(bytes);
        const val = try fromSlice(i64, testing.allocator, bytes);
        try testing.expectEqual(v, val);
    }
}

test "roundtrip i8 negative" {
    const bytes = try toSlice(testing.allocator, @as(i8, -128));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i8, testing.allocator, bytes);
    try testing.expectEqual(@as(i8, -128), val);
}

test "roundtrip f32" {
    const bytes = try toSlice(testing.allocator, @as(f32, 1.5));
    defer testing.allocator.free(bytes);
    const val = try fromSlice(f32, testing.allocator, bytes);
    try testing.expectEqual(@as(f32, 1.5), val);
}

test "roundtrip f64 precision" {
    const orig: f64 = 1.23456789012345;
    const bytes = try toSlice(testing.allocator, orig);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(f64, testing.allocator, bytes);
    try testing.expectEqual(orig, val);
}

test "roundtrip zero values" {
    {
        const bytes = try toSlice(testing.allocator, @as(i32, 0));
        defer testing.allocator.free(bytes);
        try testing.expectEqualStrings("0", bytes);
        const val = try fromSlice(i32, testing.allocator, bytes);
        try testing.expectEqual(@as(i32, 0), val);
    }
    {
        const bytes = try toSlice(testing.allocator, @as(f64, 0.0));
        defer testing.allocator.free(bytes);
        const val = try fromSlice(f64, testing.allocator, bytes);
        try testing.expectEqual(@as(f64, 0.0), val);
    }
}

// Float edge cases.

test "serialize NaN to null" {
    const bytes = try toSlice(testing.allocator, std.math.nan(f64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("null", bytes);
}

test "serialize Inf to null" {
    const bytes = try toSlice(testing.allocator, std.math.inf(f64));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("null", bytes);

    const neg_bytes = try toSlice(testing.allocator, -std.math.inf(f64));
    defer testing.allocator.free(neg_bytes);
    try testing.expectEqualStrings("null", neg_bytes);
}

// Error paths.

test "deserialize error: unexpected eof" {
    const result = fromSlice(struct { a: i32 }, testing.allocator, "{\"a\":");
    try testing.expectError(error.UnexpectedEof, result);
}

test "deserialize error: invalid number for float" {
    // "1.2.3" — scanner parses "1.2" as a valid number, then ".3" is trailing data.
    // Instead, test a genuinely unparseable number token fed to parseInt.
    const result = fromSlice(i32, testing.allocator, "99999999999999999999");
    try testing.expectError(error.InvalidNumber, result);
}

test "deserialize error: overflow i8" {
    const result = fromSlice(i8, testing.allocator, "200");
    try testing.expectError(error.InvalidNumber, result);
}

test "deserialize error: wrong type for struct" {
    const Point = struct { x: i32, y: i32 };
    const result = fromSlice(Point, testing.allocator, "[1,2]");
    try testing.expectError(error.WrongType, result);
}

test "deserialize error: invalid json syntax" {
    const result = fromSlice(bool, testing.allocator, "{bad}");
    try testing.expectError(error.WrongType, result);
}

test "deny_unknown_fields in JSON roundtrip" {
    const Strict = struct {
        x: i32,
        pub const serde = .{
            .deny_unknown_fields = true,
        };
    };
    // Known field only — succeeds.
    const val = try fromSlice(Strict, testing.allocator, "{\"x\":10}");
    try testing.expectEqual(@as(i32, 10), val.x);

    // Extra field — fails.
    const result = fromSlice(Strict, testing.allocator, "{\"x\":10,\"y\":20}");
    try testing.expectError(error.UnknownField, result);
}

// Skip conditions.

test "serialize skip if null" {
    const serde_opts = @import("../../core/options.zig");
    const Partial = struct {
        name: []const u8,
        email: ?[]const u8,

        pub const serde = .{
            .skip = .{ .email = serde_opts.SkipMode.@"null" },
        };
    };

    // null — field omitted.
    const bytes1 = try toSlice(testing.allocator, Partial{ .name = "Alice", .email = null });
    defer testing.allocator.free(bytes1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "email") == null);

    // non-null — field present.
    const bytes2 = try toSlice(testing.allocator, Partial{ .name = "Alice", .email = "a@b.c" });
    defer testing.allocator.free(bytes2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "email") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2, "a@b.c") != null);
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

    // empty — field omitted.
    const bytes1 = try toSlice(testing.allocator, Tagged{ .id = 1, .tags = &.{} });
    defer testing.allocator.free(bytes1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "tags") == null);

    // non-empty — field present.
    const tags: []const []const u8 = &.{"a"};
    const bytes2 = try toSlice(testing.allocator, Tagged{ .id = 1, .tags = tags });
    defer testing.allocator.free(bytes2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "tags") != null);
}

// Fixed-length array.

test "roundtrip fixed array" {
    const arr = [3]i32{ 10, 20, 30 };
    const bytes = try toSlice(testing.allocator, arr);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("[10,20,30]", bytes);
    const val = try fromSlice([3]i32, testing.allocator, bytes);
    try testing.expectEqual(arr, val);
}

// Tuple.

test "roundtrip tuple" {
    const Tuple = struct { i32, bool };
    const bytes = try toSlice(testing.allocator, Tuple{ 42, true });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("[42,true]", bytes);
    const val = try fromSlice(Tuple, testing.allocator, bytes);
    try testing.expectEqual(@as(i32, 42), val[0]);
    try testing.expectEqual(true, val[1]);
}

// Pointer dereference.

test "roundtrip pointer" {
    const val: i32 = 42;
    const ptr: *const i32 = &val;
    const bytes = try toSlice(testing.allocator, ptr);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("42", bytes);

    const result = try fromSlice(*const i32, testing.allocator, bytes);
    defer testing.allocator.destroy(result);
    try testing.expectEqual(@as(i32, 42), result.*);
}

// Custom serialization.

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
    const bytes = try toSlice(testing.allocator, original);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\"12345\"", bytes);

    const result = try fromSlice(StringWrappedU64, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 12345), result.inner);
}

// Unicode and string edge cases.

test "roundtrip unicode string" {
    const emoji: []const u8 = "hello 🌍";
    const bytes = try toSlice(testing.allocator, emoji);
    defer testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings(emoji, val);
}

test "roundtrip empty string" {
    const bytes = try toSlice(testing.allocator, @as([]const u8, ""));
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\"\"", bytes);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const u8, arena.allocator(), bytes);
    try testing.expectEqualStrings("", val);
}

// Nested collections.

test "roundtrip slice of strings" {
    const data: []const []const u8 = &.{ "alpha", "beta", "gamma" };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const []const u8, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 3), val.len);
    try testing.expectEqualStrings("alpha", val[0]);
    try testing.expectEqualStrings("beta", val[1]);
    try testing.expectEqualStrings("gamma", val[2]);
}

test "roundtrip nested slices" {
    const data: []const []const i32 = &.{
        &.{ 1, 2, 3 },
        &.{ 4, 5 },
        &.{},
    };
    const bytes = try toSlice(testing.allocator, data);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("[[1,2,3],[4,5],[]]", bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const []const i32, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 3), val.len);
    try testing.expectEqualDeep(@as([]const i32, &.{ 1, 2, 3 }), val[0]);
    try testing.expectEqualDeep(@as([]const i32, &.{ 4, 5 }), val[1]);
    try testing.expectEqual(@as(usize, 0), val[2].len);
}

test "roundtrip i128" {
    const v: i128 = @as(i128, std.math.maxInt(i64)) + 1;
    const bytes = try toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(i128, testing.allocator, bytes);
    try testing.expectEqual(v, val);
}

test "roundtrip u128" {
    const v: u128 = @as(u128, std.math.maxInt(u64)) + 1;
    const bytes = try toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const val = try fromSlice(u128, testing.allocator, bytes);
    try testing.expectEqual(v, val);
}

// Combined serde options.

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
                .opt_note = serde_opts.SkipMode.@"null",
            },
        };
    };

    // Serialize with null opt_note — should be omitted along with secret_key.
    const bytes = try toSlice(testing.allocator, Record{
        .record_id = 42,
        .display_name = "test",
        .secret_key = "s3cret",
        .opt_note = null,
        .retry_count = 3,
    });
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"displayName\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"retryCount\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "secretKey") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "optNote") == null);

    // Deserialize back (without the skipped/omitted fields).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Record, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 42), val.record_id);
    try testing.expectEqualStrings("test", val.display_name);
    try testing.expectEqual(@as(i32, 3), val.retry_count);
    try testing.expectEqual(@as(?[]const u8, null), val.opt_note);
}
