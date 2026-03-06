const std = @import("std");
const core_deserialize = @import("../../core/deserialize.zig");

const Allocator = std.mem.Allocator;

pub const DeserializeError = error{
    OutOfMemory,
    UnexpectedTag,
    UnexpectedEof,
    UnknownField,
    MissingField,
    Overflow,
    WrongType,
};

pub const Deserializer = struct {
    input: []const u8,
    pos: usize = 0,

    pub const Error = DeserializeError;

    pub fn init(input: []const u8) Deserializer {
        return .{ .input = input };
    }

    pub fn deserializeBool(self: *Deserializer) Error!bool {
        const tag = try self.readByte();
        return switch (tag) {
            0xc2 => false,
            0xc3 => true,
            else => error.WrongType,
        };
    }

    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        const tag = try self.readByte();

        // For unsigned targets, read via u64 to avoid i64 overflow on large values.
        if (@typeInfo(T).int.signedness == .unsigned) {
            const val = try readUintValue(self, tag);
            return std.math.cast(T, val) orelse error.Overflow;
        }

        const val = try readIntValue(self, tag);
        return std.math.cast(T, val) orelse error.Overflow;
    }

    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        const tag = try self.readByte();
        return switch (tag) {
            0xca => {
                const bits = try self.readBE(u32);
                const f: f32 = @bitCast(bits);
                return @floatCast(f);
            },
            0xcb => {
                const bits = try self.readBE(u64);
                const f: f64 = @bitCast(bits);
                return @floatCast(f);
            },
            // Allow integers to be read as float.
            else => {
                const ival = readIntValue(self, tag) catch return error.WrongType;
                return @floatFromInt(ival);
            },
        };
    }

    pub fn deserializeString(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        const tag = try self.readByte();
        const len = try readStrLen(tag, self);
        const raw = try self.readSlice(len);
        const copy = allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(copy, raw);
        return copy;
    }

    pub fn deserializeBytes(self: *Deserializer, allocator: Allocator) Error![]u8 {
        const tag = try self.readByte();
        const len = readBinLen(tag, self) catch return error.WrongType;
        const raw = try self.readSlice(len);
        const copy = allocator.alloc(u8, len) catch return error.OutOfMemory;
        @memcpy(copy, raw);
        return copy;
    }

    pub fn deserializeVoid(self: *Deserializer) Error!void {
        const tag = try self.readByte();
        if (tag != 0xc0) return error.WrongType;
    }

    pub fn deserializeOptional(self: *Deserializer, comptime T: type, allocator: Allocator) Error!?T {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] == 0xc0) {
            self.pos += 1;
            return null;
        }
        return try core_deserialize.deserialize(T, allocator, self);
    }

    pub fn deserializeEnum(self: *Deserializer, comptime T: type) Error!T {
        const tag = try self.readByte();
        const len = readStrLen(tag, self) catch return error.WrongType;
        const raw = try self.readSlice(len);
        inline for (@typeInfo(T).@"enum".fields) |field| {
            if (std.mem.eql(u8, raw, field.name))
                return @enumFromInt(field.value);
        }
        return error.UnexpectedTag;
    }

    pub fn deserializeUnion(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T).@"union";

        // Void variants may be encoded as bare strings.
        if (self.pos < self.input.len) {
            const peek_tag = self.input[self.pos];
            if (isStrTag(peek_tag)) {
                const saved = self.pos;
                self.pos += 1;
                const len = readStrLen(peek_tag, self) catch {
                    self.pos = saved;
                    return error.WrongType;
                };
                const name = self.readSlice(len) catch {
                    self.pos = saved;
                    return error.WrongType;
                };
                inline for (info.fields) |field| {
                    if (field.type == void and std.mem.eql(u8, name, field.name)) {
                        return @unionInit(T, field.name, {});
                    }
                }
                self.pos = saved;
            }
        }

        // External tagging: map(1) { variant_name: payload }
        const map_tag = try self.readByte();
        const map_len = readMapLen(map_tag, self) catch return error.WrongType;
        if (map_len != 1) return error.WrongType;

        const key_tag = try self.readByte();
        const key_len = readStrLen(key_tag, self) catch return error.WrongType;
        const variant_name = try self.readSlice(key_len);

        inline for (info.fields) |field| {
            if (std.mem.eql(u8, variant_name, field.name)) {
                if (field.type == void) {
                    const nil_tag = try self.readByte();
                    if (nil_tag != 0xc0) return error.WrongType;
                    return @unionInit(T, field.name, {});
                } else {
                    const payload = try core_deserialize.deserialize(field.type, allocator, self);
                    return @unionInit(T, field.name, payload);
                }
            }
        }
        return error.UnexpectedTag;
    }

    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        const tag = try self.readByte();
        const len = readMapLen(tag, self) catch return error.WrongType;
        return .{ .parent = self, .remaining = len };
    }

    pub fn deserializeSeq(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .slice)
            @compileError("deserializeSeq expects a slice type");
        const Child = info.pointer.child;

        const tag = try self.readByte();
        const len = readArrayLen(tag, self) catch return error.WrongType;

        var items: std.ArrayList(Child) = .empty;
        errdefer items.deinit(allocator);

        for (0..len) |_| {
            const elem = try core_deserialize.deserialize(Child, allocator, self);
            items.append(allocator, elem) catch return error.OutOfMemory;
        }

        return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    pub fn deserializeSeqAccess(self: *Deserializer) Error!SeqAccess {
        const tag = try self.readByte();
        const len = readArrayLen(tag, self) catch return error.WrongType;
        return .{ .parent = self, .remaining = len };
    }

    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return errorFromAny(err);
    }

    // Raw read helpers.

    fn readByte(self: *Deserializer) Error!u8 {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const b = self.input[self.pos];
        self.pos += 1;
        return b;
    }

    fn readSlice(self: *Deserializer, len: usize) Error![]const u8 {
        if (self.pos + len > self.input.len) return error.UnexpectedEof;
        const s = self.input[self.pos..][0..len];
        self.pos += len;
        return s;
    }

    fn readBE(self: *Deserializer, comptime T: type) Error!T {
        const bytes = try self.readSlice(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
    }

    fn skipValue(self: *Deserializer) Error!void {
        const tag = try self.readByte();
        try skipByTag(self, tag);
    }
};

pub const MapAccess = struct {
    parent: *Deserializer,
    remaining: usize,

    pub const Error = DeserializeError;

    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        if (self.remaining == 0) return null;
        const tag = try self.parent.readByte();
        const len = readStrLen(tag, self.parent) catch return error.WrongType;
        return try self.parent.readSlice(len);
    }

    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        self.remaining -= 1;
        return core_deserialize.deserialize(T, allocator, self.parent);
    }

    pub fn skipValue(self: *MapAccess) Error!void {
        self.remaining -= 1;
        try self.parent.skipValue();
    }

    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const SeqAccess = struct {
    parent: *Deserializer,
    remaining: usize,

    pub const Error = DeserializeError;

    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const val = try core_deserialize.deserialize(T, allocator, self.parent);
        return val;
    }
};

// Tag classification and reading helpers.

fn isStrTag(tag: u8) bool {
    return (tag & 0xe0 == 0xa0) or tag == 0xd9 or tag == 0xda or tag == 0xdb;
}

fn readStrLen(tag: u8, d: *Deserializer) DeserializeError!usize {
    if (tag & 0xe0 == 0xa0) return @as(usize, tag & 0x1f);
    return switch (tag) {
        0xd9 => @as(usize, try d.readByte()),
        0xda => @as(usize, try d.readBE(u16)),
        0xdb => @as(usize, try d.readBE(u32)),
        else => error.WrongType,
    };
}

fn readBinLen(tag: u8, d: *Deserializer) DeserializeError!usize {
    return switch (tag) {
        0xc4 => @as(usize, try d.readByte()),
        0xc5 => @as(usize, try d.readBE(u16)),
        0xc6 => @as(usize, try d.readBE(u32)),
        else => error.WrongType,
    };
}

fn readMapLen(tag: u8, d: *Deserializer) DeserializeError!usize {
    if (tag & 0xf0 == 0x80) return @as(usize, tag & 0x0f);
    return switch (tag) {
        0xde => @as(usize, try d.readBE(u16)),
        0xdf => @as(usize, try d.readBE(u32)),
        else => error.WrongType,
    };
}

fn readArrayLen(tag: u8, d: *Deserializer) DeserializeError!usize {
    if (tag & 0xf0 == 0x90) return @as(usize, tag & 0x0f);
    return switch (tag) {
        0xdc => @as(usize, try d.readBE(u16)),
        0xdd => @as(usize, try d.readBE(u32)),
        else => error.WrongType,
    };
}

// Decode an unsigned integer from a tag byte. Returns u64 to avoid truncation.
fn readUintValue(d: *Deserializer, tag: u8) DeserializeError!u64 {
    if (tag <= 0x7f) return @intCast(tag);

    // Negative fixint -> cannot represent as unsigned
    if (tag >= 0xe0) return error.Overflow;

    return switch (tag) {
        0xcc => @as(u64, try d.readByte()),
        0xcd => @as(u64, try d.readBE(u16)),
        0xce => @as(u64, try d.readBE(u32)),
        0xcf => try d.readBE(u64),
        0xd0 => {
            const v: i8 = @bitCast(try d.readByte());
            return if (v >= 0) @intCast(v) else error.Overflow;
        },
        0xd1 => {
            const v: i16 = @bitCast(try d.readBE(u16));
            return if (v >= 0) @intCast(v) else error.Overflow;
        },
        0xd2 => {
            const v: i32 = @bitCast(try d.readBE(u32));
            return if (v >= 0) @intCast(v) else error.Overflow;
        },
        0xd3 => {
            const v: i64 = @bitCast(try d.readBE(u64));
            return if (v >= 0) @intCast(v) else error.Overflow;
        },
        else => error.WrongType,
    };
}

// Decode a signed integer from a tag byte. Returns i64.
fn readIntValue(d: *Deserializer, tag: u8) DeserializeError!i64 {
    // Positive fixint: 0x00–0x7f
    if (tag <= 0x7f) return @intCast(tag);

    // Negative fixint: 0xe0–0xff -> -32..-1
    if (tag >= 0xe0) return @as(i64, @as(i8, @bitCast(tag)));

    return switch (tag) {
        0xcc => @as(i64, try d.readByte()),
        0xcd => @as(i64, try d.readBE(u16)),
        0xce => @as(i64, try d.readBE(u32)),
        0xcf => blk: {
            const v = try d.readBE(u64);
            break :blk std.math.cast(i64, v) orelse return error.Overflow;
        },
        0xd0 => @as(i64, @as(i8, @bitCast(try d.readByte()))),
        0xd1 => @as(i64, @as(i16, @bitCast(try d.readBE(u16)))),
        0xd2 => @as(i64, @as(i32, @bitCast(try d.readBE(u32)))),
        0xd3 => @as(i64, @bitCast(try d.readBE(u64))),
        else => error.WrongType,
    };
}

// Skip a single msgpack value by tag. Used for unknown struct fields.
fn skipByTag(d: *Deserializer, tag: u8) DeserializeError!void {
    // nil, false, true
    if (tag == 0xc0 or tag == 0xc2 or tag == 0xc3) return;

    // Positive fixint, negative fixint
    if (tag <= 0x7f or tag >= 0xe0) return;

    // Fixed-size numeric types.
    const skip_sizes = [_]struct { t: u8, s: usize }{
        .{ .t = 0xcc, .s = 1 },
        .{ .t = 0xcd, .s = 2 },
        .{ .t = 0xce, .s = 4 },
        .{ .t = 0xcf, .s = 8 },
        .{ .t = 0xd0, .s = 1 },
        .{ .t = 0xd1, .s = 2 },
        .{ .t = 0xd2, .s = 4 },
        .{ .t = 0xd3, .s = 8 },
        .{ .t = 0xca, .s = 4 },
        .{ .t = 0xcb, .s = 8 },
    };
    for (skip_sizes) |entry| {
        if (tag == entry.t) {
            _ = try d.readSlice(entry.s);
            return;
        }
    }

    // Strings.
    if (tag & 0xe0 == 0xa0 or tag == 0xd9 or tag == 0xda or tag == 0xdb) {
        const len = try readStrLen(tag, d);
        _ = try d.readSlice(len);
        return;
    }

    // Binary.
    switch (tag) {
        0xc4 => {
            const len: usize = try d.readByte();
            _ = try d.readSlice(len);
            return;
        },
        0xc5 => {
            const len: usize = try d.readBE(u16);
            _ = try d.readSlice(len);
            return;
        },
        0xc6 => {
            const len: usize = try d.readBE(u32);
            _ = try d.readSlice(len);
            return;
        },
        else => {},
    }

    // Arrays.
    if (tag & 0xf0 == 0x90 or tag == 0xdc or tag == 0xdd) {
        const len = try readArrayLen(tag, d);
        for (0..len) |_| {
            const inner = try d.readByte();
            try skipByTag(d, inner);
        }
        return;
    }

    // Maps.
    if (tag & 0xf0 == 0x80 or tag == 0xde or tag == 0xdf) {
        const len = try readMapLen(tag, d);
        for (0..len) |_| {
            const k = try d.readByte();
            try skipByTag(d, k);
            const v = try d.readByte();
            try skipByTag(d, v);
        }
        return;
    }

    return error.UnexpectedTag;
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

// Tests.

const testing = std.testing;

test "deserialize bool" {
    var d = Deserializer.init(&.{0xc3});
    try testing.expectEqual(true, try d.deserializeBool());

    var d2 = Deserializer.init(&.{0xc2});
    try testing.expectEqual(false, try d2.deserializeBool());
}

test "deserialize positive fixint" {
    var d = Deserializer.init(&.{42});
    try testing.expectEqual(@as(u8, 42), try d.deserializeInt(u8));
}

test "deserialize uint8" {
    var d = Deserializer.init(&.{ 0xcc, 200 });
    try testing.expectEqual(@as(u8, 200), try d.deserializeInt(u8));
}

test "deserialize uint16" {
    var d = Deserializer.init(&.{ 0xcd, 0x12, 0x34 });
    try testing.expectEqual(@as(u16, 0x1234), try d.deserializeInt(u16));
}

test "deserialize uint32" {
    var d = Deserializer.init(&.{ 0xce, 0x12, 0x34, 0x56, 0x78 });
    try testing.expectEqual(@as(u32, 0x12345678), try d.deserializeInt(u32));
}

test "deserialize uint64" {
    var d = Deserializer.init(&.{ 0xcf, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 });
    try testing.expectEqual(@as(u64, 1), try d.deserializeInt(u64));
}

test "deserialize negative fixint" {
    var d = Deserializer.init(&.{0xff});
    try testing.expectEqual(@as(i8, -1), try d.deserializeInt(i8));

    var d2 = Deserializer.init(&.{0xe0});
    try testing.expectEqual(@as(i8, -32), try d2.deserializeInt(i8));
}

test "deserialize int8" {
    var d = Deserializer.init(&.{ 0xd0, @as(u8, @bitCast(@as(i8, -33))) });
    try testing.expectEqual(@as(i8, -33), try d.deserializeInt(i8));
}

test "deserialize int16" {
    const bytes = std.mem.toBytes(std.mem.nativeTo(u16, @bitCast(@as(i16, -200)), .big));
    var d = Deserializer.init(&(.{0xd1} ++ bytes));
    try testing.expectEqual(@as(i16, -200), try d.deserializeInt(i16));
}

test "deserialize float32" {
    const val: f32 = 1.5;
    const bits: u32 = @bitCast(val);
    const bytes = std.mem.toBytes(std.mem.nativeTo(u32, bits, .big));
    var d = Deserializer.init(&(.{0xca} ++ bytes));
    try testing.expect(@abs(try d.deserializeFloat(f32) - 1.5) < 0.001);
}

test "deserialize float64" {
    const val: f64 = 3.14;
    const bits: u64 = @bitCast(val);
    const bytes = std.mem.toBytes(std.mem.nativeTo(u64, bits, .big));
    var d = Deserializer.init(&(.{0xcb} ++ bytes));
    try testing.expect(@abs(try d.deserializeFloat(f64) - 3.14) < 0.001);
}

test "deserialize string" {
    var d = Deserializer.init(&.{ 0xa2, 'h', 'i' });
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hi", s);
}

test "deserialize empty string" {
    var d = Deserializer.init(&.{0xa0});
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}

test "deserialize nil" {
    var d = Deserializer.init(&.{0xc0});
    try d.deserializeVoid();
}

test "deserialize optional null" {
    var d = Deserializer.init(&.{0xc0});
    const val = try d.deserializeOptional(i32, testing.allocator);
    try testing.expectEqual(@as(?i32, null), val);
}

test "deserialize optional present" {
    var d = Deserializer.init(&.{42});
    const val = try d.deserializeOptional(i32, testing.allocator);
    try testing.expectEqual(@as(?i32, 42), val);
}

test "deserialize enum" {
    const Color = enum { red, green, blue };
    var d = Deserializer.init(&(.{0xa0 | 5} ++ "green".*));
    try testing.expectEqual(Color.green, try d.deserializeEnum(Color));
}

test "deserialize bytes bin8" {
    var d = Deserializer.init(&.{ 0xc4, 5, 'h', 'e', 'l', 'l', 'o' });
    const bytes = try d.deserializeBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("hello", bytes);
}

test "deserialize bytes empty" {
    var d = Deserializer.init(&.{ 0xc4, 0 });
    const bytes = try d.deserializeBytes(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), bytes.len);
}

test "deserialize wrong type error" {
    var d = Deserializer.init(&.{0xa2, 'h', 'i'});
    try testing.expectError(error.WrongType, d.deserializeBool());
}

test "deserialize unexpected eof" {
    var d = Deserializer.init(&.{});
    try testing.expectError(error.UnexpectedEof, d.deserializeBool());
}

test "deserialize overflow" {
    var d = Deserializer.init(&.{ 0xcd, 0x01, 0x00 }); // 256 as uint16
    try testing.expectError(error.Overflow, d.deserializeInt(u8));
}
