const std = @import("std");
const core_serialize = @import("../../core/serialize.zig");
const json_writer = @import("writer.zig");

pub const Options = struct {
    pretty: bool = false,
    indent: u8 = 2,
};

pub const SerializeError = error{ OutOfMemory, WriteFailed };

pub const Serializer = struct {
    out: *std.io.Writer,
    depth: u32 = 0,
    options: Options,

    // Each bit tracks whether a nesting level needs a comma before the next element.
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
            self.out.writeAll("null") catch return error.WriteFailed;
            return;
        }
        if (std.math.isInf(value)) {
            self.out.writeAll("null") catch return error.WriteFailed;
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        json_writer.writeJsonString(self.out, value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *Serializer) Error!void {
        self.out.writeAll("null") catch return error.WriteFailed;
    }

    pub fn serializeVoid(self: *Serializer) Error!void {
        self.out.writeAll("null") catch return error.WriteFailed;
    }

    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        self.out.writeByte('{') catch return error.WriteFailed;
        self.pushLevel();
        return .{ .parent = self };
    }

    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        self.out.writeByte('[') catch return error.WriteFailed;
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
        try self.parent.serializeString(key);
        self.parent.out.writeByte(':') catch return error.WriteFailed;
        if (self.parent.options.pretty) {
            self.parent.out.writeByte(' ') catch return error.WriteFailed;
        }
        try core_serialize.serialize(@TypeOf(value), value, self.parent);
    }

    pub fn serializeEntry(self: *StructSerializer, key: anytype, value: anytype) Error!void {
        try self.parent.writeComma();
        try self.parent.writeIndent();
        try core_serialize.serialize(@TypeOf(key), key, self.parent);
        self.parent.out.writeByte(':') catch return error.WriteFailed;
        if (self.parent.options.pretty) {
            self.parent.out.writeByte(' ') catch return error.WriteFailed;
        }
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
        self.parent.out.writeByte(']') catch return error.WriteFailed;
    }
};

// Tests.

const testing = std.testing;

fn serializeToString(value: anytype, opts: Options) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, opts);
    try core_serialize.serialize(@TypeOf(value), value, &ser);
    return aw.toOwnedSlice();
}

test "serialize bool" {
    const t = try serializeToString(true, .{});
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("true", t);

    const f = try serializeToString(false, .{});
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("false", f);
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

test "serialize string with escapes" {
    const s = try serializeToString(@as([]const u8, "he\"llo"), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"he\\\"llo\"", s);
}

test "serialize null" {
    const s = try serializeToString(@as(?i32, null), .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("null", s);
}

test "serialize struct" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"x\":1,\"y\":2}", s);
}

test "serialize array" {
    const s = try serializeToString([3]i32{ 1, 2, 3 }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[1,2,3]", s);
}

test "serialize slice" {
    const data: []const i32 = &.{ 10, 20 };
    const s = try serializeToString(data, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[10,20]", s);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const s = try serializeToString(Color.green, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"green\"", s);
}

test "serialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const s = try serializeToString(Outer{ .name = "test", .inner = .{ .val = 42 } }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"name\":\"test\",\"inner\":{\"val\":42}}", s);
}

test "serialize pretty" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 }, .{ .pretty = true, .indent = 2 });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\n  \"x\": 1,\n  \"y\": 2\n}", s);
}

test "serialize void" {
    const s = try serializeToString({}, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("null", s);
}

test "serialize union with void payload" {
    const Cmd = union(enum) { ping: void, quit: void };
    const s = try serializeToString(Cmd.ping, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"ping\"", s);
}

test "serialize union with payload" {
    const Cmd = union(enum) { set: i32, ping: void };
    const s = try serializeToString(Cmd{ .set = 42 }, .{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("{\"set\":42}", s);
}
