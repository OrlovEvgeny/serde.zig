const std = @import("std");
const kind_mod = @import("kind.zig");
const serialize_mod = @import("serialize.zig");

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

    /// Convert any Zig value to a dynamic Value.
    pub fn fromAny(comptime T: type, value: T, allocator: Allocator) !Value {
        const k = comptime kind_mod.typeKind(T);
        switch (k) {
            .bool => return .{ .bool = value },
            .int => {
                const info = @typeInfo(T);
                if (info == .comptime_int) {
                    if (value >= 0) return .{ .uint = @intCast(value) };
                    return .{ .int = @intCast(value) };
                }
                if (info.int.signedness == .unsigned) {
                    return .{ .uint = @intCast(value) };
                }
                if (value >= 0) return .{ .uint = @intCast(value) };
                return .{ .int = @intCast(value) };
            },
            .float => return .{ .float = @floatCast(value) },
            .string => {
                const copy = try allocator.alloc(u8, value.len);
                @memcpy(copy, value);
                return .{ .string = copy };
            },
            .void => return .null,
            .optional => {
                if (value) |v| {
                    return fromAny(kind_mod.Child(T), v, allocator);
                }
                return .null;
            },
            .pointer => return fromAny(kind_mod.Child(T), value.*, allocator),
            .@"enum" => {
                const name = @tagName(value);
                const copy = try allocator.alloc(u8, name.len);
                @memcpy(copy, name);
                return .{ .string = copy };
            },
            .array => {
                const child = kind_mod.Child(T);
                var arr = try allocator.alloc(Value, value.len);
                errdefer {
                    for (arr) |a| a.deinit(allocator);
                    allocator.free(arr);
                }
                for (value, 0..) |elem, i| {
                    arr[i] = try fromAny(child, elem, allocator);
                }
                return .{ .array = arr };
            },
            .slice => {
                const child = kind_mod.Child(T);
                var arr = try allocator.alloc(Value, value.len);
                errdefer {
                    for (arr) |a| a.deinit(allocator);
                    allocator.free(arr);
                }
                for (value, 0..) |elem, i| {
                    arr[i] = try fromAny(child, elem, allocator);
                }
                return .{ .array = arr };
            },
            .@"struct" => {
                const info = @typeInfo(T).@"struct";
                var entries = try allocator.alloc(Entry, info.fields.len);
                errdefer {
                    for (entries) |e| {
                        allocator.free(e.key);
                        e.value.deinit(allocator);
                    }
                    allocator.free(entries);
                }
                inline for (info.fields, 0..) |field, i| {
                    const key = try allocator.alloc(u8, field.name.len);
                    @memcpy(key, field.name);
                    entries[i] = .{
                        .key = key,
                        .value = try fromAny(field.type, @field(value, field.name), allocator),
                    };
                }
                return .{ .object = entries };
            },
            .@"union" => {
                const info = @typeInfo(T).@"union";
                inline for (info.fields) |field| {
                    if (value == @field(T, field.name)) {
                        if (field.type == void) {
                            const key = try allocator.alloc(u8, field.name.len);
                            @memcpy(key, field.name);
                            const entries = try allocator.alloc(Entry, 1);
                            entries[0] = .{ .key = key, .value = .null };
                            return .{ .object = entries };
                        } else {
                            const payload = @field(value, field.name);
                            const key = try allocator.alloc(u8, field.name.len);
                            @memcpy(key, field.name);
                            const child_val = try fromAny(field.type, payload, allocator);
                            const entries = try allocator.alloc(Entry, 1);
                            entries[0] = .{ .key = key, .value = child_val };
                            return .{ .object = entries };
                        }
                    }
                }
                return .null;
            },
            .tuple => {
                const info = @typeInfo(T).@"struct";
                var arr = try allocator.alloc(Value, info.fields.len);
                errdefer {
                    for (arr) |a| a.deinit(allocator);
                    allocator.free(arr);
                }
                inline for (info.fields, 0..) |field, i| {
                    arr[i] = try fromAny(field.type, @field(value, field.name), allocator);
                }
                return .{ .array = arr };
            },
            .map => {
                var it = value.iterator();
                var count: usize = 0;
                while (it.next()) |_| count += 1;

                var entries = try allocator.alloc(Entry, count);
                errdefer {
                    for (entries) |e| {
                        allocator.free(e.key);
                        e.value.deinit(allocator);
                    }
                    allocator.free(entries);
                }

                var it2 = value.iterator();
                var idx: usize = 0;
                while (it2.next()) |entry| {
                    const kp = entry.key_ptr.*;
                    const key_str = if (@TypeOf(kp) == []const u8) blk: {
                        const copy = try allocator.alloc(u8, kp.len);
                        @memcpy(copy, kp);
                        break :blk copy;
                    } else blk: {
                        var buf: [40]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "{d}", .{kp}) catch unreachable;
                        const copy = try allocator.alloc(u8, s.len);
                        @memcpy(copy, s);
                        break :blk copy;
                    };
                    entries[idx] = .{
                        .key = key_str,
                        .value = try fromAny(@TypeOf(entry.value_ptr.*), entry.value_ptr.*, allocator),
                    };
                    idx += 1;
                }
                return .{ .object = entries };
            },
            else => return .null,
        }
    }

    /// Convert a dynamic Value back to a typed Zig value.
    pub fn toType(self: Value, comptime T: type, allocator: Allocator) !T {
        const k = comptime kind_mod.typeKind(T);
        switch (k) {
            .bool => return switch (self) {
                .bool => |b| b,
                else => error.WrongType,
            },
            .int => return switch (self) {
                .int => |i| std.math.cast(T, i) orelse error.Overflow,
                .uint => |u| std.math.cast(T, u) orelse error.Overflow,
                else => error.WrongType,
            },
            .float => return switch (self) {
                .float => |f| @floatCast(f),
                .int => |i| @floatFromInt(i),
                .uint => |u| @floatFromInt(u),
                else => error.WrongType,
            },
            .string => return switch (self) {
                .string => |s| {
                    const copy = try allocator.alloc(u8, s.len);
                    @memcpy(copy, s);
                    return copy;
                },
                else => error.WrongType,
            },
            .optional => {
                if (self == .null) return null;
                return try self.toType(kind_mod.Child(T), allocator);
            },
            .@"enum" => return switch (self) {
                .string => |s| {
                    inline for (@typeInfo(T).@"enum".fields) |field| {
                        if (std.mem.eql(u8, s, field.name))
                            return @enumFromInt(field.value);
                    }
                    return error.UnknownVariant;
                },
                else => error.WrongType,
            },
            .@"struct" => {
                const info = @typeInfo(T).@"struct";
                switch (self) {
                    .object => |entries| {
                        var result: T = undefined;
                        inline for (info.fields) |field| {
                            var found = false;
                            for (entries) |e| {
                                if (std.mem.eql(u8, e.key, field.name)) {
                                    @field(result, field.name) = try e.value.toType(field.type, allocator);
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                if (comptime field.defaultValue()) |dv| {
                                    @field(result, field.name) = dv;
                                } else if (@typeInfo(field.type) == .optional) {
                                    @field(result, field.name) = null;
                                } else {
                                    return error.MissingField;
                                }
                            }
                        }
                        return result;
                    },
                    else => return error.WrongType,
                }
            },
            .slice => {
                const child = kind_mod.Child(T);
                switch (self) {
                    .array => |arr| {
                        var items = try allocator.alloc(child, arr.len);
                        errdefer allocator.free(items);
                        for (arr, 0..) |elem, i| {
                            items[i] = try elem.toType(child, allocator);
                        }
                        return items;
                    },
                    else => return error.WrongType,
                }
            },
            .void => {
                if (self == .null) return {};
                return error.WrongType;
            },
            .array => {
                const info = @typeInfo(T).array;
                switch (self) {
                    .array => |arr| {
                        if (arr.len != info.len) return error.WrongType;
                        var result: T = undefined;
                        for (arr, 0..) |elem, i| {
                            result[i] = try elem.toType(info.child, allocator);
                        }
                        return result;
                    },
                    else => return error.WrongType,
                }
            },
            .pointer => {
                const child = kind_mod.Child(T);
                const val = try self.toType(child, allocator);
                const ptr = try allocator.create(child);
                ptr.* = val;
                return ptr;
            },
            .tuple => {
                const info = @typeInfo(T).@"struct";
                switch (self) {
                    .array => |arr| {
                        if (arr.len != info.fields.len) return error.WrongType;
                        var result: T = undefined;
                        inline for (info.fields, 0..) |field, i| {
                            @field(result, field.name) = try arr[i].toType(field.type, allocator);
                        }
                        return result;
                    },
                    else => return error.WrongType,
                }
            },
            .@"union" => {
                const info = @typeInfo(T).@"union";
                switch (self) {
                    // External tagging: single-entry object {"variant": payload}
                    .object => |entries| {
                        if (entries.len != 1) return error.WrongType;
                        const name = entries[0].key;
                        inline for (info.fields) |field| {
                            if (std.mem.eql(u8, name, field.name)) {
                                if (field.type == void) {
                                    return @unionInit(T, field.name, {});
                                } else {
                                    const payload = try entries[0].value.toType(field.type, allocator);
                                    return @unionInit(T, field.name, payload);
                                }
                            }
                        }
                        return error.UnknownVariant;
                    },
                    // Void variant as bare string.
                    .string => |s| {
                        inline for (info.fields) |field| {
                            if (field.type == void and std.mem.eql(u8, s, field.name)) {
                                return @unionInit(T, field.name, {});
                            }
                        }
                        return error.UnknownVariant;
                    },
                    else => return error.WrongType,
                }
            },
            .map => {
                const V = kind_mod.MapValueType(T);
                const managed = comptime kind_mod.isMapManaged(T);
                switch (self) {
                    .object => |entries| {
                        var result: T = if (managed) T.init(allocator) else .{};
                        for (entries) |e| {
                            const key_copy = try allocator.alloc(u8, e.key.len);
                            @memcpy(key_copy, e.key);
                            const val = try e.value.toType(V, allocator);
                            if (managed) {
                                result.put(key_copy, val) catch return error.OutOfMemory;
                            } else {
                                result.put(allocator, key_copy, val) catch return error.OutOfMemory;
                            }
                        }
                        return result;
                    },
                    else => return error.WrongType,
                }
            },
            else => return error.WrongType,
        }
    }

    pub const Error = error{
        OutOfMemory,
        WrongType,
        Overflow,
        MissingField,
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
