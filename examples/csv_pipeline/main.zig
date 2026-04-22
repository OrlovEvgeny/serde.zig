const std = @import("std");
const serde = @import("serde");

const Employee = struct {
    id: u32,
    name: []const u8,
    department: []const u8,
    salary: f64,
    remote: bool,
    manager: ?[]const u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const file = try serde.compat.openFileForRead("examples/csv_pipeline/employees.csv");
    defer serde.compat.closeFile(file);
    var file_buf: [65536]u8 = undefined;
    var file_reader = serde.compat.fileReaderStreaming(file, &file_buf);
    const csv_input = try serde.compat.readerAllocRemaining(&file_reader, allocator, .unlimited);
    defer allocator.free(csv_input);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    std.debug.print("=== Streaming CSV rows ===\n", .{});
    var stream = try serde.csv.streamingDeserializer([]const Employee, arena.allocator(), csv_input);
    defer stream.deinit();

    var total_count: u32 = 0;
    var total_salary: f64 = 0.0;
    var dept_counts = std.StringHashMap(u32).init(allocator);
    defer {
        var dit = dept_counts.iterator();
        while (dit.next()) |e| allocator.free(e.key_ptr.*);
        dept_counts.deinit();
    }

    while (try stream.next()) |emp| {
        total_count += 1;
        total_salary += emp.salary;

        const gop = try dept_counts.getOrPut(emp.department);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, emp.department);
            gop.value_ptr.* = 1;
        } else {
            gop.value_ptr.* += 1;
        }

        std.debug.print("  [{d}] {s} - {s} (${d:.2}) remote={any}", .{
            emp.id,
            emp.name,
            emp.department,
            emp.salary,
            emp.remote,
        });
        if (emp.manager) |m| std.debug.print(" manager={s}", .{m});
        std.debug.print("\n", .{});
    }

    const avg_salary = if (total_count > 0) total_salary / @as(f64, @floatFromInt(total_count)) else 0.0;
    std.debug.print("\n=== Aggregate Stats ===\n", .{});
    std.debug.print("Total employees: {}\n", .{total_count});
    std.debug.print("Average salary:  ${d:.2}\n", .{avg_salary});
    std.debug.print("By department:\n", .{});
    var dept_it = dept_counts.iterator();
    while (dept_it.next()) |e|
        std.debug.print("  {s}: {}\n", .{ e.key_ptr.*, e.value_ptr.* });

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const all_emps = try serde.csv.fromSlice([]const Employee, arena2.allocator(), csv_input);
    const json_out = try serde.json.toSliceWith(allocator, all_emps, .{ .pretty = true });
    defer allocator.free(json_out);
    std.debug.print("\n=== All employees as JSON ===\n{s}\n", .{json_out});

    const TsvRow = struct { name: []const u8, score: i32 };
    const tsv_data = "name\tscore\nAlice\t95\nBob\t87\n";
    var arena3 = std.heap.ArenaAllocator.init(allocator);
    defer arena3.deinit();
    const tsv_rows = try serde.csv.fromSliceWith([]const TsvRow, arena3.allocator(), tsv_data, serde.csv.tsv_dialect);
    std.debug.print("\n=== TSV dialect demo ===\n", .{});
    for (tsv_rows) |row|
        std.debug.print("  {s}: {}\n", .{ row.name, row.score });
}
