const std = @import("std");
const serde = @import("serde");

const Reading = struct {
    sensor_id: []const u8,
    unit: enum { celsius, percent, hectopascal },
    value: ?f64,
    status: enum { ok, warning, failed },
};
const TelemetryBatch = struct {
    schema_version: u16 = 1,
    device_id: []const u8,
    sequence: u64,
    timestamp: i64,
    readings: []const Reading,
};

fn receive(comptime Format: type, allocator: std.mem.Allocator, payload: []const u8) !serde.Parsed(TelemetryBatch) {
    var parsed = try Format.fromSliceManaged(TelemetryBatch, allocator, payload);
    errdefer parsed.deinit();
    if (parsed.value.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (parsed.value.device_id.len == 0 or parsed.value.readings.len == 0) return error.EmptyBatch;
    for (parsed.value.readings) |reading| {
        if (reading.sensor_id.len == 0) return error.MissingSensorId;
        if (reading.status == .failed) {
            if (reading.value != null) return error.FailedSensorHasValue;
        } else {
            const value = reading.value orelse return error.MissingReading;
            if (!std.math.isFinite(value)) return error.InvalidReading;
        }
    }
    return parsed;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const batch = TelemetryBatch{
        .device_id = "warehouse-07",
        .sequence = 1042,
        .timestamp = 1700000000,
        .readings = &.{
            .{ .sensor_id = "cold-room", .unit = .celsius, .value = 3.5, .status = .ok },
            .{ .sensor_id = "loading-bay", .unit = .celsius, .value = 29.1, .status = .warning },
            .{ .sensor_id = "humidity", .unit = .percent, .value = 45.0, .status = .ok },
            .{ .sensor_id = "pressure", .unit = .hectopascal, .value = null, .status = .failed },
        },
    };
    const json = try serde.json.toSlice(allocator, batch);
    defer allocator.free(json);
    const msgpack = try serde.msgpack.toSlice(allocator, batch);
    defer allocator.free(msgpack);
    const etf = try serde.etf.toSlice(allocator, batch);
    defer allocator.free(etf);

    // These slices stand in for queue message bodies; each message needs its
    // own framing at the transport layer.
    var from_msgpack = try receive(serde.msgpack, allocator, msgpack);
    defer from_msgpack.deinit();
    var from_etf = try receive(serde.etf, allocator, etf);
    defer from_etf.deinit();
    inline for (.{ from_msgpack.value, from_etf.value }) |decoded| {
        const canonical = try serde.json.toSlice(allocator, decoded);
        defer allocator.free(canonical);
        if (!std.mem.eql(u8, json, canonical)) return error.RoundtripMismatch;
    }
    var alert_count: usize = 0;
    for (from_msgpack.value.readings) |reading| {
        if (reading.status != .ok) alert_count += 1;
    }
    std.debug.print("Payload sizes: JSON {d}, MessagePack {d}, ETF {d} bytes\n", .{ json.len, msgpack.len, etf.len });
    std.debug.print("Received batch {d}: {d} readings, {d} alerts; both binary formats verified\n", .{
        from_msgpack.value.sequence, from_msgpack.value.readings.len, alert_count,
    });
    try serde.compat.writeStdout(json);
    try serde.compat.writeStdout("\n");
}
