const std = @import("std");
const serde = @import("serde");

const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    debug: bool = false,
};

const DatabaseConfig = struct {
    url: []const u8,
    max_connections: u32 = 10,
    timeout_seconds: ?u32 = null,
};

const AppConfig = struct {
    app_name: []const u8,
    version: []const u8,
    server: ServerConfig,
    database: DatabaseConfig,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const config = AppConfig{
        .app_name = "my-service",
        .version = "1.2.0",
        .server = .{
            .host = "0.0.0.0",
            .port = 3000,
            .debug = true,
        },
        .database = .{
            .url = "postgres://localhost:5432/mydb",
            .max_connections = 25,
            .timeout_seconds = 30,
        },
    };

    const toml_bytes = try serde.toml.toSlice(allocator, config);
    defer allocator.free(toml_bytes);
    std.debug.print("=== Serialized TOML ===\n{s}\n", .{toml_bytes});

    const tmp_path = "config_example.toml";
    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = tmp_path, .data = toml_bytes });
    defer cwd.deleteFile(tmp_path) catch {};

    const file = try cwd.openFile(tmp_path, .{});
    defer file.close();
    var file_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(&file_buf);
    const file_content = try reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(file_content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const loaded = try serde.toml.fromSlice(AppConfig, arena.allocator(), file_content);
    std.debug.print("=== Loaded from file ===\n", .{});
    std.debug.print("app_name   = {s}\n", .{loaded.app_name});
    std.debug.print("version    = {s}\n", .{loaded.version});
    std.debug.print("server.host = {s}\n", .{loaded.server.host});
    std.debug.print("server.port = {}\n", .{loaded.server.port});
    std.debug.print("server.debug = {}\n", .{loaded.server.debug});
    std.debug.print("database.url = {s}\n", .{loaded.database.url});
    std.debug.print("database.max_connections = {}\n", .{loaded.database.max_connections});
    std.debug.print("database.timeout_seconds = {?}\n", .{loaded.database.timeout_seconds});

    const inline_toml =
        \\app_name = "minimal"
        \\version = "0.1.0"
        \\
        \\[server]
        \\port = 9090
        \\
        \\[database]
        \\url = "sqlite://local.db"
        \\
    ;
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();

    const minimal = try serde.toml.fromSlice(AppConfig, arena2.allocator(), inline_toml);
    std.debug.print("\n=== Inline TOML (defaults applied) ===\n", .{});
    std.debug.print("app_name    = {s}\n", .{minimal.app_name});
    std.debug.print("server.host = {s} (default)\n", .{minimal.server.host});
    std.debug.print("server.port = {} (explicit)\n", .{minimal.server.port});
    std.debug.print("server.debug = {} (default)\n", .{minimal.server.debug});
    std.debug.print("database.max_connections = {} (default)\n", .{minimal.database.max_connections});
    std.debug.print("database.timeout_seconds = {?} (default null)\n", .{minimal.database.timeout_seconds});
}
