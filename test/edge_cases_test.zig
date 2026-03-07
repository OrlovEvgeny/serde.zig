const std = @import("std");
const testing = std.testing;
const sz = @import("serde");


test "edge: empty string roundtrip JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { s: []const u8 };
    const bytes = try sz.json.toSlice(arena.allocator(), S{ .s = "" });
    const r = try sz.json.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqualStrings("", r.s);
}

test "edge: CJK multibyte string JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { s: []const u8 };
    const v = S{ .s = "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e" }; // "日本語"
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqualStrings(v.s, r.s);
}

test "edge: 4-byte emoji string JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { s: []const u8 };
    const v = S{ .s = "\xf0\x9f\x98\x80" }; // U+1F600
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqualStrings(v.s, r.s);
}

test "edge: string with all JSON escape chars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { s: []const u8 };
    const v = S{ .s = "tab\there\nnewline\rcarriage\\backslash\"quote" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqualStrings(v.s, r.s);
}

test "edge: control chars in string JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { s: []const u8 };
    // Control char 0x01 should be escaped as \u0001 in JSON.
    const v = S{ .s = &[_]u8{ 0x01, 0x1f } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqualSlices(u8, v.s, r.s);
}


test "edge: i8 min/max JSON" {
    const vals = [_]i8{ std.math.minInt(i8), std.math.maxInt(i8), 0, -1, 1 };
    for (vals) |v| {
        try testing.expectEqual(v, try jsonRoundtrip(i8, v));
    }
}

test "edge: i16 min/max JSON" {
    const vals = [_]i16{ std.math.minInt(i16), std.math.maxInt(i16), 0 };
    for (vals) |v| {
        try testing.expectEqual(v, try jsonRoundtrip(i16, v));
    }
}

test "edge: i32 min/max JSON" {
    const vals = [_]i32{ std.math.minInt(i32), std.math.maxInt(i32), 0, -1 };
    for (vals) |v| {
        try testing.expectEqual(v, try jsonRoundtrip(i32, v));
    }
}

test "edge: i64 min/max JSON" {
    const vals = [_]i64{ std.math.minInt(i64), std.math.maxInt(i64), 0 };
    for (vals) |v| {
        try testing.expectEqual(v, try jsonRoundtrip(i64, v));
    }
}

test "edge: u64 max JSON" {
    const v: u64 = std.math.maxInt(u64);
    try testing.expectEqual(v, try jsonRoundtrip(u64, v));
}

test "edge: negative zero f64 JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: f64 = -0.0;
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(f64, arena.allocator(), bytes);
    // -0.0 may or may not preserve sign through JSON; just check value.
    try testing.expectEqual(@as(f64, 0.0), @abs(r));
}

test "edge: float max/min JSON" {
    const vals = [_]f64{ std.math.floatMax(f64), std.math.floatMin(f64), std.math.floatEps(f64) };
    for (vals) |v| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const bytes = try sz.json.toSlice(arena.allocator(), v);
        const r = try sz.json.fromSlice(f64, arena.allocator(), bytes);
        // Tolerate some float precision loss through text serialization.
        if (v != 0.0) {
            try testing.expect(@abs((r - v) / v) < 1e-10);
        }
    }
}

// NaN/Inf behavior.

test "edge: NaN serializes to null in JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: f64 = std.math.nan(f64);
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expectEqualStrings("null", bytes);
}

test "edge: Inf serializes to null in JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: f64 = std.math.inf(f64);
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expectEqualStrings("null", bytes);
}

test "edge: NaN preserved in msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: f64 = std.math.nan(f64);
    const bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(f64, arena.allocator(), bytes);
    try testing.expect(std.math.isNan(r));
}

test "edge: Inf preserved in msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: f64 = std.math.inf(f64);
    const bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(f64, arena.allocator(), bytes);
    try testing.expect(std.math.isInf(r));
}

// JSON format quirk tests.

test "edge: JSON trailing whitespace accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try sz.json.fromSlice(i32, arena.allocator(), "42   \n\t ");
    try testing.expectEqual(@as(i32, 42), r);
}

test "edge: JSON number with exponent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try sz.json.fromSlice(f64, arena.allocator(), "1e10");
    try testing.expectEqual(@as(f64, 1e10), r);
}

test "edge: JSON negative exponent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try sz.json.fromSlice(f64, arena.allocator(), "1.5e-3");
    try testing.expect(@abs(r - 0.0015) < 1e-10);
}

// Struct deserialization edge cases.

test "edge: all-optional struct from empty JSON object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const AllOpt = struct {
        a: ?i32 = null,
        b: ?[]const u8 = null,
    };
    const r = try sz.json.fromSlice(AllOpt, arena.allocator(), "{}");
    try testing.expectEqual(@as(?i32, null), r.a);
}

test "edge: struct with default values JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const WithDefaults = struct {
        name: []const u8,
        count: i32 = 10,
    };
    const r = try sz.json.fromSlice(WithDefaults, arena.allocator(),
        \\{"name":"test"}
    );
    try testing.expectEqualStrings("test", r.name);
    try testing.expectEqual(@as(i32, 10), r.count);
}

// Integer type boundary roundtrips in msgpack.

test "edge: i8 min/max msgpack" {
    const vals = [_]i8{ std.math.minInt(i8), std.math.maxInt(i8) };
    for (vals) |v| {
        try testing.expectEqual(v, try msgpackRoundtrip(i8, v));
    }
}

test "edge: u8 max msgpack" {
    const v: u8 = std.math.maxInt(u8);
    try testing.expectEqual(v, try msgpackRoundtrip(u8, v));
}

test "edge: i64 min/max msgpack" {
    const vals = [_]i64{ std.math.minInt(i64), std.math.maxInt(i64) };
    for (vals) |v| {
        try testing.expectEqual(v, try msgpackRoundtrip(i64, v));
    }
}

test "edge: u64 max msgpack" {
    const v: u64 = std.math.maxInt(u64);
    try testing.expectEqual(v, try msgpackRoundtrip(u64, v));
}

// ZON edge cases.

test "edge: empty string ZON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { s: []const u8 };
    const bytes = try sz.zon.toSliceWith(arena.allocator(), S{ .s = "" }, .{ .pretty = false });
    const r = try sz.zon.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqualStrings("", r.s);
}

test "edge: string with escapes ZON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { s: []const u8 };
    const v = S{ .s = "line1\nline2\ttab" };
    const bytes = try sz.zon.toSliceWith(arena.allocator(), v, .{ .pretty = false });
    const r = try sz.zon.fromSlice(S, arena.allocator(), bytes);
    try testing.expectEqualStrings(v.s, r.s);
}

// TOML edge cases (struct at top level required).

test "edge: absent key = null for optional TOML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cfg = struct {
        name: []const u8,
        debug: ?bool = null,
    };
    const r = try sz.toml.fromSlice(Cfg, arena.allocator(), "name = \"app\"\n");
    try testing.expectEqualStrings("app", r.name);
    try testing.expectEqual(@as(?bool, null), r.debug);
}

test "edge: TOML multiline basic string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cfg = struct { msg: []const u8 };
    const r = try sz.toml.fromSlice(Cfg, arena.allocator(),
        \\msg = """
        \\hello
        \\world"""
        \\
    );
    try testing.expect(r.msg.len > 0);
}

// YAML edge cases.

test "edge: YAML absent key = null for optional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cfg = struct {
        name: []const u8,
        debug: ?bool = null,
    };
    const r = try sz.yaml.fromSlice(Cfg, arena.allocator(), "name: app\n");
    try testing.expectEqualStrings("app", r.name);
    try testing.expectEqual(@as(?bool, null), r.debug);
}

test "edge: YAML quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cfg = struct { name: []const u8 };
    const r = try sz.yaml.fromSlice(Cfg, arena.allocator(), "name: \"hello world\"\n");
    try testing.expectEqualStrings("hello world", r.name);
}

// Fixed array edge cases.

test "edge: fixed array [0]i32 JSON" {
    const arr = [0]i32{};
    const bytes = try sz.json.toSlice(testing.allocator, arr);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("[]", bytes);
    const r = try sz.json.fromSlice([0]i32, testing.allocator, bytes);
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "edge: fixed array [1]bool JSON" {
    const arr = [1]bool{true};
    const bytes = try sz.json.toSlice(testing.allocator, arr);
    defer testing.allocator.free(bytes);
    const r = try sz.json.fromSlice([1]bool, testing.allocator, bytes);
    try testing.expectEqual(true, r[0]);
}

// Bool edge cases.

test "edge: bool true/false JSON deserialization" {
    try testing.expectEqual(true, try sz.json.fromSlice(bool, testing.allocator, "true"));
    try testing.expectEqual(false, try sz.json.fromSlice(bool, testing.allocator, "false"));
}

// Enum edge cases.

test "edge: enum all variants JSON roundtrip" {
    const Color = enum { red, green, blue, alpha };
    const variants = [_]Color{ .red, .green, .blue, .alpha };
    for (variants) |v| {
        const bytes = try sz.json.toSlice(testing.allocator, v);
        defer testing.allocator.free(bytes);
        const r = try sz.json.fromSlice(Color, testing.allocator, bytes);
        try testing.expectEqual(v, r);
    }
}

test "edge: enum integer repr roundtrip JSON" {
    const Status = enum(u8) {
        active = 0,
        inactive = 1,
        pending = 2,

        pub const serde = .{
            .enum_repr = sz.EnumRepr.integer,
        };
    };
    const variants = [_]Status{ .active, .inactive, .pending };
    for (variants) |v| {
        const bytes = try sz.json.toSlice(testing.allocator, v);
        defer testing.allocator.free(bytes);
        const r = try sz.json.fromSlice(Status, testing.allocator, bytes);
        try testing.expectEqual(v, r);
    }
}

// Helpers.

fn jsonRoundtrip(comptime T: type, value: T) !T {
    const bytes = try sz.json.toSlice(testing.allocator, value);
    defer testing.allocator.free(bytes);
    return sz.json.fromSlice(T, testing.allocator, bytes);
}

fn msgpackRoundtrip(comptime T: type, value: T) !T {
    const bytes = try sz.msgpack.toSlice(testing.allocator, value);
    defer testing.allocator.free(bytes);
    return sz.msgpack.fromSlice(T, testing.allocator, bytes);
}
