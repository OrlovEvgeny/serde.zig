const std = @import("std");
const serde = @import("serde");

const SensorStatus = enum { ok, warning, failed };

const Reading = struct {
    sensor_id: []const u8,
    value: f64,
    status: SensorStatus,
};

const TelemetryBatch = struct {
    device_id: []const u8,
    timestamp: i64,
    readings: []const Reading,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const batch = TelemetryBatch{
        .device_id = "sensor-array-001",
        .timestamp = 1700000000,
        .readings = &.{
            .{ .sensor_id = "temp-1", .value = 23.5, .status = .ok },
            .{ .sensor_id = "temp-2", .value = 99.1, .status = .warning },
            .{ .sensor_id = "humidity", .value = 45.0, .status = .ok },
            .{ .sensor_id = "pressure", .value = -1.0, .status = .failed },
        },
    };

    const json_bytes = try serde.json.toSlice(allocator, batch);
    defer allocator.free(json_bytes);
    std.debug.print("=== JSON ===\n{s}\n", .{json_bytes});
    std.debug.print("JSON size: {} bytes\n\n", .{json_bytes.len});

    const msgpack_bytes = try serde.msgpack.toSlice(allocator, batch);
    defer allocator.free(msgpack_bytes);
    std.debug.print("=== MessagePack (hex) ===\n", .{});
    for (msgpack_bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\nMsgPack size: {} bytes\n\n", .{msgpack_bytes.len});

    const json_f = @as(f64, @floatFromInt(json_bytes.len));
    const mp_f = @as(f64, @floatFromInt(msgpack_bytes.len));
    const pct = (json_f - mp_f) / json_f * 100.0;
    std.debug.print("MsgPack is {d:.1}% smaller than JSON ({} vs {} bytes)\n\n", .{
        pct,
        msgpack_bytes.len,
        json_bytes.len,
    });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const roundtrip = try serde.msgpack.fromSlice(TelemetryBatch, arena.allocator(), msgpack_bytes);
    std.debug.print("=== MsgPack roundtrip ===\n", .{});
    std.debug.print("device_id: {s}\n", .{roundtrip.device_id});
    std.debug.print("timestamp: {}\n", .{roundtrip.timestamp});
    std.debug.print("readings ({} entries):\n", .{roundtrip.readings.len});
    for (roundtrip.readings) |r|
        std.debug.print("  {s}: {d} [{s}]\n", .{ r.sensor_id, r.value, @tagName(r.status) });
}
