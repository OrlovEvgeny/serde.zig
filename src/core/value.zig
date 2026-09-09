const std = @import("std");
const kind_mod = @import("kind.zig");
const serialize_mod = @import("serialize.zig");
const reflect = @import("../reflect.zig");

const Allocator = std.mem.Allocator;
const Kind = kind_mod.Kind;

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

/// Format-agnostic dynamic value type. Preserves insertion order for objects.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    array: []Value,
    object: []Entry,

    /// Free all memory owned by this value.
    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |elem| elem.deinit(allocator);
                allocator.free(arr);
            },
            .object => |entries| {
                for (entries) |e| {
                    allocator.free(e.key);
                    e.value.deinit(allocator);
                }
                allocator.free(entries);
            },
            else => {},
        }
    }

    /// Convert through the common serialization engine, including type options.
    pub fn fromAny(comptime T: type, value: T, allocator: Allocator) !Value {
        var result: ?Value = null;
        errdefer if (result) |v| v.deinit(allocator);
        var serializer = @import("value_adapter.zig").Serializer.init(allocator, &result);
        try serialize_mod.serialize(T, value, &serializer, .{});
        return result.?;
    }

    /// Convert through the common deserialization engine, including cleanup.
    pub fn toType(self: Value, comptime T: type, allocator: Allocator) !T {
        var deserializer = @import("value_adapter.zig").Deserializer{ .value = &self };
        return @import("deserialize.zig").deserialize(T, allocator, &deserializer, .{});
    }

    pub const Error = error{
        OutOfMemory,
        WrongType,
        Overflow,
        MissingField,
        DuplicateField,
        UnknownVariant,
    };
};

// Tests.

const testing = std.testing;

test "fromAny scalar types" {
    const b = try Value.fromAny(bool, true, testing.allocator);
    try testing.expectEqual(Value{ .bool = true }, b);

    const i = try Value.fromAny(i32, -42, testing.allocator);
    try testing.expectEqual(Value{ .int = -42 }, i);

    const u = try Value.fromAny(u32, 42, testing.allocator);
    try testing.expectEqual(Value{ .uint = 42 }, u);

    const f = try Value.fromAny(f64, 3.14, testing.allocator);
    try testing.expectEqual(Value{ .float = 3.14 }, f);
}

test "fromAny string" {
    const v = try Value.fromAny([]const u8, "hello", testing.allocator);
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", v.string);
}

test "fromAny null optional" {
    const v = try Value.fromAny(?i32, null, testing.allocator);
    try testing.expectEqual(Value.null, v);
}

test "fromAny struct" {
    const Point = struct { x: i32, y: i32 };
    const v = try Value.fromAny(Point, .{ .x = 1, .y = 2 }, testing.allocator);
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), v.object.len);
    try testing.expectEqualStrings("x", v.object[0].key);
    try testing.expectEqual(Value{ .uint = 1 }, v.object[0].value);
}

test "fromAny slice" {
    const data: []const i32 = &.{ 1, 2, 3 };
    const v = try Value.fromAny([]const i32, data, testing.allocator);
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), v.array.len);
    try testing.expectEqual(Value{ .uint = 1 }, v.array[0]);
}

test "toType roundtrip" {
    const Point = struct { x: i32, y: i32 };
    const v = try Value.fromAny(Point, .{ .x = 10, .y = 20 }, testing.allocator);
    defer v.deinit(testing.allocator);

    const result = try v.toType(Point, testing.allocator);
    try testing.expectEqual(@as(i32, 10), result.x);
    try testing.expectEqual(@as(i32, 20), result.y);
}

test "toType string" {
    const v = try Value.fromAny([]const u8, "hello", testing.allocator);
    defer v.deinit(testing.allocator);

    const result = try v.toType([]const u8, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "toType optional" {
    const v: Value = .null;
    const result = try v.toType(?i32, testing.allocator);
    try testing.expectEqual(@as(?i32, null), result);
}

test "toType enum" {
    const Color = enum { red, green, blue };
    const v = try Value.fromAny(Color, .green, testing.allocator);
    defer v.deinit(testing.allocator);

    const result = try v.toType(Color, testing.allocator);
    try testing.expectEqual(Color.green, result);
}

test "toType void" {
    const v: Value = .null;
    const result = try v.toType(void, testing.allocator);
    _ = result;
}

test "toType array" {
    const data: [3]i32 = .{ 1, 2, 3 };
    const v = try Value.fromAny([3]i32, data, testing.allocator);
    defer v.deinit(testing.allocator);

    const result = try v.toType([3]i32, testing.allocator);
    try testing.expectEqual(@as(i32, 1), result[0]);
    try testing.expectEqual(@as(i32, 2), result[1]);
    try testing.expectEqual(@as(i32, 3), result[2]);
}

test "toType pointer" {
    const v: Value = .{ .uint = 42 };
    const result = try v.toType(*i32, testing.allocator);
    defer testing.allocator.destroy(result);
    try testing.expectEqual(@as(i32, 42), result.*);
}

test "toType tuple" {
    const T = struct { i32, []const u8 };
    var arr = try testing.allocator.alloc(Value, 2);
    arr[0] = .{ .int = 10 };
    const s = try testing.allocator.alloc(u8, 2);
    @memcpy(s, "hi");
    arr[1] = .{ .string = s };
    const v: Value = .{ .array = arr };
    defer v.deinit(testing.allocator);

    const result = try v.toType(T, testing.allocator);
    defer testing.allocator.free(result[1]);
    try testing.expectEqual(@as(i32, 10), result[0]);
    try testing.expectEqualStrings("hi", result[1]);
}

test "fromAny and toType union roundtrip" {
    const Shape = union(enum) { circle: f64, point: void };
    const v = try Value.fromAny(Shape, .{ .circle = 3.14 }, testing.allocator);
    defer v.deinit(testing.allocator);

    const result = try v.toType(Shape, testing.allocator);
    try testing.expect(@abs(result.circle - 3.14) < 0.001);

    const v2 = try Value.fromAny(Shape, Shape.point, testing.allocator);
    defer v2.deinit(testing.allocator);
    const result2 = try v2.toType(Shape, testing.allocator);
    try testing.expectEqual(Shape.point, result2);
}

test "fromAny and toType tuple roundtrip" {
    const T = struct { i32, bool };
    const v = try Value.fromAny(T, .{ 7, true }, testing.allocator);
    defer v.deinit(testing.allocator);
    const result = try v.toType(T, testing.allocator);
    try testing.expectEqual(@as(i32, 7), result[0]);
    try testing.expectEqual(true, result[1]);
}
