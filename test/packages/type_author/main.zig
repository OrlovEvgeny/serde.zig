const std = @import("std");
const serde = @import("serde");
const Id = struct { raw: u64 };
const IdAdapter = struct {
    pub fn serialize(value: Id, s: anytype) @TypeOf(s.*).Error!void {
        return s.serializeInt(value.raw);
    }
    pub fn deserialize(comptime _: type, allocator: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!Id {
        _ = allocator;
        return .{ .raw = try d.deserializeInt(u64) };
    }
};
const Label = struct {
    number: u8,
    pub fn zerdeDeserialize(comptime _: type, allocator: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!@This() {
        const text = try d.deserializeString(allocator);
        defer serde.core.releaseString(d, allocator, text);
        return .{ .number = std.fmt.parseInt(u8, text, 10) catch return d.raiseError(error.WithFailed) };
    }
};
test "an external adapter survives nested containers" {
    const T = struct { ids: [2]Id };
    const value = T{ .ids = .{ .{ .raw = 1 }, .{ .raw = 2 } } };
    const adapters = .{.{ Id, IdAdapter }};
    var buffer: [16]serde.testing.Token = undefined;
    var s = serde.testing.TokenSerializer.init(std.testing.allocator, &buffer);
    defer s.deinit();
    try serde.serializeWith(T, value, &s, adapters);
    const expected = [_]serde.testing.Token{ .object_begin, .{ .string = "ids" }, .array_begin, .{ .uint = .{ .bits = 64, .value = 1 } }, .{ .uint = .{ .bits = 64, .value = 2 } }, .array_end, .object_end };
    try std.testing.expectEqualDeep(@as([]const serde.testing.Token, &expected), s.tokens());
    var d = serde.testing.TokenDeserializer.init(s.tokens());
    const actual = try serde.deserializeWith(T, std.testing.allocator, &d, adapters);
    try d.finish();
    try std.testing.expectEqualDeep(value, actual);
}
test "custom hooks release both owned and borrowed strings" {
    const owned = try serde.json.fromSlice(Label, std.testing.allocator, "\"42\"");
    const borrowed = try serde.json.fromSliceBorrowed(Label, std.testing.allocator, "\"42\"");
    try std.testing.expectEqual(owned.number, borrowed.number);
}
