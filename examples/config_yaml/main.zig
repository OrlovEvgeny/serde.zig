const std = @import("std");
const serde = @import("serde");

const Service = struct {
    image: []const u8,
    ports: []const u16,
    environment: ?std.StringHashMap([]const u8) = null,
    restart: ?[]const u8 = null,
    depends_on: ?[]const []const u8 = null,
};

const DockerCompose = struct {
    services: std.StringHashMap(Service),
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile("examples/config_yaml/docker.yaml", .{});
    defer file.close();
    var file_buf: [65536]u8 = undefined;
    var file_reader = file.readerStreaming(&file_buf);
    const yaml_input = try file_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(yaml_input);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const compose = try serde.yaml.fromSlice(DockerCompose, arena.allocator(), yaml_input);

    std.debug.print("=== Parsed Docker Compose ===\n", .{});
    var it = compose.services.iterator();
    while (it.next()) |entry| {
        std.debug.print("Service \"{s}\":\n", .{entry.key_ptr.*});
        std.debug.print("  image: {s}\n", .{entry.value_ptr.image});
        std.debug.print("  ports:", .{});
        for (entry.value_ptr.ports) |p| std.debug.print(" {}", .{p});
        std.debug.print("\n", .{});
        if (entry.value_ptr.environment) |env| {
            var env_it = env.iterator();
            while (env_it.next()) |e|
                std.debug.print("  {s}: {s}\n", .{ e.key_ptr.*, e.value_ptr.* });
        }
        if (entry.value_ptr.restart) |r|
            std.debug.print("  restart: {s}\n", .{r});
        if (entry.value_ptr.depends_on) |deps| {
            std.debug.print("  depends_on:", .{});
            for (deps) |d| std.debug.print(" {s}", .{d});
            std.debug.print("\n", .{});
        }
    }

    const yaml_out = try serde.yaml.toSliceWith(allocator, compose, .{ .explicit_start = true });
    defer allocator.free(yaml_out);
    std.debug.print("\n=== Serialized YAML (explicit_start) ===\n{s}", .{yaml_out});

    const json_out = try serde.json.toSliceWith(allocator, compose, .{ .pretty = true });
    defer allocator.free(json_out);
    std.debug.print("\n=== Cross-format: as JSON ===\n{s}\n", .{json_out});

    const multi_doc =
        \\---
        \\name: doc1
        \\value: 10
        \\---
        \\name: doc2
        \\value: 20
        \\
    ;
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const docs = try serde.yaml.parseAllValues(arena2.allocator(), multi_doc);
    std.debug.print("\n=== Multi-doc YAML: {} documents ===\n", .{docs.len});
    for (docs, 0..) |doc, i| {
        if (doc == .mapping) {
            std.debug.print("Doc {}: {} keys\n", .{ i, doc.mapping.count() });
        }
    }
}
