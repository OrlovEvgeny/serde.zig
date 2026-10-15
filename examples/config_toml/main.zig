const std = @import("std");
const serde = @import("serde");

const AppConfig = struct {
    app_name: []const u8,
    server: struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
        workers: u16 = 4,
    },
    database: struct {
        host: []const u8,
        port: u16 = 5432,
        name: []const u8,
        max_connections: u16 = 10,
        timeout_seconds: u16 = 30,
    },
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = try serde.compat.readFileAlloc(allocator, "examples/config_toml/service.toml", 64 * 1024);
    defer allocator.free(input);
    var parsed = try serde.toml.fromSliceManaged(AppConfig, allocator, input);
    defer parsed.deinit();
    const config = parsed.value;
    // Type checking alone cannot reject a zero port or an empty pool.
    if (config.app_name.len == 0 or config.server.host.len == 0 or
        config.server.port == 0 or config.server.workers == 0) return error.InvalidServerConfig;
    if (config.database.host.len == 0 or config.database.name.len == 0 or
        config.database.port == 0 or config.database.max_connections == 0 or
        config.database.timeout_seconds == 0) return error.InvalidDatabaseConfig;

    std.debug.print("{s}: listen {s}:{d}, {d} workers, database pool {d}\n", .{
        config.app_name,       config.server.host,              config.server.port,
        config.server.workers, config.database.max_connections,
    });
    // Export effective settings, including defaults, without rewriting the input.
    const effective = try serde.toml.toSlice(allocator, config);
    defer allocator.free(effective);
    try serde.compat.writeStdout(effective);
}
