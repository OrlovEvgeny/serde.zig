const std = @import("std");
const serde = @import("serde");

const WorkerConfig = struct {
    service: []const u8,
    concurrency: u16,
    dry_run: bool,
};

fn overrideField(object: *serde.Value, name: []const u8, replacement: serde.Value) !void {
    if (object.* != .object) return error.ExpectedObject;
    for (object.object) |*entry| {
        if (!std.mem.eql(u8, entry.key, name)) continue;
        // This settings editor only changes scalar fields, which own no memory.
        switch (entry.value) {
            .uint => if (replacement != .uint) return error.InvalidSettingType,
            .bool => if (replacement != .bool) return error.InvalidSettingType,
            else => return error.ReadOnlySetting,
        }
        entry.value = replacement;
        return;
    }
    return error.UnknownSetting;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const defaults = WorkerConfig{ .service = "invoice-worker", .concurrency = 4, .dry_run = true };
    var settings = try serde.json.toValue(allocator, defaults);
    defer settings.deinit(allocator);

    // An admin UI can address fields by name without knowing WorkerConfig.
    try overrideField(&settings, "concurrency", .{ .uint = 12 });
    try overrideField(&settings, "dry_run", .{ .bool = false });
    for (settings.object) |entry| {
        std.debug.print("Setting {s}: {s}\n", .{ entry.key, @tagName(entry.value) });
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Conversion checks Zig field types; domain constraints are separate.
    const effective = try serde.json.fromValue(WorkerConfig, arena.allocator(), settings);
    if (effective.concurrency == 0 or effective.concurrency > 64) return error.InvalidConcurrency;
    const output = try serde.json.toSliceWith(allocator, effective, .{ .pretty = true });
    defer allocator.free(output);
    try serde.compat.writeStdout(output);
    try serde.compat.writeStdout("\n");
}
