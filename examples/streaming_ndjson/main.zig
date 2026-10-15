const std = @import("std");
const serde = @import("serde");

const LogEntry = struct {
    timestamp: i64,
    service: []const u8,
    level: enum { debug, info, warn, err },
    message: []const u8,
    request_id: ?[]const u8 = null,
    duration_ms: ?u32 = null,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const file = try serde.compat.openFileForRead("examples/streaming_ndjson/requests.ndjson");
    defer serde.compat.closeFile(file);
    var buffer: [4096]u8 = undefined;
    var reader = serde.compat.fileReaderStreaming(file, &buffer);
    var stream = serde.helpers.StreamingDeserializer(LogEntry).init(allocator, &reader.interface);
    defer stream.deinit();

    var accepted: usize = 0;
    var rejected: usize = 0;
    var alerts: usize = 0;
    while (true) {
        // next() consumes a complete line before parsing it, so a malformed
        // JSON record can be skipped. I/O and allocation failures must stop us.
        const entry = (stream.next() catch |err| {
            if (err == error.OutOfMemory or err == error.ReadFailed) return err;
            rejected += 1;
            std.debug.print("Skipping malformed record: {s}\n", .{@errorName(err)});
            continue;
        }) orelse break;
        defer serde.core.freeAllocated(LogEntry, entry, allocator);
        accepted += 1;
        switch (entry.level) {
            .warn, .err => {
                const line = try serde.json.toSlice(allocator, entry);
                defer allocator.free(line);
                try serde.compat.writeStdout(line);
                try serde.compat.writeStdout("\n");
                alerts += 1;
            },
            else => {},
        }
    }
    std.debug.print("Records: {d} valid, {d} rejected, {d} alerts\n", .{ accepted, rejected, alerts });
}
