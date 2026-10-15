const std = @import("std");
const serde = @import("serde");
const options = serde;

const Database = struct {
    host: []const u8,
    port: u16,
    name: []const u8,
};
const AppConfig = struct {
    id: []const u8,
    version: []const u8,
    name: []const u8,
    database: Database,
    features: []const []const u8,

    pub const serde = .{
        .xml_root = "config",
        .xml_attribute = .{ .id, .version },
    };
};
const public_schema = .{ .skip = .{ .database = options.SkipMode.always } };

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = try serde.compat.readFileAlloc(allocator, "examples/config_xml/config.xml", 64 * 1024);
    defer allocator.free(input);
    var parsed = try serde.xml.fromSliceManaged(AppConfig, allocator, input);
    defer parsed.deinit();
    const config = parsed.value;
    if (!std.mem.eql(u8, config.version, "2.1")) return error.UnsupportedConfigVersion;
    if (config.id.len == 0 or config.name.len == 0 or config.database.host.len == 0 or
        config.database.name.len == 0 or config.database.port == 0) return error.InvalidConfig;
    for (config.features) |feature| {
        if (!std.mem.eql(u8, feature, "logging") and
            !std.mem.eql(u8, feature, "metrics") and
            !std.mem.eql(u8, feature, "tracing")) return error.UnsupportedFeature;
    }

    // A legacy XML config can feed a JSON status endpoint without exposing its
    // database connection settings. Entity references are decoded automatically.
    const status = try serde.json.toSliceWithSchema(allocator, config, .{ .pretty = true }, public_schema);
    defer allocator.free(status);
    try serde.compat.writeStdout(status);
    try serde.compat.writeStdout("\n");

    const normalized = try serde.xml.toSliceWith(allocator, config, .{
        .xml_declaration = true,
        .pretty = true,
    });
    defer allocator.free(normalized);
    std.debug.print("Normalized XML (attributes and escaping retained):\n{s}\n", .{normalized});
}
