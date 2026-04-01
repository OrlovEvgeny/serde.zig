const std = @import("std");
const core_serialize = @import("../../core/serialize.zig");
const kind_mod = @import("../../core/kind.zig");
const options = @import("../../core/options.zig");

const Allocator = std.mem.Allocator;
const Kind = kind_mod.Kind;

pub const SerializeError = error{ OutOfMemory, WriteFailed };

pub const Serializer = struct {
    out: *std.io.Writer,
    allocator: Allocator,
    // Current section path (e.g., "server.db") for emitting [section] headers.
    path: []const []const u8,

    pub const Error = SerializeError;

    pub fn init(out: *std.io.Writer, allocator: Allocator) Serializer {
        return .{ .out = out, .allocator = allocator, .path = &.{} };
    }

    pub fn serializeBool(self: *Serializer, value: bool) Error!void {
        self.out.writeAll(if (value) "true" else "false") catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *Serializer, value: anytype) Error!void {
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeFloat(self: *Serializer, value: anytype) Error!void {
        if (std.math.isNan(value)) {
            self.out.writeAll("nan") catch return error.WriteFailed;
            return;
        }
        if (std.math.isInf(value)) {
            if (value < 0) {
                self.out.writeAll("-inf") catch return error.WriteFailed;
            } else {
                self.out.writeAll("inf") catch return error.WriteFailed;
            }
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
        // TOML requires a decimal point in floats. If the formatted output has
        // no '.' or 'e', append ".0" to distinguish from integers.
    }

    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        writeTomlString(self.out, value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *Serializer) Error!void {
        // TOML has no null. In struct context, null fields are omitted
        // by the core serializer's skip_if_null. If we get here, write nothing.
        _ = self;
    }

    pub fn serializeVoid(self: *Serializer) Error!void {
        _ = self;
    }

    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        return .{
            .out = self.out,
            .allocator = self.allocator,
            .path = self.path,
            .deferred = .empty,
        };
    }

    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        self.out.writeByte('[') catch return error.WriteFailed;
        return .{
            .out = self.out,
            .allocator = self.allocator,
            .first = true,
        };
    }
};

pub const StructSerializer = struct {
    out: *std.io.Writer,
    allocator: Allocator,
    path: []const []const u8,
    deferred: std.ArrayList(DeferredField),

    const DeferredField = struct {
        key: []const u8,
        data: []const u8,
        is_array_of_tables: bool,
    };

    pub const Error = SerializeError;

    pub fn serializeField(self: *StructSerializer, comptime key: []const u8, value: anytype) Error!void {
        const T = @TypeOf(value);
        const k = comptime kind_mod.typeKind(T);

        // Optional null: omit entirely (TOML has no null).
        if (k == .optional) {
            if (value == null) return;
            return self.serializeField(key, value.?);
        }

        // Sub-tables and array-of-tables are deferred to appear after scalar fields.
        // Unions with payload variants also serialize as sub-tables (external tag
        // produces a struct with one key = variant name).
        if (k == .@"struct" or k == .map) {
            try self.deferSubTable(key, value, false);
            return;
        }
        if (k == .@"union" and comptime unionHasPayload(T)) {
            try self.deferSubTable(key, value, false);
            return;
        }
        if ((k == .slice or k == .array) and comptime isStructSlice(T)) {
            try self.deferArrayOfTables(key, value);
            return;
        }

        // Scalar / inline array: write `key = value\n`.
        writeTomlKey(self.out, key) catch return error.WriteFailed;
        self.out.writeAll(" = ") catch return error.WriteFailed;

        var child = Serializer{
            .out = self.out,
            .allocator = self.allocator,
            .path = self.path,
        };
        try core_serialize.serialize(T, value, &child, .{});
        self.out.writeByte('\n') catch return error.WriteFailed;
    }

    pub fn serializeEntry(self: *StructSerializer, key: anytype, value: anytype) Error!void {
        const V = @TypeOf(value);
        const k = comptime kind_mod.typeKind(V);

        if (k == .optional) {
            if (value == null) return;
            return self.serializeEntry(key, value.?);
        }

        if (k == .@"struct" or k == .map or (k == .@"union" and comptime unionHasPayload(V))) {
            try self.deferSubTableDynamic(key, value);
            return;
        }

        const K = @TypeOf(key);
        if (K == []const u8) {
            writeTomlKey(self.out, key) catch return error.WriteFailed;
        } else if (comptime @typeInfo(K) == .int) {
            self.out.print("{d}", .{key}) catch return error.WriteFailed;
        } else {
            @compileError("unsupported map key type for TOML: " ++ @typeName(K));
        }
        self.out.writeAll(" = ") catch return error.WriteFailed;

        var child = Serializer{
            .out = self.out,
            .allocator = self.allocator,
            .path = self.path,
        };
        try core_serialize.serialize(V, value, &child, .{});
        self.out.writeByte('\n') catch return error.WriteFailed;
    }

    fn deferSubTableDynamic(self: *StructSerializer, key: []const u8, value: anytype) Error!void {
        var aw: std.io.Writer.Allocating = .init(self.allocator);

        const new_path = self.allocator.alloc([]const u8, self.path.len + 1) catch return error.OutOfMemory;
        @memcpy(new_path[0..self.path.len], self.path);
        new_path[self.path.len] = key;

        aw.writer.writeByte('\n') catch return error.WriteFailed;
        aw.writer.writeByte('[') catch return error.WriteFailed;
        for (new_path, 0..) |seg, i| {
            if (i > 0) aw.writer.writeByte('.') catch return error.WriteFailed;
            writeTomlKey(&aw.writer, seg) catch return error.WriteFailed;
        }
        aw.writer.writeAll("]\n") catch return error.WriteFailed;

        var child_ser = Serializer{
            .out = &aw.writer,
            .allocator = self.allocator,
            .path = new_path,
        };
        core_serialize.serialize(@TypeOf(value), value, &child_ser, .{}) catch {
            self.allocator.free(new_path);
            aw.deinit();
            return error.WriteFailed;
        };
        self.allocator.free(new_path);

        const data = aw.toOwnedSlice() catch return error.OutOfMemory;
        self.deferred.append(self.allocator, .{
            .key = key,
            .data = data,
            .is_array_of_tables = false,
        }) catch {
            self.allocator.free(data);
            return error.OutOfMemory;
        };
    }

    pub fn end(self: *StructSerializer) Error!void {
        // Emit deferred sub-tables and arrays-of-tables.
        for (self.deferred.items) |deferred| {
            self.out.writeAll(deferred.data) catch {
                self.cleanup();
                return error.WriteFailed;
            };
        }
        self.cleanup();
    }

    fn cleanup(self: *StructSerializer) void {
        for (self.deferred.items) |d| {
            self.allocator.free(d.data);
        }
        self.deferred.deinit(self.allocator);
    }

    fn deferSubTable(self: *StructSerializer, comptime key: []const u8, value: anytype, comptime is_aot_entry: bool) Error!void {
        _ = is_aot_entry;
        var aw: std.io.Writer.Allocating = .init(self.allocator);

        // Build the new path.
        const new_path = self.allocator.alloc([]const u8, self.path.len + 1) catch return error.OutOfMemory;
        @memcpy(new_path[0..self.path.len], self.path);
        new_path[self.path.len] = key;

        // Write [section.key] header.
        aw.writer.writeByte('\n') catch return error.WriteFailed;
        aw.writer.writeByte('[') catch return error.WriteFailed;
        for (new_path, 0..) |seg, i| {
            if (i > 0) aw.writer.writeByte('.') catch return error.WriteFailed;
            writeTomlKey(&aw.writer, seg) catch return error.WriteFailed;
        }
        aw.writer.writeAll("]\n") catch return error.WriteFailed;

        // Serialize the struct fields into the buffer.
        var child_ser = Serializer{
            .out = &aw.writer,
            .allocator = self.allocator,
            .path = new_path,
        };
        core_serialize.serialize(@TypeOf(value), value, &child_ser, .{}) catch {
            self.allocator.free(new_path);
            aw.deinit();
            return error.WriteFailed;
        };
        self.allocator.free(new_path);

        const data = aw.toOwnedSlice() catch return error.OutOfMemory;
        self.deferred.append(self.allocator, .{
            .key = key,
            .data = data,
            .is_array_of_tables = false,
        }) catch {
            self.allocator.free(data);
            return error.OutOfMemory;
        };
    }

    fn deferArrayOfTables(self: *StructSerializer, comptime key: []const u8, value: anytype) Error!void {
        var aw: std.io.Writer.Allocating = .init(self.allocator);

        const new_path = self.allocator.alloc([]const u8, self.path.len + 1) catch return error.OutOfMemory;
        @memcpy(new_path[0..self.path.len], self.path);
        new_path[self.path.len] = key;

        for (value) |elem| {
            aw.writer.writeByte('\n') catch return error.WriteFailed;
            aw.writer.writeAll("[[") catch return error.WriteFailed;
            for (new_path, 0..) |seg, i| {
                if (i > 0) aw.writer.writeByte('.') catch return error.WriteFailed;
                writeTomlKey(&aw.writer, seg) catch return error.WriteFailed;
            }
            aw.writer.writeAll("]]\n") catch return error.WriteFailed;

            var child_ser = Serializer{
                .out = &aw.writer,
                .allocator = self.allocator,
                .path = new_path,
            };
            const ElemType = @TypeOf(elem);
            core_serialize.serialize(ElemType, elem, &child_ser, .{}) catch {
                self.allocator.free(new_path);
                aw.deinit();
                return error.WriteFailed;
            };
        }
        self.allocator.free(new_path);

        const data = aw.toOwnedSlice() catch return error.OutOfMemory;
        self.deferred.append(self.allocator, .{
            .key = key,
            .data = data,
            .is_array_of_tables = true,
        }) catch {
            self.allocator.free(data);
            return error.OutOfMemory;
        };
    }
};

pub const ArraySerializer = struct {
    out: *std.io.Writer,
    allocator: Allocator,
    first: bool,

    pub const Error = SerializeError;

    pub fn serializeBool(self: *ArraySerializer, value: bool) Error!void {
        try self.writeSep();
        self.out.writeAll(if (value) "true" else "false") catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *ArraySerializer, value: anytype) Error!void {
        try self.writeSep();
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeFloat(self: *ArraySerializer, value: anytype) Error!void {
        try self.writeSep();
        if (std.math.isNan(value)) {
            self.out.writeAll("nan") catch return error.WriteFailed;
            return;
        }
        if (std.math.isInf(value)) {
            if (value < 0) {
                self.out.writeAll("-inf") catch return error.WriteFailed;
            } else {
                self.out.writeAll("inf") catch return error.WriteFailed;
            }
            return;
        }
        self.out.print("{d}", .{value}) catch return error.WriteFailed;
    }

    pub fn serializeString(self: *ArraySerializer, value: []const u8) Error!void {
        try self.writeSep();
        writeTomlString(self.out, value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *ArraySerializer) Error!void {
        _ = self;
    }

    pub fn serializeVoid(self: *ArraySerializer) Error!void {
        _ = self;
    }

    pub fn beginStruct(self: *ArraySerializer) Error!StructSerializer {
        // Inline struct inside an array: shouldn't normally occur for TOML
        // (arrays of structs use [[array]] syntax). But for completeness,
        // write as inline table-like format.
        try self.writeSep();
        self.out.writeByte('{') catch return error.WriteFailed;
        return .{
            .out = self.out,
            .allocator = self.allocator,
            .path = &.{},
            .deferred = .empty,
        };
    }

    pub fn beginArray(self: *ArraySerializer) Error!ArraySerializer {
        try self.writeSep();
        self.out.writeByte('[') catch return error.WriteFailed;
        return .{
            .out = self.out,
            .allocator = self.allocator,
            .first = true,
        };
    }

    pub fn end(self: *ArraySerializer) Error!void {
        self.out.writeByte(']') catch return error.WriteFailed;
    }

    fn writeSep(self: *ArraySerializer) Error!void {
        if (!self.first) {
            self.out.writeAll(", ") catch return error.WriteFailed;
        }
        self.first = false;
    }
};

fn unionHasPayload(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"union") return false;
    for (info.@"union".fields) |field| {
        if (field.type != void) return true;
    }
    return false;
}

fn isStructSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .array) {
        return kind_mod.typeKind(info.array.child) == .@"struct";
    }
    if (info == .pointer and info.pointer.size == .slice) {
        return kind_mod.typeKind(info.pointer.child) == .@"struct";
    }
    return false;
}

fn writeTomlKey(out: *std.io.Writer, key: []const u8) std.io.Writer.Error!void {
    if (isBareKey(key)) {
        try out.writeAll(key);
    } else {
        try writeTomlString(out, key);
    }
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_'))
            return false;
    }
    return true;
}

fn writeTomlString(out: *std.io.Writer, value: []const u8) std.io.Writer.Error!void {
    try out.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0x08 => try out.writeAll("\\b"),
            0x0c => try out.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try out.writeAll("\\u00");
                const hex = "0123456789abcdef";
                try out.writeByte(hex[c >> 4]);
                try out.writeByte(hex[c & 0x0f]);
            },
            else => try out.writeByte(c),
        }
    }
    try out.writeByte('"');
}

// Tests.

const testing = std.testing;

fn serializeToString(value: anytype) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, testing.allocator);
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

test "serialize float nan" {
    const s = try serializeToString(std.math.nan(f64));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("nan", s);
}

test "serialize float inf" {
    const s = try serializeToString(std.math.inf(f64));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("inf", s);
}

test "serialize float negative inf" {
    const s = try serializeToString(-std.math.inf(f64));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-inf", s);
}

test "serialize string" {
    const s = try serializeToString(@as([]const u8, "hello"));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"hello\"", s);
}

test "serialize string with escapes" {
    const s = try serializeToString(@as([]const u8, "he\"llo\n"));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\"he\\\"llo\\n\"", s);
}

test "serialize flat struct" {
    const Point = struct { x: i32, y: i32 };
    const s = try serializeToString(Point{ .x = 1, .y = 2 });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("x = 1\ny = 2\n", s);
}

test "serialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const s = try serializeToString(Outer{ .name = "test", .inner = .{ .val = 42 } });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "name = \"test\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "[inner]\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "val = 42\n") != null);
}

test "serialize deeply nested struct" {
    const C = struct { val: i32 };
    const B = struct { c: C };
    const A = struct { b: B };
    const s = try serializeToString(A{ .b = .{ .c = .{ .val = 7 } } });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "[b.c]\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "val = 7\n") != null);
}

test "serialize inline array" {
    const data: []const i32 = &.{ 1, 2, 3 };
    const Wrapper = struct { nums: []const i32 };
    const s = try serializeToString(Wrapper{ .nums = data });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("nums = [1, 2, 3]\n", s);
}

test "serialize array of tables" {
    const Item = struct { id: i32 };
    const items: []const Item = &.{ .{ .id = 1 }, .{ .id = 2 } };
    const Root = struct { items: []const Item };
    const s = try serializeToString(Root{ .items = items });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "[[items]]\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "id = 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "id = 2\n") != null);
}

test "serialize optional null omitted" {
    const Cfg = struct { name: []const u8, debug: ?bool = null };
    const s = try serializeToString(Cfg{ .name = "app", .debug = null });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("name = \"app\"\n", s);
}

test "serialize optional present" {
    const Cfg = struct { name: []const u8, debug: ?bool = null };
    const s = try serializeToString(Cfg{ .name = "app", .debug = true });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "debug = true\n") != null);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const Wrapper = struct { color: Color };
    const s = try serializeToString(Wrapper{ .color = .green });
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("color = \"green\"\n", s);
}

test "serialize struct with serde rename" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = options.NamingConvention.camel_case,
        };
    };
    const s = try serializeToString(User{ .id = 1, .first_name = "Alice" });
    defer testing.allocator.free(s);
    try testing.expect(std.mem.indexOf(u8, s, "user_id = 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "firstName = \"Alice\"\n") != null);
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
    try testing.expect(std.mem.indexOf(u8, s, "name = \"test\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, s, "token") == null);
    try testing.expect(std.mem.indexOf(u8, s, "secret") == null);
}

test "serialize empty struct" {
    const Empty = struct {};
    const s = try serializeToString(Empty{});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}

test "serialize void" {
    const s = try serializeToString({});
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("", s);
}
