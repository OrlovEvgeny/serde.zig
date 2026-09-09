const std = @import("std");
const serde = @import("serde");
const User = struct { name: []const u8, age: u32, email: ?[]const u8 = null };

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const bytes = try serde.json.toSlice(allocator, User{ .name = "Alice", .age = 30 });
    defer allocator.free(bytes);
    var parsed = try serde.json.fromSliceManaged(User, allocator, bytes);
    defer parsed.deinit();
    std.debug.print("{s}: {d}\n", .{ parsed.value.name, parsed.value.age });

    var buffer: [128]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    var invalid = serde.json.fromSliceManagedWithDiagnostics(User, allocator, "{\"name\":\"Alice\",\"age\":\"old\"}", .{}, &diagnostics) catch |err| {
        std.debug.print("{s} at {s} ({d}:{d})\n", .{ @errorName(err), diagnostics.path, diagnostics.line, diagnostics.column });
        return;
    };
    defer invalid.deinit();
}
