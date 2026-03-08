const std = @import("std");
const testing = std.testing;
const serde = @import("serde");

const Point = struct { x: i32, y: i32 };
const Nested = struct { name: []const u8, inner: Point };
const Color = enum { red, green, blue };
const Cmd = union(enum) { ping: void, set: i32 };

fn jsonRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const bytes = try serde.json.toSlice(allocator, value);
    defer allocator.free(bytes);
    return serde.json.fromSlice(T, allocator, bytes);
}

fn msgpackRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const bytes = try serde.msgpack.toSlice(allocator, value);
    defer allocator.free(bytes);
    return serde.msgpack.fromSlice(T, allocator, bytes);
}

fn zonRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const bytes = try serde.zon.toSliceWith(allocator, value, .{ .pretty = false });
    defer allocator.free(bytes);
    return serde.zon.fromSlice(T, allocator, bytes);
}

// TOML requires a struct at the top level. For scalars we wrap in a struct.
fn Wrap(comptime T: type) type {
    return struct { v: T };
}

// TOML and YAML parsers build intermediate Value trees. All calls use arena
// allocators to keep cleanup simple.

fn tomlRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const bytes = try serde.toml.toSlice(allocator, value);
    return serde.toml.fromSlice(T, allocator, bytes);
}

fn tomlScalarRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const W = Wrap(T);
    const bytes = try serde.toml.toSlice(allocator, W{ .v = value });
    const result = try serde.toml.fromSlice(W, allocator, bytes);
    return result.v;
}

fn yamlRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const bytes = try serde.yaml.toSlice(allocator, value);
    return serde.yaml.fromSlice(T, allocator, bytes);
}

fn yamlScalarRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const W = Wrap(T);
    const bytes = try serde.yaml.toSlice(allocator, W{ .v = value });
    const result = try serde.yaml.fromSlice(W, allocator, bytes);
    return result.v;
}

fn xmlRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const bytes = try serde.xml.toSlice(allocator, value);
    return serde.xml.fromSlice(T, allocator, bytes);
}

fn xmlScalarRoundtrip(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    const W = Wrap(T);
    const bytes = try serde.xml.toSlice(allocator, W{ .v = value });
    const result = try serde.xml.fromSlice(W, allocator, bytes);
    return result.v;
}

// Bool.

test "cross-format roundtrip: bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]bool{ true, false }) |v| {
        try testing.expectEqual(v, try jsonRoundtrip(bool, testing.allocator, v));
        try testing.expectEqual(v, try msgpackRoundtrip(bool, testing.allocator, v));
        try testing.expectEqual(v, try zonRoundtrip(bool, testing.allocator, v));
        try testing.expectEqual(v, try tomlScalarRoundtrip(bool, a, v));
        try testing.expectEqual(v, try yamlScalarRoundtrip(bool, a, v));
        try testing.expectEqual(v, try xmlScalarRoundtrip(bool, a, v));
    }
}

// Integers.

test "cross-format roundtrip: i32" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]i32{ 0, -1, 42, std.math.minInt(i32), std.math.maxInt(i32) }) |v| {
        try testing.expectEqual(v, try jsonRoundtrip(i32, testing.allocator, v));
        try testing.expectEqual(v, try msgpackRoundtrip(i32, testing.allocator, v));
        try testing.expectEqual(v, try zonRoundtrip(i32, testing.allocator, v));
        try testing.expectEqual(v, try tomlScalarRoundtrip(i32, a, v));
        try testing.expectEqual(v, try yamlScalarRoundtrip(i32, a, v));
        try testing.expectEqual(v, try xmlScalarRoundtrip(i32, a, v));
    }
}

test "cross-format roundtrip: i64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64), 0 }) |v| {
        try testing.expectEqual(v, try jsonRoundtrip(i64, testing.allocator, v));
        try testing.expectEqual(v, try msgpackRoundtrip(i64, testing.allocator, v));
        try testing.expectEqual(v, try zonRoundtrip(i64, testing.allocator, v));
        try testing.expectEqual(v, try tomlScalarRoundtrip(i64, a, v));
        try testing.expectEqual(v, try yamlScalarRoundtrip(i64, a, v));
        try testing.expectEqual(v, try xmlScalarRoundtrip(i64, a, v));
    }
}

// Float.

test "cross-format roundtrip: f64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v: f64 = 3.14;
    try testing.expectEqual(v, try jsonRoundtrip(f64, testing.allocator, v));
    try testing.expectEqual(v, try msgpackRoundtrip(f64, testing.allocator, v));
    try testing.expectEqual(v, try zonRoundtrip(f64, testing.allocator, v));
    try testing.expectEqual(v, try tomlScalarRoundtrip(f64, a, v));
    {
        const r = try yamlScalarRoundtrip(f64, a, v);
        try testing.expect(@abs(r - v) < 0.001);
    }
    {
        const r = try xmlScalarRoundtrip(f64, a, v);
        try testing.expect(@abs(r - v) < 0.001);
    }
}

// String.

test "cross-format roundtrip: string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v: []const u8 = "hello world";
    try testing.expectEqualStrings(v, try jsonRoundtrip([]const u8, a, v));
    try testing.expectEqualStrings(v, try msgpackRoundtrip([]const u8, a, v));
    try testing.expectEqualStrings(v, try zonRoundtrip([]const u8, a, v));
    try testing.expectEqualStrings(v, try tomlScalarRoundtrip([]const u8, a, v));
    try testing.expectEqualStrings(v, try yamlScalarRoundtrip([]const u8, a, v));
    try testing.expectEqualStrings(v, try xmlScalarRoundtrip([]const u8, a, v));
}

// Struct.

test "cross-format roundtrip: Point struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Point{ .x = 10, .y = -20 };
    try testing.expectEqualDeep(v, try jsonRoundtrip(Point, testing.allocator, v));
    try testing.expectEqualDeep(v, try msgpackRoundtrip(Point, testing.allocator, v));
    try testing.expectEqualDeep(v, try zonRoundtrip(Point, testing.allocator, v));
    try testing.expectEqualDeep(v, try tomlRoundtrip(Point, a, v));
    try testing.expectEqualDeep(v, try yamlRoundtrip(Point, a, v));
    try testing.expectEqualDeep(v, try xmlRoundtrip(Point, a, v));
}

// Nested struct.

test "cross-format roundtrip: nested struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Nested{ .name = "test", .inner = .{ .x = 1, .y = 2 } };
    {
        const r = try jsonRoundtrip(Nested, a, v);
        try testing.expectEqualStrings("test", r.name);
        try testing.expectEqual(@as(i32, 1), r.inner.x);
    }
    {
        const r = try msgpackRoundtrip(Nested, a, v);
        try testing.expectEqualStrings("test", r.name);
        try testing.expectEqual(@as(i32, 1), r.inner.x);
    }
    {
        const r = try zonRoundtrip(Nested, a, v);
        try testing.expectEqualStrings("test", r.name);
        try testing.expectEqual(@as(i32, 1), r.inner.x);
    }
    {
        const r = try tomlRoundtrip(Nested, a, v);
        try testing.expectEqualStrings("test", r.name);
        try testing.expectEqual(@as(i32, 1), r.inner.x);
    }
    {
        const r = try yamlRoundtrip(Nested, a, v);
        try testing.expectEqualStrings("test", r.name);
        try testing.expectEqual(@as(i32, 1), r.inner.x);
    }
    {
        const r = try xmlRoundtrip(Nested, a, v);
        try testing.expectEqualStrings("test", r.name);
        try testing.expectEqual(@as(i32, 1), r.inner.x);
    }
}

// Optional present.

test "cross-format roundtrip: optional present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v: ?i32 = 42;
    try testing.expectEqual(v, try jsonRoundtrip(?i32, testing.allocator, v));
    try testing.expectEqual(v, try msgpackRoundtrip(?i32, testing.allocator, v));
    try testing.expectEqual(v, try zonRoundtrip(?i32, testing.allocator, v));
    try testing.expectEqual(v, try tomlScalarRoundtrip(?i32, a, v));
    try testing.expectEqual(v, try yamlScalarRoundtrip(?i32, a, v));
    try testing.expectEqual(v, try xmlScalarRoundtrip(?i32, a, v));
}

// Optional null.

test "cross-format roundtrip: optional null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v: ?i32 = null;
    try testing.expectEqual(v, try jsonRoundtrip(?i32, testing.allocator, v));
    try testing.expectEqual(v, try msgpackRoundtrip(?i32, testing.allocator, v));
    try testing.expectEqual(v, try zonRoundtrip(?i32, testing.allocator, v));
    try testing.expectEqual(v, try tomlScalarRoundtrip(?i32, a, v));
    try testing.expectEqual(v, try yamlScalarRoundtrip(?i32, a, v));
    try testing.expectEqual(v, try xmlScalarRoundtrip(?i32, a, v));
}

// Slice.

test "cross-format roundtrip: slice" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v: []const i32 = &.{ 1, 2, 3 };
    try testing.expectEqualDeep(v, try jsonRoundtrip([]const i32, a, v));
    try testing.expectEqualDeep(v, try msgpackRoundtrip([]const i32, a, v));
    try testing.expectEqualDeep(v, try zonRoundtrip([]const i32, a, v));
    try testing.expectEqualDeep(v, try tomlScalarRoundtrip([]const i32, a, v));
    {
        const W = Wrap([]const i32);
        const bytes = try serde.yaml.toSlice(a, W{ .v = v });
        const result = try serde.yaml.fromSlice(W, a, bytes);
        try testing.expectEqualDeep(v, result.v);
    }
}

// Enum.

test "cross-format roundtrip: enum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Color.green, try jsonRoundtrip(Color, testing.allocator, Color.green));
    try testing.expectEqual(Color.green, try msgpackRoundtrip(Color, testing.allocator, Color.green));
    try testing.expectEqual(Color.green, try zonRoundtrip(Color, testing.allocator, Color.green));
    try testing.expectEqual(Color.green, try tomlScalarRoundtrip(Color, a, Color.green));
    try testing.expectEqual(Color.green, try yamlScalarRoundtrip(Color, a, Color.green));
    try testing.expectEqual(Color.green, try xmlScalarRoundtrip(Color, a, Color.green));
}

// Union void variant (ZON excluded — no union deserialization support).

test "cross-format roundtrip: union void variant" {
    try testing.expectEqual(Cmd.ping, try jsonRoundtrip(Cmd, testing.allocator, Cmd.ping));
    try testing.expectEqual(Cmd.ping, try msgpackRoundtrip(Cmd, testing.allocator, Cmd.ping));
}

// Union with payload.

test "cross-format roundtrip: union with payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Cmd{ .set = 99 };
    try testing.expectEqual(v, try jsonRoundtrip(Cmd, testing.allocator, v));
    try testing.expectEqual(v, try msgpackRoundtrip(Cmd, testing.allocator, v));
    {
        const W = Wrap(Cmd);
        const bytes = try serde.yaml.toSlice(a, W{ .v = v });
        const result = try serde.yaml.fromSlice(W, a, bytes);
        try testing.expectEqual(v, result.v);
    }
}
