const std = @import("std");
const compat = @import("../../compat.zig");
const core_serialize = @import("../../core/serialize.zig");
const scanner_mod = @import("scanner.zig");

const Dialect = scanner_mod.Dialect;

pub const SerializeError = error{ OutOfMemory, WriteFailed };

pub const Serializer = struct {
    out: *compat.Writer,
    dialect: Dialect,
    first_field: bool,

    pub const Error = SerializeError;

    pub fn init(out: *compat.Writer, dialect: Dialect) Serializer {
        return .{ .out = out, .dialect = dialect, .first_field = true };
    }

    pub fn serializeBool(self: *Serializer, value: bool) Error!void {
        try self.writeFieldSep();
        self.out.writeAll(if (value) "true" else "false") catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *Serializer, value: anytype) Error!void {
        try self.writeFieldSep();
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeFloat(self: *Serializer, value: anytype) Error!void {
        try self.writeFieldSep();
        if (std.math.isNan(value)) {
            self.out.writeAll("NaN") catch return error.WriteFailed;
            return;
        }
        if (std.math.isInf(value)) {
            if (value < 0) {
                self.out.writeAll("-Infinity") catch return error.WriteFailed;
            } else {
                self.out.writeAll("Infinity") catch return error.WriteFailed;
            }
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        try self.writeFieldSep();
        if (needsQuoting(value, self.dialect)) {
            try self.writeQuotedString(value);
        } else {
            self.out.writeAll(value) catch return error.WriteFailed;
        }
    }

    pub fn serializeNull(self: *Serializer) Error!void {
        try self.writeFieldSep();
    }

    pub fn serializeVoid(self: *Serializer) Error!void {
        try self.writeFieldSep();
    }

    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        return .{ .parent = self };
    }

    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        return .{ .parent = self };
    }

    /// Write a newline at the end of the current row and reset field tracking.
    pub fn endRow(self: *Serializer) Error!void {
        self.out.writeByte('\n') catch return error.WriteFailed;
        self.first_field = true;
    }

    fn writeFieldSep(self: *Serializer) Error!void {
        if (!self.first_field) {
            self.out.writeByte(self.dialect.delimiter) catch return error.WriteFailed;
        }
        self.first_field = false;
    }

    fn writeQuotedString(self: *Serializer, value: []const u8) Error!void {
        self.out.writeByte(self.dialect.quote) catch return error.WriteFailed;
        for (value) |c| {
            if (c == self.dialect.quote) {
                self.out.writeByte(self.dialect.quote) catch return error.WriteFailed;
                self.out.writeByte(self.dialect.quote) catch return error.WriteFailed;
            } else {
                self.out.writeByte(c) catch return error.WriteFailed;
            }
        }
        self.out.writeByte(self.dialect.quote) catch return error.WriteFailed;
    }
};

pub const StructSerializer = struct {
    parent: *Serializer,

    pub const Error = SerializeError;

    pub fn serializeField(self: *StructSerializer, comptime _: []const u8, value: anytype) Error!void {
        try core_serialize.serialize(@TypeOf(value), value, self.parent, .{});
    }

    pub fn serializeEntry(self: *StructSerializer, _: anytype, value: anytype) Error!void {
        try core_serialize.serialize(@TypeOf(value), value, self.parent, .{});
    }

    pub fn end(_: *StructSerializer) Error!void {
        // Row termination handled by mod.zig after serializing all fields.
    }
};

pub const ArraySerializer = struct {
    parent: *Serializer,

    pub const Error = SerializeError;

    pub fn serializeBool(self: *ArraySerializer, value: bool) Error!void {
        try self.parent.serializeBool(value);
    }

    pub fn serializeInt(self: *ArraySerializer, value: anytype) Error!void {
        try self.parent.serializeInt(value);
    }

    pub fn serializeFloat(self: *ArraySerializer, value: anytype) Error!void {
        try self.parent.serializeFloat(value);
    }

    pub fn serializeString(self: *ArraySerializer, value: []const u8) Error!void {
        try self.parent.serializeString(value);
    }

    pub fn serializeNull(self: *ArraySerializer) Error!void {
        try self.parent.serializeNull();
    }

    pub fn serializeVoid(self: *ArraySerializer) Error!void {
        try self.parent.serializeVoid();
    }

    pub fn beginStruct(self: *ArraySerializer) Error!StructSerializer {
        return self.parent.beginStruct();
    }

    pub fn beginArray(self: *ArraySerializer) Error!ArraySerializer {
        return .{ .parent = self.parent };
    }

    pub fn end(_: *ArraySerializer) Error!void {}
};

fn needsQuoting(value: []const u8, dialect: Dialect) bool {
    for (value) |c| {
        if (c == dialect.delimiter or c == dialect.quote or c == '\n' or c == '\r')
            return true;
    }
    return false;
}

const testing = std.testing;

fn serializeToString(value: anytype, dialect: Dialect) ![]u8 {
    var aw: compat.AllocatingWriter = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, dialect);
    try core_serialize.serialize(@TypeOf(value), value, &ser, .{});
    return aw.toOwnedSlice();
}

test "serialize bool" {
    const s = try serializeToString(true, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("true", s);
}

test "serialize int" {
    const s = try serializeToString(@as(i32, -42), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-42", s);
}

test "serialize float" {
    const s = try serializeToString(@as(f64, 3.14), .{});
    defer testing.allocator.free(s);
    try testing.expect(s.len > 0);
}

test "serialize string no quoting" {
    const s = try serializeToString(@as([]const u8, "hello"), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "serialize string with comma" {
    const s = try serializeToString(@as([]const u8, "hello, world"), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"hello, world\"", s);
}

test "serialize string with quote" {
    const s = try serializeToString(@as([]const u8, "say \"hi\""), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"say \"\"hi\"\"\"", s);
}

test "serialize string with newline" {
    const s = try serializeToString(@as([]const u8, "line1\nline2"), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"line1\nline2\"", s);
}

test "serialize struct as row" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("1,2", s);
}

test "serialize null" {
    const s = try serializeToString(@as(?i32, null), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}
