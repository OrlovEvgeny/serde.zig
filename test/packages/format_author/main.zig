const std = @import("std");
const serde = @import("serde");
const format = @import("format.zig");
test "a backend with independent state names implements the public contract" {
    comptime {
        serde.core.assertSerializer(format.Serializer);
        serde.core.assertDeserializer(format.Deserializer);
    }
    const T = struct { name: []const u8, values: []const i32, active: ?bool };
    const value = T{ .name = "hello\nworld", .values = &.{ -1, 2 }, .active = true };
    var writer: serde.compat.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    var s = format.Serializer.init(&writer.writer);
    try serde.serialize(T, value, &s, .{});
    try std.testing.expectEqualStrings("{\ns4:name\ns11:hello\nworld\ns6:values\n[\ni32:-1\ni32:2\n]\ns6:active\ntrue\n}\n", writer.written());
    var d = format.Deserializer.init(writer.written());
    const result = try serde.deserialize(T, std.testing.allocator, &d, .{});
    defer serde.core.freeAllocated(T, result, std.testing.allocator);
    try d.finish();
    try std.testing.expectEqualDeep(value, result);
}
test "explicit checkpoints replay an untagged union" {
    const U = union(enum) {
        flag: bool,
        number: i32,
        pub const serde = .{ .tag = .untagged };
    };
    var d = format.Deserializer.init("i32:42\n");
    const value = try serde.deserialize(U, std.testing.allocator, &d, .{});
    try d.finish();
    try std.testing.expectEqual(@as(i32, 42), value.number);
}
