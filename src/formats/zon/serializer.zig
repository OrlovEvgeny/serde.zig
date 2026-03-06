const std = @import("std");
const core_serialize = @import("../../core/serialize.zig");

pub const Options = struct {
    pretty: bool = true,
    indent: u8 = 4,
};

pub const SerializeError = error{ OutOfMemory, WriteFailed };

pub const Serializer = struct {
    out: *std.io.Writer,
    depth: u32 = 0,
    options: Options,
    needs_comma: u64 = 0,

    pub const Error = SerializeError;

    pub fn init(out: *std.io.Writer, opts: Options) Serializer {
        return .{ .out = out, .options = opts };
    }

    pub fn serializeBool(self: *Serializer, value: bool) Error!void {
        self.out.writeAll(if (value) "true" else "false") catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *Serializer, value: anytype) Error!void {
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeFloat(self: *Serializer, value: anytype) Error!void {
        if (std.math.isNan(value)) {
            self.out.writeAll("std.math.nan(f64)") catch return error.WriteFailed;
            return;
        }
        if (std.math.isPositiveInf(value)) {
            self.out.writeAll("std.math.inf(f64)") catch return error.WriteFailed;
            return;
        }
        if (std.math.isNegativeInf(value)) {
            self.out.writeAll("-std.math.inf(f64)") catch return error.WriteFailed;
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        writeZonString(self.out, value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *Serializer) Error!void {
        self.out.writeAll("null") catch return error.WriteFailed;
    }

    pub fn serializeVoid(self: *Serializer) Error!void {
        self.out.writeAll("null") catch return error.WriteFailed;
    }

    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        self.out.writeAll(".{") catch return error.WriteFailed;
        self.pushLevel();
        return .{ .parent = self };
    }

    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        self.out.writeAll(".{") catch return error.WriteFailed;
        self.pushLevel();
        return .{ .parent = self };
    }

    fn pushLevel(self: *Serializer) void {
        self.depth += 1;
        self.needs_comma &= ~(@as(u64, 1) << @intCast(self.depth));
    }

    fn popLevel(self: *Serializer) void {
        self.depth -= 1;
    }

    fn writeComma(self: *Serializer) Error!void {
        const bit = @as(u64, 1) << @intCast(self.depth);
        if (self.needs_comma & bit != 0) {
            self.out.writeByte(',') catch return error.WriteFailed;
        }
        self.needs_comma |= bit;
    }

    fn writeIndent(self: *Serializer) Error!void {
        if (!self.options.pretty) return;
        self.out.writeByte('\n') catch return error.WriteFailed;
        const spaces = self.depth * self.options.indent;
        for (0..spaces) |_| {
            self.out.writeByte(' ') catch return error.WriteFailed;
        }
    }

    fn writeClosingIndent(self: *Serializer) Error!void {
        if (!self.options.pretty) return;
        self.out.writeByte('\n') catch return error.WriteFailed;
        const spaces = self.depth * self.options.indent;
        for (0..spaces) |_| {
            self.out.writeByte(' ') catch return error.WriteFailed;
        }
    }
};

pub const StructSerializer = struct {
    parent: *Serializer,

    pub const Error = SerializeError;

    pub fn serializeField(self: *StructSerializer, comptime key: []const u8, value: anytype) Error!void {
        try self.parent.writeComma();
        try self.parent.writeIndent();
        // ZON uses .field_name = value syntax.
        self.parent.out.writeByte('.') catch return error.WriteFailed;
        self.parent.out.writeAll(key) catch return error.WriteFailed;
        self.parent.out.writeAll(" = ") catch return error.WriteFailed;
        try core_serialize.serialize(@TypeOf(value), value, self.parent);
    }

    pub fn serializeEntry(self: *StructSerializer, key: anytype, value: anytype) Error!void {
        try self.parent.writeComma();
        try self.parent.writeIndent();
        self.parent.out.writeByte('.') catch return error.WriteFailed;
        try core_serialize.serialize(@TypeOf(key), key, self.parent);
        self.parent.out.writeAll(" = ") catch return error.WriteFailed;
        try core_serialize.serialize(@TypeOf(value), value, self.parent);
    }

    pub fn end(self: *StructSerializer) Error!void {
        self.parent.popLevel();
        try self.parent.writeClosingIndent();
        self.parent.out.writeByte('}') catch return error.WriteFailed;
    }
};

pub const ArraySerializer = struct {
    parent: *Serializer,

    pub const Error = SerializeError;

    pub fn serializeBool(self: *ArraySerializer, value: bool) Error!void {
        try self.writeElement();
        try self.parent.serializeBool(value);
    }
    pub fn serializeInt(self: *ArraySerializer, value: anytype) Error!void {
        try self.writeElement();
        try self.parent.serializeInt(value);
    }
    pub fn serializeFloat(self: *ArraySerializer, value: anytype) Error!void {
        try self.writeElement();
        try self.parent.serializeFloat(value);
    }
    pub fn serializeString(self: *ArraySerializer, value: []const u8) Error!void {
        try self.writeElement();
        try self.parent.serializeString(value);
    }
    pub fn serializeNull(self: *ArraySerializer) Error!void {
        try self.writeElement();
        try self.parent.serializeNull();
    }
    pub fn serializeVoid(self: *ArraySerializer) Error!void {
        try self.writeElement();
        try self.parent.serializeVoid();
    }

    pub fn beginStruct(self: *ArraySerializer) Error!StructSerializer {
        try self.writeElement();
        return self.parent.beginStruct();
    }

    pub fn beginArray(self: *ArraySerializer) Error!ArraySerializer {
        try self.writeElement();
        return self.parent.beginArray();
    }

    fn writeElement(self: *ArraySerializer) Error!void {
        try self.parent.writeComma();
        try self.parent.writeIndent();
    }

    pub fn end(self: *ArraySerializer) Error!void {
        self.parent.popLevel();
        try self.parent.writeClosingIndent();
        self.parent.out.writeByte('}') catch return error.WriteFailed;
    }
};

/// Write a Zig string literal with proper escaping.
fn writeZonString(out: *std.io.Writer, value: []const u8) !void {
    try out.writeByte('"');
    for (value) |c| {
        switch (c) {
            '\\' => try out.writeAll("\\\\"),
            '"' => try out.writeAll("\\\""),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                try out.print("\\x{x:0>2}", .{c});
            },
            else => try out.writeByte(c),
        }
    }
    try out.writeByte('"');
}

// Tests.

const testing = std.testing;

fn serializeToString(value: anytype, opts: Options) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, opts);
    try core_serialize.serialize(@TypeOf(value), value, &ser);
    return aw.toOwnedSlice();
}

test "serialize bool" {
    const t = try serializeToString(true, .{ .pretty = false });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("true", t);
}

test "serialize int" {
    const s = try serializeToString(@as(i32, -42), .{ .pretty = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-42", s);
}

test "serialize string" {
    const s = try serializeToString(@as([]const u8, "hello"), .{ .pretty = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"hello\"", s);
}

test "serialize string with escapes" {
    const s = try serializeToString(@as([]const u8, "a\nb\"c"), .{ .pretty = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"a\\nb\\\"c\"", s);
}

test "serialize null" {
    const s = try serializeToString(@as(?i32, null), .{ .pretty = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("null", s);
}

test "serialize struct compact" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 }, .{ .pretty = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(".{.x = 1,.y = 2}", s);
}

test "serialize struct pretty" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 }, .{ .pretty = true, .indent = 4 });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(".{\n    .x = 1,\n    .y = 2\n}", s);
}

test "serialize array compact" {
    const s = try serializeToString([3]i32{ 1, 2, 3 }, .{ .pretty = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(".{1,2,3}", s);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const s = try serializeToString(Color.green, .{ .pretty = false });
    defer testing.allocator.free(s);
    // Enums serialize as strings in the core layer, so ZON gets "green".
    // The caller would need to handle .green representation at a higher level.
    try testing.expectEqualStrings("\"green\"", s);
}

test "serialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const s = try serializeToString(Outer{ .name = "test", .inner = .{ .val = 42 } }, .{ .pretty = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(".{.name = \"test\",.inner = .{.val = 42}}", s);
}
