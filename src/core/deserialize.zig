const std = @import("std");
const kind_mod = @import("kind.zig");
const opts = @import("options.zig");

const Kind = kind_mod.Kind;
const Child = kind_mod.Child;
const typeKind = kind_mod.typeKind;
const Allocator = std.mem.Allocator;

pub fn deserialize(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    return deserializeSchema(T, allocator, deserializer, {}, map);
}

/// Deserialize with out-of-band type overrides.
/// Map: `.{ .{ Type, Adapter }, ... }` where Adapter has `fn deserialize(T, allocator, d) !T`.
pub fn deserializeWith(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    return deserializeSchema(T, allocator, deserializer, {}, map);
}

/// Deserialize with an external schema. Schema overrides T.serde.
/// Types with zerdeDeserialize bypass the schema.
pub fn deserializeSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    if (comptime opts.hasCustomDeserializer(T)) {
        return T.zerdeDeserialize(T, allocator, deserializer);
    }

    if (comptime @TypeOf(map) != void) {
        if (comptime findOobAdapter(T, map)) |adapter| {
            return adapter.deserialize(T, allocator, deserializer);
        }
    }

    return switch (comptime typeKind(T)) {
        .bool => deserializer.deserializeBool(),
        .int => deserializer.deserializeInt(T),
        .float => deserializer.deserializeFloat(T),
        .string => deserializer.deserializeString(allocator),
        .void => deserializer.deserializeVoid(),
        .optional => deserializer.deserializeOptional(Child(T), allocator),
        .@"struct" => deserializeStructFieldsSchema(T, allocator, deserializer, schema, map),
        .@"enum" => deserializeEnumSchema(T, allocator, deserializer, schema),
        .@"union" => deserializeUnionDispatchSchema(T, allocator, deserializer, schema, map),
        .array => deserializeArray(T, allocator, deserializer),
        .slice => deserializer.deserializeSeq(T, allocator),
        .pointer => deserializePointerSchema(T, allocator, deserializer, map),
        .tuple => deserializeTupleSchema(T, allocator, deserializer, map),
        .bytes => {
            if (comptime @hasDecl(@TypeOf(deserializer.*), "deserializeBytes")) {
                return deserializer.deserializeBytes(allocator);
            }
            return deserializer.deserializeString(allocator);
        },
        .map => deserializeMapSchema(T, allocator, deserializer, map),
        else => @compileError("Cannot auto-deserialize: " ++ @typeName(T)),
    };
}

fn findOobAdapter(comptime T: type, comptime map: anytype) ?type {
    inline for (@typeInfo(@TypeOf(map)).@"struct".fields) |field| {
        const entry = @field(map, field.name);
        if (entry[0] == T) return entry[1];
    }
    return null;
}

fn deserializeEnumSchema(comptime T: type, allocator: Allocator, deserializer: anytype, comptime schema: anytype) @TypeOf(deserializer.*).Error!T {
    if (comptime opts.getEnumReprSchema(T, schema) == .integer) {
        const tag_type = @typeInfo(T).@"enum".tag_type;
        const int_val = try deserializer.deserializeInt(tag_type);
        return std.enums.fromInt(T, int_val) orelse
            return deserializer.raiseError(error.UnexpectedToken);
    }
    // No rename/alias: let the format handle it directly.
    if (comptime !opts.hasNameOverrides(T, schema)) {
        return deserializer.deserializeEnum(T);
    }
    // With rename/alias: read string and match in core.
    const name = try deserializer.deserializeString(allocator);
    defer freeAllocated([]const u8, name, allocator);
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (opts.matchesDeserializeName(T, field.name, name, schema)) {
            return @enumFromInt(field.value);
        }
    }
    return deserializer.raiseError(error.UnexpectedToken);
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
    // Consume the closing delimiter.
    if (try seq.nextElement(child, allocator) != null)
        return deserializer.raiseError(error.UnexpectedToken);
    return result;
}

fn deserializePointerSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const child = Child(T);
    const val = try deserializeSchema(child, allocator, deserializer, {}, map);
    errdefer freeAllocated(child, val, allocator);
    const ptr = try allocator.create(child);
    ptr.* = val;
    return ptr;
}

fn deserializeTupleSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    _ = map;
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    var seq = try deserializer.deserializeSeqAccess();
    inline for (info.fields) |field| {
        @field(result, field.name) = try seq.nextElement(field.type, allocator) orelse
            return deserializer.raiseError(error.UnexpectedEof);
    }
    if (info.fields.len > 0) {
        if (try seq.nextElement(info.fields[0].type, allocator) != null)
            return deserializer.raiseError(error.UnexpectedToken);
    }
    return result;
}

/// Recursively free heap memory owned by a deserialized value.
/// No-op for borrowed deserialization with ArenaAllocator.
fn freeAllocated(comptime T: type, value: T, allocator: Allocator) void {
    switch (comptime kind_mod.typeKind(T)) {
        .string => allocator.free(value),
        .slice => {
            for (value) |elem| freeAllocated(@typeInfo(T).pointer.child, elem, allocator);
            allocator.free(value);
        },
        .pointer => {
            freeAllocated(@typeInfo(T).pointer.child, value.*, allocator);
            allocator.destroy(value);
        },
        .@"struct" => {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                freeAllocated(field.type, @field(value, field.name), allocator);
            }
        },
        .optional => if (value) |v| freeAllocated(@typeInfo(T).optional.child, v, allocator),
        .map => {
            var mut = value;
            if (comptime kind_mod.isMapManaged(T)) {
                mut.deinit();
            } else {
                mut.deinit(allocator);
            }
        },
        else => {},
    }
}

fn freeStructFields(comptime T: type, result: *T, fields_seen: anytype, allocator: Allocator) void {
    const info = @typeInfo(T).@"struct";
    inline for (info.fields, 0..) |field, i| {
        if (fields_seen.isSet(i)) {
            freeAllocated(field.type, @field(result, field.name), allocator);
        }
    }
}

fn deserializeStructFieldsSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
    comptime oob_map: anytype,
) @TypeOf(deserializer.*).Error!T {
    _ = oob_map;
    const info = @typeInfo(T).@"struct";

    var result: T = undefined;
    var fields_seen = std.StaticBitSet(info.fields.len).initEmpty();
    errdefer freeStructFields(T, &result, fields_seen, allocator);

    inline for (info.fields, 0..) |field, i| {
        if (comptime opts.shouldSkipFieldSchema(T, field.name, .deserialize, schema)) {
            if (comptime field.defaultValue()) |dv| {
                @field(result, field.name) = dv;
                fields_seen.set(i);
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
                fields_seen.set(i);
            }
            continue;
        }

        if (comptime opts.isFlattenedFieldSchema(T, field.name, schema)) {
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
        if (comptime opts.hasSerdeDefaultSchema(T, field.name, schema)) {
            @field(result, field.name) = comptime opts.getSerdeDefaultSchema(T, field.name, schema);
            fields_seen.set(i);
        }
    }

    var map = try deserializer.deserializeStruct(T);

    while (try map.nextKey(allocator)) |key| {
        var matched = false;

        inline for (info.fields, 0..) |field, i| {
            if (comptime opts.shouldSkipFieldSchema(T, field.name, .deserialize, schema)) continue;
            if (comptime opts.isFlattenedFieldSchema(T, field.name, schema)) continue;

            if (opts.matchesDeserializeName(T, field.name, key, schema)) {
                if (comptime opts.hasFieldWithSchema(T, field.name, schema)) {
                    const WithMod = comptime opts.getFieldWithSchema(T, field.name, schema);
                    const raw = try map.nextValue(WithMod.WireType, allocator);
                    @field(result, field.name) = WithMod.deserialize(raw);
                } else {
                    @field(result, field.name) = try map.nextValue(field.type, allocator);
                }
                fields_seen.set(i);
                matched = true;
            }
        }

        if (!matched) {
            inline for (info.fields) |field| {
                if (comptime opts.isFlattenedFieldSchema(T, field.name, schema)) {
                    const nested_info = @typeInfo(field.type).@"struct";
                    inline for (nested_info.fields) |sf| {
                        if (opts.matchesDeserializeName(field.type, sf.name, key, {})) {
                            @field(@field(result, field.name), sf.name) = try map.nextValue(sf.type, allocator);
                            matched = true;
                        }
                    }
                }
            }
        }

        if (!matched) {
            if (comptime opts.denyUnknownFieldsSchema(T, schema)) {
                return map.raiseError(error.UnknownField);
            }
            try map.skipValue();
        }
    }

    // Validate required fields. Flattened fields already initialized above.
    inline for (info.fields, 0..) |field, i| {
        if (comptime opts.isFlattenedFieldSchema(T, field.name, schema)) continue;
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

fn deserializeUnionDispatchSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const tag_style = comptime opts.getUnionTagSchema(T, schema);
    return switch (tag_style) {
        .external => if (comptime opts.hasNameOverrides(T, schema))
            deserializeUnionExternalSchema(T, allocator, deserializer, schema)
        else
            deserializer.deserializeUnion(T, allocator),
        .internal => deserializeUnionInternalSchema(T, allocator, deserializer, schema),
        .adjacent => deserializeUnionAdjacentSchema(T, allocator, deserializer, schema),
        .untagged => deserializeUnionUntaggedSchema(T, allocator, deserializer, map),
    };
}

/// External union deser with rename/alias. Tries bare string first (void
/// variants), then {"variant": payload} form. Uses save/restore like untagged.
fn deserializeUnionExternalSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"union";

    {
        const saved = deserializer.*;
        if (deserializer.deserializeString(allocator)) |name| {
            defer freeAllocated([]const u8, name, allocator);
            inline for (info.fields) |field| {
                if (field.type == void and opts.matchesDeserializeName(T, field.name, name, schema)) {
                    return @unionInit(T, field.name, {});
                }
            }
            deserializer.* = saved;
        } else |_| {
            deserializer.* = saved;
        }
    }

    var map = try deserializer.deserializeStruct(T);
    const key = (try map.nextKey(allocator)) orelse return deserializer.raiseError(error.MissingField);

    inline for (info.fields) |field| {
        if (opts.matchesDeserializeName(T, field.name, key, schema)) {
            if (field.type == void) {
                try map.skipValue();
            } else {
                const payload = try map.nextValue(field.type, allocator);
                while (try map.nextKey(allocator)) |_| try map.skipValue();
                return @unionInit(T, field.name, payload);
            }
            // Consume remaining keys (closing brace).
            while (try map.nextKey(allocator)) |_| try map.skipValue();
            return @unionInit(T, field.name, {});
        }
    }

    return deserializer.raiseError(error.UnexpectedToken);
}

fn deserializeUnionInternalSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"union";
    const tag_field = comptime opts.getTagFieldSchema(T, schema);

    var map = try deserializer.deserializeStruct(T);

    var tag_name: ?[]const u8 = null;
    while (try map.nextKey(allocator)) |key| {
        if (std.mem.eql(u8, key, tag_field)) {
            tag_name = try map.nextValue([]const u8, allocator);
            break;
        }
        try map.skipValue();
    }

    const name = tag_name orelse return deserializer.raiseError(error.MissingField);

    inline for (info.fields) |field| {
        if (opts.matchesDeserializeName(T, field.name, name, schema)) {
            if (field.type == void) {
                while (try map.nextKey(allocator)) |_| {
                    try map.skipValue();
                }
                return @unionInit(T, field.name, {});
            }

            const payload_info = @typeInfo(field.type);
            if (payload_info != .@"struct")
                @compileError("Internal tagging requires struct payloads for " ++ field.name);

            var result: field.type = undefined;
            var fields_seen = std.StaticBitSet(payload_info.@"struct".fields.len).initEmpty();
            errdefer freeStructFields(field.type, &result, fields_seen, allocator);

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

fn deserializeUnionAdjacentSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime schema: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"union";
    const tag_field = comptime opts.getTagFieldSchema(T, schema);
    const content_field = comptime opts.getContentFieldSchema(T, schema);

    var map = try deserializer.deserializeStruct(T);

    var tag_name: ?[]const u8 = null;
    var found_content = false;
    var result: ?T = null;

    while (try map.nextKey(allocator)) |key| {
        if (std.mem.eql(u8, key, tag_field)) {
            tag_name = try map.nextValue([]const u8, allocator);
        } else if (std.mem.eql(u8, key, content_field)) {
            const name = tag_name orelse return deserializer.raiseError(error.UnexpectedToken);
            found_content = true;
            inline for (info.fields) |field| {
                if (opts.matchesDeserializeName(T, field.name, name, schema)) {
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

    if (tag_name) |name| {
        if (!found_content) {
            inline for (info.fields) |field| {
                if (field.type == void and opts.matchesDeserializeName(T, field.name, name, schema))
                    return @unionInit(T, field.name, {});
            }
        }
    }

    return deserializer.raiseError(error.MissingField);
}

fn deserializeMapSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime oob_map: anytype,
) @TypeOf(deserializer.*).Error!T {
    _ = oob_map;
    const K = kind_mod.MapKeyType(T);
    const V = kind_mod.MapValueType(T);
    const managed = comptime kind_mod.isMapManaged(T);

    var result: T = if (managed) T.init(allocator) else .{};
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            freeAllocated(V, entry.value_ptr.*, allocator);
            if (K == []const u8) freeAllocated(K, entry.key_ptr.*, allocator);
        }
        if (managed) result.deinit() else result.deinit(allocator);
    }

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

fn deserializeUnionUntaggedSchema(
    comptime T: type,
    allocator: Allocator,
    deserializer: anytype,
    comptime map: anytype,
) @TypeOf(deserializer.*).Error!T {
    const info = @typeInfo(T).@"union";

    inline for (info.fields) |field| {
        const saved = deserializer.*;
        if (field.type == void) {
            if (deserializer.deserializeVoid()) {
                return @unionInit(T, field.name, {});
            } else |_| {
                deserializer.* = saved;
            }
        } else {
            if (deserializeSchema(field.type, allocator, deserializer, {}, map)) |payload| {
                return @unionInit(T, field.name, payload);
            } else |_| {
                deserializer.* = saved;
            }
        }
    }

    return deserializer.raiseError(error.UnexpectedToken);
}

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
    const point = try deserialize(Point, testing.allocator, &deser, .{});
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
    const val = try deserialize(Opt, testing.allocator, &deser, .{});
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
    const result = deserialize(Req, testing.allocator, &deser, .{});
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
    const val = try deserialize(Def, testing.allocator, &deser, .{});
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
    const val = try deserialize(User, testing.allocator, &deser, .{});
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
    const result = deserialize(Strict, testing.allocator, &deser, .{});
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
    const val = try deserialize(Loose, testing.allocator, &deser, .{});
    try testing.expectEqual(@as(i32, 5), val.x);
}

// Schema-based deserialization tests.

test "deserializeSchema with rename on plain struct" {
    const Point = struct { x: i32, y: i32 };
    const schema = .{ .rename = .{ .x = "X", .y = "Y" } };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "X", "Y" },
            .values = &.{ .{ .int = 10 }, .{ .int = 20 } },
        },
    };
    const val = try deserializeSchema(Point, testing.allocator, &deser, schema, .{});
    try testing.expectEqual(@as(i32, 10), val.x);
    try testing.expectEqual(@as(i32, 20), val.y);
}

test "deserializeSchema with deny_unknown_fields via schema" {
    const Plain = struct { x: i32 };
    const schema = .{ .deny_unknown_fields = true };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{ "x", "extra" },
            .values = &.{ .{ .int = 1 }, .{ .int = 2 } },
        },
    };
    const result = deserializeSchema(Plain, testing.allocator, &deser, schema, .{});
    try testing.expectError(error.UnknownField, result);
}

test "deserializeSchema with skip via schema" {
    const S = struct { a: i32, b: i32 = 0 };
    const schema = .{ .skip = .{ .b = opts.SkipMode.always } };
    var deser = MockDeserializer{
        .map = .{
            .keys = &.{"a"},
            .values = &.{.{ .int = 5 }},
        },
    };
    const val = try deserializeSchema(S, testing.allocator, &deser, schema, .{});
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(i32, 0), val.b);
}

// Out-of-band (OOB) customization tests.

test "deserializeWith: custom adapter compiles" {
    const Wrapper = struct { inner: u32 };

    const WrapperAdapter = struct {
        pub fn deserialize(comptime _: type, _: Allocator, d: anytype) @TypeOf(d.*).Error!Wrapper {
            const val = try d.deserializeInt(u32);
            return .{ .inner = val };
        }
    };

    // Verify the adapter type is valid for the map pattern.
    const map = .{.{ Wrapper, WrapperAdapter }};
    _ = map;
}
