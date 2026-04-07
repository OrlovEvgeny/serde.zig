const std = @import("std");
const serde = @import("serde");

const Metadata = struct {
    region: []const u8,
    tier: []const u8,
};

const ServiceConfig = struct {
    service_name: []const u8,
    port_number: u16,
    max_retries: u32,
    is_enabled: bool,
    metadata: Metadata,
    description: ?[]const u8,
};

const schema = .{ .rename_all = serde.NamingConvention.kebab_case };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const config = ServiceConfig{
        .service_name = "web-api",
        .port_number = 8080,
        .max_retries = 3,
        .is_enabled = true,
        .metadata = .{ .region = "us-east-1", .tier = "production" },
        .description = "Main web service",
    };

    const json_bytes = try serde.json.toSliceSchema(allocator, config, schema);
    defer allocator.free(json_bytes);
    std.debug.print("=== JSON ===\n{s}\n\n", .{json_bytes});

    const toml_bytes = try serde.toml.toSliceSchema(allocator, config, schema);
    defer allocator.free(toml_bytes);
    std.debug.print("=== TOML ===\n{s}\n", .{toml_bytes});

    const yaml_bytes = try serde.yaml.toSliceSchema(allocator, config, schema);
    defer allocator.free(yaml_bytes);
    std.debug.print("=== YAML ===\n{s}", .{yaml_bytes});

    const xml_bytes = try serde.xml.toSliceWithSchema(allocator, config, .{ .xml_declaration = false, .pretty = true }, schema);
    defer allocator.free(xml_bytes);
    std.debug.print("\n=== XML ===\n{s}\n\n", .{xml_bytes});

    const msgpack_bytes = try serde.msgpack.toSliceSchema(allocator, config, schema);
    defer allocator.free(msgpack_bytes);
    std.debug.print("=== MessagePack ({} bytes) ===\n", .{msgpack_bytes.len});
    for (msgpack_bytes) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print("\n\n", .{});

    const zon_bytes = try serde.zon.toSliceSchema(allocator, config, schema);
    defer allocator.free(zon_bytes);
    std.debug.print("=== ZON ===\n{s}\n\n", .{zon_bytes});

    const flat_config: []const ServiceConfig = &.{config};
    const csv_bytes = try serde.csv.toSliceSchema(allocator, flat_config, schema);
    defer allocator.free(csv_bytes);
    std.debug.print("=== CSV ===\n{s}\n", .{csv_bytes});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed_json = try serde.json.fromSliceSchema(ServiceConfig, arena.allocator(), json_bytes, schema);
    std.debug.print("\n=== Roundtrip from JSON ===\n", .{});
    std.debug.print("service_name={s} port_number={} max_retries={}\n", .{
        parsed_json.service_name,
        parsed_json.port_number,
        parsed_json.max_retries,
    });

    const parsed_toml = try serde.toml.fromSliceSchema(ServiceConfig, arena.allocator(), toml_bytes, schema);
    std.debug.print("Roundtrip from TOML: service_name={s} ok={}\n", .{
        parsed_toml.service_name,
        std.mem.eql(u8, parsed_toml.service_name, config.service_name),
    });

    const parsed_yaml = try serde.yaml.fromSliceSchema(ServiceConfig, arena.allocator(), yaml_bytes, schema);
    std.debug.print("Roundtrip from YAML: service_name={s} ok={}\n", .{
        parsed_yaml.service_name,
        std.mem.eql(u8, parsed_yaml.service_name, config.service_name),
    });

    const parsed_msgpack = try serde.msgpack.fromSliceSchema(ServiceConfig, arena.allocator(), msgpack_bytes, schema);
    std.debug.print("Roundtrip from MsgPack: service_name={s} ok={}\n", .{
        parsed_msgpack.service_name,
        std.mem.eql(u8, parsed_msgpack.service_name, config.service_name),
    });
}
