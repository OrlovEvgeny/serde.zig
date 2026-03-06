const std = @import("std");
const kind_mod = @import("kind.zig");
const options = @import("options.zig");

const Kind = kind_mod.Kind;
const Child = kind_mod.Child;
const typeKind = kind_mod.typeKind;

/// Serialize any value using a format-specific serializer.
pub fn serialize(
    comptime T: type,
    value: T,
    serializer: anytype,
) @TypeOf(serializer.*).Error!void {
    if (comptime options.hasCustomSerializer(T)) {
        return value.zerdeSerialize(serializer);
    }

    switch (comptime typeKind(T)) {
        .bool => return serializer.serializeBool(value),
        .int => return serializer.serializeInt(value),
        .float => return serializer.serializeFloat(value),
        .void => return serializer.serializeVoid(),
        .string => return serializer.serializeString(value),
        .optional => return serializeOptional(T, value, serializer),
        .pointer => return serialize(Child(T), value.*, serializer),
        .array => return serializeArray(T, value, serializer),
        .slice => return serializeSlice(T, value, serializer),
        .@"struct" => return serializeStruct(T, value, serializer),
        .tuple => return serializeTuple(T, value, serializer),
        .@"union" => return serializeUnion(T, value, serializer),
        .@"enum" => return serializeEnum(T, value, serializer),
        .map => return serializeMap(T, value, serializer),
        .bytes => {
            if (comptime @hasDecl(@TypeOf(serializer.*), "serializeBytes")) {
                return serializer.serializeBytes(value);
            }
            return serializer.serializeString(value);
        },
        .custom => @compileError(@typeName(T) ++ " declares custom kind but no zerdeSerialize"),
    }
}

fn serializeOptional(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    if (value) |v| {
        return serialize(Child(T), v, serializer);
    } else {
        return serializer.serializeNull();
    }
}

fn serializeArray(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const child = Child(T);
    var arr = try serializer.beginArray();
    for (value) |elem| {
        try serialize(child, elem, &arr);
    }
    return arr.end();
}

fn serializeSlice(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const child = Child(T);
    var arr = try serializer.beginArray();
    for (value) |elem| {
        try serialize(child, elem, &arr);
    }
    return arr.end();
}

fn serializeStruct(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"struct";

    var ss = try serializer.beginStruct();

    inline for (info.fields) |field| {
        if (comptime options.shouldSkipField(T, field.name, .serialize)) continue;

        // Flattened fields: inline the sub-struct's fields at the parent level.
        if (comptime options.isFlattenedField(T, field.name)) {
            if (@typeInfo(field.type) != .@"struct")
                @compileError("Flatten requires a struct type, got " ++ @typeName(field.type));
            const nested = @field(value, field.name);
            const nested_info = @typeInfo(field.type).@"struct";
            inline for (nested_info.fields) |sf| {
                const nested_wire = comptime options.wireFieldName(field.type, sf.name);
                try ss.serializeField(nested_wire, @field(nested, sf.name));
            }
            continue;
        }

        const wire_name = comptime options.wireFieldName(T, field.name);
        const field_value = @field(value, field.name);

        const skip_null = comptime options.isSkipIfNull(T, field.name) and @typeInfo(field.type) == .optional;
        const skip_empty = comptime options.isSkipIfEmpty(T, field.name) and @typeInfo(field.type) == .pointer;

        const should_skip = (skip_null and field_value == null) or
            (skip_empty and field_value.len == 0);

        if (!should_skip) {
            if (comptime options.hasFieldWith(T, field.name)) {
                const WithMod = comptime options.getFieldWith(T, field.name);
                try ss.serializeField(wire_name, WithMod.serialize(field_value));
            } else {
                try ss.serializeField(wire_name, field_value);
            }
        }
    }

    return ss.end();
}

fn serializeTuple(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"struct";
    var arr = try serializer.beginArray();
    inline for (info.fields) |field| {
        try serialize(field.type, @field(value, field.name), &arr);
    }
    return arr.end();
}

fn serializeUnion(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const tag_style = comptime options.getUnionTag(T);
    if (tag_style == .external) {
        return serializeUnionExternal(T, value, serializer);
    } else if (tag_style == .internal) {
        return serializeUnionInternal(T, value, serializer);
    } else if (tag_style == .adjacent) {
        return serializeUnionAdjacent(T, value, serializer);
    } else {
        return serializeUnionUntagged(T, value, serializer);
    }
}

fn serializeUnionExternal(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"union";
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            if (field.type == void) {
                return serializer.serializeString(field.name);
            } else {
                const payload = @field(value, field.name);
                var ss = try serializer.beginStruct();
                try ss.serializeField(field.name, payload);
                return ss.end();
            }
        }
    }
}

fn serializeUnionInternal(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"union";
    const tag_field_name = comptime options.getTagField(T);
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            var ss = try serializer.beginStruct();
            try ss.serializeField(tag_field_name, @as([]const u8, field.name));
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

fn serializeUnionAdjacent(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"union";
    const tag_field_name = comptime options.getTagField(T);
    const content_field_name = comptime options.getContentField(T);
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            var ss = try serializer.beginStruct();
            try ss.serializeField(tag_field_name, @as([]const u8, field.name));
            if (field.type != void) {
                const payload = @field(value, field.name);
                try ss.serializeField(content_field_name, payload);
            }
            return ss.end();
        }
    }
}

fn serializeUnionUntagged(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    const info = @typeInfo(T).@"union";
    inline for (info.fields) |field| {
        if (value == @field(T, field.name)) {
            if (field.type == void) {
                return serializer.serializeNull();
            } else {
                const payload = @field(value, field.name);
                return serialize(field.type, payload, serializer);
            }
        }
    }
}

fn serializeEnum(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    if (comptime options.getEnumRepr(T) == .integer) {
        const tag_type = @typeInfo(T).@"enum".tag_type;
        return serializer.serializeInt(@as(tag_type, @intFromEnum(value)));
    }
    return serializer.serializeString(@tagName(value));
}

fn serializeMap(comptime T: type, value: T, serializer: anytype) @TypeOf(serializer.*).Error!void {
    var ss = try serializer.beginStruct();
    var it = value.iterator();
    while (it.next()) |entry| {
        try ss.serializeEntry(entry.key_ptr.*, entry.value_ptr.*);
    }
    return ss.end();
}

// Tests using a mock serializer.

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
            try serialize(@TypeOf(value), value, self.parent);
        }

        pub fn serializeEntry(self: *StructSer, key: anytype, value: anytype) SerError!void {
            _ = key;
            try serialize(@TypeOf(value), value, self.parent);
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
    try serialize(bool, true, &mock);
    try testing.expectEqual(TestEvent{ .bool_val = true }, mock.events.items[0]);
}

test "serialize int" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(u32, 42, &mock);
    try testing.expectEqual(TestEvent{ .int_val = 42 }, mock.events.items[0]);
}

test "serialize float" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(f64, 3.14, &mock);
    try testing.expectEqual(TestEvent{ .float_val = 3.14 }, mock.events.items[0]);
}

test "serialize string" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize([]const u8, "hello", &mock);
    try testing.expectEqualStrings("hello", mock.events.items[0].string_val);
}

test "serialize optional null" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const val: ?u32 = null;
    try serialize(?u32, val, &mock);
    try testing.expectEqual(TestEvent.null_val, mock.events.items[0]);
}

test "serialize optional value" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    const val: ?u32 = 7;
    try serialize(?u32, val, &mock);
    try testing.expectEqual(TestEvent{ .int_val = 7 }, mock.events.items[0]);
}

test "serialize struct" {
    const Point = struct { x: i32, y: i32 };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Point, .{ .x = 1, .y = 2 }, &mock);
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
    try serialize(User, .{ .id = 1, .first_name = "Bob" }, &mock);
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
    try serialize(Secret, .{ .name = "test", .token = "secret" }, &mock);
    try testing.expectEqual(@as(usize, 4), mock.events.items.len);
    try testing.expectEqual(TestEvent{ .field = "name" }, mock.events.items[1]);
}

test "serialize array" {
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize([3]i32, .{ 1, 2, 3 }, &mock);
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
    try serialize([]const i32, data, &mock);
    try testing.expectEqual(TestEvent.array_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .int_val = 10 }, mock.events.items[1]);
    try testing.expectEqual(TestEvent{ .int_val = 20 }, mock.events.items[2]);
    try testing.expectEqual(TestEvent.array_end, mock.events.items[3]);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Color, .green, &mock);
    try testing.expectEqualStrings("green", mock.events.items[0].string_val);
}

test "serialize tagged union with void payload" {
    const Cmd = union(enum) { ping: void, quit: void };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Cmd, .ping, &mock);
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
    try serialize(Command, .ping, &mock);
    // Internal tagging for void: {"type":"ping"}
    try testing.expectEqual(TestEvent.struct_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .field = "type" }, mock.events.items[1]);
    try testing.expectEqualStrings("ping", mock.events.items[2].string_val);
    try testing.expectEqual(TestEvent.struct_end, mock.events.items[3]);
}

test "serialize tagged union with payload" {
    const Cmd = union(enum) { set: u32, ping: void };
    var mock = MockSerializer.init(testing.allocator);
    defer mock.deinit();
    try serialize(Cmd, .{ .set = 42 }, &mock);
    try testing.expectEqual(TestEvent.struct_begin, mock.events.items[0]);
    try testing.expectEqual(TestEvent{ .field = "set" }, mock.events.items[1]);
    try testing.expectEqual(TestEvent{ .int_val = 42 }, mock.events.items[2]);
    try testing.expectEqual(TestEvent.struct_end, mock.events.items[3]);
}
