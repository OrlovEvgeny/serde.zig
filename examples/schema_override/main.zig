const std = @import("std");
const serde = @import("serde");

const RawConfig = struct {
    name: []const u8,
    max_retries: u32,
    base_url: []const u8,
    auth_token: []const u8,
    log_level: []const u8,
};

const schema_api = .{
    .rename_all = serde.NamingConvention.camel_case,
    .skip = .{ .auth_token = serde.SkipMode.always },
};

const schema_config = .{
    .rename_all = serde.NamingConvention.kebab_case,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const config = RawConfig{
        .name = "my-service",
        .max_retries = 5,
        .base_url = "https://api.example.com",
        .auth_token = "super-secret",
        .log_level = "debug",
    };

    const api_json = try serde.json.toSliceSchema(allocator, config, schema_api);
    defer allocator.free(api_json);
    std.debug.print("=== Schema A: API (camelCase, skip auth_token) ===\n{s}\n\n", .{api_json});

    const config_json = try serde.json.toSliceSchema(allocator, config, schema_config);
    defer allocator.free(config_json);
    std.debug.print("=== Schema B: Config (kebab-case, all fields) ===\n{s}\n\n", .{config_json});

    const file = try serde.compat.openFileForRead("examples/schema_override/service.toml");
    defer serde.compat.closeFile(file);
    var file_buf: [4096]u8 = undefined;
    var file_reader = serde.compat.fileReaderStreaming(file, &file_buf);
    const toml_input = try serde.compat.readerAllocRemaining(&file_reader, allocator, .unlimited);
    defer allocator.free(toml_input);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const loaded = try serde.toml.fromSliceSchema(RawConfig, arena.allocator(), toml_input, schema_config);
    std.debug.print("=== Loaded from TOML with schema B ===\n", .{});
    std.debug.print("name:        {s}\n", .{loaded.name});
    std.debug.print("max_retries: {}\n", .{loaded.max_retries});
    std.debug.print("base_url:    {s}\n", .{loaded.base_url});
    std.debug.print("auth_token:  {s}\n", .{loaded.auth_token});
    std.debug.print("log_level:   {s}\n", .{loaded.log_level});

    const api_from_toml = try serde.json.toSliceSchema(allocator, loaded, schema_api);
    defer allocator.free(api_from_toml);
    std.debug.print("\n=== Same data serialized with API schema ===\n{s}\n", .{api_from_toml});
}
