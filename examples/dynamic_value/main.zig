const std = @import("std");
const serde = @import("serde");

const Address = struct {
    city: []const u8,
    zip: []const u8,
};

const Person = struct {
    name: []const u8,
    age: u32,
    scores: []const i32,
    address: ?Address = null,
};

fn valueTypeName(v: serde.Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "bool",
        .int => "int",
        .uint => "uint",
        .float => "float",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn maxDepth(v: serde.Value) usize {
    return switch (v) {
        .object => |entries| {
            var d: usize = 1;
            for (entries) |e| {
                const child = maxDepth(e.value) + 1;
                if (child > d) d = child;
            }
            return d;
        },
        .array => |arr| {
            var d: usize = 1;
            for (arr) |elem| {
                const child = maxDepth(elem) + 1;
                if (child > d) d = child;
            }
            return d;
        },
        else => 1,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const person = Person{
        .name = "Alice",
        .age = 30,
        .scores = &.{ 95, 87, 92 },
        .address = .{ .city = "NYC", .zip = "10001" },
    };

    const json_str = try serde.json.toSlice(allocator, person);
    defer allocator.free(json_str);
    std.debug.print("=== Original JSON ===\n{s}\n\n", .{json_str});

    const val = try serde.json.toValue(allocator, person);
    defer val.deinit(allocator);

    std.debug.print("=== Inspecting serde.Value ===\n", .{});
    std.debug.print("Active tag: {s}\n", .{valueTypeName(val)});

    if (val == .object) {
        std.debug.print("Object has {} fields:\n", .{val.object.len});
        for (val.object) |entry| {
            std.debug.print("  {s} -> {s}", .{ entry.key, valueTypeName(entry.value) });
            switch (entry.value) {
                .int => |i| std.debug.print(" ({})", .{i}),
                .uint => |u| std.debug.print(" ({})", .{u}),
                .string => |s| std.debug.print(" (\"{s}\")", .{s}),
                .array => |a| std.debug.print(" ({} items)", .{a.len}),
                .object => |o| std.debug.print(" ({} fields)", .{o.len}),
                else => {},
            }
            std.debug.print("\n", .{});
        }
    }

    std.debug.print("Max nesting depth: {}\n\n", .{maxDepth(val)});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const extracted = try serde.json.fromValue(Person, arena.allocator(), val);
    std.debug.print("=== Extracted from Value ===\n", .{});
    std.debug.print("name: {s}\n", .{extracted.name});
    std.debug.print("age: {}\n", .{extracted.age});
    std.debug.print("scores:", .{});
    for (extracted.scores) |s| std.debug.print(" {}", .{s});
    std.debug.print("\n", .{});
    if (extracted.address) |addr|
        std.debug.print("address: {s} {s}\n", .{ addr.city, addr.zip });

    const x_key = try allocator.dupe(u8, "x");
    const y_key = try allocator.dupe(u8, "y");
    const manual_entries = try allocator.alloc(serde.Entry, 2);
    manual_entries[0] = .{ .key = x_key, .value = .{ .uint = 10 } };
    manual_entries[1] = .{ .key = y_key, .value = .{ .uint = 20 } };
    const manual: serde.Value = .{ .object = manual_entries };
    defer manual.deinit(allocator);

    const Point = struct { x: u32, y: u32 };
    const point = try serde.json.fromValue(Point, arena.allocator(), manual);
    std.debug.print("\n=== Manually built Value -> struct ===\n", .{});
    std.debug.print("Point: ({}, {})\n", .{ point.x, point.y });
}
