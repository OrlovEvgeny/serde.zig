const std = @import("std");
const compat = @import("compat");
const scanner_mod = @import("scanner.zig");
const core_deserialize = @import("../../core/deserialize.zig");
const kind_mod = @import("../../core/kind.zig");

const Scanner = scanner_mod.Scanner;
const Field = scanner_mod.Field;
const Dialect = scanner_mod.Dialect;
const Allocator = std.mem.Allocator;
const Kind = kind_mod.Kind;

pub const DeserializeError = error{
    OutOfMemory,
    UnexpectedEof,
    UnexpectedToken,
    UnknownField,
    MissingField,
    InvalidNumber,
    InvalidQuoting,
    WrongType,
    Overflow,
};

pub const Deserializer = struct {
    headers: []const []const u8,
    fields: []const Field,
    col: usize,

    pub const Error = DeserializeError;

    pub fn init(headers: []const []const u8, fields: []const Field) Deserializer {
        return .{ .headers = headers, .fields = fields, .col = 0 };
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

    pub fn deserializeUnion(_: *Deserializer, comptime _: type, _: Allocator) Error!void {
        return error.WrongType;
    }

    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        return .{ .headers = self.headers, .fields = self.fields, .col = 0 };
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
    headers: []const []const u8,
    fields: []const Field,
    col: usize,

    pub const Error = DeserializeError;

    pub fn nextKey(self: *MapAccess, _: Allocator) Error!?[]const u8 {
        if (self.col >= self.headers.len) return null;
        return self.headers[self.col];
    }

    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        const field = if (self.col < self.fields.len)
            self.fields[self.col]
        else
            Field{ .raw = "", .quoted = false };
        self.col += 1;
        return parseField(T, field, allocator);
    }

    pub fn skipValue(self: *MapAccess) Error!void {
        self.col += 1;
    }

    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return errorFromAny(err);
    }
};

fn parseField(comptime T: type, field: Field, allocator: Allocator) DeserializeError!T {
    const raw = field.raw;

    switch (comptime kind_mod.typeKind(T)) {
        .bool => {
            if (eqlIgnoreCase(raw, "true")) return true;
            if (eqlIgnoreCase(raw, "false")) return false;
            if (std.mem.eql(u8, raw, "1")) return true;
            if (std.mem.eql(u8, raw, "0")) return false;
            return error.WrongType;
        },
        .int => {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) return error.InvalidNumber;
            return std.fmt.parseInt(T, trimmed, 10) catch return error.InvalidNumber;
        },
        .float => {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0) return error.InvalidNumber;
            return std.fmt.parseFloat(T, trimmed) catch return error.InvalidNumber;
        },
        .string => {
            if (field.quoted) {
                return scanner_mod.unquoteField(allocator, raw, '"') catch return error.OutOfMemory;
            }
            return allocator.dupe(u8, raw) catch return error.OutOfMemory;
        },
        .optional => {
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (trimmed.len == 0 and !field.quoted) return null;
            const child = kind_mod.Child(T);
            return try parseField(child, field, allocator);
        },
        .@"enum" => {
            const opts = @import("../../core/options.zig");
            const trimmed = std.mem.trim(u8, raw, " \t");
            if (comptime opts.getEnumRepr(T) == .integer) {
                const tag_type = @typeInfo(T).@"enum".tag_type;
                const int_val = std.fmt.parseInt(tag_type, trimmed, 10) catch return error.InvalidNumber;
                return compat.intToEnum(T, int_val) orelse return error.UnexpectedToken;
            }
            inline for (@typeInfo(T).@"enum".fields) |f| {
                if (std.mem.eql(u8, trimmed, f.name))
                    return @enumFromInt(f.value);
            }
            return error.UnexpectedToken;
        },
        else => @compileError("CSV does not support deserializing type: " ++ @typeName(T)),
    }
}

fn eqlIgnoreCase(a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        if (al != bc) return false;
    }
    return true;
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

const testing = std.testing;

test "parse bool field" {
    const f = Field{ .raw = "true", .quoted = false };
    try testing.expectEqual(true, try parseField(bool, f, testing.allocator));
    const f2 = Field{ .raw = "FALSE", .quoted = false };
    try testing.expectEqual(false, try parseField(bool, f2, testing.allocator));
}

test "parse int field" {
    const f = Field{ .raw = "42", .quoted = false };
    try testing.expectEqual(@as(i32, 42), try parseField(i32, f, testing.allocator));
}

test "parse float field" {
    const f = Field{ .raw = "3.14", .quoted = false };
    const val = try parseField(f64, f, testing.allocator);
    try testing.expect(@abs(val - 3.14) < 0.001);
}

test "parse string field" {
    const f = Field{ .raw = "hello", .quoted = false };
    const s = try parseField([]const u8, f, testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "parse optional empty" {
    const f = Field{ .raw = "", .quoted = false };
    const val = try parseField(?i32, f, testing.allocator);
    try testing.expectEqual(@as(?i32, null), val);
}

test "parse optional present" {
    const f = Field{ .raw = "42", .quoted = false };
    const val = try parseField(?i32, f, testing.allocator);
    try testing.expectEqual(@as(?i32, 42), val);
}

test "parse quoted string with doubled quotes" {
    const f = Field{ .raw = "say \"\"hi\"\"", .quoted = true };
    const s = try parseField([]const u8, f, testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("say \"hi\"", s);
}

test "parse enum field" {
    const Color = enum { red, green, blue };
    const f = Field{ .raw = "green", .quoted = false };
    try testing.expectEqual(Color.green, try parseField(Color, f, testing.allocator));
}

test "parse invalid number" {
    const f = Field{ .raw = "abc", .quoted = false };
    try testing.expectError(error.InvalidNumber, parseField(i32, f, testing.allocator));
}
