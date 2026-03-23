const std = @import("std");
const testing = std.testing;
const serde = @import("serde");

// Deeply nested struct chain: Level0 -> Level1 -> ... -> Level9.
const Level9 = struct { val: i32 };
const Level8 = struct { inner: Level9 };
const Level7 = struct { inner: Level8 };
const Level6 = struct { inner: Level7 };
const Level5 = struct { inner: Level6 };
const Level4 = struct { inner: Level5 };
const Level3 = struct { inner: Level4 };
const Level2 = struct { inner: Level3 };
const Level1 = struct { inner: Level2 };
const Level0 = struct { inner: Level1 };

fn makeNested() Level0 {
    return .{ .inner = .{ .inner = .{ .inner = .{ .inner = .{ .inner = .{
        .inner = .{ .inner = .{ .inner = .{ .inner = .{ .val = 42 } } } },
    } } } } } };
}

fn extractDeep(l: Level0) i32 {
    return l.inner.inner.inner.inner.inner.inner.inner.inner.inner.val;
}

const WideStruct = struct {
    f01: i32,
    f02: i32,
    f03: i32,
    f04: i32,
    f05: i32,
    f06: f64,
    f07: f64,
    f08: f64,
    f09: bool,
    f10: bool,
    f11: []const u8,
    f12: []const u8,
    f13: ?i32,
    f14: ?i32,
    f15: ?[]const u8,
    f16: i64,
    f17: i64,
    f18: u32,
    f19: u32,
    f20: u64,
    f21: i8,
    f22: i16,
    f23: u8,
    f24: u16,
    f25: f32,
    f26: bool,
    f27: bool,
    f28: bool,
    f29: i32,
    f30: i32,
};

fn makeWide() WideStruct {
    return .{
        .f01 = 1,
        .f02 = -2,
        .f03 = 3,
        .f04 = 4,
        .f05 = 5,
        .f06 = 1.5,
        .f07 = -2.5,
        .f08 = 0.0,
        .f09 = true,
        .f10 = false,
        .f11 = "hello",
        .f12 = "world",
        .f13 = 42,
        .f14 = null,
        .f15 = null,
        .f16 = std.math.maxInt(i64),
        .f17 = std.math.minInt(i64),
        .f18 = 100,
        .f19 = 0,
        .f20 = std.math.maxInt(u64),
        .f21 = -1,
        .f22 = -256,
        .f23 = 255,
        .f24 = 65535,
        .f25 = 3.14,
        .f26 = true,
        .f27 = false,
        .f28 = true,
        .f29 = -999,
        .f30 = 999,
    };
}

const TreeNode = struct {
    label: []const u8,
    value: i32,
    children: []const TreeNode,
};

fn makeTree() TreeNode {
    return .{
        .label = "root",
        .value = 1,
        .children = &.{
            .{
                .label = "left",
                .value = 2,
                .children = &.{
                    .{ .label = "ll", .value = 4, .children = &.{} },
                    .{ .label = "lr", .value = 5, .children = &.{} },
                },
            },
            .{
                .label = "right",
                .value = 3,
                .children = &.{
                    .{ .label = "rl", .value = 6, .children = &.{} },
                },
            },
        },
    };
}

const BigUnion = union(enum) {
    v_void: void,
    v_int: i32,
    v_float: f64,
    v_str: []const u8,
    v_bool: bool,
    v_point: struct { x: i32, y: i32 },
    v_opt: ?i32,
    v_i64: i64,
    v_u32: u32,
    v_pair: struct { a: []const u8, b: []const u8 },
};

const Item = struct {
    name: []const u8,
    tags: []const []const u8,
};

const AllOptional = struct {
    a: ?i32 = null,
    b: ?[]const u8 = null,
    c: ?bool = null,
    d: ?f64 = null,
};

// JSON roundtrip.

test "stress: deeply nested struct JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeNested();
    const bytes = try serde.json.toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const r = try serde.json.fromSlice(Level0, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), extractDeep(r));
}

test "stress: wide struct JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeWide();
    const bytes = try serde.json.toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const r = try serde.json.fromSlice(WideStruct, arena.allocator(), bytes);
    try testing.expectEqual(v.f01, r.f01);
    try testing.expectEqual(v.f05, r.f05);
    try testing.expectEqual(v.f09, r.f09);
    try testing.expectEqual(v.f14, r.f14);
    try testing.expectEqual(v.f20, r.f20);
    try testing.expectEqual(v.f30, r.f30);
}

test "stress: recursive tree JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeTree();
    const bytes = try serde.json.toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const r = try serde.json.fromSlice(TreeNode, arena.allocator(), bytes);
    try testing.expectEqualStrings("root", r.label);
    try testing.expectEqual(@as(usize, 2), r.children.len);
    try testing.expectEqualStrings("left", r.children[0].label);
    try testing.expectEqual(@as(usize, 2), r.children[0].children.len);
    try testing.expectEqualStrings("rl", r.children[1].children[0].label);
}

test "stress: large i32 slice JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var data: [1000]i32 = undefined;
    for (&data, 0..) |*d, i| d.* = @intCast(i);
    const slice: []const i32 = &data;
    const bytes = try serde.json.toSlice(arena.allocator(), slice);
    const r = try serde.json.fromSlice([]const i32, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 1000), r.len);
    try testing.expectEqual(@as(i32, 0), r[0]);
    try testing.expectEqual(@as(i32, 999), r[999]);
}

test "stress: large string JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const big = "A" ** 10000;
    const S = struct { data: []const u8 };
    const bytes = try serde.json.toSlice(arena.allocator(), S{ .data = big });
    const r = try serde.json.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 10000), r.data.len);
}

test "stress: big union variants JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cases = [_]BigUnion{
        .{ .v_void = {} },
        .{ .v_int = -42 },
        .{ .v_float = 3.14 },
        .{ .v_str = "hello" },
        .{ .v_bool = true },
        .{ .v_point = .{ .x = 1, .y = 2 } },
        .{ .v_i64 = std.math.maxInt(i64) },
        .{ .v_u32 = 999 },
    };
    for (cases) |v| {
        const bytes = try serde.json.toSlice(arena.allocator(), v);
        const r = try serde.json.fromSlice(BigUnion, arena.allocator(), bytes);
        switch (v) {
            .v_void => try testing.expectEqual(BigUnion.v_void, r),
            .v_int => |val| try testing.expectEqual(val, r.v_int),
            .v_bool => |val| try testing.expectEqual(val, r.v_bool),
            .v_u32 => |val| try testing.expectEqual(val, r.v_u32),
            .v_i64 => |val| try testing.expectEqual(val, r.v_i64),
            .v_str => |val| try testing.expectEqualStrings(val, r.v_str),
            .v_point => |val| {
                try testing.expectEqual(val.x, r.v_point.x);
                try testing.expectEqual(val.y, r.v_point.y);
            },
            .v_float => |val| try testing.expect(@abs(val - r.v_float) < 0.001),
            else => {},
        }
    }
}

test "stress: nested string slices JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const item = Item{ .name = "test", .tags = &.{ "a", "b", "c" } };
    const bytes = try serde.json.toSlice(arena.allocator(), item);
    const r = try serde.json.fromSlice(Item, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", r.name);
    try testing.expectEqual(@as(usize, 3), r.tags.len);
    try testing.expectEqualStrings("b", r.tags[1]);
}

test "stress: empty containers JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Empty slice.
    const empty: []const i32 = &.{};
    const bytes1 = try serde.json.toSlice(arena.allocator(), empty);
    const r1 = try serde.json.fromSlice([]const i32, arena.allocator(), bytes1);
    try testing.expectEqual(@as(usize, 0), r1.len);

    // Empty string.
    const S = struct { s: []const u8 };
    const bytes2 = try serde.json.toSlice(arena.allocator(), S{ .s = "" });
    const r2 = try serde.json.fromSlice(S, arena.allocator(), bytes2);
    try testing.expectEqualStrings("", r2.s);

    // All null optionals.
    const bytes3 = try serde.json.toSlice(arena.allocator(), AllOptional{});
    const r3 = try serde.json.fromSlice(AllOptional, arena.allocator(), bytes3);
    try testing.expectEqual(@as(?i32, null), r3.a);
    try testing.expectEqual(@as(?bool, null), r3.c);
}

test "stress: slice of 100 structs JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Point = struct { x: i32, y: i32 };
    var items: [100]Point = undefined;
    for (&items, 0..) |*p, i| {
        p.* = .{ .x = @intCast(i), .y = @intCast(i * 2) };
    }
    const slice: []const Point = &items;
    const bytes = try serde.json.toSlice(arena.allocator(), slice);
    const r = try serde.json.fromSlice([]const Point, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 100), r.len);
    try testing.expectEqual(@as(i32, 0), r[0].x);
    try testing.expectEqual(@as(i32, 99), r[99].x);
    try testing.expectEqual(@as(i32, 198), r[99].y);
}

// MsgPack roundtrip.

test "stress: deeply nested struct msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeNested();
    const bytes = try serde.msgpack.toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const r = try serde.msgpack.fromSlice(Level0, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), extractDeep(r));
}

test "stress: wide struct msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeWide();
    const bytes = try serde.msgpack.toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const r = try serde.msgpack.fromSlice(WideStruct, arena.allocator(), bytes);
    try testing.expectEqual(v.f01, r.f01);
    try testing.expectEqual(v.f20, r.f20);
    try testing.expectEqual(v.f30, r.f30);
}

test "stress: recursive tree msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeTree();
    const bytes = try serde.msgpack.toSlice(testing.allocator, v);
    defer testing.allocator.free(bytes);
    const r = try serde.msgpack.fromSlice(TreeNode, arena.allocator(), bytes);
    try testing.expectEqualStrings("root", r.label);
    try testing.expectEqual(@as(usize, 2), r.children.len);
}

test "stress: big union variants msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = BigUnion{ .v_int = 42 };
    const bytes = try serde.msgpack.toSlice(arena.allocator(), v);
    const r = try serde.msgpack.fromSlice(BigUnion, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), r.v_int);
}

// ZON roundtrip.

test "stress: deeply nested struct ZON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeNested();
    const bytes = try serde.zon.toSliceWith(testing.allocator, v, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const r = try serde.zon.fromSlice(Level0, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), extractDeep(r));
}

test "stress: wide struct ZON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = makeWide();
    const bytes = try serde.zon.toSliceWith(testing.allocator, v, .{ .pretty = false });
    defer testing.allocator.free(bytes);
    const r = try serde.zon.fromSlice(WideStruct, arena.allocator(), bytes);
    try testing.expectEqual(v.f01, r.f01);
    try testing.expectEqual(v.f20, r.f20);
}

// TOML roundtrip (struct required at top level).

test "stress: nested struct TOML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // TOML can't go 10 levels deep easily, use 3 levels.
    const C = struct { val: i32 };
    const B = struct { c: C };
    const A = struct { name: []const u8, b: B };
    const v = A{ .name = "test", .b = .{ .c = .{ .val = 7 } } };
    const bytes = try serde.toml.toSlice(arena.allocator(), v);
    const r = try serde.toml.fromSlice(A, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", r.name);
    try testing.expectEqual(@as(i32, 7), r.b.c.val);
}

test "stress: wide struct TOML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // TOML needs struct at top level. Use a subset since TOML doesn't support
    // all types (no u64 max as TOML integers are i64).
    const TomlWide = struct {
        f01: i32,
        f02: i32,
        f03: i32,
        f04: i32,
        f05: i32,
        f06: f64,
        f09: bool,
        f10: bool,
        f11: []const u8,
        f12: []const u8,
        f16: i64,
        f29: i32,
        f30: i32,
    };
    const v = TomlWide{
        .f01 = 1,
        .f02 = -2,
        .f03 = 3,
        .f04 = 4,
        .f05 = 5,
        .f06 = 1.5,
        .f09 = true,
        .f10 = false,
        .f11 = "hello",
        .f12 = "world",
        .f16 = 123456,
        .f29 = -999,
        .f30 = 999,
    };
    const bytes = try serde.toml.toSlice(arena.allocator(), v);
    const r = try serde.toml.fromSlice(TomlWide, arena.allocator(), bytes);
    try testing.expectEqual(v.f01, r.f01);
    try testing.expectEqual(v.f30, r.f30);
    try testing.expectEqualStrings("hello", r.f11);
}

// YAML roundtrip.

test "stress: deeply nested struct YAML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const C = struct { val: i32 };
    const B = struct { inner: C };
    const A = struct { inner: B };
    const v = A{ .inner = .{ .inner = .{ .val = 7 } } };
    const bytes = try serde.yaml.toSlice(arena.allocator(), v);
    const r = try serde.yaml.fromSlice(A, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 7), r.inner.inner.val);
}

test "stress: slice of 100 structs msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Point = struct { x: i32, y: i32 };
    var items: [100]Point = undefined;
    for (&items, 0..) |*p, i| {
        p.* = .{ .x = @intCast(i), .y = @intCast(i * 2) };
    }
    const slice: []const Point = &items;
    const bytes = try serde.msgpack.toSlice(arena.allocator(), slice);
    const r = try serde.msgpack.fromSlice([]const Point, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 100), r.len);
    try testing.expectEqual(@as(i32, 99), r[99].x);
}

test "stress: nested slices of structs JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Container = struct {
        items: []const Item,
    };
    const items: []const Item = &.{
        .{ .name = "a", .tags = &.{ "x", "y" } },
        .{ .name = "b", .tags = &.{} },
        .{ .name = "c", .tags = &.{"z"} },
    };
    const c = Container{ .items = items };
    const bytes = try serde.json.toSlice(arena.allocator(), c);
    const r = try serde.json.fromSlice(Container, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 3), r.items.len);
    try testing.expectEqual(@as(usize, 2), r.items[0].tags.len);
    try testing.expectEqualStrings("y", r.items[0].tags[1]);
    try testing.expectEqual(@as(usize, 0), r.items[1].tags.len);
}
