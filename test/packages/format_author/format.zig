//! Educational tagged event format. Not a new supported serde format.
const std = @import("std");
const serde = @import("serde");
const core = serde.core;
const reflect = struct {
    const EnumField = struct { name: [:0]const u8, value: comptime_int };
    const UnionField = struct { name: [:0]const u8, type: type };
    inline fn enumFields(comptime T: type) []const EnumField {
        const info = @typeInfo(T).@"enum";
        comptime var fields: []const EnumField = &.{};
        if (comptime @hasField(@TypeOf(info), "fields")) {
            inline for (info.fields) |f| fields = fields ++ &[_]EnumField{.{ .name = f.name, .value = f.value }};
        } else {
            inline for (info.field_names, info.field_values) |name, value| fields = fields ++ &[_]EnumField{.{ .name = name, .value = value }};
        }
        return fields;
    }
    inline fn unionFields(comptime T: type) []const UnionField {
        const info = @typeInfo(T).@"union";
        comptime var fields: []const UnionField = &.{};
        if (comptime @hasField(@TypeOf(info), "fields")) {
            inline for (info.fields) |f| fields = fields ++ &[_]UnionField{.{ .name = f.name, .type = f.type }};
        } else {
            inline for (info.field_names, info.field_types) |name, field_type| fields = fields ++ &[_]UnionField{.{ .name = name, .type = field_type }};
        }
        return fields;
    }
};
const Allocator = std.mem.Allocator;

pub const Token = union(enum) {
    boolean: bool,
    int: struct { bits: u16, value: i128 },
    uint: struct { bits: u16, value: u128 },
    float: struct { bits: u16, value: f128 },
    string: []const u8,
    null,
    void,
    array_begin,
    array_end,
    object_begin,
    object_end,
};

pub const Serializer = struct {
    destination: *serde.compat.Io.Writer,
    pub const Error = error{ OutOfMemory, UnsupportedNumber, WrongType, WriteFailed };
    pub fn init(destination: *serde.compat.Io.Writer) Serializer {
        return .{ .destination = destination };
    }
    fn emit(self: *Serializer, token: Token) Error!void {
        const writer = self.destination;
        (switch (token) {
            .boolean => |v| writer.writeAll(if (v) "true\n" else "false\n"),
            .int => |v| writer.print("i{d}:{d}\n", .{ v.bits, v.value }),
            .uint => |v| writer.print("u{d}:{d}\n", .{ v.bits, v.value }),
            .float => |v| writer.print("f{d}:{d}\n", .{ v.bits, v.value }),
            .string => |v| writer.print("s{d}:{s}\n", .{ v.len, v }),
            .null => writer.writeAll("null\n"),
            .void => writer.writeAll("void\n"),
            .array_begin => writer.writeAll("[\n"),
            .array_end => writer.writeAll("]\n"),
            .object_begin => writer.writeAll("{\n"),
            .object_end => writer.writeAll("}\n"),
        }) catch return error.WriteFailed;
    }
    pub fn serializeBool(self: *Serializer, value: bool) Error!void {
        try self.emit(.{ .boolean = value });
    }
    pub fn serializeInt(self: *Serializer, value: anytype) Error!void {
        const info = @typeInfo(@TypeOf(value)).int;
        if (info.bits > 128) return error.UnsupportedNumber;
        if (info.signedness == .signed) try self.emit(.{ .int = .{ .bits = info.bits, .value = value } }) else try self.emit(.{ .uint = .{ .bits = info.bits, .value = value } });
    }
    pub fn serializeFloat(self: *Serializer, value: anytype) Error!void {
        try self.emit(.{ .float = .{ .bits = @typeInfo(@TypeOf(value)).float.bits, .value = value } });
    }
    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        try self.emit(.{ .string = value });
    }
    pub fn serializeNull(self: *Serializer) Error!void {
        try self.emit(.null);
    }
    pub fn serializeVoid(self: *Serializer) Error!void {
        try self.emit(.void);
    }
    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        try self.emit(.array_begin);
        return .{ .sink = self };
    }
    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        try self.emit(.object_begin);
        return .{ .sink = self };
    }
};

pub const StructSerializer = struct {
    sink: *Serializer,
    pub const Error = Serializer.Error;
    pub fn serializeField(self: *StructSerializer, comptime key: []const u8, value: anytype) Error!void {
        try self.sink.serializeString(key);
        try core.serialize(@TypeOf(value), value, self.sink, .{});
    }
    pub fn serializeEntry(self: *StructSerializer, key: anytype, value: anytype) Error!void {
        try core.serialize(@TypeOf(key), key, self.sink, .{});
        try core.serialize(@TypeOf(value), value, self.sink, .{});
    }
    pub fn end(self: *StructSerializer) Error!void {
        try self.sink.emit(.object_end);
    }
};

pub const ArraySerializer = struct {
    sink: *Serializer,
    pub const Error = Serializer.Error;
    pub fn serializeBool(self: *ArraySerializer, value: bool) Error!void {
        try self.sink.serializeBool(value);
    }
    pub fn serializeInt(self: *ArraySerializer, value: anytype) Error!void {
        try self.sink.serializeInt(value);
    }
    pub fn serializeFloat(self: *ArraySerializer, value: anytype) Error!void {
        try self.sink.serializeFloat(value);
    }
    pub fn serializeString(self: *ArraySerializer, value: []const u8) Error!void {
        try self.sink.serializeString(value);
    }
    pub fn serializeNull(self: *ArraySerializer) Error!void {
        try self.sink.serializeNull();
    }
    pub fn serializeVoid(self: *ArraySerializer) Error!void {
        try self.sink.serializeVoid();
    }
    pub fn beginArray(self: *ArraySerializer) Error!ArraySerializer {
        return self.sink.beginArray();
    }
    pub fn beginStruct(self: *ArraySerializer) Error!StructSerializer {
        return self.sink.beginStruct();
    }
    pub fn end(self: *ArraySerializer) Error!void {
        try self.sink.emit(.array_end);
    }
};

pub const Deserializer = struct {
    document: []const u8,
    offset: usize = 0,
    pub const Error = error{ OutOfMemory, UnexpectedToken, UnexpectedEof, WrongType, Overflow, MissingField, DuplicateField, UnknownField, WithFailed };
    pub const serde_protocol = struct {
        pub fn borrowedInput(_: *const Deserializer) ?[]const u8 {
            return null;
        }
        pub fn checkpoint(self: *const Deserializer) usize {
            return self.offset;
        }
        pub fn restore(self: *Deserializer, saved: usize) void {
            self.offset = saved;
        }
    };
    pub fn init(document: []const u8) Deserializer {
        return .{ .document = document };
    }
    fn peek(self: *const Deserializer) Error!Token {
        var copy = self.*;
        return copy.take();
    }
    fn take(self: *Deserializer) Error!Token {
        if (self.offset == self.document.len) return error.UnexpectedEof;
        const rest = self.document[self.offset..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.UnexpectedEof;
        const line = rest[0..end];
        const names = .{ "true", "false", "null", "void", "[", "]", "{", "}" };
        const values = [_]Token{ .{ .boolean = true }, .{ .boolean = false }, .null, .void, .array_begin, .array_end, .object_begin, .object_end };
        inline for (names, values) |name, value| {
            if (std.mem.eql(u8, line, name)) {
                self.offset += end + 1;
                return value;
            }
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.UnexpectedToken;
        if (colon < 2) return error.UnexpectedToken;
        const width = std.fmt.parseInt(usize, line[1..colon], 10) catch return error.UnexpectedToken;
        if (line[0] == 's') {
            const start = colon + 1;
            if (width >= rest.len - start) return error.UnexpectedEof;
            if (rest[start + width] != '\n') return error.UnexpectedToken;
            self.offset += start + width + 1;
            return .{ .string = rest[start..][0..width] };
        }
        if (width > 128) return error.Overflow;
        const bits: u16 = @intCast(width);
        const value = line[colon + 1 ..];
        const event: Token = switch (line[0]) {
            'i' => .{ .int = .{ .bits = bits, .value = std.fmt.parseInt(i128, value, 10) catch return error.UnexpectedToken } },
            'u' => .{ .uint = .{ .bits = bits, .value = std.fmt.parseInt(u128, value, 10) catch return error.UnexpectedToken } },
            'f' => .{ .float = .{ .bits = bits, .value = std.fmt.parseFloat(f128, value) catch return error.UnexpectedToken } },
            else => return error.UnexpectedToken,
        };
        self.offset += end + 1;
        return event;
    }
    fn expect(self: *Deserializer, tag: std.meta.Tag(Token)) Error!void {
        if (try self.take() != tag) return error.WrongType;
    }
    pub fn finish(self: *const Deserializer) Error!void {
        if (self.offset != self.document.len) return error.UnexpectedToken;
    }
    pub fn deserializeBool(self: *Deserializer) Error!bool {
        return switch (try self.take()) {
            .boolean => |v| v,
            else => error.WrongType,
        };
    }
    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        const info = @typeInfo(T).int;
        const token = try self.take();
        if (info.signedness == .signed) {
            if (token != .int or token.int.bits != info.bits) return error.WrongType;
            return std.math.cast(T, token.int.value) orelse error.Overflow;
        }
        if (token != .uint or token.uint.bits != info.bits) return error.WrongType;
        return std.math.cast(T, token.uint.value) orelse error.Overflow;
    }
    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        const token = try self.take();
        if (token != .float or token.float.bits != @typeInfo(T).float.bits) return error.WrongType;
        return @floatCast(token.float.value);
    }
    pub fn deserializeString(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        return switch (try self.take()) {
            .string => |v| try allocator.dupe(u8, v),
            else => error.WrongType,
        };
    }
    pub fn deserializeVoid(self: *Deserializer) Error!void {
        try self.expect(.void);
    }
    pub fn deserializeOptional(self: *Deserializer, comptime T: type, allocator: Allocator) Error!?T {
        if (try self.peek() == .null) {
            _ = try self.take();
            return null;
        }
        return try core.deserialize(T, allocator, self, .{});
    }
    pub fn deserializeEnum(self: *Deserializer, comptime T: type) Error!T {
        const token = try self.take();
        if (token != .string) return error.WrongType;
        inline for (reflect.enumFields(T)) |f| if (std.mem.eql(u8, token.string, f.name)) return @enumFromInt(f.value);
        return error.UnexpectedToken;
    }
    pub fn deserializeUnion(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        if (try self.peek() == .string) {
            const name = (try self.take()).string;
            inline for (reflect.unionFields(T)) |f| if (f.type == void and std.mem.eql(u8, name, f.name)) return @unionInit(T, f.name, {});
            return error.UnexpectedToken;
        }
        var access = try self.deserializeStruct(T);
        const key = (try access.nextKey(allocator)) orelse return error.MissingField;
        inline for (reflect.unionFields(T)) |f| {
            if (std.mem.eql(u8, key, f.name)) {
                const value = try access.nextValue(f.type, allocator);
                errdefer core.freeAllocated(f.type, value, allocator);
                if (try access.nextKey(allocator) != null) return error.UnexpectedToken;
                return @unionInit(T, f.name, value);
            }
        }
        return error.UnexpectedToken;
    }
    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        try self.expect(.object_begin);
        return .{ .source = self };
    }
    pub fn deserializeSeqAccess(self: *Deserializer) Error!SeqAccess {
        try self.expect(.array_begin);
        return .{ .source = self };
    }
    pub fn deserializeSeq(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        return core.deserialize(T, allocator, self, .{});
    }
    fn skip(self: *Deserializer) Error!void {
        switch (try self.take()) {
            .array_begin => {
                while (try self.peek() != .array_end) try self.skip();
                _ = try self.take();
            },
            .object_begin => {
                while (try self.peek() != .object_end) {
                    if (try self.take() != .string) return error.WrongType;
                    try self.skip();
                }
                _ = try self.take();
            },
            .array_end, .object_end => return error.UnexpectedToken,
            else => {},
        }
    }
    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.MissingField => error.MissingField,
            error.DuplicateField => error.DuplicateField,
            error.UnknownField => error.UnknownField,
            error.Overflow => error.Overflow,
            error.WithFailed => error.WithFailed,
            error.WrongType => error.WrongType,
            error.UnexpectedEof => error.UnexpectedEof,
            else => error.UnexpectedToken,
        };
    }
};

pub const MapAccess = struct {
    source: *Deserializer,
    pub const Error = Deserializer.Error;
    pub const serde_protocol = struct {
        pub fn borrowedInput(_: *const MapAccess) ?[]const u8 {
            return null;
        }
    };
    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        return switch (try self.source.take()) {
            .object_end => null,
            .string => |key| key,
            else => error.WrongType,
        };
    }
    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        return core.deserialize(T, allocator, self.source, .{});
    }
    pub fn skipValue(self: *MapAccess) Error!void {
        try self.source.skip();
    }
    pub fn raiseError(self: *MapAccess, err: anyerror) Error {
        return self.source.raiseError(err);
    }
};
pub const SeqAccess = struct {
    source: *Deserializer,
    pub const Error = Deserializer.Error;
    pub const serde_protocol = struct {
        pub fn borrowedInput(_: *const SeqAccess) ?[]const u8 {
            return null;
        }
        pub fn sizeHint(_: *const SeqAccess) ?usize {
            return null;
        }
    };
    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        if (try self.source.peek() == .array_end) {
            _ = try self.source.take();
            return null;
        }
        return try core.deserialize(T, allocator, self.source, .{});
    }
};
