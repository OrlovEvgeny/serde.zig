const std = @import("std");
const serde = @import("serde");

const Job = struct {
    id: []const u8,
    recipients: []const []const u8,
    retry: struct { max_attempts: u8 = 3 },
};

fn inspectJob(allocator: std.mem.Allocator, input: []const u8) !bool {
    var path_buffer: [256]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&path_buffer);
    var parsed = serde.json.fromSliceManagedWithDiagnostics(Job, allocator, input, .{}, &diagnostics) catch |err| {
        // Infrastructure failures are not invalid user input.
        if (err == error.OutOfMemory) return err;
        std.debug.print("Rejected job: {s} at {s} ({d}:{d})\n", .{
            @errorName(err), diagnostics.path, diagnostics.line, diagnostics.column,
        });
        return false;
    };
    // One deinit releases the nested recipient strings and slice too.
    defer parsed.deinit();
    if (parsed.value.id.len == 0 or parsed.value.recipients.len == 0 or parsed.value.retry.max_attempts == 0) {
        std.debug.print("Rejected job: id, recipients and max_attempts must be nonempty/nonzero\n", .{});
        return false;
    }
    std.debug.print("Accepted {s}: {d} recipients, {d} attempts\n", .{
        parsed.value.id, parsed.value.recipients.len, parsed.value.retry.max_attempts,
    });
    return true;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // Independent messages have independent lifetimes. A bad job does not stop
    // the consumer from inspecting the following message.
    const messages = [_][]const u8{
        @embedFile("job.json"),
        @embedFile("invalid-job.json"),
        "{\"id\":\"mail-1044\",\"recipients\":[\"ops@example.com\"],\"retry\":{}}",
    };
    var accepted: usize = 0;
    for (messages) |input| {
        if (try inspectJob(allocator, input)) accepted += 1;
    }
    std.debug.print("Jobs: {d} accepted, {d} rejected\n", .{ accepted, messages.len - accepted });
}
