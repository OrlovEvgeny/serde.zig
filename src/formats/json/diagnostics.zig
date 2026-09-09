//! Opt-in context over the ordinary JSON scanner and scalar parser.
const std = @import("std");
const base = @import("deserializer.zig");
const core = @import("../../core/deserialize.zig");
const Allocator = std.mem.Allocator;

pub const Category = enum { object, array, string, number, boolean, null, eof, invalid };

/// The buffer owns the JSON pointer, including escaped keys. No heap allocation.
/// Reuse by calling init or initializing another diagnostic deserializer.
pub const Diagnostics = struct {
    buffer: []u8,
    path: []const u8 = "",
    original_error: ?anyerror = null,
    byte_offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
    expected: ?[]const u8 = null,
    actual: ?Category = null,
    path_truncated: bool = false,
    used: usize = 0,

    pub fn init(buffer: []u8) Diagnostics {
        return .{ .buffer = buffer };
    }

    fn append(self: *Diagnostics, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.used < self.buffer.len) self.buffer[self.used] = byte;
            self.used += 1;
        }
    }
    fn push(self: *Diagnostics, key: []const u8) void {
        if (self.original_error != null) return;
        self.append("/");
        for (key) |byte| switch (byte) {
            '~' => self.append("~0"),
            '/' => self.append("~1"),
            else => self.append(&.{byte}),
        };
    }
    fn pop(self: *Diagnostics, length: usize) void {
        if (self.original_error == null) self.used = length;
    }
    fn record(self: *Diagnostics, input: []const u8, err: anyerror, offset: usize, expected: ?[]const u8, actual: ?Category) void {
        if (self.original_error != null) return;
        self.original_error = err;
        self.byte_offset = @min(offset, input.len);
        self.line = 1;
        self.column = 1;
        for (input[0..self.byte_offset]) |byte| {
            if (byte == '\n') {
                self.line += 1;
                self.column = 1;
            } else self.column += 1;
        }
        self.expected = expected;
        self.actual = actual;
        self.path_truncated = self.used > self.buffer.len;
        self.path = self.buffer[0..@min(self.used, self.buffer.len)];
    }
};

pub const DeserializerWithDiagnostics = struct {
    inner: base.Deserializer,
    diagnostics: *Diagnostics,
    value_start: usize = 0,
    pub const Error = base.DeserializeError;
    const Self = @This();

    pub fn init(input: []const u8, options: base.Options, diagnostics: *Diagnostics) Self {
        diagnostics.* = Diagnostics.init(diagnostics.buffer);
        return .{ .inner = base.Deserializer.initWith(input, options), .diagnostics = diagnostics };
    }
    pub const serde_protocol = struct {
        pub fn borrowedInput(self: *const Self) ?[]const u8 {
            return base.Deserializer.serde_protocol.borrowedInput(&self.inner);
        }
        pub const Checkpoint = struct { inner: base.Deserializer, diagnostics: Diagnostics, value_start: usize };
        pub fn checkpoint(self: *const Self) Checkpoint {
            return .{ .inner = self.inner, .diagnostics = self.diagnostics.*, .value_start = self.value_start };
        }
        pub fn restore(self: *Self, saved: Checkpoint) void {
            self.inner = saved.inner;
            self.diagnostics.* = saved.diagnostics;
            self.value_start = saved.value_start;
        }
        pub fn unionVariant(self: *Self, key: []const u8) void {
            self.diagnostics.push(key);
        }
        pub fn failure(self: *Self, err: anyerror) void {
            self.note(err, null);
        }
    };
    fn start(self: *Self) void {
        self.inner.scanner.skipWhitespace();
        self.value_start = self.inner.scanner.pos;
    }
    fn category(self: *const Self) Category {
        const input = self.inner.scanner.input;
        if (self.value_start >= input.len) return .eof;
        return switch (input[self.value_start]) {
            '{' => .object,
            '[' => .array,
            '"' => .string,
            '-', '0'...'9' => .number,
            't', 'f' => .boolean,
            'n' => .null,
            else => .invalid,
        };
    }
    fn note(self: *Self, err: anyerror, expected: ?[]const u8) void {
        const offset = switch (err) {
            error.WrongType, error.Overflow, error.WithFailed => self.value_start,
            error.UnexpectedEof => self.inner.scanner.input.len,
            else => self.inner.scanner.pos,
        };
        self.diagnostics.record(self.inner.scanner.input, err, offset, expected, self.category());
    }
    fn fail(self: *Self, err: anyerror, expected: ?[]const u8) Error {
        self.note(err, expected);
        return @errorCast(err);
    }
    pub fn raiseError(self: *Self, err: anyerror) Error {
        return self.fail(err, null);
    }
    pub fn finish(self: *Self) Error!void {
        self.start();
        if (self.inner.scanner.pos != self.inner.scanner.input.len) return self.fail(error.TrailingData, null);
    }
    pub fn deserializeBool(self: *Self) Error!bool {
        self.start();
        return self.inner.deserializeBool() catch |err| return self.fail(err, "bool");
    }
    pub fn deserializeInt(self: *Self, comptime T: type) Error!T {
        self.start();
        return self.inner.deserializeInt(T) catch |err| return self.fail(err, @typeName(T));
    }
    pub fn deserializeFloat(self: *Self, comptime T: type) Error!T {
        self.start();
        return self.inner.deserializeFloat(T) catch |err| return self.fail(err, @typeName(T));
    }
    pub fn deserializeString(self: *Self, allocator: Allocator) Error![]const u8 {
        self.start();
        return self.inner.deserializeString(allocator) catch |err| return self.fail(err, "string");
    }
    pub fn deserializeVoid(self: *Self) Error!void {
        self.start();
        return self.inner.deserializeVoid() catch |err| return self.fail(err, "null");
    }
    pub fn deserializeEnum(self: *Self, comptime T: type) Error!T {
        self.start();
        return self.inner.deserializeEnum(T) catch |err| return self.fail(err, @typeName(T));
    }
    pub fn deserializeOptional(self: *Self, comptime T: type, allocator: Allocator) Error!?T {
        self.start();
        const tok = self.inner.scanner.peek() catch |err| return self.fail(err, @typeName(?T));
        if (tok == .null_lit) {
            _ = try self.inner.scanner.next();
            return null;
        }
        return try core.deserialize(T, allocator, self, .{});
    }
    pub fn deserializeStruct(self: *Self, comptime T: type) Error!MapAccess {
        self.start();
        const access = self.inner.deserializeStruct(T) catch |err| return self.fail(err, "object");
        return .{ .inner = access, .owner = self, .path_length = self.diagnostics.used };
    }
    pub fn deserializeSeqAccess(self: *Self) Error!SeqAccess {
        self.start();
        const access = self.inner.deserializeSeqAccess() catch |err| return self.fail(err, "array");
        return .{ .inner = access, .owner = self, .path_length = self.diagnostics.used };
    }
    pub fn deserializeSeq(self: *Self, comptime T: type, allocator: Allocator) Error!T {
        return core.deserialize(T, allocator, self, .{});
    }
    pub fn deserializeUnion(self: *Self, comptime T: type, allocator: Allocator) Error!T {
        self.start();
        const length = self.diagnostics.used;
        defer self.diagnostics.pop(length);
        return self.inner.deserializeUnionContext(T, allocator, self) catch |err| return self.fail(err, @typeName(T));
    }
};

pub const MapAccess = struct {
    inner: base.MapAccess,
    owner: *DeserializerWithDiagnostics,
    path_length: usize,
    key_start: usize = 0,
    pub const Error = base.DeserializeError;
    pub const serde_protocol = struct {
        pub fn borrowedInput(self: *const MapAccess) ?[]const u8 {
            return base.MapAccess.serde_protocol.borrowedInput(&self.inner);
        }
        pub fn missingField(self: *MapAccess, name: []const u8) void {
            self.owner.diagnostics.pop(self.path_length);
            self.owner.diagnostics.push(name);
            const pos = self.inner.scanner.pos;
            self.owner.diagnostics.record(self.inner.scanner.input, error.MissingField, pos -| 1, name, .object);
        }
    };
    pub fn nextKey(self: *MapAccess, allocator: Allocator) Error!?[]const u8 {
        self.owner.diagnostics.pop(self.path_length);
        // Locate the key without consuming anything. Parsing remains in base.MapAccess.
        var cursor = self.inner.scanner.*;
        cursor.skipWhitespace();
        if (!self.inner.at_start and cursor.pos < cursor.input.len and cursor.input[cursor.pos] == ',') {
            cursor.pos += 1;
            cursor.skipWhitespace();
        }
        self.key_start = cursor.pos;
        const key = self.inner.nextKey(allocator) catch |err| return self.owner.fail(err, "object key");
        if (key) |name| self.owner.diagnostics.push(name);
        return key;
    }
    pub fn freeKey(self: *MapAccess, key: []const u8, allocator: Allocator) void {
        self.inner.freeKey(key, allocator);
    }
    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        // The wrapper, not base.nextValue, must receive recursive calls.
        return core.deserialize(T, allocator, self.owner, .{});
    }
    pub fn skipValue(self: *MapAccess) Error!void {
        self.owner.start();
        self.inner.skipValue() catch |err| return self.owner.fail(err, null);
    }
    pub fn raiseError(self: *MapAccess, err: anyerror) Error {
        if (err == error.UnknownField or err == error.DuplicateField)
            self.owner.diagnostics.record(self.inner.scanner.input, err, self.key_start, null, .string);
        return self.owner.raiseError(err);
    }
};

pub const SeqAccess = struct {
    pub const Error = base.DeserializeError;
    inner: base.SeqAccess,
    owner: *DeserializerWithDiagnostics,
    path_length: usize,
    index: usize = 0,
    pub const serde_protocol = struct {
        pub fn borrowedInput(self: *const SeqAccess) ?[]const u8 {
            return base.SeqAccess.serde_protocol.borrowedInput(&self.inner);
        }
        pub fn sizeHint(_: *const SeqAccess) ?usize {
            return null;
        }
    };
    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) base.DeserializeError!?T {
        self.owner.diagnostics.pop(self.path_length);
        const scanner = self.inner.scanner;
        if (self.inner.at_start) {
            self.inner.at_start = false;
            const empty = scanner.isContainerEmpty(']') catch |err| return self.owner.fail(err, "array");
            if (empty) {
                _ = try scanner.next();
                return null;
            }
        } else {
            const step = scanner.finishContainer(']') catch |err| return self.owner.fail(err, "array");
            if (step == .end) return null;
        }
        var digits: [20]u8 = undefined;
        self.owner.diagnostics.push(std.fmt.bufPrint(&digits, "{d}", .{self.index}) catch unreachable);
        const value = try core.deserialize(T, allocator, self.owner, .{});
        self.index += 1;
        return value;
    }
};
