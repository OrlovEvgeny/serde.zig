const std = @import("std");
const serde = @import("serde");

const FuzzRow = struct {
    name: []const u8,
    value: i32,
    opt: ?bool,
};

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) c_int {
    const input = data[0..size];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = serde.csv.fromSlice([]const FuzzRow, arena.allocator(), input) catch {};
    return 0;
}
