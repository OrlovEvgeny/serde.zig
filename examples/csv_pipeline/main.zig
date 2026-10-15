const std = @import("std");
const serde = @import("serde");

const Employee = struct {
    id: u32,
    name: []const u8,
    department: []const u8,
    annual_salary_cents: u64,
    remote: bool,
    manager: ?[]const u8,
};
const Totals = struct {
    headcount: u64 = 0,
    remote_count: u64 = 0,
    annual_payroll_cents: u64 = 0,
};
const DepartmentReport = struct {
    department: []const u8,
    headcount: u64,
    remote_count: u64,
    annual_payroll_cents: u64,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = try serde.compat.readFileAlloc(allocator, "examples/csv_pipeline/employees.csv", 1024 * 1024);
    defer allocator.free(input);
    // The CSV scanner works over an input slice. Rows are decoded one at a time,
    // but the source file remains in memory for the duration of this import.
    var stream = try serde.csv.streamingDeserializer([]const Employee, allocator, input);
    defer stream.deinit();
    var departments = std.StringHashMap(Totals).init(allocator);
    defer {
        var it = departments.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        departments.deinit();
    }
    var count: u64 = 0;
    while (try stream.next()) |employee| {
        defer serde.core.freeAllocated(Employee, employee, allocator);
        if (employee.id == 0 or employee.name.len == 0 or employee.department.len == 0)
            return error.InvalidEmployee;
        if (!departments.contains(employee.department)) {
            // Aggregate keys must outlive the current row.
            const name = try allocator.dupe(u8, employee.department);
            errdefer allocator.free(name);
            try departments.put(name, .{});
        }
        const totals = departments.getPtr(employee.department).?;
        totals.headcount = try std.math.add(u64, totals.headcount, 1);
        totals.remote_count = try std.math.add(u64, totals.remote_count, @intFromBool(employee.remote));
        totals.annual_payroll_cents = try std.math.add(u64, totals.annual_payroll_cents, employee.annual_salary_cents);
        count = try std.math.add(u64, count, 1);
    }
    if (count == 0) return error.EmptyImport;

    var report: std.ArrayList(DepartmentReport) = .empty;
    defer report.deinit(allocator);
    var it = departments.iterator();
    while (it.next()) |entry| {
        try report.append(allocator, .{
            .department = entry.key_ptr.*,
            .headcount = entry.value_ptr.headcount,
            .remote_count = entry.value_ptr.remote_count,
            .annual_payroll_cents = entry.value_ptr.annual_payroll_cents,
        });
    }
    std.mem.sort(DepartmentReport, report.items, {}, struct {
        fn lessThan(_: void, a: DepartmentReport, b: DepartmentReport) bool {
            return std.mem.lessThan(u8, a.department, b.department);
        }
    }.lessThan);
    const output = try serde.csv.toSlice(allocator, report.items);
    defer allocator.free(output);
    std.debug.print("Imported {d} employees into {d} department totals (EUR cents)\n", .{ count, report.items.len });
    try serde.compat.writeStdout(output);
}
