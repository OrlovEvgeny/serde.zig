const std = @import("std");
const kind_mod = @import("kind.zig");
const opts = @import("options.zig");

const Kind = kind_mod.Kind;
const Child = kind_mod.Child;
const typeKind = kind_mod.typeKind;
const Allocator = std.mem.Allocator;

/// Deserialize a value of type T from a format-specific deserializer.
pub fn deserialize(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    if (comptime opts.hasCustomDeserializer(T)) {
        return T.zerdeDeserialize(T, allocator, deserializer);
    }

    return switch (comptime typeKind(T)) {
        .bool => deserializer.deserializeBool(),
        .int => deserializer.deserializeInt(T),
        .float => deserializer.deserializeFloat(T),
        .string => deserializer.deserializeString(allocator),
        .void => deserializer.deserializeVoid(),
        .optional => deserializer.deserializeOptional(Child(T), allocator),
        .@"struct" => deserializeStructFields(T, allocator, deserializer),
        .@"enum" => deserializer.deserializeEnum(T),
        .@"union" => deserializer.deserializeUnion(T, allocator),
        .array => deserializeArray(T, allocator, deserializer),
        .slice => deserializer.deserializeSeq(T, allocator),
        .pointer => deserializePointer(T, allocator, deserializer),
        .tuple => deserializeTuple(T, allocator, deserializer),
        else => @compileError("Cannot auto-deserialize: " ++ @typeName(T)),
    };
}

fn deserializeArray(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).array;
    const child = info.child;
    var result: T = undefined;
    var seq = try deserializer.deserializeSeqAccess();
    for (0..info.len) |i| {
        result[i] = try seq.nextElement(child, allocator) orelse return deserializer.raiseError(error.UnexpectedEof);
    }
    return result;
}

fn deserializePointer(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const child = Child(T);
    const val = try deserialize(child, allocator, deserializer);
    const ptr = try allocator.create(child);
    ptr.* = val;
    return ptr;
}

fn deserializeTuple(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    var seq = try deserializer.deserializeSeqAccess();
    inline for (info.fields) |field| {
        @field(result, field.name) = try seq.nextElement(field.type, allocator) orelse
            return deserializer.raiseError(error.UnexpectedEof);
    }
    return result;
}

/// Struct deserialization: iterate input keys, match against comptime-known fields.
fn deserializeStructFields(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"struct";

    var result: T = undefined;
    var fields_seen = std.StaticBitSet(info.fields.len).initEmpty();

    // Apply compile-time and struct-level defaults.
    inline for (info.fields, 0..) |field, i| {
        if (comptime opts.shouldSkipField(T, field.name, .deserialize)) {
            if (comptime field.defaultValue()) |dv| {
                @field(result, field.name) = dv;
                fields_seen.set(i);
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
                fields_seen.set(i);
            }
            continue;
        }
        if (comptime field.defaultValue()) |dv| {
            @field(result, field.name) = dv;
            fields_seen.set(i);
        }
        if (comptime opts.hasSerdeDefault(T, field.name)) {
            @field(result, field.name) = comptime opts.getSerdeDefault(T, field.name);
            fields_seen.set(i);
        }
    }

    var map = try deserializer.deserializeStruct(T);

    while (try map.nextKey(allocator)) |key| {
        var matched = false;

        inline for (info.fields, 0..) |field, i| {
            if (comptime opts.shouldSkipField(T, field.name, .deserialize)) continue;

            const wire_name = comptime opts.wireFieldName(T, field.name);
            if (std.mem.eql(u8, key, wire_name)) {
                @field(result, field.name) = try map.nextValue(field.type, allocator);
                fields_seen.set(i);
                matched = true;
            }
        }

        if (!matched) {
            if (comptime opts.denyUnknownFields(T)) {
                return map.raiseError(error.UnknownField);
            }
            try map.skipValue();
        }
    }

    // Validate required fields.
    inline for (info.fields, 0..) |field, i| {
        if (!fields_seen.isSet(i)) {
            if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return map.raiseError(error.MissingField);
            }
        }
    }

    return result;
}

// Tests with a mock deserializer.

const testing = std.testing;

const MockMapAccess = struct {
    keys: []const []const u8,
    values: []const MockValue,
    pos: usize = 0,

    pub const Error = error{ UnknownField, MissingField, UnexpectedEof, OutOfMemory, WrongType };

    pub fn nextKey(self: *MockMapAccess, _: Allocator) Error!?[]const u8 {
        if (self.pos >= self.keys.len) return null;
        return self.keys[self.pos];
    }

    pub fn nextValue(self: *MockMapAccess, comptime T: type, _: Allocator) Error!T {
        if (self.pos >= self.values.len) return error.UnexpectedEof;
        const v = self.values[self.pos];
        self.pos += 1;
        return switch (v) {
            .int => |i| if (T == i32 or T == u32 or T == u64 or T == i64) @intCast(i) else error.WrongType,
            .string => |s| if (T == []const u8) s else error.WrongType,
            .boolean => |b| if (T == bool) b else error.WrongType,
            .float => |f| if (T == f64 or T == f32) @floatCast(f) else error.WrongType,
        };
    }

    pub fn skipValue(self: *MockMapAccess) Error!void {
        self.pos += 1;
    }

    pub fn raiseError(_: *MockMapAccess, err: anyerror) Error {
        return switch (err) {
            error.UnknownField => error.UnknownField,
            error.MissingField => error.MissingField,
            else => error.WrongType,
        };
    }
};

const MockValue = union(enum) {
    int: i64,
    string: []const u8,
    boolean: bool,
    float: f64,
};

const MockDeserializer = struct {
    map: MockMapAccess,

    pub const Error = MockMapAccess.Error;

    pub fn deserializeStruct(self: *MockDeserializer, comptime _: type) Error!*MockMapAccess {
        return &self.map;
    }

    pub fn deserializeBool(_: *MockDeserializer) Error!bool {
        return true;
    }

    pub fn deserializeInt(_: *MockDeserializer, comptime T: type) Error!T {
        return 0;
    }

    pub fn deserializeFloat(_: *MockDeserializer, comptime T: type) Error!T {
        return 0;
    }

    pub fn deserializeString(_: *MockDeserializer, _: Allocator) Error![]const u8 {
        return "";
    }

    pub fn deserializeVoid(_: *MockDeserializer) Error!void {}

    pub fn deserializeOptional(_: *MockDeserializer, comptime _: type, _: Allocator) Error!void {}

    pub fn deserializeEnum(_: *MockDeserializer, comptime T: type) Error!T {
        return @enumFromInt(0);
    }

    pub fn deserializeUnion(_: *MockDeserializer, comptime _: type, _: Allocator) Error!void {}

    pub fn deserializeSeq(_: *MockDeserializer, comptime _: type, _: Allocator) Error!void {}

    pub fn raiseError(_: *MockDeserializer, err: anyerror) Error {
        return switch (err) {
            error.UnknownField => error.UnknownField,
            error.MissingField => error.MissingField,
            else => error.WrongType,
        };
    }
};

test "deserialize struct basic" {
    const Point = struct { x: i32, y: i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "y" },
            .values = &.{ .{ .int = 10 }, .{ .int = 20 } },
        },
    };
    const point = try deserialize(Point, testing.allocator, &deser);
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize struct with optional missing" {
    const Opt = struct { a: i32, b: ?i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 5 }},
        },
    };
    const val = try deserialize(Opt, testing.allocator, &deser);
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deserialize struct missing required field" {
    const Req = struct { a: i32, b: i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 1 }},
        },
    };
    const result = deserialize(Req, testing.allocator, &deser);
    try testing.expectError(error.MissingField, result);
}

test "deserialize struct with default" {
    const Def = struct {
        a: i32,
        b: i32 = 99,
    };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 1 }},
        },
    };
    const val = try deserialize(Def, testing.allocator, &deser);
    try testing.expectEqual(@as(i32, 1), val.a);
    try testing.expectEqual(@as(i32, 99), val.b);
}

test "deserialize struct with rename" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = opts.NamingConvention.camel_case,
        };
    };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "user_id", "firstName" },
            .values = &.{ .{ .int = 42 }, .{ .string = "Bob" } },
        },
    };
    const val = try deserialize(User, testing.allocator, &deser);
    try testing.expectEqual(@as(u64, 42), val.id);
    try testing.expectEqualStrings("Bob", val.first_name);
}

test "deserialize struct deny unknown fields" {
    const Strict = struct {
        x: i32,
        pub const serde = .{
            .deny_unknown_fields = true,
        };
    };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "unknown" },
            .values = &.{ .{ .int = 1 }, .{ .int = 2 } },
        },
    };
    const result = deserialize(Strict, testing.allocator, &deser);
    try testing.expectError(error.UnknownField, result);
}

test "deserialize struct ignores unknown fields by default" {
    const Loose = struct { x: i32 };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "extra" },
            .values = &.{ .{ .int = 5 }, .{ .int = 99 } },
        },
    };
    const val = try deserialize(Loose, testing.allocator, &deser);
    try testing.expectEqual(@as(i32, 5), val.x);
}
