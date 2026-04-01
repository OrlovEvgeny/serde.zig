const std = @import("std");
const core_serialize = @import("../../core/serialize.zig");
const kind_mod = @import("../../core/kind.zig");
const options = @import("../../core/options.zig");

pub const SerializeError = error{ OutOfMemory, WriteFailed };

pub const Options = struct {
    indent: u8 = 2,
    explicit_start: bool = false,
    explicit_end: bool = false,
    null_repr: NullRepr = .null_word,

    pub const NullRepr = enum { null_word, tilde, empty };
};

pub const Serializer = struct {
    out: *std.io.Writer,
    depth: u32,
    indent_size: u8,
    is_map_value: bool,
    opts: Options,

    pub const Error = SerializeError;

    pub fn init(out: *std.io.Writer) Serializer {
        return initWith(out, .{});
    }

    pub fn initWith(out: *std.io.Writer, opts: Options) Serializer {
        return .{ .out = out, .depth = 0, .indent_size = opts.indent, .is_map_value = false, .opts = opts };
    }

    pub fn serializeBool(self: *Serializer, value: bool) Error!void {
        self.out.writeAll(if (value) "true" else "false") catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *Serializer, value: anytype) Error!void {
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeFloat(self: *Serializer, value: anytype) Error!void {
        if (std.math.isNan(value)) {
            self.out.writeAll(".nan") catch return error.WriteFailed;
            return;
        }
        if (std.math.isInf(value)) {
            if (value < 0) {
                self.out.writeAll("-.inf") catch return error.WriteFailed;
            } else {
                self.out.writeAll(".inf") catch return error.WriteFailed;
            }
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        if (value.len == 0) {
            self.out.writeAll("''") catch return error.WriteFailed;
            return;
        }
        if (needsQuoting(value)) {
            writeDoubleQuoted(self.out, value) catch return error.WriteFailed;
            return;
        }
        self.out.writeAll(value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *Serializer) Error!void {
        self.out.writeAll(nullReprString(self.opts.null_repr)) catch return error.WriteFailed;
    }

    pub fn serializeVoid(self: *Serializer) Error!void {
        self.out.writeAll(nullReprString(self.opts.null_repr)) catch return error.WriteFailed;
    }

    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        return .{
            .out = self.out,
            .depth = self.depth,
            .indent_size = self.indent_size,
            .is_map_value = self.is_map_value,
            .opts = self.opts,
            .first = true,
        };
    }

    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        return .{
            .out = self.out,
            .depth = self.depth,
            .indent_size = self.indent_size,
            .is_map_value = self.is_map_value,
            .opts = self.opts,
            .first = true,
        };
    }
};

pub const StructSerializer = struct {
    out: *std.io.Writer,
    depth: u32,
    indent_size: u8,
    is_map_value: bool,
    opts: Options,
    first: bool,

    pub const Error = SerializeError;

    pub fn serializeField(self: *StructSerializer, comptime key: []const u8, value: anytype) Error!void {
        const T = @TypeOf(value);
        const k = comptime kind_mod.typeKind(T);

        if (k == .optional) {
            if (value == null) {
                return self.serializeFieldInner(key, @as(void, {}), .void);
            }
            return self.serializeFieldInner(key, value.?, comptime kind_mod.typeKind(kind_mod.Child(T)));
        }

        return self.serializeFieldInner(key, value, k);
    }

    fn serializeFieldInner(self: *StructSerializer, comptime key: []const u8, value: anytype, comptime k: kind_mod.Kind) Error!void {
        if (self.first and self.is_map_value) {
            // First field after a "key:\n" — parent already wrote the newline,
            // just write indentation.
            self.first = false;
            writeIndent(self.out, self.depth, self.indent_size) catch return error.WriteFailed;
        } else {
            if (!self.first) {
                self.out.writeByte('\n') catch return error.WriteFailed;
            }
            self.first = false;
            writeIndent(self.out, self.depth, self.indent_size) catch return error.WriteFailed;
        }

        writeYamlKey(self.out, key) catch return error.WriteFailed;
        self.out.writeAll(": ") catch return error.WriteFailed;

        // Compound types start on the next line. Unions with payloads are treated
        // as compound because external tagging serializes them as a mapping.
        if (k == .@"struct" or k == .map or (k == .@"union" and comptime unionHasPayload(@TypeOf(value)))) {
            self.out.writeByte('\n') catch return error.WriteFailed;
            var child = Serializer{
                .out = self.out,
                .depth = self.depth + 1,
                .indent_size = self.indent_size,
                .is_map_value = true,
                .opts = self.opts,
            };
            core_serialize.serialize(@TypeOf(value), value, &child, .{}) catch return error.WriteFailed;
            return;
        }

        if (k == .slice or k == .array) {
            self.out.writeByte('\n') catch return error.WriteFailed;
            var child = Serializer{
                .out = self.out,
                .depth = self.depth + 1,
                .indent_size = self.indent_size,
                .is_map_value = false,
                .opts = self.opts,
            };
            core_serialize.serialize(@TypeOf(value), value, &child, .{}) catch return error.WriteFailed;
            return;
        }

        // Scalar: write inline.
        var child = Serializer{
            .out = self.out,
            .depth = self.depth + 1,
            .indent_size = self.indent_size,
            .is_map_value = false,
            .opts = self.opts,
        };
        core_serialize.serialize(@TypeOf(value), value, &child, .{}) catch return error.WriteFailed;
    }

    pub fn serializeEntry(self: *StructSerializer, key: anytype, value: anytype) Error!void {
        const V = @TypeOf(value);
        const k = comptime kind_mod.typeKind(V);

        if (self.first and self.is_map_value) {
            self.first = false;
            writeIndent(self.out, self.depth, self.indent_size) catch return error.WriteFailed;
        } else {
            if (!self.first) {
                self.out.writeByte('\n') catch return error.WriteFailed;
            }
            self.first = false;
            writeIndent(self.out, self.depth, self.indent_size) catch return error.WriteFailed;
        }

        const K = @TypeOf(key);
        if (K == []const u8) {
            writeYamlKey(self.out, key) catch return error.WriteFailed;
        } else if (comptime @typeInfo(K) == .int) {
            self.out.print("{d}", .{key}) catch return error.WriteFailed;
        } else {
            @compileError("unsupported map key type for YAML: " ++ @typeName(K));
        }
        self.out.writeAll(": ") catch return error.WriteFailed;

        if (k == .@"struct" or k == .map or (k == .@"union" and comptime unionHasPayload(V))) {
            self.out.writeByte('\n') catch return error.WriteFailed;
            var child = Serializer{
                .out = self.out,
                .depth = self.depth + 1,
                .indent_size = self.indent_size,
                .is_map_value = true,
                .opts = self.opts,
            };
            core_serialize.serialize(V, value, &child, .{}) catch return error.WriteFailed;
            return;
        }

        if (k == .slice or k == .array) {
            self.out.writeByte('\n') catch return error.WriteFailed;
            var child = Serializer{
                .out = self.out,
                .depth = self.depth + 1,
                .indent_size = self.indent_size,
                .is_map_value = false,
                .opts = self.opts,
            };
            core_serialize.serialize(V, value, &child, .{}) catch return error.WriteFailed;
            return;
        }

        var child = Serializer{
            .out = self.out,
            .depth = self.depth + 1,
            .indent_size = self.indent_size,
            .is_map_value = false,
            .opts = self.opts,
        };
        core_serialize.serialize(V, value, &child, .{}) catch return error.WriteFailed;
    }

    pub fn end(self: *StructSerializer) Error!void {
        _ = self;
    }
};

pub const ArraySerializer = struct {
    out: *std.io.Writer,
    depth: u32,
    indent_size: u8,
    is_map_value: bool,
    opts: Options,
    first: bool,

    pub const Error = SerializeError;

    pub fn serializeBool(self: *ArraySerializer, value: bool) Error!void {
        try self.writePrefix();
        self.out.writeAll(if (value) "true" else "false") catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *ArraySerializer, value: anytype) Error!void {
        try self.writePrefix();
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeFloat(self: *ArraySerializer, value: anytype) Error!void {
        try self.writePrefix();
        if (std.math.isNan(value)) {
            self.out.writeAll(".nan") catch return error.WriteFailed;
            return;
        }
        if (std.math.isInf(value)) {
            if (value < 0) {
                self.out.writeAll("-.inf") catch return error.WriteFailed;
            } else {
                self.out.writeAll(".inf") catch return error.WriteFailed;
            }
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeString(self: *ArraySerializer, value: []const u8) Error!void {
        try self.writePrefix();
        if (value.len == 0) {
            self.out.writeAll("''") catch return error.WriteFailed;
            return;
        }
        if (needsQuoting(value)) {
            writeDoubleQuoted(self.out, value) catch return error.WriteFailed;
            return;
        }
        self.out.writeAll(value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *ArraySerializer) Error!void {
        try self.writePrefix();
        self.out.writeAll(nullReprString(self.opts.null_repr)) catch return error.WriteFailed;
    }

    pub fn serializeVoid(self: *ArraySerializer) Error!void {
        try self.writePrefix();
        self.out.writeAll(nullReprString(self.opts.null_repr)) catch return error.WriteFailed;
    }

    pub fn beginStruct(self: *ArraySerializer) Error!StructSerializer {
        try self.writePrefix();
        return .{
            .out = self.out,
            .depth = self.depth,
            .indent_size = self.indent_size,
            .is_map_value = true,
            .opts = self.opts,
            .first = true,
        };
    }

    pub fn beginArray(self: *ArraySerializer) Error!ArraySerializer {
        try self.writePrefix();
        return .{
            .out = self.out,
            .depth = self.depth + 1,
            .indent_size = self.indent_size,
            .is_map_value = false,
            .opts = self.opts,
            .first = true,
        };
    }

    pub fn end(self: *ArraySerializer) Error!void {
        _ = self;
    }

    fn writePrefix(self: *ArraySerializer) Error!void {
        if (!self.first) {
            self.out.writeByte('\n') catch return error.WriteFailed;
        }
        self.first = false;
        writeIndent(self.out, self.depth, self.indent_size) catch return error.WriteFailed;
        self.out.writeAll("- ") catch return error.WriteFailed;
    }
};

fn nullReprString(repr: Options.NullRepr) []const u8 {
    return switch (repr) {
        .null_word => "null",
        .tilde => "~",
        .empty => "",
    };
}

fn unionHasPayload(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"union") return false;
    for (info.@"union".fields) |field| {
        if (field.type != void) return true;
    }
    return false;
}

fn needsQuoting(value: []const u8) bool {
    // YAML keywords.
    if (looksLikeYamlKeyword(value)) return true;

    for (value) |c| {
        switch (c) {
            ':', '#', '{', '}', '[', ']', ',', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`', '\n', '\r', '\t' => return true,
            else => {},
        }
    }

    // Leading/trailing whitespace.
    if (value[0] == ' ' or value[value.len - 1] == ' ') return true;

    return false;
}

fn looksLikeYamlKeyword(value: []const u8) bool {
    const keywords = [_][]const u8{
        "true",  "True",  "TRUE",
        "false", "False", "FALSE",
        "null",  "Null",  "NULL",
        "~",     "yes",   "Yes",
        "YES",   "no",    "No",
        "NO",    "on",    "On",
        "ON",    "off",   "Off",
        "OFF",   ".inf",  ".Inf",
        ".INF",  "-.inf", "-.Inf",
        "-.INF", ".nan",  ".NaN",
        ".NAN",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, value, kw)) return true;
    }

    // Looks like a number.
    if (looksLikeNumber(value)) return true;

    return false;
}

fn looksLikeNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    var start: usize = 0;
    if (value[0] == '+' or value[0] == '-') start = 1;
    if (start >= value.len) return false;
    if (value[start] < '0' or value[start] > '9') return false;
    // Has at least one digit — could be parsed as a number.
    return true;
}

fn writeDoubleQuoted(out: *std.io.Writer, value: []const u8) std.io.Writer.Error!void {
    try out.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try out.writeAll("\\x");
                const hex = "0123456789abcdef";
                try out.writeByte(hex[c >> 4]);
                try out.writeByte(hex[c & 0x0f]);
            },
            else => try out.writeByte(c),
        }
    }
    try out.writeByte('"');
}

fn writeYamlKey(out: *std.io.Writer, key: []const u8) std.io.Writer.Error!void {
    if (needsQuoting(key)) {
        try writeDoubleQuoted(out, key);
    } else {
        try out.writeAll(key);
    }
}

fn writeIndent(out: *std.io.Writer, depth: u32, indent_size: u8) std.io.Writer.Error!void {
    const total = depth * indent_size;
    for (0..total) |_| {
        try out.writeByte(' ');
    }
}

const testing = std.testing;

fn serializeToString(value: anytype) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer);
    try core_serialize.serialize(@TypeOf(value), value, &ser, .{});
    return aw.toOwnedSlice();
}

test "serialize bool" {
    const t = try serializeToString(true);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("true", t);

    const f = try serializeToString(false);
    defer testing.allocator.free(f);
    try testing.expectEqualStrings("false", f);
}

test "serialize int" {
    const s = try serializeToString(@as(i32, -42));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-42", s);
}

test "serialize float" {
    const s = try serializeToString(@as(f64, 3.14));
    defer testing.allocator.free(s);
    try testing.expect(s.len > 0);
}

test "serialize float specials" {
    const nan = try serializeToString(std.math.nan(f64));
    defer testing.allocator.free(nan);
    try testing.expectEqualStrings(".nan", nan);

    const inf = try serializeToString(std.math.inf(f64));
    defer testing.allocator.free(inf);
    try testing.expectEqualStrings(".inf", inf);

    const ninf = try serializeToString(-std.math.inf(f64));
    defer testing.allocator.free(ninf);
    try testing.expectEqualStrings("-.inf", ninf);
}

test "serialize string plain" {
    const s = try serializeToString(@as([]const u8, "hello"));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "serialize string needs quoting" {
    const s = try serializeToString(@as([]const u8, "true"));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"true\"", s);
}

test "serialize string with special chars" {
    const s = try serializeToString(@as([]const u8, "hello: world"));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"hello: world\"", s);
}

test "serialize empty string" {
    const s = try serializeToString(@as([]const u8, ""));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("''", s);
}

test "serialize null" {
    const val: ?i32 = null;
    const s = try serializeToString(val);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("null", s);
}

test "serialize flat struct" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("x: 1\ny: 2", s);
}

test "serialize slice" {
    const data: []const i32 = &.{ 1, 2, 3 };
    const s = try serializeToString(data);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("- 1\n- 2\n- 3", s);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const s = try serializeToString(Color.green);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("green", s);
}

test "serialize struct with skip" {
    const Secret = struct {
        name: []const u8,
        token: []const u8,

        pub const serde = .{
            .skip = .{
                .token = options.SkipMode.always,
            },
        };
    };
    const s = try serializeToString(Secret{ .name = "test", .token = "secret" });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "name: test") != null);
    try testing.expect(std.mem.indexOf(u8, s, "token") == null);
    try testing.expect(std.mem.indexOf(u8, s, "secret") == null);
}
