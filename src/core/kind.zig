const std = @import("std");

pub const Kind = enum {
    bool,
    int,
    float,
    string,
    bytes,
    array,
    slice,
    optional,
    @"struct",
    tuple,
    @"union",
    @"enum",
    void,
    pointer,
    map,
    custom,
};

/// Classify a Zig type into the serde data model.
pub fn typeKind(comptime T: type) Kind {
    // Custom takes priority — the type opts out of auto-derivation.
    // @hasDecl only works on struct/enum/union/opaque types.
    if (hasDeclSafe(T, "zerdeSerialize") or hasDeclSafe(T, "zerdeDeserialize"))
        return .custom;

    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int, .comptime_int => .int,
        .float, .comptime_float => .float,
        .void, .null => .void,
        .optional => .optional,
        .@"enum" => .@"enum",
        .@"union" => .@"union",
        .pointer => |p| classifyPointer(p),
        .array => .array,
        .@"struct" => |s| classifyStruct(T, s),
        else => @compileError("Unsupported type for serde: " ++ @typeName(T)),
    };
}

fn classifyPointer(comptime p: std.builtin.Type.Pointer) Kind {
    if (p.size == .slice) {
        if (p.child == u8) return .string;
        return .slice;
    }
    // Sentinel-terminated pointer to u8 → string.
    if (p.size == .many and p.child == u8 and p.sentinel != null)
        return .string;
    if (p.size == .one)
        return .pointer;
    @compileError("Unsupported pointer type for serde");
}

fn classifyStruct(comptime T: type, comptime s: std.builtin.Type.Struct) Kind {
    // HashMap-like: duck-type on getOrPut + iterator.
    if (isMapLike(T)) return .map;
    // Tuple: anonymous struct with all numeric field names.
    if (s.is_tuple) return .tuple;
    return .@"struct";
}

fn hasDeclSafe(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

fn isMapLike(comptime T: type) bool {
    return @hasDecl(T, "getOrPut") and @hasDecl(T, "iterator");
}

/// Extract the key type from a HashMap-like type via its KV declaration.
pub fn MapKeyType(comptime T: type) type {
    if (@hasDecl(T, "KV")) {
        return @TypeOf(@as(T.KV, undefined).key);
    }
    @compileError(@typeName(T) ++ " has no KV decl; cannot extract map key type");
}

/// Extract the value type from a HashMap-like type via its KV declaration.
pub fn MapValueType(comptime T: type) type {
    if (@hasDecl(T, "KV")) {
        return @TypeOf(@as(T.KV, undefined).value);
    }
    @compileError(@typeName(T) ++ " has no KV decl; cannot extract map value type");
}

/// Managed HashMaps store an allocator internally; unmanaged ones don't.
/// Distinguishes put(key, val) vs put(allocator, key, val).
pub fn isMapManaged(comptime T: type) bool {
    return @hasDecl(T, "Unmanaged");
}

/// Extract the child type from optionals, pointers, slices, arrays.
pub fn Child(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        .pointer => |p| switch (p.size) {
            .one => p.child,
            .slice, .many => p.child,
            else => @compileError("Cannot get child of " ++ @typeName(T)),
        },
        .array => |a| a.child,
        else => @compileError("Cannot get child of " ++ @typeName(T)),
    };
}

// Tests.

const testing = std.testing;

test "scalar kinds" {
    try testing.expectEqual(.bool, comptime typeKind(bool));
    try testing.expectEqual(.int, comptime typeKind(u8));
    try testing.expectEqual(.int, comptime typeKind(i64));
    try testing.expectEqual(.int, comptime typeKind(u128));
    try testing.expectEqual(.float, comptime typeKind(f32));
    try testing.expectEqual(.float, comptime typeKind(f64));
    try testing.expectEqual(.void, comptime typeKind(void));
}

test "string kinds" {
    try testing.expectEqual(.string, comptime typeKind([]const u8));
    try testing.expectEqual(.string, comptime typeKind([]u8));
    try testing.expectEqual(.string, comptime typeKind([:0]const u8));
}

test "container kinds" {
    try testing.expectEqual(.array, comptime typeKind([4]u8));
    try testing.expectEqual(.array, comptime typeKind([3]i32));
    try testing.expectEqual(.slice, comptime typeKind([]const i32));
    try testing.expectEqual(.optional, comptime typeKind(?u32));
    try testing.expectEqual(.pointer, comptime typeKind(*u32));
}

test "struct and tuple kinds" {
    const Point = struct { x: i32, y: i32 };
    try testing.expectEqual(.@"struct", comptime typeKind(Point));
    try testing.expectEqual(.tuple, comptime typeKind(struct { i32, i32 }));
}

test "enum and union kinds" {
    const Color = enum { red, green, blue };
    const Shape = union(enum) { circle: f64, rect: struct { w: f64, h: f64 } };
    try testing.expectEqual(.@"enum", comptime typeKind(Color));
    try testing.expectEqual(.@"union", comptime typeKind(Shape));
}

test "custom kind" {
    const Custom = struct {
        val: u32,
        pub fn zerdeSerialize(_: @This(), _: anytype) !void {}
    };
    try testing.expectEqual(.custom, comptime typeKind(Custom));
}

test "map kind" {
    try testing.expectEqual(.map, comptime typeKind(std.StringHashMap(i32)));
    try testing.expectEqual(.map, comptime typeKind(std.AutoHashMap(u32, u32)));
}

test "Child extraction" {
    try testing.expect(Child(?u32) == u32);
    try testing.expect(Child(*u32) == u32);
    try testing.expect(Child([]const u8) == u8);
    try testing.expect(Child([4]i32) == i32);
}
