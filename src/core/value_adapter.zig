//! Value implements the format interfaces, so type options have one implementation.
const std = @import("std");
const model = @import("value.zig");
const ser = @import("serialize.zig");
const de = @import("deserialize.zig");
const reflect = @import("../reflect.zig");
const Value = model.Value;
const Entry = model.Entry;
const Allocator = std.mem.Allocator;
const Errors = error{ OutOfMemory, WrongType, Overflow, MissingField, DuplicateField, UnknownField, UnknownVariant, UnexpectedToken, UnexpectedEof, InvalidNumber, WithFailed };

const Sink = union(enum) {
    root: *?Value,
    array: *std.ArrayList(Value),
    fn put(self: Sink, allocator: Allocator, value: Value) Errors!void {
        errdefer value.deinit(allocator);
        switch (self) {
            .root => |out| out.* = value,
            .array => |out| try out.append(allocator, value),
        }
    }
};
pub const Serializer = struct {
    allocator: Allocator,
    sink: Sink,
    pub const Error = Errors;
    pub fn init(allocator: Allocator, result: *?Value) Serializer {
        return .{ .allocator = allocator, .sink = .{ .root = result } };
    }
    pub fn serializeBool(self: *Serializer, v: bool) Error!void {
        try self.sink.put(self.allocator, .{ .bool = v });
    }
    pub fn serializeInt(self: *Serializer, v: anytype) Error!void {
        const value: Value = if (v < 0) .{ .int = std.math.cast(i64, v) orelse return error.Overflow } else .{ .uint = std.math.cast(u64, v) orelse return error.Overflow };
        try self.sink.put(self.allocator, value);
    }
    pub fn serializeFloat(self: *Serializer, v: anytype) Error!void {
        try self.sink.put(self.allocator, .{ .float = @floatCast(v) });
    }
    pub fn serializeString(self: *Serializer, v: []const u8) Error!void {
        try self.sink.put(self.allocator, .{ .string = try self.allocator.dupe(u8, v) });
    }
    pub fn serializeNull(self: *Serializer) Error!void {
        try self.sink.put(self.allocator, .null);
    }
    pub fn serializeVoid(self: *Serializer) Error!void {
        return self.serializeNull();
    }
    pub fn beginArray(self: *Serializer) Error!Array {
        return self.beginArrayLen(0);
    }
    pub fn beginStruct(self: *Serializer) Error!Object {
        return self.beginStructLen(0);
    }
    pub fn beginArrayLen(self: *Serializer, n: usize) Error!Array {
        var items: std.ArrayList(Value) = .empty;
        try items.ensureTotalCapacity(self.allocator, n);
        return .{ .allocator = self.allocator, .sink = self.sink, .items = items };
    }
    pub fn beginStructLen(self: *Serializer, n: usize) Error!Object {
        var items: std.ArrayList(Entry) = .empty;
        try items.ensureTotalCapacity(self.allocator, n);
        return .{ .allocator = self.allocator, .sink = self.sink, .items = items };
    }
};
const Object = struct {
    allocator: Allocator,
    sink: Sink,
    items: std.ArrayList(Entry),
    pub const Error = Errors;
    pub fn serializeField(self: *Object, comptime key: []const u8, value: anytype) Error!void {
        return self.serializeEntry(key, value);
    }
    pub fn serializeEntry(self: *Object, key: anytype, value: anytype) Error!void {
        const owned_key = if (@typeInfo(@TypeOf(key)) == .int) try std.fmt.allocPrint(self.allocator, "{d}", .{key}) else try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        var result: ?Value = null;
        errdefer if (result) |v| v.deinit(self.allocator);
        var child = Serializer.init(self.allocator, &result);
        try ser.serialize(@TypeOf(value), value, &child, .{});
        try self.items.append(self.allocator, .{ .key = owned_key, .value = result.? });
    }
    pub fn end(self: *Object) Error!void {
        try self.sink.put(self.allocator, .{ .object = try self.items.toOwnedSlice(self.allocator) });
    }
    pub fn deinit(self: *Object) void {
        for (self.items.items) |e| {
            self.allocator.free(e.key);
            e.value.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
    }
};
const Array = struct {
    allocator: Allocator,
    sink: Sink,
    items: std.ArrayList(Value),
    pub const Error = Errors;
    fn child(self: *Array) Serializer {
        return .{ .allocator = self.allocator, .sink = .{ .array = &self.items } };
    }
    pub fn end(self: *Array) Error!void {
        try self.sink.put(self.allocator, .{ .array = try self.items.toOwnedSlice(self.allocator) });
    }
    pub fn deinit(self: *Array) void {
        for (self.items.items) |v| v.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
    pub fn serializeBool(self: *Array, v: bool) Error!void {
        var c = self.child();
        return c.serializeBool(v);
    }
    pub fn serializeInt(self: *Array, v: anytype) Error!void {
        var c = self.child();
        return c.serializeInt(v);
    }
    pub fn serializeFloat(self: *Array, v: anytype) Error!void {
        var c = self.child();
        return c.serializeFloat(v);
    }
    pub fn serializeString(self: *Array, v: []const u8) Error!void {
        var c = self.child();
        return c.serializeString(v);
    }
    pub fn serializeNull(self: *Array) Error!void {
        var c = self.child();
        return c.serializeNull();
    }
    pub fn serializeVoid(self: *Array) Error!void {
        var c = self.child();
        return c.serializeVoid();
    }
    pub fn beginArray(self: *Array) Error!Array {
        var c = self.child();
        return c.beginArray();
    }
    pub fn beginStruct(self: *Array) Error!Object {
        var c = self.child();
        return c.beginStruct();
    }
    pub fn beginArrayLen(self: *Array, v: usize) Error!Array {
        var c = self.child();
        return c.beginArrayLen(v);
    }
    pub fn beginStructLen(self: *Array, v: usize) Error!Object {
        var c = self.child();
        return c.beginStructLen(v);
    }
};
pub const Deserializer = struct {
    pub const serde_protocol = struct {
        pub fn borrowedInput(_: *const Deserializer) ?[]const u8 {
            return null;
        }
        pub fn checkpoint(self: *const Deserializer) Deserializer {
            return self.*;
        }
        pub fn restore(self: *Deserializer, saved: Deserializer) void {
            self.* = saved;
        }
    };

    value: *const Value,
    pub const Error = Errors;
    pub fn deserializeBool(self: *Deserializer) Error!bool {
        return switch (self.value.*) {
            .bool => |v| v,
            else => error.WrongType,
        };
    }
    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        return switch (self.value.*) {
            .int => |v| std.math.cast(T, v) orelse error.Overflow,
            .uint => |v| std.math.cast(T, v) orelse error.Overflow,
            else => error.WrongType,
        };
    }
    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        return switch (self.value.*) {
            .float => |v| @floatCast(v),
            .int => |v| @floatFromInt(v),
            .uint => |v| @floatFromInt(v),
            else => error.WrongType,
        };
    }
    pub fn deserializeString(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        return switch (self.value.*) {
            .string => |v| allocator.dupe(u8, v),
            else => error.WrongType,
        };
    }
    pub fn deserializeVoid(self: *Deserializer) Error!void {
        if (self.value.* != .null) return error.WrongType;
    }
    pub fn deserializeOptional(self: *Deserializer, comptime T: type, allocator: Allocator) Error!?T {
        if (self.value.* == .null) return null;
        return try de.deserialize(T, allocator, self, .{});
    }
    pub fn deserializeEnum(self: *Deserializer, comptime T: type) Error!T {
        if (self.value.* != .string) return error.WrongType;
        inline for (reflect.enumFields(T)) |f| {
            if (std.mem.eql(u8, self.value.string, f.name)) return @enumFromInt(f.value);
        }
        return error.UnknownVariant;
    }
    pub fn deserializeUnion(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        if (self.value.* == .string) {
            inline for (reflect.unionFields(T)) |f| {
                if (f.type == void and std.mem.eql(u8, self.value.string, f.name)) return @unionInit(T, f.name, {});
            }
        } else if (self.value.* == .object and self.value.object.len == 1) {
            const entry = &self.value.object[0];
            inline for (reflect.unionFields(T)) |f| {
                if (std.mem.eql(u8, entry.key, f.name)) {
                    var child = Deserializer{ .value = &entry.value };
                    return @unionInit(T, f.name, try de.deserialize(f.type, allocator, &child, .{}));
                }
            }
        }
        return error.UnknownVariant;
    }
    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        if (self.value.* != .object) return error.WrongType;
        return .{ .entries = self.value.object };
    }
    pub fn deserializeSeq(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        return de.deserialize(T, allocator, self, .{});
    }
    pub fn deserializeSeqAccess(self: *Deserializer) Error!SeqAccess {
        if (self.value.* != .array) return error.WrongType;
        return .{ .items = self.value.array, .remaining = self.value.array.len };
    }
    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return narrow(err);
    }
};
const MapAccess = struct {
    pub const serde_protocol = struct {
        pub fn borrowedInput(_: *const MapAccess) ?[]const u8 {
            return null;
        }
    };

    entries: []const Entry,
    pos: usize = 0,
    pub const Error = Errors;
    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        if (self.pos == self.entries.len) return null;
        const key = self.entries[self.pos].key;
        self.pos += 1;
        return key;
    }
    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        var child = Deserializer{ .value = &self.entries[self.pos - 1].value };
        return de.deserialize(T, allocator, &child, .{});
    }
    pub fn skipValue(_: *MapAccess) Error!void {}
    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return narrow(err);
    }
};
const SeqAccess = struct {
    pub const serde_protocol = struct {
        pub fn borrowedInput(_: *const SeqAccess) ?[]const u8 {
            return null;
        }
        pub fn sizeHint(self: *const SeqAccess) ?usize {
            return self.remaining;
        }
    };

    items: []const Value,
    remaining: usize,
    pub const Error = Errors;
    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        if (self.remaining == 0) return null;
        var child = Deserializer{ .value = &self.items[self.items.len - self.remaining] };
        self.remaining -= 1;
        return try de.deserialize(T, allocator, &child, .{});
    }
};
fn narrow(err: anyerror) Errors {
    return switch (err) {
        error.OutOfMemory,
        error.WrongType,
        error.Overflow,
        error.MissingField,
        error.DuplicateField,
        error.UnknownField,
        error.UnknownVariant,
        error.UnexpectedToken,
        error.UnexpectedEof,
        error.InvalidNumber,
        error.WithFailed,
        => |known| known,
        else => error.WrongType,
    };
}
