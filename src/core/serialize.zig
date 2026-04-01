const std = @import("std");
const kind_mod = @import("kind.zig");
const options = @import("options.zig");

const Kind = kind_mod.Kind;
const Child = kind_mod.Child;
const typeKind = kind_mod.typeKind;

pub fn serialize(
    comptime T: type,
    value: T,
    serializer: anytype,
    comptime map: anytype,
) @TypeOf(serializer.*).Error!void {
    return serializeSchema(T, value, serializer, {}, map);
}

/// Serialize with out-of-band type overrides.
/// Map: `.{ .{ Type, Adapter }, ... }` where Adapter has `fn serialize(value, s) !void`.
pub fn serializeWith(
    comptime T: type,
    value: T,
    serializer: anytype,
    comptime map: anytype,
) @TypeOf(serializer.*).Error!void {
    return serializeSchema(T, value, serializer, {}, map);
}

/// Serialize with an external schema. Schema overrides T.serde.
/// Types with zerdeSerialize bypass the schema.
pub fn serializeSchema(
    comptime T: type,
    value: T,
    serializer: anytype,
    comptime schema: anytype,
    comptime map: anytype,
) @TypeOf(serializer.*).Error!void {
    if (comptime options.hasCustomSerializer(T)) {
        return value.zerdeSerialize(serializer);
    }

    if (comptime @TypeOf(map) != void) {
        if (comptime findOobAdapter(T, map)) |adapter| {
            return adapter.serialize(value, serializer);
        }
    }

    switch (comptime typeKind(T)) {
        .bool => return serializer.serializeBool(value),
        .int => return serializer.serializeInt(value),
        .float => return serializer.serializeFloat(value),
        .void => return serializer.serializeVoid(),
        .string => return serializer.serializeString(value),
        .optional => return serializeOptionalSchema(T, value, serializer, schema, map),
        .pointer => return serializeSchema(Child(T), value.*, serializer, schema, map),
        .array => return serializeArraySchema(T, value, serializer, map),
        .slice => return serializeSliceSchema(T, value, serializer, map),
        .@"struct" => return serializeStructSchema(T, value, serializer, schema, map),
        .tuple => return serializeTupleSchema(T, value, serializer, map),
        .@"union" => return serializeUnionSchema(T, value, serializer, schema, map),
        .@"enum" => return serializeEnumSchema(T, value, serializer, schema),
        .map => return serializeMapSchema(T, value, serializer, map),
        .bytes => {
            if (comptime @hasDecl(@TypeOf(serializer.*), "serializeBytes")) {
                return serializer.serializeBytes(value);
            }
            return serializer.serializeString(value);
        },
        .custom => @compileError(@typeName(T) ++ " declares custom kind but no zerdeSerialize"),
    }
}

fn findOobAdapter(comptime T: type, comptime map: anytype) ?type {
    inline for (@typeInfo(@TypeOf(map)).@"struct".fields) |field| {
        const entry = @field(map, field.name);
        if (entry[0] == T) return entry[1];
    }
    return null;
}

fn serializeOptionalSchema(comptime T: type, value: T, serializer: anytype, comptime schema: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    if (value) |v| {
        return serializeSchema(Child(T), v, serializer, schema, map);
    } else {
        return serializer.serializeNull();
    }
}

fn serializeArraySchema(comptime T: type, value: T, serializer: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    const child = Child(T);
    var arr = try serializer.beginArray();
    for (value) |elem| {
        try serializeSchema(child, elem, &arr, {}, map);
    }
    return arr.end();
}

fn serializeSliceSchema(comptime T: type, value: T, serializer: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    const child = Child(T);
    var arr = try serializer.beginArray();
    for (value) |elem| {
        try serializeSchema(child, elem, &arr, {}, map);
    }
    return arr.end();
}

fn serializeStructSchema(comptime T: type, value: T, serializer: anytype, comptime schema: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    _ = map;
    const info = @typeInfo(T).@"struct";

    var ss = try serializer.beginStruct();

    inline for (info.fields) |field| {
        if (comptime options.shouldSkipFieldSchema(T, field.name, .serialize, schema)) continue;

        if (comptime options.isFlattenedFieldSchema(T, field.name, schema)) {
            if (@typeInfo(field.type) != .@"struct")
                @compileError("Flatten requires a struct type, got " ++ @typeName(field.type));
            const nested = @field(value, field.name);
            const nested_info = @typeInfo(field.type).@"struct";
            inline for (nested_info.fields) |sf| {
                const nested_wire = comptime options.wireFieldNameForDir(field.type, sf.name, {}, .serialize);
                try ss.serializeField(nested_wire, @field(nested, sf.name));
            }
            continue;
        }

        const wire_name = comptime options.wireFieldNameForDir(T, field.name, schema, .serialize);
        const field_value = @field(value, field.name);

        const skip_null = comptime options.isSkipIfNullSchema(T, field.name, schema) and @typeInfo(field.type) == .optional;
        const skip_empty = comptime options.isSkipIfEmptySchema(T, field.name, schema) and @typeInfo(field.type) == .pointer;

        const should_skip = (skip_null and field_value == null) or
            (skip_empty and field_value.len == 0);

        if (!should_skip) {
            if (comptime options.hasFieldWithSchema(T, field.name, schema)) {
                const WithMod = comptime options.getFieldWithSchema(T, field.name, schema);
                try ss.serializeField(wire_name, WithMod.serialize(field_value));
            } else {
                try ss.serializeField(wire_name, field_value);
            }
        }
    }

    return ss.end();
}

fn serializeTupleSchema(comptime T: type, value: T, serializer: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"struct";
    var arr = try serializer.beginArray();
    inline for (info.fields) |field| {
        try serializeSchema(field.type, @field(value, field.name), &arr, {}, map);
    }
    return arr.end();
}

fn serializeUnionSchema(comptime T: type, value: T, serializer: anytype, comptime schema: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    const tag_style = comptime options.getUnionTagSchema(T, schema);
    if (tag_style == .external) {
        return serializeUnionExternalSchema(T, value, serializer, schema, map);
    } else if (tag_style == .internal) {
        return serializeUnionInternalSchema(T, value, serializer, schema);
    } else if (tag_style == .adjacent) {
        return serializeUnionAdjacentSchema(T, value, serializer, schema);
    } else {
        return serializeUnionUntaggedSchema(T, value, serializer, map);
    }
}

fn serializeUnionExternalSchema(comptime T: type, value: T, serializer: anytype, comptime schema: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    _ = map;
    const info = @typeInfo(T).@"union";
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            const wire_name = comptime options.wireFieldNameForDir(T, field.name, schema, .serialize);
            if (field.type == void) {
                return serializer.serializeString(wire_name);
            } else {
                const payload = @field(value, field.name);
                var ss = try serializer.beginStruct();
                try ss.serializeField(wire_name, payload);
                return ss.end();
            }
        }
    }
}

fn serializeUnionInternalSchema(comptime T: type, value: T, serializer: anytype, comptime schema: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"union";
    const tag_field_name = comptime options.getTagFieldSchema(T, schema);
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            const wire_name = comptime options.wireFieldNameForDir(T, field.name, schema, .serialize);
            var ss = try serializer.beginStruct();
            try ss.serializeField(tag_field_name, @as([]const u8, wire_name));
            if (field.type == void) {
                return ss.end();
            } else {
                const payload_info = @typeInfo(field.type);
                if (payload_info != .@"struct")
                    @compileError("Internal tagging requires struct payloads, got " ++ @typeName(field.type));
                const payload = @field(value, field.name);
                inline for (payload_info.@"struct".fields) |sf| {
                    try ss.serializeField(sf.name, @field(payload, sf.name));
                }
                return ss.end();
            }
        }
    }
}

fn serializeUnionAdjacentSchema(comptime T: type, value: T, serializer: anytype, comptime schema: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"union";
    const tag_field_name = comptime options.getTagFieldSchema(T, schema);
    const content_field_name = comptime options.getContentFieldSchema(T, schema);
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            const wire_name = comptime options.wireFieldNameForDir(T, field.name, schema, .serialize);
            var ss = try serializer.beginStruct();
            try ss.serializeField(tag_field_name, @as([]const u8, wire_name));
            if (field.type != void) {
                const payload = @field(value, field.name);
                try ss.serializeField(content_field_name, payload);
            }
            return ss.end();
        }
    }
}

fn serializeUnionUntaggedSchema(comptime T: type, value: T, serializer: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"union";
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            if (field.type == void) {
                return serializer.serializeNull();
            } else {
                const payload = @field(value, field.name);
                return serializeSchema(field.type, payload, serializer, {}, map);
            }
        }
    }
}

fn serializeEnumSchema(comptime T: type, value: T, serializer: anytype, comptime schema: anytype) @TypeOf(serializer.*).Error!void {
    if (comptime options.getEnumReprSchema(T, schema) == .integer) {
        const tag_type = @typeInfo(T).@"enum".tag_type;
        return serializer.serializeInt(@as(tag_type, @intFromEnum(value)));
    }
    inline for (@typeInfo(T).@"enum".fields) |field| {
        if (@intFromEnum(value) == field.value) {
            const wire_name = comptime options.wireFieldNameForDir(T, field.name, schema, .serialize);
            return serializer.serializeString(wire_name);
        }
    }
    unreachable;
}

fn serializeMapSchema(comptime T: type, value: T, serializer: anytype, comptime map: anytype) @TypeOf(serializer.*).Error!void {
    _ = map;
    var ss = try serializer.beginStruct();
    var it = value.iterator();
    while (it.next()) |entry| {
        try ss.serializeEntry(entry.key_ptr.*, entry.value_ptr.*);
    }
    return ss.end();
}

const testing = std.testing;

const TestEvent = union(enum) {
    bool_val: bool,
    int_val: i128,
    float_val: f64,
    string_val: []const u8,
    null_val,
    void_val,
    struct_begin,
    struct_end,
    field: []const u8,
    array_begin,
    array_end,
    enum_val: []const u8,
};

const SerError = error{OutOfMemory};

const MockSerializer = struct {
    events: std.ArrayList(TestEvent) = .empty,
    alloc: std.mem.Allocator,

    pub const Error = SerError;

    const StructSer = struct {
        parent: *MockSerializer,

        pub const Error = SerError;

        pub fn serializeField(self: *StructSer, comptime key: []const u8, value: anytype) SerError!void {
            self.parent.events.append(self.parent.alloc, .{ .field = key }) catch return error.OutOfMemory;
            try serialize(@TypeOf(value), value, self.parent, .{});
        }

        pub fn serializeEntry(self: *StructSer, key: anytype, value: anytype) SerError!void {
            _ = key;
            try serialize(@TypeOf(value), value, self.parent, .{});
        }

        pub fn end(self: *StructSer) SerError!void {
            self.parent.events.append(self.parent.alloc, .struct_end) catch return error.OutOfMemory;
        }
    };

    const ArraySer = struct {
        parent: *MockSerializer,

        pub const Error = SerError;

        pub fn serializeBool(self: *ArraySer, value: bool) SerError!void {
            try self.parent.serializeBool(value);
        }
        pub fn serializeInt(self: *ArraySer, value: anytype) SerError!void {
            try self.parent.serializeInt(value);
        }
        pub fn serializeFloat(self: *ArraySer, value: anytype) SerError!void {
            try self.parent.serializeFloat(value);
        }
        pub fn serializeString(self: *ArraySer, value: []const u8) SerError!void {
            try self.parent.serializeString(value);
        }
        pub fn serializeNull(self: *ArraySer) SerError!void {
            try self.parent.serializeNull();
        }
        pub fn serializeVoid(self: *ArraySer) SerError!void {
            try self.parent.serializeVoid();
        }
        pub fn beginArray(self: *ArraySer) SerError!ArraySer {
            return self.parent.beginArray();
        }
        pub fn beginStruct(self: *ArraySer) SerError!StructSer {
            return self.parent.beginStruct();
        }
        pub fn end(self: *ArraySer) SerError!void {
            self.parent.events.append(self.parent.alloc, .array_end) catch return error.OutOfMemory;
        }
    };

    fn init(alloc: std.mem.Allocator) MockSerializer {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *MockSerializer) void {
        self.events.deinit(self.alloc);
    }

    pub fn serializeBool(self: *MockSerializer, value: bool) SerError!void {
        self.events.append(self.alloc, .{ .bool_val = value }) catch return error.OutOfMemory;
    }

    pub fn serializeInt(self: *MockSerializer, value: anytype) SerError!void {
        self.events.append(self.alloc, .{ .int_val = @intCast(value) }) catch return error.OutOfMemory;
    }

    pub fn serializeFloat(self: *MockSerializer, value: anytype) SerError!void {
        self.events.append(self.alloc, .{ .float_val = @floatCast(value) }) catch return error.OutOfMemory;
    }

    pub fn serializeString(self: *MockSerializer, value: []const u8) SerError!void {
        self.events.append(self.alloc, .{ .string_val = value }) catch return error.OutOfMemory;
    }

    pub fn serializeNull(self: *MockSerializer) SerError!void {
        self.events.append(self.alloc, .null_val) catch return error.OutOfMemory;
    }

    pub fn serializeVoid(self: *MockSerializer) SerError!void {
        self.events.append(self.alloc, .void_val) catch return error.OutOfMemory;
    }

    pub fn beginStruct(self: *MockSerializer) SerError!StructSer {
        self.events.append(self.alloc, .struct_begin) catch return error.OutOfMemory;
        return .{ .parent = self };
    }

    pub fn beginArray(self: *MockSerializer) SerError!ArraySer {
        self.events.append(self.alloc, .array_begin) catch return error.OutOfMemory;
        return .{ .parent = self };
    }
};

test "serialize bool" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(bool, true, &mock, .{});
    try testing.expectEqual(TestEvent{ .bool_val = true }, mock.events.items[0]);
}

test "serialize int" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(u32, 42, &mock, .{});
    try testing.expectEqual(TestEvent{ .int_val = 42 }, mock.events.items[0]);
}

test "serialize float" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(f64, 3.14, &mock, .{});
    try testing.expectEqual(TestEvent{ .float_val = 3.14 }, mock.events.items[0]);
}

test "serialize string" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize([]const u8, "hello", &mock, .{});
    try testing.expectEqualStrings("hello", mock.events.items[0].string_val);
}

test "serialize optional null" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const val: ?u32 = null;
    try serialize(?u32, val, &mock, .{});
    try testing.expectEqual(TestEvent.null_val, mock.events.items[0]);
}

test "serialize optional value" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const val: ?u32 = 7;
    try serialize(?u32, val, &mock, .{});
    try testing.expectEqual(TestEvent{ .int_val = 7 }, mock.events.items[0]);
}

test "serialize struct" {
    const Point = struct { x: i32, y: i32 };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Point, .{ .x = 1, .y = 2 }, &mock, .{});
    try testing.expectEqual(TestEvent.struct_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .field = "x" }, mock.events.items[1]);
    try testing.expectEqual(TestEvent{ .int_val = 1 }, mock.events.items[2]);
    try testing.expectEqual(TestEvent{ .field = "y" }, mock.events.items[3]);
    try testing.expectEqual(TestEvent{ .int_val = 2 }, mock.events.items[4]);
    try testing.expectEqual(TestEvent.struct_end, mock.events.items[5]);
}

test "serialize struct with rename" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{
                .id = "user_id",
            },
            .rename_all = options.NamingConvention.camel_case,
        };
    };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(User, .{ .id = 1, .first_name = "Bob" }, &mock, .{});
    try testing.expectEqualStrings("user_id", mock.events.items[1].field);
    try testing.expectEqualStrings("firstName", mock.events.items[3].field);
}

test "serialize struct with skip" {
    const Secret = struct {
        name: []const u8,
        token: []const u8,

        pub const serde = .{
            .skip = .{
                .token = options.SkipMode.always,
            },
        };
    };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Secret, .{ .name = "test", .token = "secret" }, &mock, .{});
    try testing.expectEqual(@as(usize, 4), mock.events.items.len);
    try testing.expectEqual(TestEvent{ .field = "name" }, mock.events.items[1]);
}

test "serialize array" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize([3]i32, .{ 1, 2, 3 }, &mock, .{});
    try testing.expectEqual(TestEvent.array_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .int_val = 1 }, mock.events.items[1]);
    try testing.expectEqual(TestEvent{ .int_val = 2 }, mock.events.items[2]);
    try testing.expectEqual(TestEvent{ .int_val = 3 }, mock.events.items[3]);
    try testing.expectEqual(TestEvent.array_end, mock.events.items[4]);
}

test "serialize slice" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const data: []const i32 = &.{ 10, 20 };
    try serialize([]const i32, data, &mock, .{});
    try testing.expectEqual(TestEvent.array_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .int_val = 10 }, mock.events.items[1]);
    try testing.expectEqual(TestEvent{ .int_val = 20 }, mock.events.items[2]);
    try testing.expectEqual(TestEvent.array_end, mock.events.items[3]);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Color, .green, &mock, .{});
    try testing.expectEqualStrings("green", mock.events.items[0].string_val);
}

test "serialize tagged union with void payload" {
    const Cmd = union(enum) { ping: void, quit: void };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Cmd, .ping, &mock, .{});
    try testing.expectEqualStrings("ping", mock.events.items[0].string_val);
}

test "serialize union internal tagging" {
    const Command = union(enum) {
        ping: void,
        execute: struct { query: []const u8 },

        pub const serde = .{
            .tag = options.UnionTag.internal,
            .tag_field = "type",
        };
    };

    comptime {
        std.debug.assert(options.getUnionTag(Command) == .internal);
    }

    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Command, .ping, &mock, .{});
    try testing.expectEqual(TestEvent.struct_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .field = "type" }, mock.events.items[1]);
    try testing.expectEqualStrings("ping", mock.events.items[2].string_val);
    try testing.expectEqual(TestEvent.struct_end, mock.events.items[3]);
}

test "serialize tagged union with payload" {
    const Cmd = union(enum) { set: u32, ping: void };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Cmd, .{ .set = 42 }, &mock, .{});
    try testing.expectEqual(TestEvent.struct_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .field = "set" }, mock.events.items[1]);
    try testing.expectEqual(TestEvent{ .int_val = 42 }, mock.events.items[2]);
    try testing.expectEqual(TestEvent.struct_end, mock.events.items[3]);
}

// Schema-based serialization tests.

test "serializeSchema with rename on plain struct" {
    const Point = struct { x: i32, y: i32 };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const schema = .{ .rename = .{ .x = "X", .y = "Y" } };
    try serializeSchema(Point, .{ .x = 1, .y = 2 }, &mock, schema, .{});
    try testing.expectEqual(TestEvent.struct_begin, mock.events.items[0]);
    try testing.expectEqualStrings("X", mock.events.items[1].field);
    try testing.expectEqual(TestEvent{ .int_val = 1 }, mock.events.items[2]);
    try testing.expectEqualStrings("Y", mock.events.items[3].field);
    try testing.expectEqual(TestEvent{ .int_val = 2 }, mock.events.items[4]);
    try testing.expectEqual(TestEvent.struct_end, mock.events.items[5]);
}

test "serializeSchema with skip on plain struct" {
    const Point = struct { x: i32, y: i32, z: i32 };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const schema = .{ .skip = .{ .z = options.SkipMode.always } };
    try serializeSchema(Point, .{ .x = 1, .y = 2, .z = 3 }, &mock, schema, .{});
    // Should only have x and y fields.
    try testing.expectEqual(@as(usize, 6), mock.events.items.len);
    try testing.expectEqualStrings("x", mock.events.items[1].field);
    try testing.expectEqualStrings("y", mock.events.items[3].field);
}

test "serializeSchema overrides T.serde" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
        };
    };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    // Schema overrides the rename.
    const schema = .{ .rename = .{ .id = "ID" } };
    try serializeSchema(User, .{ .id = 1, .first_name = "Bob" }, &mock, schema, .{});
    try testing.expectEqualStrings("ID", mock.events.items[1].field);
}

test "serializeWith: custom adapter for unsupported type" {
    const Wrapper = struct {
        inner: u32,
    };

    const WrapperAdapter = struct {
        pub fn serialize(value: Wrapper, s: anytype) @TypeOf(s.*).Error!void {
            try s.serializeInt(value.inner);
        }
    };

    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const map = .{.{ Wrapper, WrapperAdapter }};
    try serializeWith(Wrapper, .{ .inner = 42 }, &mock, map);
    try testing.expectEqual(TestEvent{ .int_val = 42 }, mock.events.items[0]);
}

test "serializeWith: struct containing OOB-overridden type" {
    const Inner = struct { val: u32 };

    const InnerAdapter = struct {
        pub fn serialize(value: Inner, s: anytype) @TypeOf(s.*).Error!void {
            try s.serializeInt(value.val);
        }
    };

    // Direct serialization of Inner via OOB map works.
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const map = .{.{ Inner, InnerAdapter }};
    try serializeWith(Inner, .{ .val = 99 }, &mock, map);
    // Inner should be serialized via the adapter (as int), not as a struct.
    try testing.expectEqual(TestEvent{ .int_val = 99 }, mock.events.items[0]);
}

test "serializeWith: no match falls through to default" {
    const Point = struct { x: i32, y: i32 };
    const Unrelated = struct { z: u32 };

    const UnrelatedAdapter = struct {
        pub fn serialize(_: Unrelated, _: anytype) !void {}
    };

    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    // Map only has Unrelated, not Point — Point should serialize normally.
    const map = .{.{ Unrelated, UnrelatedAdapter }};
    try serializeWith(Point, .{ .x = 1, .y = 2 }, &mock, map);
    try testing.expectEqual(TestEvent.struct_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .field = "x" }, mock.events.items[1]);
    try testing.expectEqual(TestEvent{ .int_val = 1 }, mock.events.items[2]);
}
