const std = @import("std");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const scanner_mod = @import("scanner.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");
const kind_mod = @import("../../core/kind.zig");
const xml_writer = @import("writer.zig");
const opt = @import("../../core/options.zig");

pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;
pub const Options = serializer_mod.Options;
pub const Scanner = scanner_mod.Scanner;

/// Serialize a value to an XML byte slice. Caller owns the returned memory.
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

/// Serialize with explicit options.
pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    try xmlSerialize(@TypeOf(value), value, &aw.writer, opts, {});
    return aw.toOwnedSlice();
}

/// Serialize a value to a writer in XML format.
pub fn toWriter(writer: *std.io.Writer, value: anytype) !void {
    return toWriterWith(writer, value, .{});
}

/// Serialize with explicit options to a writer.
pub fn toWriterWith(writer: *std.io.Writer, value: anytype, opts: Options) !void {
    try xmlSerialize(@TypeOf(value), value, writer, opts, {});
}

/// Serialize a value to a null-terminated XML byte slice. Caller owns the returned memory.
pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    const bytes = try toSlice(allocator, value);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

/// Serialize with an external schema.
pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    return toSliceWithSchema(allocator, value, .{}, schema);
}

/// Serialize with explicit options and an external schema.
pub fn toSliceWithSchema(allocator: std.mem.Allocator, value: anytype, opts: Options, comptime schema: anytype) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    try xmlSerialize(@TypeOf(value), value, &aw.writer, opts, schema);
    return aw.toOwnedSlice();
}

/// Serialize to a writer with an external schema.
pub fn toWriterSchema(writer: *std.io.Writer, value: anytype, comptime schema: anytype) !void {
    try xmlSerialize(@TypeOf(value), value, writer, .{}, schema);
}

/// Serialize with explicit options to a writer with an external schema.
pub fn toWriterWithSchema(writer: *std.io.Writer, value: anytype, opts: Options, comptime schema: anytype) !void {
    try xmlSerialize(@TypeOf(value), value, writer, opts, schema);
}

/// Deserialize a value of type T from an XML byte slice.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return xmlDeserialize(T, allocator, input, false, {});
}

/// Deserialize with zero-copy string borrowing.
pub fn fromSliceBorrowed(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return xmlDeserialize(T, allocator, input, true, {});
}

/// Deserialize from a reader.
pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *std.io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

/// Deserialize from a file path.
pub fn fromFilePath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    var reader = file.reader().any();
    return fromReader(T, allocator, &reader);
}

/// Deserialize with an external schema.
pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    return xmlDeserialize(T, allocator, input, false, schema);
}

/// Deserialize with zero-copy borrowing and an external schema.
pub fn fromSliceBorrowedSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    return xmlDeserialize(T, allocator, input, true, schema);
}

/// Deserialize from a reader with an external schema.
pub fn fromReaderSchema(comptime T: type, allocator: std.mem.Allocator, reader: *std.io.Reader, comptime schema: anytype) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceSchema(T, allocator, buf, schema);
}

// XML-specific serialization: wraps values in root element, handles attributes.
fn xmlSerialize(
    comptime T: type,
    value: T,
    writer: *std.io.Writer,
    opts: Options,
    comptime schema: anytype,
) !void {
    if (opts.xml_declaration) {
        writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>") catch return error.WriteFailed;
        if (opts.pretty) writer.writeByte('\n') catch return error.WriteFailed;
    }

    const k = comptime kind_mod.typeKind(T);

    if (k == .@"struct") {
        const root_name = comptime resolveRootName(T, schema);
        try writeStructElement(T, value, writer, opts, root_name, schema);
    } else {
        // Non-struct: wrap in a <value> root element.
        writer.writeAll("<value>") catch return error.WriteFailed;
        var ser = serializer_mod.Serializer.init(writer, opts);
        if (@TypeOf(schema) != void) {
            try core_serialize.serializeSchema(T, value, &ser, schema, .{});
        } else {
            try core_serialize.serialize(T, value, &ser, .{});
        }
        writer.writeAll("</value>") catch return error.WriteFailed;
    }
}

fn writeStructElement(
    comptime T: type,
    value: T,
    writer: *std.io.Writer,
    opts: Options,
    comptime root_name: []const u8,
    comptime schema: anytype,
) !void {
    const info = @typeInfo(T).@"struct";

    // Opening tag with attributes.
    writer.writeByte('<') catch return error.WriteFailed;
    writer.writeAll(root_name) catch return error.WriteFailed;

    // Attributes: fields marked with xml_attribute.
    inline for (info.fields) |field| {
        if (comptime opt.shouldSkipFieldSchema(T, field.name, .serialize, schema)) continue;
        if (comptime isXmlAttribute(T, field.name, schema)) {
            writer.writeByte(' ') catch return error.WriteFailed;
            const wire_name = comptime opt.wireFieldNameForDir(T, field.name, schema, .serialize);
            writer.writeAll(wire_name) catch return error.WriteFailed;
            writer.writeByte('=') catch return error.WriteFailed;
            // Write attribute value.
            var buf: [64]u8 = undefined;
            const val_str = fieldToString(field.type, @field(value, field.name), &buf);
            xml_writer.writeXmlAttrEscaped(writer, val_str) catch return error.WriteFailed;
        }
    }

    writer.writeByte('>') catch return error.WriteFailed;

    // Children: non-attribute fields.
    var ser = serializer_mod.Serializer.init(writer, opts);
    if (opts.pretty) ser.depth = 1;
    var ss = try ser.beginStruct();

    inline for (info.fields) |field| {
        if (comptime opt.shouldSkipFieldSchema(T, field.name, .serialize, schema)) continue;
        if (comptime isXmlAttribute(T, field.name, schema)) continue;

        if (comptime opt.isFlattenedFieldSchema(T, field.name, schema)) {
            if (@typeInfo(field.type) != .@"struct")
                @compileError("Flatten requires a struct type, got " ++ @typeName(field.type));
            const nested = @field(value, field.name);
            const nested_info = @typeInfo(field.type).@"struct";
            inline for (nested_info.fields) |sf| {
                const nested_wire = comptime opt.wireFieldNameForDir(field.type, sf.name, {}, .serialize);
                try ss.serializeField(nested_wire, @field(nested, sf.name));
            }
            continue;
        }

        const wire_name = comptime opt.wireFieldNameForDir(T, field.name, schema, .serialize);
        const field_value = @field(value, field.name);

        const skip_null = comptime opt.isSkipIfNullSchema(T, field.name, schema) and @typeInfo(field.type) == .optional;
        const skip_empty = comptime opt.isSkipIfEmptySchema(T, field.name, schema) and @typeInfo(field.type) == .pointer;

        const should_skip = (skip_null and field_value == null) or
            (skip_empty and field_value.len == 0);

        if (!should_skip) {
            if (comptime opt.hasFieldWithSchema(T, field.name, schema)) {
                const WithMod = comptime opt.getFieldWithSchema(T, field.name, schema);
                try ss.serializeField(wire_name, WithMod.serialize(field_value));
            } else {
                try ss.serializeField(wire_name, field_value);
            }
        }
    }

    try ss.end();

    // Closing tag.
    if (opts.pretty) {
        writer.writeByte('\n') catch return error.WriteFailed;
    }
    writer.writeAll("</") catch return error.WriteFailed;
    writer.writeAll(root_name) catch return error.WriteFailed;
    writer.writeByte('>') catch return error.WriteFailed;
}

fn fieldToString(comptime T: type, value: T, buf: *[64]u8) []const u8 {
    const k = comptime kind_mod.typeKind(T);
    return switch (k) {
        .bool => if (value) "true" else "false",
        .int => std.fmt.bufPrint(buf, "{d}", .{value}) catch "0",
        .float => std.fmt.bufPrint(buf, "{d}", .{value}) catch "0",
        .string => value,
        .@"enum" => @tagName(value),
        else => "",
    };
}

fn resolveRootName(comptime T: type, comptime schema: anytype) []const u8 {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "xml_root"))
            return schema.xml_root;
    }
    if (opt.hasSerdeOptions(T)) {
        const serde_opts = T.serde;
        if (@hasField(@TypeOf(serde_opts), "xml_root") or @hasDecl(@TypeOf(serde_opts), "xml_root"))
            return serde_opts.xml_root;
    }
    // Derive from type name: take the last component after the dot.
    const name = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse 0;
    const candidate = if (dot > 0) name[dot + 1 ..] else name;
    // Validate as XML element name (letters, digits, underscore, hyphen; must start with letter/underscore).
    if (candidate.len == 0) return "root";
    if (!isXmlNameStart(candidate[0])) return "root";
    for (candidate[1..]) |c| {
        if (!isXmlNameChar(c)) return "root";
    }
    return candidate;
}

fn isXmlNameStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isXmlNameChar(c: u8) bool {
    return isXmlNameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

fn isXmlAttribute(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "xml_attribute")) {
            const attrs = schema.xml_attribute;
            const attr_fields = @typeInfo(@TypeOf(attrs)).@"struct".fields;
            inline for (attr_fields) |f| {
                const val = @field(attrs, f.name);
                const tag_name = @tagName(val);
                if (std.mem.eql(u8, tag_name, field_name)) return true;
            }
            return false;
        }
    }
    if (!opt.hasSerdeOptions(T)) return false;
    const serde = T.serde;
    const SerdeTy = @TypeOf(serde);
    if (!@hasField(SerdeTy, "xml_attribute") and !@hasDecl(SerdeTy, "xml_attribute")) return false;
    const attrs = serde.xml_attribute;
    const attr_fields = @typeInfo(@TypeOf(attrs)).@"struct".fields;
    inline for (attr_fields) |f| {
        const val = @field(attrs, f.name);
        const tag_name = @tagName(val);
        if (std.mem.eql(u8, tag_name, field_name)) return true;
    }
    return false;
}

// XML-specific deserialization: handles root element, then delegates.
fn xmlDeserialize(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    borrow: bool,
    comptime schema: anytype,
) !T {
    var scanner = scanner_mod.Scanner{ .input = input };

    const k = comptime kind_mod.typeKind(T);

    if (k == .@"struct") {
        // Expect root element.
        const tok = try scanner.next();
        switch (tok) {
            .element_open => {
                // Root element found, scanner is now past the attributes (or in in_tag state).
                // Deserialize the struct fields.
                var deser = deserializer_mod.Deserializer{
                    .scanner = scanner,
                    .borrow_strings = borrow,
                };
                if (@TypeOf(schema) != void) {
                    return core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
                } else {
                    return core_deserialize.deserialize(T, allocator, &deser, .{});
                }
            },
            .self_closing => {
                // Empty root: return struct with defaults.
                return initStructDefaults(T, schema);
            },
            else => return error.MalformedXml,
        }
    } else {
        // Non-struct: expect <value>content</value>.
        const tok = try scanner.next();
        if (tok != .element_open) return error.MalformedXml;
        var deser = deserializer_mod.Deserializer{
            .scanner = scanner,
            .borrow_strings = borrow,
        };
        return core_deserialize.deserialize(T, allocator, &deser, .{});
    }
}

fn initStructDefaults(comptime T: type, comptime schema: anytype) !T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.fields) |field| {
        if (comptime field.defaultValue()) |dv| {
            @field(result, field.name) = dv;
        } else if (comptime opt.hasSerdeDefaultSchema(T, field.name, schema)) {
            @field(result, field.name) = comptime opt.getSerdeDefaultSchema(T, field.name, schema);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return error.MissingField;
        }
    }
    return result;
}

fn readAll(allocator: std.mem.Allocator, reader: *std.io.Reader) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const chunk = buf.addManyAsSlice(allocator, 4096) catch return error.OutOfMemory;
        const n = reader.read(chunk) catch return error.OutOfMemory;
        buf.shrinkRetainingCapacity(buf.items.len - chunk.len + n);
        if (n == 0) break;
    }
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}



const testing = std.testing;

test "serialize simple struct" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSliceWith(testing.allocator, Point{ .x = 1, .y = 2 }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Point><x>1</x><y>2</y></Point>", bytes);
}

test "serialize with xml_root" {
    const User = struct {
        name: []const u8,
        pub const serde = .{ .xml_root = "user" };
    };
    const bytes = try toSliceWith(testing.allocator, User{ .name = "Alice" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<user><name>Alice</name></user>", bytes);
}

test "serialize with xml_attribute" {
    const User = struct {
        id: u64,
        name: []const u8,
        pub const serde = .{ .xml_attribute = .{.id}, .xml_root = "user" };
    };
    const bytes = try toSliceWith(testing.allocator, User{ .id = 42, .name = "Alice" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<user id=\"42\"><name>Alice</name></user>", bytes);
}

test "serialize with xml declaration" {
    const Point = struct { x: i32 };
    const bytes = try toSlice(testing.allocator, Point{ .x = 1 });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
}

test "serialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const bytes = try toSliceWith(testing.allocator, Outer{ .name = "test", .inner = .{ .val = 42 } }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Outer><name>test</name><inner><val>42</val></inner></Outer>", bytes);
}

test "serialize optional null" {
    const Opt = struct { val: ?i32 };
    const bytes = try toSliceWith(testing.allocator, Opt{ .val = null }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Opt><val/></Opt>", bytes);
}

test "serialize optional present" {
    const Opt = struct { val: ?i32 };
    const bytes = try toSliceWith(testing.allocator, Opt{ .val = 42 }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Opt><val>42</val></Opt>", bytes);
}

test "serialize slice" {
    const List = struct { items: []const i32 };
    const bytes = try toSliceWith(testing.allocator, List{ .items = &.{ 1, 2, 3 } }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<List><items><item>1</item><item>2</item><item>3</item></items></List>", bytes);
}

test "serialize string with entities" {
    const Msg = struct { text: []const u8 };
    const bytes = try toSliceWith(testing.allocator, Msg{ .text = "a<b&c" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Msg><text>a&lt;b&amp;c</text></Msg>", bytes);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const Wrapper = struct { color: Color };
    const bytes = try toSliceWith(testing.allocator, Wrapper{ .color = .green }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Wrapper><color>green</color></Wrapper>", bytes);
}

test "serialize bool" {
    const Flags = struct { active: bool };
    const bytes = try toSliceWith(testing.allocator, Flags{ .active = true }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Flags><active>true</active></Flags>", bytes);
}

test "serialize void field" {
    const Cmd = struct { ping: void };
    const bytes = try toSliceWith(testing.allocator, Cmd{ .ping = {} }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Cmd><ping/></Cmd>", bytes);
}

test "deserialize simple struct" {
    const Point = struct { x: i32, y: i32 };
    const point = try fromSlice(Point, testing.allocator, "<Point><x>10</x><y>20</y></Point>");
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize with xml declaration" {
    const Point = struct { x: i32, y: i32 };
    const point = try fromSlice(Point, testing.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Point><x>10</x><y>20</y></Point>");
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize with attributes" {
    const User = struct { id: u64, name: []const u8 };
    const user = try fromSlice(User, testing.allocator, "<user id=\"42\"><name>Alice</name></user>");
    defer testing.allocator.free(user.name);
    try testing.expectEqual(@as(u64, 42), user.id);
    try testing.expectEqualStrings("Alice", user.name);
}

test "deserialize optional null" {
    const Opt = struct { a: i32, b: ?i32 };
    const val = try fromSlice(Opt, testing.allocator, "<Opt><a>5</a></Opt>");
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deserialize optional present" {
    const Opt = struct { a: i32, b: ?i32 };
    const val = try fromSlice(Opt, testing.allocator, "<Opt><a>5</a><b>7</b></Opt>");
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, 7), val.b);
}

test "deserialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Outer, arena.allocator(), "<Outer><name>test</name><inner><val>42</val></inner></Outer>");
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqual(@as(i32, 42), val.inner.val);
}

test "deserialize enum" {
    const Color = enum { red, green, blue };
    const Wrapper = struct { color: Color };
    const val = try fromSlice(Wrapper, testing.allocator, "<Wrapper><color>green</color></Wrapper>");
    try testing.expectEqual(Color.green, val.color);
}

test "deserialize string with entities" {
    const Msg = struct { text: []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Msg, arena.allocator(), "<Msg><text>a&amp;b&lt;c</text></Msg>");
    try testing.expectEqualStrings("a&b<c", val.text);
}

test "deserialize bool" {
    const Flags = struct { active: bool };
    const val = try fromSlice(Flags, testing.allocator, "<Flags><active>true</active></Flags>");
    try testing.expectEqual(true, val.active);
}

test "roundtrip simple struct" {
    const Point = struct { x: i32, y: i32 };
    const original = Point{ .x = 42, .y = -7 };
    const bytes = try toSliceWith(testing.allocator, original, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    const result = try fromSlice(Point, testing.allocator, bytes);
    try testing.expectEqualDeep(original, result);
}

test "roundtrip nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Outer{ .name = "test", .inner = .{ .val = 42 } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", result.name);
    try testing.expectEqual(@as(i32, 42), result.inner.val);
}

test "roundtrip with optional" {
    const Opt = struct { a: i32, b: ?i32 };
    const original = Opt{ .a = 5, .b = 7 };
    const bytes = try toSliceWith(testing.allocator, original, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    const result = try fromSlice(Opt, testing.allocator, bytes);
    try testing.expectEqualDeep(original, result);
}

test "roundtrip with enum" {
    const Color = enum { red, green, blue };
    const Wrapper = struct { color: Color };
    const original = Wrapper{ .color = .green };
    const bytes = try toSliceWith(testing.allocator, original, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    const result = try fromSlice(Wrapper, testing.allocator, bytes);
    try testing.expectEqualDeep(original, result);
}

test "roundtrip with string entities" {
    const Msg = struct { text: []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Msg{ .text = "a<b&c>d" };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(Msg, arena.allocator(), bytes);
    try testing.expectEqualStrings("a<b&c>d", result.text);
}

test "roundtrip with xml_root and xml_attribute" {
    const User = struct {
        id: u64,
        name: []const u8,
        pub const serde = .{ .xml_attribute = .{.id}, .xml_root = "user" };
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = User{ .id = 42, .name = "Alice" };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 42), result.id);
    try testing.expectEqualStrings("Alice", result.name);
}

test "serialize with rename" {
    const Config = struct {
        max_retries: u32,
        pub const serde = .{ .rename_all = opt.NamingConvention.camel_case };
    };
    const bytes = try toSliceWith(testing.allocator, Config{ .max_retries = 3 }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Config><maxRetries>3</maxRetries></Config>", bytes);
}

test "serialize with skip" {
    const Secret = struct {
        name: []const u8,
        token: []const u8,
        pub const serde = .{ .skip = .{ .token = opt.SkipMode.always } };
    };
    const bytes = try toSliceWith(testing.allocator, Secret{ .name = "test", .token = "secret" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Secret><name>test</name></Secret>", bytes);
}

test "deserialize ignores unknown fields" {
    const Point = struct { x: i32 };
    const val = try fromSlice(Point, testing.allocator, "<Point><x>5</x><extra>99</extra></Point>");
    try testing.expectEqual(@as(i32, 5), val.x);
}

test "deserialize with defaults" {
    const Def = struct {
        a: i32,
        b: i32 = 99,
    };
    const val = try fromSlice(Def, testing.allocator, "<Def><a>1</a></Def>");
    try testing.expectEqual(@as(i32, 1), val.a);
    try testing.expectEqual(@as(i32, 99), val.b);
}

test "serialize pretty" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSliceWith(testing.allocator, Point{ .x = 1, .y = 2 }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Point>\n  <x>1</x>\n  <y>2</y>\n</Point>", bytes);
}

test "serialize pretty nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const bytes = try toSliceWith(testing.allocator, Outer{ .name = "test", .inner = .{ .val = 42 } }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Outer>\n  <name>test</name>\n  <inner>\n    <val>42</val>\n  </inner>\n</Outer>", bytes);
}

test "serialize pretty with attributes" {
    const User = struct {
        id: u64,
        name: []const u8,
        pub const serde = .{ .xml_attribute = .{.id}, .xml_root = "user" };
    };
    const bytes = try toSliceWith(testing.allocator, User{ .id = 42, .name = "Alice" }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<user id=\"42\">\n  <name>Alice</name>\n</user>", bytes);
}

test "serialize pretty deeply nested" {
    const C = struct { z: i32 };
    const B = struct { c: C };
    const A = struct { b: B };
    const bytes = try toSliceWith(testing.allocator, A{ .b = .{ .c = .{ .z = 1 } } }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<A>\n  <b>\n    <c>\n      <z>1</z>\n    </c>\n  </b>\n</A>", bytes);
}

test "serialize pretty slice" {
    const List = struct { items: []const i32 };
    const bytes = try toSliceWith(testing.allocator, List{ .items = &.{ 1, 2 } }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<List>\n  <items>\n    <item>1</item>\n    <item>2</item>\n  </items>\n</List>", bytes);
}

test "pretty roundtrip" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Outer{ .name = "test", .inner = .{ .val = 42 } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .pretty = true, .indent = 2 });
    const result = try fromSlice(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", result.name);
    try testing.expectEqual(@as(i32, 42), result.inner.val);
}

test "deserialize slice" {
    const List = struct { items: []const i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(List, arena.allocator(), "<List><items><item>1</item><item>2</item><item>3</item></items></List>");
    try testing.expectEqual(@as(usize, 3), val.items.len);
    try testing.expectEqual(@as(i32, 1), val.items[0]);
    try testing.expectEqual(@as(i32, 2), val.items[1]);
    try testing.expectEqual(@as(i32, 3), val.items[2]);
}

test "roundtrip slice" {
    const List = struct { items: []const i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = List{ .items = &.{ 10, 20, 30 } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(List, arena.allocator(), bytes);
    try testing.expectEqualDeep(original.items, result.items);
}

test "deserialize string slice" {
    const Tags = struct { tags: []const []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Tags, arena.allocator(), "<Tags><tags><item>a</item><item>b</item></tags></Tags>");
    try testing.expectEqual(@as(usize, 2), val.tags.len);
    try testing.expectEqualStrings("a", val.tags[0]);
    try testing.expectEqualStrings("b", val.tags[1]);
}
