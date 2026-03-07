const std = @import("std");
const core_deserialize = @import("../../core/deserialize.zig");

const Allocator = std.mem.Allocator;

pub const DeserializeError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEof,
    UnknownField,
    MissingField,
    InvalidNumber,
    InvalidEscape,
    WrongType,
    Overflow,
    TrailingData,
};

pub const Deserializer = struct {
    input: []const u8,
    pos: usize = 0,
    borrow_strings: bool = false,

    pub const Error = DeserializeError;

    pub fn init(input: []const u8) Deserializer {
        return .{ .input = input };
    }

    pub fn initBorrowed(input: []const u8) Deserializer {
        return .{ .input = input, .borrow_strings = true };
    }

    pub fn deserializeBool(self: *Deserializer) Error!bool {
        self.skipWhitespace();
        if (self.startsWith("true")) {
            self.pos += 4;
            return true;
        }
        if (self.startsWith("false")) {
            self.pos += 5;
            return false;
        }
        return error.WrongType;
    }

    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        self.skipWhitespace();
        const raw = self.readNumber();
        if (raw.len == 0) return error.WrongType;
        return std.fmt.parseInt(T, raw, 10) catch error.InvalidNumber;
    }

    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        self.skipWhitespace();
        const raw = self.readNumber();
        if (raw.len == 0) return error.WrongType;
        return std.fmt.parseFloat(T, raw) catch error.InvalidNumber;
    }

    pub fn deserializeString(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != '"') return error.WrongType;
        self.pos += 1;
        return self.readStringContent(allocator);
    }

    pub fn deserializeStringBorrowed(self: *Deserializer) Error![]const u8 {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != '"') return error.WrongType;
        self.pos += 1;
        var scan = self.pos;
        while (scan < self.input.len) {
            if (self.input[scan] == '"') break;
            if (self.input[scan] == '\\') return error.InvalidEscape;
            scan += 1;
        }
        if (scan >= self.input.len) return error.UnexpectedEof;
        const raw = self.input[self.pos..scan];
        self.pos = scan + 1;
        return raw;
    }

    pub fn deserializeVoid(self: *Deserializer) Error!void {
        self.skipWhitespace();
        if (self.startsWith("null")) {
            self.pos += 4;
            return;
        }
        // ZON also uses {} for void.
        if (self.startsWith("{}")) {
            self.pos += 2;
            return;
        }
        return error.WrongType;
    }

    pub fn deserializeOptional(self: *Deserializer, comptime T: type, allocator: Allocator) Error!?T {
        self.skipWhitespace();
        if (self.startsWith("null")) {
            self.pos += 4;
            return null;
        }
        return try core_deserialize.deserialize(T, allocator, self);
    }

    pub fn deserializeEnum(self: *Deserializer, comptime T: type) Error!T {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        // ZON enums are .variant_name, but our serializer emits "string".
        // Support both forms.
        if (self.input[self.pos] == '.') {
            self.pos += 1;
            const name = self.readIdentifier();
            if (name.len == 0) return error.UnexpectedToken;
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (std.mem.eql(u8, name, field.name))
                    return @enumFromInt(field.value);
            }
            return error.UnexpectedToken;
        }

        // Quoted string form.
        if (self.input[self.pos] == '"') {
            self.pos += 1;
            const raw = self.readUntil('"') orelse return error.UnexpectedEof;
            self.pos += 1; // skip closing quote
            inline for (@typeInfo(T).@"enum".fields) |field| {
                if (std.mem.eql(u8, raw, field.name))
                    return @enumFromInt(field.value);
            }
            return error.UnexpectedToken;
        }

        return error.WrongType;
    }

    pub fn deserializeUnion(_: *Deserializer, comptime _: type, _: Allocator) Error!noreturn {
        @compileError("ZON union deserialization is not yet supported");
    }

    /// Parse `.{ .key = value, ... }` as a struct.
    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        self.skipWhitespace();
        if (!self.startsWith(".{")) return error.WrongType;
        self.pos += 2;
        return .{ .parent = self };
    }

    /// Parse `.{ elem, elem, ... }` as a sequence.
    pub fn deserializeSeq(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .slice)
            @compileError("deserializeSeq expects a slice type");
        const Child = info.pointer.child;

        self.skipWhitespace();
        if (!self.startsWith(".{")) return error.WrongType;
        self.pos += 2;

        var items: std.ArrayList(Child) = .empty;
        errdefer items.deinit(allocator);

        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            if (self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            const elem = try core_deserialize.deserialize(Child, allocator, self);
            items.append(allocator, elem) catch return error.OutOfMemory;
            self.skipWhitespace();
            if (self.pos < self.input.len and self.input[self.pos] == ',')
                self.pos += 1;
        }

        return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    pub fn deserializeSeqAccess(self: *Deserializer) Error!SeqAccess {
        self.skipWhitespace();
        if (!self.startsWith(".{")) return error.WrongType;
        self.pos += 2;
        return .{ .parent = self };
    }

    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return errorFromAny(err);
    }

    // Scanning helpers.

    pub fn skipWhitespace(self: *Deserializer) void {
        while (self.pos < self.input.len and isWhitespace(self.input[self.pos]))
            self.pos += 1;
    }

    fn startsWith(self: *Deserializer, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos..][0..prefix.len], prefix);
    }

    fn readNumber(self: *Deserializer) []const u8 {
        const start = self.pos;
        if (self.pos < self.input.len and self.input[self.pos] == '-')
            self.pos += 1;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if ((c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                // Avoid double-consuming leading '-'.
                if ((c == '-' or c == '+') and self.pos > start + 1)
                    if (self.input[self.pos - 1] != 'e' and self.input[self.pos - 1] != 'E') break;
                self.pos += 1;
            } else break;
        }
        return self.input[start..self.pos];
    }

    fn readIdentifier(self: *Deserializer) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_') {
                self.pos += 1;
            } else break;
        }
        return self.input[start..self.pos];
    }

    fn readUntil(self: *Deserializer, delim: u8) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == delim)
                return self.input[start..self.pos];
            if (self.input[self.pos] == '\\') self.pos += 1; // skip escaped char
            self.pos += 1;
        }
        return null;
    }

    fn readStringContent(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        var has_escape = false;
        const start = self.pos;
        var scan = self.pos;
        while (scan < self.input.len) {
            if (self.input[scan] == '"') break;
            if (self.input[scan] == '\\') {
                has_escape = true;
                scan += 2;
            } else {
                scan += 1;
            }
        }
        if (scan >= self.input.len) return error.UnexpectedEof;

        const raw = self.input[start..scan];
        self.pos = scan + 1;

        if (!has_escape) {
            if (self.borrow_strings) return raw;
            const copy = allocator.alloc(u8, raw.len) catch return error.OutOfMemory;
            @memcpy(copy, raw);
            return copy;
        }
        if (self.borrow_strings) return error.InvalidEscape;
        return unescapeZonString(allocator, raw);
    }

    fn skipValue(self: *Deserializer) Error!void {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const c = self.input[self.pos];
        if (c == '"') {
            self.pos += 1;
            while (self.pos < self.input.len and self.input[self.pos] != '"') {
                if (self.input[self.pos] == '\\') self.pos += 1;
                self.pos += 1;
            }
            if (self.pos < self.input.len) self.pos += 1;
        } else if (c == '.' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '{') {
            self.pos += 2;
            var depth: u32 = 1;
            while (self.pos < self.input.len and depth > 0) {
                if (self.input[self.pos] == '{') depth += 1;
                if (self.input[self.pos] == '}') depth -= 1;
                if (self.input[self.pos] == '"') {
                    self.pos += 1;
                    while (self.pos < self.input.len and self.input[self.pos] != '"') {
                        if (self.input[self.pos] == '\\') self.pos += 1;
                        self.pos += 1;
                    }
                }
                self.pos += 1;
            }
        } else {
            // Number, bool, null, .enum — scan until delimiter.
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                if (ch == ',' or ch == '}' or isWhitespace(ch)) break;
                self.pos += 1;
            }
        }
    }
};

pub const MapAccess = struct {
    parent: *Deserializer,

    pub const Error = DeserializeError;

    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        self.parent.skipWhitespace();
        if (self.parent.pos >= self.parent.input.len) return error.UnexpectedEof;
        if (self.parent.input[self.parent.pos] == '}') {
            self.parent.pos += 1;
            return null;
        }
        // Expect .identifier =
        if (self.parent.pos >= self.parent.input.len or self.parent.input[self.parent.pos] != '.')
            return error.UnexpectedToken;
        self.parent.pos += 1;
        const name = self.parent.readIdentifier();
        if (name.len == 0) return error.UnexpectedToken;
        self.parent.skipWhitespace();
        // Consume '='
        if (self.parent.pos >= self.parent.input.len or self.parent.input[self.parent.pos] != '=')
            return error.UnexpectedToken;
        self.parent.pos += 1;
        return name;
    }

    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        const result = try core_deserialize.deserialize(T, allocator, self.parent);
        self.parent.skipWhitespace();
        // Consume trailing comma.
        if (self.parent.pos < self.parent.input.len and self.parent.input[self.parent.pos] == ',')
            self.parent.pos += 1;
        return result;
    }

    pub fn skipValue(self: *MapAccess) Error!void {
        try self.parent.skipValue();
        self.parent.skipWhitespace();
        if (self.parent.pos < self.parent.input.len and self.parent.input[self.parent.pos] == ',')
            self.parent.pos += 1;
    }

    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const SeqAccess = struct {
    parent: *Deserializer,

    pub const Error = DeserializeError;

    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        self.parent.skipWhitespace();
        if (self.parent.pos >= self.parent.input.len) return error.UnexpectedEof;
        if (self.parent.input[self.parent.pos] == '}') {
            self.parent.pos += 1;
            return null;
        }
        const result = try core_deserialize.deserialize(T, allocator, self.parent);
        self.parent.skipWhitespace();
        if (self.parent.pos < self.parent.input.len and self.parent.input[self.parent.pos] == ',')
            self.parent.pos += 1;
        return result;
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

fn errorFromAny(err: anyerror) DeserializeError {
    return switch (err) {
        error.UnknownField => error.UnknownField,
        error.MissingField => error.MissingField,
        error.UnexpectedEof => error.UnexpectedEof,
        error.OutOfMemory => error.OutOfMemory,
        else => error.WrongType,
    };
}

fn unescapeZonString(allocator: Allocator, raw: []const u8) DeserializeError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            i += 1;
            if (i >= raw.len) return error.UnexpectedEof;
            switch (raw[i]) {
                '\\' => out.append(allocator, '\\') catch return error.OutOfMemory,
                '"' => out.append(allocator, '"') catch return error.OutOfMemory,
                'n' => out.append(allocator, '\n') catch return error.OutOfMemory,
                'r' => out.append(allocator, '\r') catch return error.OutOfMemory,
                't' => out.append(allocator, '\t') catch return error.OutOfMemory,
                'x' => {
                    // \xNN hex escape
                    i += 1;
                    if (i + 2 > raw.len) return error.UnexpectedEof;
                    const hi = hexDigit(raw[i]) orelse return error.InvalidEscape;
                    const lo = hexDigit(raw[i + 1]) orelse return error.InvalidEscape;
                    out.append(allocator, hi * 16 + lo) catch return error.OutOfMemory;
                    i += 2;
                    continue;
                },
                else => return error.InvalidEscape,
            }
            i += 1;
        } else {
            out.append(allocator, raw[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// Tests.

const testing = std.testing;

test "deserialize bool" {
    var d = Deserializer.init("true");
    try testing.expectEqual(true, try d.deserializeBool());
    var d2 = Deserializer.init("false");
    try testing.expectEqual(false, try d2.deserializeBool());
}

test "deserialize int" {
    var d = Deserializer.init("42");
    try testing.expectEqual(@as(i32, 42), try d.deserializeInt(i32));
}

test "deserialize negative int" {
    var d = Deserializer.init("-7");
    try testing.expectEqual(@as(i32, -7), try d.deserializeInt(i32));
}

test "deserialize float" {
    var d = Deserializer.init("3.14");
    try testing.expect(@abs(try d.deserializeFloat(f64) - 3.14) < 0.001);
}

test "deserialize string" {
    var d = Deserializer.init("\"hello\"");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "deserialize string with escape" {
    var d = Deserializer.init("\"a\\nb\"");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a\nb", s);
}

test "deserialize string with hex escape" {
    var d = Deserializer.init("\"\\x41\"");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("A", s);
}

test "deserialize null" {
    var d = Deserializer.init("null");
    try d.deserializeVoid();
}

test "deserialize optional null" {
    var d = Deserializer.init("null");
    const val = try d.deserializeOptional(i32, testing.allocator);
    try testing.expectEqual(@as(?i32, null), val);
}

test "deserialize optional present" {
    var d = Deserializer.init("42");
    const val = try d.deserializeOptional(i32, testing.allocator);
    try testing.expectEqual(@as(?i32, 42), val);
}

test "deserialize enum dot syntax" {
    const Color = enum { red, green, blue };
    var d = Deserializer.init(".green");
    try testing.expectEqual(Color.green, try d.deserializeEnum(Color));
}

test "deserialize enum quoted string" {
    const Color = enum { red, green, blue };
    var d = Deserializer.init("\"green\"");
    try testing.expectEqual(Color.green, try d.deserializeEnum(Color));
}

test "deserialize struct" {
    const Point = struct { x: i32, y: i32 };
    var d = Deserializer.init(".{ .x = 1, .y = 2 }");
    const point = try core_deserialize.deserialize(Point, testing.allocator, &d);
    try testing.expectEqual(@as(i32, 1), point.x);
    try testing.expectEqual(@as(i32, 2), point.y);
}

test "deserialize struct compact" {
    const Point = struct { x: i32, y: i32 };
    var d = Deserializer.init(".{.x = 1,.y = 2}");
    const point = try core_deserialize.deserialize(Point, testing.allocator, &d);
    try testing.expectEqual(@as(i32, 1), point.x);
    try testing.expectEqual(@as(i32, 2), point.y);
}

test "deserialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var d = Deserializer.init(".{.name = \"test\",.inner = .{.val = 42}}");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try core_deserialize.deserialize(Outer, arena.allocator(), &d);
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqual(@as(i32, 42), val.inner.val);
}

test "deserialize slice" {
    var d = Deserializer.init(".{1, 2, 3}");
    const arr = try d.deserializeSeq([]const i32, testing.allocator);
    defer testing.allocator.free(arr);
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(i32, 1), arr[0]);
    try testing.expectEqual(@as(i32, 2), arr[1]);
    try testing.expectEqual(@as(i32, 3), arr[2]);
}

test "deserialize empty slice" {
    var d = Deserializer.init(".{}");
    const arr = try d.deserializeSeq([]const i32, testing.allocator);
    defer testing.allocator.free(arr);
    try testing.expectEqual(@as(usize, 0), arr.len);
}

test "deserialize struct with optional missing" {
    const Opt = struct { a: i32, b: ?i32 };
    var d = Deserializer.init(".{.a = 5}");
    const val = try core_deserialize.deserialize(Opt, testing.allocator, &d);
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}
