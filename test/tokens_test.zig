const std = @import("std");
const serde = @import("serde");
const t = serde.testing;
const Token = t.Token;
const A = std.testing.allocator;

test "tokens preserve numeric sign width and wide values" {
    comptime {
        serde.core.assertSerializer(t.TokenSerializer);
        serde.core.assertDeserializer(t.TokenDeserializer);
    }
    try t.expectSerialize(@as(i128, std.math.minInt(i128)), &.{.{ .int = .{ .bits = 128, .value = std.math.minInt(i128) } }});
    try t.expectDeserialize(u128, std.math.maxInt(u128), &.{.{ .uint = .{ .bits = 128, .value = std.math.maxInt(u128) } }});
    try t.expectSerialize(@as(f128, 1.25), &.{.{ .float = .{ .bits = 128, .value = 1.25 } }});
    var d = t.TokenDeserializer.init(&.{.{ .uint = .{ .bits = 16, .value = 1 } }});
    try std.testing.expectError(error.WrongType, d.deserializeInt(u8));
}

test "tokens exact container boundaries optional and union" {
    const U = union(enum) { n: u16, empty: void };
    const T = struct { enabled: bool, value: ?u8, u: U };
    const value = T{ .enabled = true, .value = null, .u = .{ .n = 7 } };
    const events = [_]Token{ .object_begin, .{ .string = "enabled" }, .{ .boolean = true }, .{ .string = "value" }, .null, .{ .string = "u" }, .object_begin, .{ .string = "n" }, .{ .uint = .{ .bits = 16, .value = 7 } }, .object_end, .object_end };
    try t.expectSerialize(value, &events);
    try t.expectDeserialize(T, value, &events);
    try t.expectSerialize(@as(?bool, true), &.{.{ .boolean = true }});
    try t.expectDeserialize(?bool, true, &.{.{ .boolean = true }});
    try t.expectSerialize(U.empty, &.{.{ .string = "empty" }});
    try t.expectDeserialize(U, .empty, &.{.{ .string = "empty" }});
}

const Wrapped = struct { n: u16 };
const Adapter = struct {
    pub fn serialize(v: Wrapped, s: anytype) @TypeOf(s.*).Error!void {
        return s.serializeInt(v.n);
    }
    pub fn deserialize(comptime _: type, a: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!Wrapped {
        _ = a;
        return .{ .n = try d.deserializeInt(u16) };
    }
};

test "tokens external schema flatten aliases and nested adapters" {
    const T = struct { inner: struct { count: u16 }, list: []const Wrapped };
    const schema = .{ .flatten = &.{"inner"}, .rename = .{ .list = "values" }, .alias = .{ .list = &.{"old"} } };
    const adapters = .{.{ Wrapped, Adapter }};
    const value = T{ .inner = .{ .count = 3 }, .list = &.{.{ .n = 9 }} };
    var buffer: [20]Token = undefined;
    var s = t.TokenSerializer.init(A, &buffer);
    defer s.deinit();
    try serde.serializeSchema(T, value, &s, schema, adapters);
    const expected = [_]Token{ .object_begin, .{ .string = "count" }, .{ .uint = .{ .bits = 16, .value = 3 } }, .{ .string = "values" }, .array_begin, .{ .uint = .{ .bits = 16, .value = 9 } }, .array_end, .object_end };
    try std.testing.expectEqualDeep(@as([]const Token, &expected), s.tokens());
    var aliased = expected;
    aliased[3] = .{ .string = "old" };
    var d = t.TokenDeserializer.init(&aliased);
    const result = try serde.deserializeSchema(T, A, &d, schema, adapters);
    defer serde.core.freeAllocated(T, result, A);
    try d.finish();
    try std.testing.expectEqualDeep(value, result);
}

test "tokens reject missing boundaries and trailing events" {
    var d = t.TokenDeserializer.init(&.{ .array_begin, .{ .boolean = true } });
    try std.testing.expectError(error.UnexpectedEof, serde.deserialize([]const bool, A, &d, .{}));
    d = t.TokenDeserializer.init(&.{ .{ .boolean = true }, .null });
    _ = try d.deserializeBool();
    try std.testing.expectError(error.UnexpectedToken, d.finish());
    d = t.TokenDeserializer.init(&.{ .object_begin, .{ .string = "unknown" }, .array_end, .object_end });
    try std.testing.expectError(error.UnexpectedToken, serde.deserialize(struct {}, A, &d, .{}));
}

test "tokens own strings emitted from scratch buffers and hooks" {
    var buffer: [4]Token = undefined;
    var s = t.TokenSerializer.init(A, &buffer);
    defer s.deinit();
    var scratch = [_]u8{ 'o', 'l', 'd' };
    try s.serializeString(&scratch);
    @memset(&scratch, 'x');
    try std.testing.expectEqualStrings("old", s.tokens()[0].string);
    const Hook = struct {
        value: u8,
        pub fn zerdeSerialize(v: @This(), serializer: anytype) @TypeOf(serializer.*).Error!void {
            var temporary: [3]u8 = undefined;
            const text = std.fmt.bufPrint(&temporary, "{d}", .{v.value}) catch unreachable;
            return serializer.serializeString(text);
        }
    };
    try t.expectSerialize(Hook{ .value = 123 }, &.{.{ .string = "123" }});
}

fn tokenAllocationFailures(allocator: std.mem.Allocator) !void {
    var buffer: [4]Token = undefined;
    var s = t.TokenSerializer.init(allocator, &buffer);
    defer s.deinit();
    try serde.serialize(struct { text: []const u8 }, .{ .text = "owned" }, &s, .{});
}
test "tokens release string copies after allocation and capacity failures" {
    try std.testing.checkAllAllocationFailures(A, tokenAllocationFailures, .{});
    var buffer: [0]Token = .{};
    var s = t.TokenSerializer.init(A, &buffer);
    defer s.deinit();
    try std.testing.expectError(error.OutOfMemory, s.serializeString("owned"));
}
