const std = @import("std");
const serde = @import("serde");

const ServiceConfig = struct {
    service_name: []const u8,
    port_number: u16,
    max_retries: u32 = 3,
    is_enabled: bool = true,
    metadata: struct { region: []const u8, tier: []const u8 },
    description: []const u8 = "",
};
const InventoryRow = struct {
    service_name: []const u8,
    port_number: u16,
    region: []const u8,
    tier: []const u8,
};
const schema = .{ .rename_all = serde.NamingConvention.kebab_case };

fn exportConfig(comptime label: []const u8, comptime Format: type, allocator: std.mem.Allocator, config: ServiceConfig) !void {
    // ZON field names must be Zig identifiers with the current backend.
    const export_schema = comptime if (Format == serde.zon) .{} else schema;
    const bytes = try Format.toSliceSchema(allocator, config, export_schema);
    defer allocator.free(bytes);
    var restored = try Format.fromSliceManagedSchema(ServiceConfig, allocator, bytes, export_schema);
    defer restored.deinit();
    // Compare all fields using a stable representation, not only the name.
    const before = try serde.json.toSlice(allocator, config);
    defer allocator.free(before);
    const after = try serde.json.toSlice(allocator, restored.value);
    defer allocator.free(after);
    if (!std.mem.eql(u8, before, after)) return error.RoundtripMismatch;
    try serde.compat.writeStdout("=== " ++ label ++ " ===\n");
    try serde.compat.writeStdout(bytes);
    try serde.compat.writeStdout("\n\n");
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = try serde.compat.readFileAlloc(allocator, "examples/multi_format/service.toml", 64 * 1024);
    defer allocator.free(input);
    var parsed = try serde.toml.fromSliceManagedSchema(ServiceConfig, allocator, input, schema);
    defer parsed.deinit();
    const config = parsed.value;
    if (config.service_name.len == 0 or config.port_number == 0 or config.max_retries > 10 or
        config.metadata.region.len == 0 or config.metadata.tier.len == 0) return error.InvalidServiceConfig;

    try exportConfig("JSON", serde.json, allocator, config);
    try exportConfig("TOML", serde.toml, allocator, config);
    try exportConfig("YAML", serde.yaml, allocator, config);
    try exportConfig("XML", serde.xml, allocator, config);
    try exportConfig("ZON", serde.zon, allocator, config);
    try exportConfig("TOON", serde.toon, allocator, config);

    // CSV is an inventory projection: explicitly flatten the useful columns
    // instead of implying that a nested config has a portable tabular shape.
    const rows = [_]InventoryRow{.{
        .service_name = config.service_name,
        .port_number = config.port_number,
        .region = config.metadata.region,
        .tier = config.metadata.tier,
    }};
    const csv = try serde.csv.toSliceSchema(allocator, rows, schema);
    defer allocator.free(csv);
    try serde.compat.writeStdout("=== CSV inventory (selected fields) ===\n");
    try serde.compat.writeStdout(csv);
    std.debug.print("Verified full configuration roundtrips through 6 text formats\n", .{});
}
