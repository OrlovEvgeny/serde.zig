const std = @import("std");
const serde = @import("serde");

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const file = try std.fs.cwd().openFile("examples/config_xml/config.xml", .{});
    defer file.close();
    var file_buf: [65536]u8 = undefined;
    var file_reader = file.readerStreaming(&file_buf);
    const xml_input = try file_reader.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(xml_input);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const config = try serde.xml.fromSlice(AppConfig, arena.allocator(), xml_input);

    std.debug.print("=== Parsed XML Config ===\n", .{});
    std.debug.print("id:       {s}\n", .{config.id});
    std.debug.print("version:  {s}\n", .{config.version});
    std.debug.print("name:     {s}\n", .{config.name});
    std.debug.print("database: {s}:{d} / {s}\n", .{
        config.database.host,
        config.database.port,
        config.database.name,
    });
    std.debug.print("features:", .{});
    for (config.features) |f| std.debug.print(" {s}", .{f});
    std.debug.print("\n", .{});

    const xml_out = try serde.xml.toSliceWith(allocator, config, .{
        .xml_declaration = true,
        .pretty = true,
    });
    defer allocator.free(xml_out);
    std.debug.print("\n=== Serialized XML (pretty + declaration) ===\n{s}\n", .{xml_out});

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const config2 = try serde.xml.fromSlice(AppConfig, arena2.allocator(), xml_out);
    std.debug.print("Roundtrip OK: id={s} version={s} name={s}\n", .{
        config2.id,
        config2.version,
        config2.name,
    });

    const EscapeDemo = struct { text: []const u8 };
    const demo = EscapeDemo{ .text = "a < b & c > d \"quoted\" 'single'" };
    const escaped = try serde.xml.toSliceWith(allocator, demo, .{ .xml_declaration = false });
    defer allocator.free(escaped);
    std.debug.print("\n=== Entity escaping ===\n", .{});
    std.debug.print("Original:  {s}\n", .{demo.text});
    std.debug.print("XML:       {s}\n", .{escaped});

    var arena3 = std.heap.ArenaAllocator.init(allocator);
    defer arena3.deinit();
    const roundtrip = try serde.xml.fromSlice(EscapeDemo, arena3.allocator(), escaped);
    std.debug.print("Roundtrip: {s}\n", .{roundtrip.text});
}
