const std = @import("std");
const core_serialize = @import("../../core/serialize.zig");
const xml_writer = @import("writer.zig");
const options = @import("../../core/options.zig");
const kind_mod = @import("../../core/kind.zig");

pub const Options = struct {
    pretty: bool = false,
    indent: u8 = 2,
    xml_declaration: bool = true,
    self_close_empty: bool = true,
};

pub const SerializeError = error{ OutOfMemory, WriteFailed };

pub const Serializer = struct {
    out: *std.Io.Writer,
    depth: u32 = 0,
    options: Options,

    pub const Error = SerializeError;

    pub fn init(out: *std.Io.Writer, opts: Options) Serializer {
        return .{ .out = out, .options = opts };
    }

    pub fn serializeBool(self: *Serializer, value: bool) Error!void {
        self.out.writeAll(if (value) "true" else "false") catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *Serializer, value: anytype) Error!void {
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeFloat(self: *Serializer, value: anytype) Error!void {
        if (std.math.isNan(value) or std.math.isInf(value)) {
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        xml_writer.writeXmlEscaped(self.out, value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *Serializer) Error!void {
        _ = self;
    }

    pub fn serializeVoid(self: *Serializer) Error!void {
        _ = self;
    }

    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        return .{ .parent = self };
    }

    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        return .{ .parent = self };
    }

    fn writeIndent(self: *Serializer) Error!void {
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
        const T = @TypeOf(value);
        const k = comptime kind_mod.typeKind(T);

        // Void/null: self-closing element.
        if (k == .void) {
            if (self.parent.options.self_close_empty) {
                try self.parent.writeIndent();
                self.parent.out.writeAll("<" ++ key ++ "/>") catch return error.WriteFailed;
            }
            return;
        }
        if (k == .optional) {
            if (value == null) {
                if (self.parent.options.self_close_empty) {
                    try self.parent.writeIndent();
                    self.parent.out.writeAll("<" ++ key ++ "/>") catch return error.WriteFailed;
                }
                return;
            }
            // Unwrap and serialize the inner value.
            try self.parent.writeIndent();
            self.parent.out.writeAll("<" ++ key ++ ">") catch return error.WriteFailed;
            try core_serialize.serialize(@typeInfo(T).optional.child, value.?, self.parent, .{});
            self.parent.out.writeAll("</" ++ key ++ ">") catch return error.WriteFailed;
            return;
        }

        // Struct and union: nested element with children.
        if (k == .@"struct" or k == .@"union") {
            try self.parent.writeIndent();
            self.parent.out.writeAll("<" ++ key ++ ">") catch return error.WriteFailed;
            self.parent.depth += 1;
            try core_serialize.serialize(T, value, self.parent, .{});
            self.parent.depth -= 1;
            try self.parent.writeIndent();
            self.parent.out.writeAll("</" ++ key ++ ">") catch return error.WriteFailed;
            return;
        }

        // Slice/array: repeated elements.
        if (k == .slice or k == .array) {
            try self.parent.writeIndent();
            self.parent.out.writeAll("<" ++ key ++ ">") catch return error.WriteFailed;
            self.parent.depth += 1;
            const Child = switch (k) {
                .slice => @typeInfo(T).pointer.child,
                .array => @typeInfo(T).array.child,
                else => unreachable,
            };
            const child_kind = comptime kind_mod.typeKind(Child);
            for (value) |elem| {
                if (child_kind == .@"struct") {
                    try self.parent.writeIndent();
                    self.parent.out.writeAll("<item>") catch return error.WriteFailed;
                    self.parent.depth += 1;
                    try core_serialize.serialize(Child, elem, self.parent, .{});
                    self.parent.depth -= 1;
                    try self.parent.writeIndent();
                    self.parent.out.writeAll("</item>") catch return error.WriteFailed;
                } else {
                    try self.parent.writeIndent();
                    self.parent.out.writeAll("<item>") catch return error.WriteFailed;
                    try core_serialize.serialize(Child, elem, self.parent, .{});
                    self.parent.out.writeAll("</item>") catch return error.WriteFailed;
                }
            }
            self.parent.depth -= 1;
            try self.parent.writeIndent();
            self.parent.out.writeAll("</" ++ key ++ ">") catch return error.WriteFailed;
            return;
        }

        // Scalar: <key>value</key>.
        try self.parent.writeIndent();
        self.parent.out.writeAll("<" ++ key ++ ">") catch return error.WriteFailed;
        try core_serialize.serialize(T, value, self.parent, .{});
        self.parent.out.writeAll("</" ++ key ++ ">") catch return error.WriteFailed;
    }

    pub fn serializeEntry(self: *StructSerializer, key: anytype, value: anytype) Error!void {
        const T = @TypeOf(value);
        const K = @TypeOf(key);
        // Runtime key: write <key>value</key> where key is a runtime string.
        const key_str: []const u8 = if (K == []const u8) key else @compileError("XML map keys must be strings");

        try self.parent.writeIndent();
        self.parent.out.writeByte('<') catch return error.WriteFailed;
        self.parent.out.writeAll(key_str) catch return error.WriteFailed;
        self.parent.out.writeByte('>') catch return error.WriteFailed;
        try core_serialize.serialize(T, value, self.parent, .{});
        self.parent.out.writeAll("</") catch return error.WriteFailed;
        self.parent.out.writeAll(key_str) catch return error.WriteFailed;
        self.parent.out.writeByte('>') catch return error.WriteFailed;
    }

    pub fn end(self: *StructSerializer) Error!void {
        _ = self;
    }
};

pub const ArraySerializer = struct {
    parent: *Serializer,

    pub const Error = SerializeError;

    pub fn serializeBool(self: *ArraySerializer, value: bool) Error!void {
        try self.writeItemOpen();
        try self.parent.serializeBool(value);
        try self.writeItemClose();
    }

    pub fn serializeInt(self: *ArraySerializer, value: anytype) Error!void {
        try self.writeItemOpen();
        try self.parent.serializeInt(value);
        try self.writeItemClose();
    }

    pub fn serializeFloat(self: *ArraySerializer, value: anytype) Error!void {
        try self.writeItemOpen();
        try self.parent.serializeFloat(value);
        try self.writeItemClose();
    }

    pub fn serializeString(self: *ArraySerializer, value: []const u8) Error!void {
        try self.writeItemOpen();
        try self.parent.serializeString(value);
        try self.writeItemClose();
    }

    pub fn serializeNull(self: *ArraySerializer) Error!void {
        try self.parent.writeIndent();
        self.parent.out.writeAll("<item/>") catch return error.WriteFailed;
    }

    pub fn serializeVoid(self: *ArraySerializer) Error!void {
        try self.parent.writeIndent();
        self.parent.out.writeAll("<item/>") catch return error.WriteFailed;
    }

    pub fn beginStruct(self: *ArraySerializer) Error!StructSerializer {
        try self.parent.writeIndent();
        self.parent.out.writeAll("<item>") catch return error.WriteFailed;
        self.parent.depth += 1;
        return .{ .parent = self.parent };
    }

    pub fn beginArray(self: *ArraySerializer) Error!ArraySerializer {
        return .{ .parent = self.parent };
    }

    pub fn end(self: *ArraySerializer) Error!void {
        _ = self;
    }

    fn writeItemOpen(self: *ArraySerializer) Error!void {
        try self.parent.writeIndent();
        self.parent.out.writeAll("<item>") catch return error.WriteFailed;
    }

    fn writeItemClose(self: *ArraySerializer) Error!void {
        self.parent.out.writeAll("</item>") catch return error.WriteFailed;
    }
};

// Tests.

const testing = std.testing;

fn serializeToString(value: anytype, opts: Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, opts);
    try core_serialize.serialize(@TypeOf(value), value, &ser, .{});
    return aw.toOwnedSlice();
}

test "serialize bool" {
    const t = try serializeToString(true, .{ .xml_declaration = false });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("true", t);
}

test "serialize int" {
    const s = try serializeToString(@as(i32, -42), .{ .xml_declaration = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-42", s);
}

test "serialize string with entities" {
    const s = try serializeToString(@as([]const u8, "a<b&c"), .{ .xml_declaration = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a&lt;b&amp;c", s);
}

test "serialize null" {
    const s = try serializeToString(@as(?i32, null), .{ .xml_declaration = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}

test "serialize struct" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 }, .{ .xml_declaration = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("<x>1</x><y>2</y>", s);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const s = try serializeToString(Color.green, .{ .xml_declaration = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("green", s);
}

test "serialize void" {
    const s = try serializeToString({}, .{ .xml_declaration = false });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}
