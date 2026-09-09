const std = @import("std");
const serde = @import("serde");
const D = struct {
    pub const Error = serde.json.Deserializer.Error;
    pub const serde_protocol = struct {};
    pub fn deserializeVoid(_: *D) Error!void {
        return error.WrongType;
    }
    pub fn raiseError(_: *D, _: anyerror) Error {
        return error.UnexpectedToken;
    }
};
const U = union(enum) {
    none: void,
    pub const serde = .{ .tag = .untagged };
};
pub fn main() !void {
    var d = D{};
    _ = try serde.deserialize(U, std.heap.page_allocator, &d, .{});
}
