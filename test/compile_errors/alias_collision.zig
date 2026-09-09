const std = @import("std");
const serde = @import("serde");
const T = struct {
    first: i32,
    second: i32,
    pub const serde = .{ .alias = .{ .first = &.{"second"} } };
};
pub fn main() !void {
    _ = try serde.json.fromSlice(T, std.heap.page_allocator, "{}");
}
