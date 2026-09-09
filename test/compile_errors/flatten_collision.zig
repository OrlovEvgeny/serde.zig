const std = @import("std");
const serde = @import("serde");
const T = struct {
    name: i32,
    nested: struct { name: i32 },
    pub const serde = .{ .flatten = &.{"nested"} };
};
pub fn main() !void {
    _ = try serde.json.fromSlice(T, std.heap.page_allocator, "{}");
}
