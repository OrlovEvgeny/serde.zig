const std = @import("std");
const serde = @import("serde");

// Imagine this type belongs to a dependency: it has no serde declarations.
const RawConfig = struct {
    name: []const u8,
    max_retries: u32,
    base_url: []const u8,
    auth_token: []const u8,
    log_level: []const u8,
};
const api_schema = .{
    .rename_all = serde.NamingConvention.camel_case,
    .skip = .{ .auth_token = serde.SkipMode.always },
};
const config_schema = .{ .rename_all = serde.NamingConvention.kebab_case };

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = try serde.compat.readFileAlloc(allocator, "examples/schema_override/service.toml", 64 * 1024);
    defer allocator.free(input);
    var loaded = try serde.toml.fromSliceManagedSchema(RawConfig, allocator, input, config_schema);
    defer loaded.deinit();
    if (loaded.value.name.len == 0 or loaded.value.auth_token.len == 0 or
        !std.mem.startsWith(u8, loaded.value.base_url, "https://") or
        loaded.value.max_retries > 10) return error.InvalidConfig;

    // Keep the full config for the client, but expose a redacted status view.
    // Never log the original config or serialize it with the default schema.
    const output = try serde.json.toSliceWithSchema(allocator, loaded.value, .{ .pretty = true }, api_schema);
    defer allocator.free(output);
    std.debug.print("Loaded {s}; publishing public configuration\n", .{loaded.value.name});
    try serde.compat.writeStdout(output);
    try serde.compat.writeStdout("\n");
}
