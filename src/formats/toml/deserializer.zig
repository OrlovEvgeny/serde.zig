const std = @import("std");
const parser_mod = @import("parser.zig");
const core_deserialize = @import("../../core/deserialize.zig");

const Allocator = std.mem.Allocator;
const Value = parser_mod.Value;
const Table = parser_mod.Table;

pub const DeserializeError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEof,
    UnknownField,
    MissingField,
    WrongType,
    InvalidNumber,
    Overflow,
};

pub const Deserializer = struct {
    table: *const Table,

    pub const Error = DeserializeError;

    pub fn init(table: *const Table) Deserializer {
        return .{ .table = table };
    }

    pub fn deserializeBool(_: *Deserializer) Error!bool {
        return error.WrongType;
    }

    pub fn deserializeInt(_: *Deserializer, comptime _: type) Error!void {
        return error.WrongType;
    }

    pub fn deserializeFloat(_: *Deserializer, comptime _: type) Error!void {
        return error.WrongType;
    }

    pub fn deserializeString(_: *Deserializer, _: Allocator) Error![]const u8 {
        return error.WrongType;
    }

    pub fn deserializeVoid(_: *Deserializer) Error!void {
        return error.WrongType;
    }

    pub fn deserializeOptional(_: *Deserializer, comptime _: type, _: Allocator) Error!void {
        return error.WrongType;
    }

    pub fn deserializeEnum(_: *Deserializer, comptime _: type) Error!void {
        return error.WrongType;
    }

    pub fn deserializeUnion(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        return deserializeUnionFromTable(self.table, T, allocator);
    }

    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        return .{ .table = self.table, .iter = self.table.iterator() };
    }

    pub fn deserializeSeq(_: *Deserializer, comptime _: type, _: Allocator) Error!void {
        return error.WrongType;
    }

    pub fn deserializeSeqAccess(_: *Deserializer) Error!void {
        return error.WrongType;
    }

    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const MapAccess = struct {
    table: *const Table,
    iter: Table.Iterator,

    pub const Error = DeserializeError;

    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        const entry = self.iter.next();
        if (entry == null) return null;
        return entry.?.key_ptr.*;
    }

    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        // The iterator has already advanced past the entry we want.
        // We need to get the value for the key that was just returned.
        // The iterator index is one past what we returned in nextKey.
        const idx = self.iter.index - 1;
        const values = self.table.values();
        const val = &values[idx];
        return deserializeValue(T, val, allocator);
    }

    pub fn skipValue(self: *MapAccess) Error!void {
        _ = self;
    }

    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const SeqAccess = struct {
    items: []const Value,
    pos: usize,

    pub const Error = DeserializeError;

    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        if (self.pos >= self.items.len) return null;
        const val = &self.items[self.pos];
        self.pos += 1;
        return deserializeValue(T, val, allocator);
    }
};

// Recursive value-to-type conversion.
fn deserializeValue(comptime T: type, val: *const Value, allocator: Allocator) DeserializeError!T {
    const kind = @import("../../core/kind.zig");
    const opts = @import("../../core/options.zig");

    if (comptime opts.hasCustomDeserializer(T)) {
        // Custom deserializers expect a Deserializer interface pointer.
        // For TOML, wrap the value and delegate.
        var vd = ValueDeserializer.init(val);
        return T.zerdeDeserialize(T, allocator, &vd);
    }

    switch (comptime kind.typeKind(T)) {
        .bool => {
            if (val.* != .boolean) return error.WrongType;
            return val.boolean;
        },
        .int => {
            if (val.* == .integer) {
                return std.math.cast(T, val.integer) orelse error.Overflow;
            }
            return error.WrongType;
        },
        .float => {
            if (val.* == .float) {
                return @floatCast(val.float);
            }
            if (val.* == .integer) {
                return @floatFromInt(val.integer);
            }
            return error.WrongType;
        },
        .string => {
            if (val.* != .string) return error.WrongType;
            return allocator.dupe(u8, val.string) catch return error.OutOfMemory;
        },
        .optional => {
            // TOML has no null; if we got here the value exists, so unwrap.
            const child = kind.Child(T);
            return try deserializeValue(child, val, allocator);
        },
        .@"struct" => {
            if (val.* != .table) return error.WrongType;
            var deser = Deserializer.init(&val.table);
            return core_deserialize.deserialize(T, allocator, &deser, .{});
        },
        .@"enum" => {
            if (comptime opts.getEnumRepr(T) == .integer) {
                if (val.* != .integer) return error.WrongType;
                const tag_type = @typeInfo(T).@"enum".tag_type;
                const int_val = std.math.cast(tag_type, val.integer) orelse return error.Overflow;
                return std.meta.intToEnum(T, int_val) catch return error.UnexpectedToken;
            }
            if (val.* != .string) return error.WrongType;
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (std.mem.eql(u8, val.string, field.name))
                    return @enumFromInt(field.value);
            }
            return error.UnexpectedToken;
        },
        .@"union" => {
            const tag_style = comptime opts.getUnionTag(T);
            if (tag_style == .external) {
                return deserializeUnionFromValue(val, T, allocator);
            }
            // Internal/adjacent/untagged: route through core dispatch which
            // calls deserializeStruct on a ValueDeserializer.
            if (val.* == .table) {
                var vd = ValueDeserializer.init(val);
                return core_deserialize.deserialize(T, allocator, &vd, .{});
            }
            return error.WrongType;
        },
        .slice => {
            if (val.* != .array) return error.WrongType;
            const info = @typeInfo(T);
            const Child = info.pointer.child;
            var items: std.ArrayList(Child) = .empty;
            errdefer items.deinit(allocator);
            for (val.array) |*elem| {
                const item = try deserializeValue(Child, elem, allocator);
                items.append(allocator, item) catch return error.OutOfMemory;
            }
            return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
        },
        .array => {
            if (val.* != .array) return error.WrongType;
            const info = @typeInfo(T).array;
            if (val.array.len != info.len) return error.WrongType;
            var result: T = undefined;
            for (val.array, 0..) |*elem, i| {
                result[i] = try deserializeValue(info.child, elem, allocator);
            }
            return result;
        },
        .pointer => {
            const child = kind.Child(T);
            const v = try deserializeValue(child, val, allocator);
            const ptr = try allocator.create(child);
            ptr.* = v;
            return ptr;
        },
        .void => return {},
        else => @compileError("TOML deserialization does not support: " ++ @typeName(T)),
    }
}

fn deserializeUnionFromValue(val: *const Value, comptime T: type, allocator: Allocator) DeserializeError!T {
    const info = @typeInfo(T).@"union";

    // Void variants from string.
    if (val.* == .string) {
        inline for (info.fields) |field| {
            if (field.type == void and std.mem.eql(u8, val.string, field.name)) {
                return @unionInit(T, field.name, {});
            }
        }
        return error.UnexpectedToken;
    }

    // External tagging: table with a single key = variant name.
    if (val.* == .table) {
        return deserializeUnionFromTable(&val.table, T, allocator);
    }

    return error.WrongType;
}

fn deserializeUnionFromTable(table: *const Table, comptime T: type, allocator: Allocator) DeserializeError!T {
    const info = @typeInfo(T).@"union";

    if (table.count() != 1) return error.WrongType;
    var it = table.iterator();
    const entry = it.next().?;
    const variant_name = entry.key_ptr.*;

    inline for (info.fields) |field| {
        if (std.mem.eql(u8, variant_name, field.name)) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            } else {
                const payload = try deserializeValue(field.type, entry.value_ptr, allocator);
                return @unionInit(T, field.name, payload);
            }
        }
    }
    return error.UnexpectedToken;
}

// Wraps a single Value to provide the Deserializer interface for custom deserializers.
const ValueDeserializer = struct {
    val: *const Value,

    pub const Error = DeserializeError;

    fn init(val: *const Value) ValueDeserializer {
        return .{ .val = val };
    }

    pub fn deserializeBool(self: *ValueDeserializer) Error!bool {
        if (self.val.* != .boolean) return error.WrongType;
        return self.val.boolean;
    }

    pub fn deserializeInt(self: *ValueDeserializer, comptime T: type) Error!T {
        if (self.val.* != .integer) return error.WrongType;
        return std.math.cast(T, self.val.integer) orelse error.Overflow;
    }

    pub fn deserializeFloat(self: *ValueDeserializer, comptime T: type) Error!T {
        if (self.val.* == .float) return @floatCast(self.val.float);
        if (self.val.* == .integer) return @floatFromInt(self.val.integer);
        return error.WrongType;
    }

    pub fn deserializeString(self: *ValueDeserializer, allocator: Allocator) Error![]const u8 {
        if (self.val.* != .string) return error.WrongType;
        return allocator.dupe(u8, self.val.string) catch return error.OutOfMemory;
    }

    pub fn deserializeVoid(self: *ValueDeserializer) Error!void {
        _ = self;
    }

    pub fn deserializeOptional(self: *ValueDeserializer, comptime T: type, allocator: Allocator) Error!?T {
        return try deserializeValue(T, self.val, allocator);
    }

    pub fn deserializeEnum(self: *ValueDeserializer, comptime T: type) Error!T {
        if (self.val.* != .string) return error.WrongType;
        inline for (@typeInfo(T).@"enum".fields) |field| {
            if (std.mem.eql(u8, self.val.string, field.name))
                return @enumFromInt(field.value);
        }
        return error.UnexpectedToken;
    }

    pub fn deserializeUnion(self: *ValueDeserializer, comptime T: type, allocator: Allocator) Error!T {
        return deserializeUnionFromValue(self.val, T, allocator);
    }

    pub fn deserializeStruct(self: *ValueDeserializer, comptime _: type) Error!MapAccess {
        if (self.val.* != .table) return error.WrongType;
        return .{ .table = &self.val.table, .iter = self.val.table.iterator() };
    }

    pub fn deserializeSeq(self: *ValueDeserializer, comptime T: type, allocator: Allocator) Error!T {
        if (self.val.* != .array) return error.WrongType;
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .slice)
            @compileError("deserializeSeq expects a slice type");
        const Child = info.pointer.child;
        var items: std.ArrayList(Child) = .empty;
        errdefer items.deinit(allocator);
        for (self.val.array) |*elem| {
            const item = try deserializeValue(Child, elem, allocator);
            items.append(allocator, item) catch return error.OutOfMemory;
        }
        return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    pub fn deserializeSeqAccess(self: *ValueDeserializer) Error!SeqAccess {
        if (self.val.* != .array) return error.WrongType;
        return .{ .items = self.val.array, .pos = 0 };
    }

    pub fn raiseError(_: *ValueDeserializer, err: anyerror) Error {
        return errorFromAny(err);
    }
};

fn errorFromAny(err: anyerror) DeserializeError {
    return switch (err) {
        error.UnknownField => error.UnknownField,
        error.MissingField => error.MissingField,
        error.UnexpectedEof => error.UnexpectedEof,
        error.OutOfMemory => error.OutOfMemory,
        else => error.WrongType,
    };
}

// Tests.

const testing = std.testing;

test "deserialize bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = true\nb = false\n");
    const a = table.get("a").?;
    try testing.expectEqual(true, try deserializeValue(bool, &a, arena.allocator()));
    const b = table.get("b").?;
    try testing.expectEqual(false, try deserializeValue(bool, &b, arena.allocator()));
}

test "deserialize int" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = 42\nb = -7\n");
    const a = table.get("a").?;
    try testing.expectEqual(@as(i32, 42), try deserializeValue(i32, &a, arena.allocator()));
    const b = table.get("b").?;
    try testing.expectEqual(@as(i32, -7), try deserializeValue(i32, &b, arena.allocator()));
}

test "deserialize float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = 3.14\n");
    const a = table.get("a").?;
    const val = try deserializeValue(f64, &a, arena.allocator());
    try testing.expect(@abs(val - 3.14) < 0.001);
}

test "deserialize string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = \"hello\"\n");
    const a = table.get("a").?;
    const val = try deserializeValue([]const u8, &a, arena.allocator());
    try testing.expectEqualStrings("hello", val);
}

test "deserialize struct" {
    const Point = struct { x: i32, y: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "x = 10\ny = 20\n");
    var deser = Deserializer.init(&table);
    const point = try core_deserialize.deserialize(Point, arena.allocator(), &deser, .{});
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(),
        \\name = "test"
        \\
        \\[inner]
        \\val = 42
        \\
    );
    var deser = Deserializer.init(&table);
    const val = try core_deserialize.deserialize(Outer, arena.allocator(), &deser, .{});
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqual(@as(i32, 42), val.inner.val);
}

test "deserialize optional present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = 42\n");
    const a = table.get("a").?;
    const val = try deserializeValue(?i32, &a, arena.allocator());
    try testing.expectEqual(@as(?i32, 42), val);
}

test "deserialize optional missing via struct" {
    const Cfg = struct { a: i32, b: ?i32 = null };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = 5\n");
    var deser = Deserializer.init(&table);
    const val = try core_deserialize.deserialize(Cfg, arena.allocator(), &deser, .{});
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deserialize enum from string" {
    const Color = enum { red, green, blue };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "c = \"green\"\n");
    const cv = table.get("c").?;
    try testing.expectEqual(Color.green, try deserializeValue(Color, &cv, arena.allocator()));
}

test "deserialize slice of scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "nums = [1, 2, 3]\n");
    const nums = table.get("nums").?;
    const val = try deserializeValue([]const i32, &nums, arena.allocator());
    try testing.expectEqual(@as(usize, 3), val.len);
    try testing.expectEqual(@as(i32, 1), val[0]);
    try testing.expectEqual(@as(i32, 3), val[2]);
}

test "deserialize slice of structs" {
    const Item = struct { id: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(),
        \\[[items]]
        \\id = 1
        \\
        \\[[items]]
        \\id = 2
        \\
    );
    const items = table.get("items").?;
    const val = try deserializeValue([]const Item, &items, arena.allocator());
    try testing.expectEqual(@as(usize, 2), val.len);
    try testing.expectEqual(@as(i32, 1), val[0].id);
    try testing.expectEqual(@as(i32, 2), val[1].id);
}

test "deserialize missing required field" {
    const Req = struct { a: i32, b: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = 1\n");
    var deser = Deserializer.init(&table);
    const result = core_deserialize.deserialize(Req, arena.allocator(), &deser, .{});
    try testing.expectError(error.MissingField, result);
}

test "deserialize struct with default" {
    const Cfg = struct { name: []const u8, retries: i32 = 3 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "name = \"app\"\n");
    var deser = Deserializer.init(&table);
    const val = try core_deserialize.deserialize(Cfg, arena.allocator(), &deser, .{});
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(i32, 3), val.retries);
}

test "deserialize wrong type error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const table = try parser_mod.parse(arena.allocator(), "a = \"not a number\"\n");
    const a = table.get("a").?;
    try testing.expectError(error.WrongType, deserializeValue(i32, &a, arena.allocator()));
}
