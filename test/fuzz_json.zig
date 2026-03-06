const std = @import("std");
const serde = @import("serde");

const FuzzTarget = struct {
    name: []const u8,
    value: i32,
    opt: ?bool,
    tags: []const []const u8,
};

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) c_int {
    const input = data[0..size];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = serde.json.fromSlice(FuzzTarget, arena.allocator(), input) catch {};
    return 0;
}
