//! Format-independent event testing. Strings in emitted tokens borrow the value;
//! keep it alive while inspecting the token buffer. Deserialization copies strings.
const std = @import("std");
const core = @import("../core/mod.zig");
const reflect = @import("../reflect.zig");
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

pub const TokenSerializer = struct {
    buffer: []Token,
    written: usize = 0,
    pub const Error = error{ OutOfMemory, UnsupportedNumber, WrongType };
    pub fn init(buffer: []Token) TokenSerializer {
        return .{ .buffer = buffer };
    }
    pub fn tokens(self: *const TokenSerializer) []const Token {
        return self.buffer[0..self.written];
    }
    fn emit(self: *TokenSerializer, token: Token) Error!void {
        if (self.written == self.buffer.len) return error.OutOfMemory;
        self.buffer[self.written] = token;
        self.written += 1;
    }
    pub fn serializeBool(self: *TokenSerializer, value: bool) Error!void {
        try self.emit(.{ .boolean = value });
    }
    pub fn serializeInt(self: *TokenSerializer, value: anytype) Error!void {
        const info = @typeInfo(@TypeOf(value)).int;
        if (info.bits > 128) return error.UnsupportedNumber;
        if (info.signedness == .signed) try self.emit(.{ .int = .{ .bits = info.bits, .value = value } }) else try self.emit(.{ .uint = .{ .bits = info.bits, .value = value } });
    }
    pub fn serializeFloat(self: *TokenSerializer, value: anytype) Error!void {
        try self.emit(.{ .float = .{ .bits = @typeInfo(@TypeOf(value)).float.bits, .value = value } });
    }
    pub fn serializeString(self: *TokenSerializer, value: []const u8) Error!void {
        try self.emit(.{ .string = value });
    }
    pub fn serializeNull(self: *TokenSerializer) Error!void {
        try self.emit(.null);
    }
    pub fn serializeVoid(self: *TokenSerializer) Error!void {
        try self.emit(.void);
    }
    pub fn beginArray(self: *TokenSerializer) Error!ArraySerializer {
        try self.emit(.array_begin);
        return .{ .sink = self };
    }
    pub fn beginStruct(self: *TokenSerializer) Error!StructSerializer {
        try self.emit(.object_begin);
        return .{ .sink = self };
    }
};

pub const StructSerializer = struct {
    sink: *TokenSerializer,
    pub const Error = TokenSerializer.Error;
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
    sink: *TokenSerializer,
    pub const Error = TokenSerializer.Error;
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

pub const TokenDeserializer = struct {
    events: []const Token,
    cursor: usize = 0,
    pub const Error = error{ OutOfMemory, UnexpectedToken, UnexpectedEof, WrongType, Overflow, MissingField, DuplicateField, UnknownField, WithFailed };
    pub const serde_protocol = struct {
        pub fn borrowedInput(_: *const TokenDeserializer) ?[]const u8 {
            return null;
        }
        pub fn checkpoint(self: *const TokenDeserializer) usize {
            return self.cursor;
        }
        pub fn restore(self: *TokenDeserializer, saved: usize) void {
            self.cursor = saved;
        }
    };
    pub fn init(events: []const Token) TokenDeserializer {
        return .{ .events = events };
    }
    fn peek(self: *const TokenDeserializer) Error!Token {
        if (self.cursor == self.events.len) return error.UnexpectedEof;
        return self.events[self.cursor];
    }
    fn take(self: *TokenDeserializer) Error!Token {
        const event = try self.peek();
        self.cursor += 1;
        return event;
    }
    fn expect(self: *TokenDeserializer, tag: std.meta.Tag(Token)) Error!void {
        if (try self.take() != tag) return error.WrongType;
    }
    pub fn finish(self: *const TokenDeserializer) Error!void {
        if (self.cursor != self.events.len) return error.UnexpectedToken;
    }
    pub fn deserializeBool(self: *TokenDeserializer) Error!bool {
        return switch (try self.take()) {
            .boolean => |v| v,
            else => error.WrongType,
        };
    }
    pub fn deserializeInt(self: *TokenDeserializer, comptime T: type) Error!T {
        const info = @typeInfo(T).int;
        const token = try self.take();
        if (info.signedness == .signed) {
            if (token != .int or token.int.bits != info.bits) return error.WrongType;
            return std.math.cast(T, token.int.value) orelse error.Overflow;
        }
        if (token != .uint or token.uint.bits != info.bits) return error.WrongType;
        return std.math.cast(T, token.uint.value) orelse error.Overflow;
    }
    pub fn deserializeFloat(self: *TokenDeserializer, comptime T: type) Error!T {
        const token = try self.take();
        if (token != .float or token.float.bits != @typeInfo(T).float.bits) return error.WrongType;
        return @floatCast(token.float.value);
    }
    pub fn deserializeString(self: *TokenDeserializer, allocator: Allocator) Error![]const u8 {
        return switch (try self.take()) {
            .string => |v| try allocator.dupe(u8, v),
            else => error.WrongType,
        };
    }
    pub fn deserializeVoid(self: *TokenDeserializer) Error!void {
        try self.expect(.void);
    }
    pub fn deserializeOptional(self: *TokenDeserializer, comptime T: type, allocator: Allocator) Error!?T {
        if (try self.peek() == .null) {
            self.cursor += 1;
            return null;
        }
        return try core.deserialize(T, allocator, self, .{});
    }
    pub fn deserializeEnum(self: *TokenDeserializer, comptime T: type) Error!T {
        const token = try self.take();
        if (token != .string) return error.WrongType;
        inline for (reflect.enumFields(T)) |f| if (std.mem.eql(u8, token.string, f.name)) return @enumFromInt(f.value);
        return error.UnexpectedToken;
    }
    pub fn deserializeUnion(self: *TokenDeserializer, comptime T: type, allocator: Allocator) Error!T {
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
    pub fn deserializeStruct(self: *TokenDeserializer, comptime _: type) Error!MapAccess {
        try self.expect(.object_begin);
        return .{ .source = self };
    }
    pub fn deserializeSeqAccess(self: *TokenDeserializer) Error!SeqAccess {
        try self.expect(.array_begin);
        return .{ .source = self };
    }
    pub fn deserializeSeq(self: *TokenDeserializer, comptime T: type, allocator: Allocator) Error!T {
        return core.deserialize(T, allocator, self, .{});
    }
    fn skip(self: *TokenDeserializer) Error!void {
        switch (try self.take()) {
            .array_begin => {
                while (try self.peek() != .array_end) try self.skip();
                self.cursor += 1;
            },
            .object_begin => {
                while (try self.peek() != .object_end) {
                    if (try self.take() != .string) return error.WrongType;
                    try self.skip();
                }
                self.cursor += 1;
            },
            .array_end, .object_end => return error.UnexpectedToken,
            else => {},
        }
    }
    pub fn raiseError(_: *TokenDeserializer, err: anyerror) Error {
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
    source: *TokenDeserializer,
    pub const Error = TokenDeserializer.Error;
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
    source: *TokenDeserializer,
    pub const Error = TokenDeserializer.Error;
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
            self.source.cursor += 1;
            return null;
        }
        return try core.deserialize(T, allocator, self.source, .{});
    }
};

/// Check exact events, including numeric width, signedness, order, and boundaries.
pub fn expectSerialize(value: anytype, expected: []const Token) !void {
    const buffer = try std.testing.allocator.alloc(Token, expected.len + 1);
    defer std.testing.allocator.free(buffer);
    var serializer = TokenSerializer.init(buffer);
    try core.serialize(@TypeOf(value), value, &serializer, .{});
    try std.testing.expectEqualDeep(expected, serializer.tokens());
}

/// Parse using an arena, compare the value, and require consumption of all events.
pub fn expectDeserialize(comptime T: type, expected: T, tokens: []const Token) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var deserializer = TokenDeserializer.init(tokens);
    const result = try core.deserialize(T, arena.allocator(), &deserializer, .{});
    try deserializer.finish();
    try std.testing.expectEqualDeep(expected, result);
}
