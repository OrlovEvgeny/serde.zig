const std = @import("std");
const serde = @import("serde");

const LogLevel = enum { debug, info, warn, err };

const LogEntry = struct {
    timestamp: i64,
    level: LogLevel,
    message: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const entries = [_]LogEntry{
        .{ .timestamp = 1700000001, .level = .info, .message = "Server started on port 8080" },
        .{ .timestamp = 1700000002, .level = .debug, .message = "Connected to database" },
        .{ .timestamp = 1700000003, .level = .warn, .message = "Slow query detected (2.3s)" },
        .{ .timestamp = 1700000004, .level = .err, .message = "Failed to connect to cache" },
        .{ .timestamp = 1700000005, .level = .info, .message = "Request processed in 12ms" },
    };

    var ndjson_buf: std.ArrayList(u8) = .empty;
    defer ndjson_buf.deinit(allocator);

    for (entries) |entry| {
        const line = try serde.json.toSlice(allocator, entry);
        defer allocator.free(line);
        try ndjson_buf.appendSlice(allocator, line);
        try ndjson_buf.append(allocator, '\n');
    }

    std.debug.print("=== Written NDJSON ({} bytes) ===\n{s}\n", .{ ndjson_buf.items.len, ndjson_buf.items });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    std.debug.print("=== Streaming read (warn + err only) ===\n", .{});
    var reader: std.Io.Reader = .fixed(ndjson_buf.items);
    var sd = serde.helpers.StreamingDeserializer(LogEntry).init(arena.allocator(), &reader);
    defer sd.deinit();

    while (try sd.next()) |entry| {
        switch (entry.level) {
            .warn, .err => std.debug.print("[{s}] {}: {s}\n", .{
                @tagName(entry.level),
                entry.timestamp,
                entry.message,
            }),
            else => {},
        }
    }
}
