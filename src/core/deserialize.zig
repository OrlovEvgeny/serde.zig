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
        .@"enum" => deserializeEnum(T, deserializer),
        .@"union" => deserializeUnionDispatch(T, allocator, deserializer),
        .array => deserializeArray(T, allocator, deserializer),
        .slice => deserializer.deserializeSeq(T, allocator),
        .pointer => deserializePointer(T, allocator, deserializer),
        .tuple => deserializeTuple(T, allocator, deserializer),
        .bytes => {
            if (comptime @hasDecl(@TypeOf(deserializer.*), "deserializeBytes")) {
                return deserializer.deserializeBytes(allocator);
            }
            return deserializer.deserializeString(allocator);
        },
        .map => deserializeMap(T, allocator, deserializer),
        else => @compileError("Cannot auto-deserialize: " ++ @typeName(T)),
    };
}

fn deserializeEnum(comptime T: type, deserializer: anytype) @TypeOf(deserializer.*).Error!T {
    if (comptime opts.getEnumRepr(T) == .integer) {
        const tag_type = @typeInfo(T).@"enum".tag_type;
        const int_val = try deserializer.deserializeInt(tag_type);
        return std.meta.intToEnum(T, int_val) catch
            return deserializer.raiseError(error.UnexpectedToken);
    }
    return deserializer.deserializeEnum(T);
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

        // Initialize flattened sub-structs with their defaults.
        if (comptime opts.isFlattenedField(T, field.name)) {
            if (@typeInfo(field.type) != .@"struct")
                @compileError("Flatten requires a struct type, got " ++ @typeName(field.type));
            @field(result, field.name) = initWithDefaults(field.type);
            fields_seen.set(i);
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
            if (comptime opts.isFlattenedField(T, field.name)) continue;

            const wire_name = comptime opts.wireFieldName(T, field.name);
            if (std.mem.eql(u8, key, wire_name)) {
                if (comptime opts.hasFieldWith(T, field.name)) {
                    const WithMod = comptime opts.getFieldWith(T, field.name);
                    const raw = try map.nextValue(WithMod.WireType, allocator);
                    @field(result, field.name) = WithMod.deserialize(raw);
                } else {
                    @field(result, field.name) = try map.nextValue(field.type, allocator);
                }
                fields_seen.set(i);
                matched = true;
            }
        }

        // Check flattened struct fields.
        if (!matched) {
            inline for (info.fields) |field| {
                if (comptime opts.isFlattenedField(T, field.name)) {
                    const nested_info = @typeInfo(field.type).@"struct";
                    inline for (nested_info.fields) |sf| {
                        const nested_wire = comptime opts.wireFieldName(field.type, sf.name);
                        if (std.mem.eql(u8, key, nested_wire)) {
                            @field(@field(result, field.name), sf.name) = try map.nextValue(sf.type, allocator);
                            matched = true;
                        }
                    }
                }
            }
        }

        if (!matched) {
            if (comptime opts.denyUnknownFields(T)) {
                return map.raiseError(error.UnknownField);
            }
            try map.skipValue();
        }
    }

    // Validate required fields (skip flattened — they're initialized above).
    inline for (info.fields, 0..) |field, i| {
        if (comptime opts.isFlattenedField(T, field.name)) continue;
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

/// Initialize a struct with default values where available, undefined otherwise.
fn initWithDefaults(comptime T: type) T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.fields) |field| {
        if (comptime field.defaultValue()) |dv| {
            @field(result, field.name) = dv;
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        }
    }
    return result;
}

fn deserializeUnionDispatch(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const tag_style = comptime opts.getUnionTag(T);
    return switch (tag_style) {
        .external => deserializer.deserializeUnion(T, allocator),
        .internal => deserializeUnionInternal(T, allocator, deserializer),
        .adjacent => deserializeUnionAdjacent(T, allocator, deserializer),
        .untagged => deserializeUnionUntagged(T, allocator, deserializer),
    };
}

fn deserializeUnionInternal(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"union";
    const tag_field = comptime opts.getTagField(T);

    // Parse as a struct map, find the tag field first.
    var map = try deserializer.deserializeStruct(T);

    // Collect all key-value pairs, looking for the tag.
    var tag_name: ?[]const u8 = null;
    // We need to buffer non-tag fields for the payload. Use a simple approach:
    // read all keys, skip non-tag fields by tracking them.
    // Because we can't rewind the deserializer, for internal tagging we require
    // the tag field to appear first. Consume keys until we find it.
    while (try map.nextKey(allocator)) |key| {
        if (std.mem.eql(u8, key, tag_field)) {
            tag_name = try map.nextValue([]const u8, allocator);
            break;
        }
        // Skip non-tag fields that appear before the tag.
        try map.skipValue();
    }

    const name = tag_name orelse return deserializer.raiseError(error.MissingField);

    inline for (info.fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            if (field.type == void) {
                // Consume remaining fields.
                while (try map.nextKey(allocator)) |_| {
                    try map.skipValue();
                }
                return @unionInit(T, field.name, {});
            }

            const payload_info = @typeInfo(field.type);
            if (payload_info != .@"struct")
                @compileError("Internal tagging requires struct payloads for " ++ field.name);

            // Read remaining map keys as struct fields.
            var result: field.type = undefined;
            var fields_seen = std.StaticBitSet(payload_info.@"struct".fields.len).initEmpty();

            // Apply defaults.
            inline for (payload_info.@"struct".fields, 0..) |sf, i| {
                if (comptime sf.defaultValue()) |dv| {
                    @field(result, sf.name) = dv;
                    fields_seen.set(i);
                }
            }

            while (try map.nextKey(allocator)) |field_key| {
                var matched = false;
                inline for (payload_info.@"struct".fields, 0..) |sf, i| {
                    if (std.mem.eql(u8, field_key, sf.name)) {
                        @field(result, sf.name) = try map.nextValue(sf.type, allocator);
                        fields_seen.set(i);
                        matched = true;
                    }
                }
                if (!matched) try map.skipValue();
            }

            // Validate required fields.
            inline for (payload_info.@"struct".fields, 0..) |sf, i| {
                if (!fields_seen.isSet(i)) {
                    if (@typeInfo(sf.type) == .optional) {
                        @field(result, sf.name) = null;
                    } else {
                        return deserializer.raiseError(error.MissingField);
                    }
                }
            }

            return @unionInit(T, field.name, result);
        }
    }

    return deserializer.raiseError(error.UnexpectedToken);
}

fn deserializeUnionAdjacent(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"union";
    const tag_field = comptime opts.getTagField(T);
    const content_field = comptime opts.getContentField(T);

    var map = try deserializer.deserializeStruct(T);

    var tag_name: ?[]const u8 = null;
    var found_content = false;
    var result: ?T = null;

    // Adjacent tagging: {"type": "variant", "content": <payload>}
    // Read keys in any order, handling tag and content.
    while (try map.nextKey(allocator)) |key| {
        if (std.mem.eql(u8, key, tag_field)) {
            tag_name = try map.nextValue([]const u8, allocator);
        } else if (std.mem.eql(u8, key, content_field)) {
            // Tag must already be known to parse content.
            const name = tag_name orelse return deserializer.raiseError(error.UnexpectedToken);
            found_content = true;
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, name, field.name)) {
                    if (field.type == void) {
                        try map.skipValue();
                        result = @unionInit(T, field.name, {});
                    } else {
                        const payload = try map.nextValue(field.type, allocator);
                        result = @unionInit(T, field.name, payload);
                    }
                }
            }
        } else {
            try map.skipValue();
        }
    }

    if (result) |r| return r;

    // If we got a tag but no content, check for void variants.
    if (tag_name) |name| {
        if (!found_content) {
            inline for (info.fields) |field| {
                if (field.type == void and std.mem.eql(u8, name, field.name))
                    return @unionInit(T, field.name, {});
            }
        }
    }

    return deserializer.raiseError(error.MissingField);
}

fn deserializeMap(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const K = kind_mod.MapKeyType(T);
    const V = kind_mod.MapValueType(T);
    const managed = comptime kind_mod.isMapManaged(T);

    var result: T = if (managed) T.init(allocator) else .{};

    // Maps serialize as objects — reuse struct access to iterate key-value pairs.
    var map = try deserializer.deserializeStruct(T);

    while (try map.nextKey(allocator)) |key| {
        const k: K = if (K == []const u8)
            key
        else if (@typeInfo(K) == .int)
            std.fmt.parseInt(K, key, 10) catch return deserializer.raiseError(error.InvalidNumber)
        else
            @compileError("Unsupported map key type: " ++ @typeName(K));

        const v = try map.nextValue(V, allocator);

        if (managed) {
            result.put(k, v) catch return deserializer.raiseError(error.OutOfMemory);
        } else {
            result.put(allocator, k, v) catch return deserializer.raiseError(error.OutOfMemory);
        }
    }

    return result;
}

fn deserializeUnionUntagged(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"union";

    // Try each variant in declaration order. Save deserializer state before
    // each attempt; restore on failure. Partial allocations on failed attempts
    // are acceptable because ArenaAllocator is the documented pattern.
    inline for (info.fields) |field| {
        const saved = deserializer.*;
        if (field.type == void) {
            if (deserializer.deserializeVoid()) {
                return @unionInit(T, field.name, {});
            } else |_| {
                deserializer.* = saved;
            }
        } else {
            if (deserialize(field.type, allocator, deserializer)) |payload| {
                return @unionInit(T, field.name, payload);
            } else |_| {
                deserializer.* = saved;
            }
        }
    }

    return deserializer.raiseError(error.UnexpectedToken);
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
