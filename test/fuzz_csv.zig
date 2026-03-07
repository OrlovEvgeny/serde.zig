const std = @import("std");
const serde = @import("serde");

const CsvFuzzTarget = struct {
    name: []const u8,
    age: i32,
    score: f64,
    active: bool,
    email: ?[]const u8,
    count: u64,
    label: []const u8,
};

const SimpleFuzz = struct {
    x: i32,
    y: []const u8,
};

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) callconv(.c) c_int {
    const input = data[0..size];
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Default CSV dialect.
    _ = serde.csv.fromSlice([]const CsvFuzzTarget, a, input) catch {};
    _ = serde.csv.fromSlice([]const SimpleFuzz, a, input) catch {};

    // TSV dialect.
    _ = serde.csv.fromSliceWith([]const CsvFuzzTarget, a, input, serde.csv.tsv_dialect) catch {};

    return 0;
}
