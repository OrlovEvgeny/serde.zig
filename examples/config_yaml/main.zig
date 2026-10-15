const std = @import("std");
const serde = @import("serde");

// A deliberately small Compose-style schema, not a full Compose implementation.
const Service = struct {
    image: []const u8,
    ports: []const []const u8 = &.{},
    environment: ?std.StringHashMap([]const u8) = null,
    restart: []const u8 = "unless-stopped",
    depends_on: []const []const u8 = &.{},
};
const Deployment = struct { services: std.StringHashMap(Service) };
const ServiceSummary = struct {
    name: []const u8,
    image: []const u8,
    published_ports: []const []const u8,
    dependency_count: usize,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const input = try serde.compat.readFileAlloc(allocator, "examples/config_yaml/docker.yaml", 256 * 1024);
    defer allocator.free(input);
    var parsed = try serde.yaml.fromSliceManaged(Deployment, allocator, input);
    defer parsed.deinit();
    const services = parsed.value.services;
    if (services.count() == 0) return error.EmptyDeployment;

    var summaries: std.ArrayList(ServiceSummary) = .empty;
    defer summaries.deinit(allocator);
    var it = services.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const service = entry.value_ptr.*;
        if (name.len == 0 or service.image.len == 0) return error.InvalidService;
        for (service.depends_on) |dependency| {
            if (!services.contains(dependency)) {
                std.debug.print("Service {s} refers to missing dependency {s}\n", .{ name, dependency });
                return error.UnknownDependency;
            }
            if (std.mem.eql(u8, name, dependency)) return error.SelfDependency;
        }
        try summaries.append(allocator, .{
            .name = name,
            .image = service.image,
            .published_ports = service.ports,
            .dependency_count = service.depends_on.len,
        });
    }
    std.mem.sort(ServiceSummary, summaries.items, {}, struct {
        fn lessThan(_: void, a: ServiceSummary, b: ServiceSummary) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    // Environment values can contain credentials; export only the inventory.
    const output = try serde.json.toSliceWith(allocator, summaries.items, .{ .pretty = true });
    defer allocator.free(output);
    std.debug.print("Validated {d} services; inventory sorted by name\n", .{summaries.items.len});
    try serde.compat.writeStdout(output);
    try serde.compat.writeStdout("\n");
}
