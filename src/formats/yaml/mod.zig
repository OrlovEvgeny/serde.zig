//! YAML serialization and deserialization.
//!
//! Serialize any Zig type to YAML with `toSlice` / `toWriter`, and
//! deserialize with `fromSlice` / `fromReader`. Supports flow and block
//! styles, multi-line strings, and anchors.

const std = @import("std");
const parser_mod = @import("parser.zig");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");
const kind_mod = @import("../../core/kind.zig");
const options = @import("../../core/options.zig");

pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;
pub const Options = serializer_mod.Options;
pub const Value = parser_mod.Value;
pub const Mapping = parser_mod.Mapping;
pub const parse = parser_mod.parse;

/// Serialize any value to a YAML byte slice. Caller owns the returned memory.
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

/// Serialize any value to a YAML byte slice with options. Caller owns the returned memory.
pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try toWriterWithOptions(&aw.writer, value, opts);
    return aw.toOwnedSlice();
}

/// Serialize a value to a null-terminated YAML byte slice. Caller owns the returned memory.
pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    const bytes = try toSlice(allocator, value);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

/// Serialize a value to a writer in YAML format.
pub fn toWriter(writer: *std.Io.Writer, value: anytype) !void {
    return toWriterWithOptions(writer, value, .{});
}

/// Serialize a value to a writer in YAML format with options.
pub fn toWriterWithOptions(writer: *std.Io.Writer, value: anytype, opts: Options) !void {
    const T = @TypeOf(value);
    if (opts.explicit_start) {
        writer.writeAll("---\n") catch return error.WriteFailed;
    }
    var ser = Serializer.initWith(writer, opts);
    try core_serialize.serialize(T, value, &ser, .{});
    writer.writeByte('\n') catch return error.WriteFailed;
    if (opts.explicit_end) {
        writer.writeAll("...\n") catch return error.WriteFailed;
    }
}

/// Parse YAML input into a dynamic Value tree. Alias for `parse`.
pub fn parseValue(allocator: std.mem.Allocator, input: []const u8) !Value {
    return parser_mod.parse(allocator, input);
}

/// Parse multi-document YAML input into a slice of Value trees.
/// Documents are separated by `---` and optionally terminated by `...`.
pub fn parseAllValues(allocator: std.mem.Allocator, input: []const u8) ![]Value {
    return parser_mod.parseAll(allocator, input);
}

// Schema-aware API.

/// Serialize a value to a YAML byte slice with an external schema.
pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    return toSliceWithSchema(allocator, value, .{}, schema);
}

/// Serialize with options and an external schema.
pub fn toSliceWithSchema(allocator: std.mem.Allocator, value: anytype, opt: Options, comptime schema: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    try toWriterWithSchema(&aw.writer, value, opt, schema);
    return aw.toOwnedSlice();
}

/// Serialize a value to a writer in YAML format with an external schema.
pub fn toWriterSchema(writer: *std.Io.Writer, value: anytype, comptime schema: anytype) !void {
    return toWriterWithSchema(writer, value, .{}, schema);
}

/// Serialize with options to a writer with an external schema.
pub fn toWriterWithSchema(writer: *std.Io.Writer, value: anytype, opt: Options, comptime schema: anytype) !void {
    const T = @TypeOf(value);
    if (opt.explicit_start) {
        writer.writeAll("---\n") catch return error.WriteFailed;
    }
    var ser = Serializer.initWith(writer, opt);
    try core_serialize.serializeSchema(T, value, &ser, schema, .{});
    writer.writeByte('\n') catch return error.WriteFailed;
    if (opt.explicit_end) {
        writer.writeAll("...\n") catch return error.WriteFailed;
    }
}

/// Deserialize a value of type T from a YAML byte slice with an external schema.
pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    const val = try parser_mod.parse(allocator, input);
    var deser = Deserializer.init(&val);
    return core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
}

/// Deserialize from a reader with an external schema.
pub fn fromReaderSchema(comptime T: type, allocator: std.mem.Allocator, reader: *std.Io.Reader, comptime schema: anytype) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceSchema(T, allocator, buf, schema);
}

/// Deserialize a value of type T from a YAML byte slice.
/// Allocates copies of all strings and slices. Use an ArenaAllocator for easy cleanup.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    const val = try parser_mod.parse(allocator, input);

    const k = comptime kind_mod.typeKind(T);

    // Top-level struct: create Deserializer with the mapping.
    if (k == .@"struct") {
        if (val != .mapping) return error.WrongType;
        var deser = Deserializer.init(&val);
        return core_deserialize.deserialize(T, allocator, &deser, .{});
    }

    // Other types: wrap in ValueDeserializer.
    var deser = Deserializer.init(&val);
    return switch (k) {
        .bool => deser.deserializeBool(),
        .int => deser.deserializeInt(T),
        .float => deser.deserializeFloat(T),
        .string => deser.deserializeString(allocator),
        .optional => deser.deserializeOptional(kind_mod.Child(T), allocator),
        .slice => deser.deserializeSeq(T, allocator),
        .@"enum" => deser.deserializeEnum(T),
        .@"union" => deser.deserializeUnion(T, allocator),
        else => @compileError("YAML top-level type not supported: " ++ @typeName(T)),
    };
}

/// Deserialize a value of type T from a reader.
pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *std.Io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

/// Deserialize a value of type T from a file path.
pub fn fromFilePath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content = try file.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);
    return fromSlice(T, allocator, content);
}

fn readAll(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return reader.allocRemaining(allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch return error.ReadFailed;
}

const CoreValue = @import("../../core/value.zig").Value;

/// Convert any Zig value to a format-agnostic dynamic Value.
pub fn toValue(allocator: std.mem.Allocator, value: anytype) !CoreValue {
    return CoreValue.fromAny(@TypeOf(value), value, allocator);
}

/// Convert a dynamic Value back to a typed Zig value.
pub fn fromValue(comptime T: type, allocator: std.mem.Allocator, value: CoreValue) !T {
    return value.toType(T, allocator);
}

const testing = std.testing;

test "roundtrip flat struct" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSlice(testing.allocator, Point{ .x = 10, .y = 20 });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Point, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 10), val.x);
    try testing.expectEqual(@as(i32, 20), val.y);
}

test "roundtrip string" {
    const Cfg = struct { name: []const u8 };
    const bytes = try toSlice(testing.allocator, Cfg{ .name = "hello world" });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello world", val.name);
}

test "roundtrip bool" {
    const Cfg = struct { debug: bool, verbose: bool };
    const bytes = try toSlice(testing.allocator, Cfg{ .debug = true, .verbose = false });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqual(true, val.debug);
    try testing.expectEqual(false, val.verbose);
}

test "roundtrip float" {
    const Cfg = struct { rate: f64 };
    const bytes = try toSlice(testing.allocator, Cfg{ .rate = 3.14 });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expect(@abs(val.rate - 3.14) < 0.001);
}

test "roundtrip nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };

    const bytes = try toSlice(testing.allocator, Outer{ .name = "test", .inner = .{ .val = 42 } });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqual(@as(i32, 42), val.inner.val);
}

test "roundtrip optional present" {
    const Cfg = struct { name: []const u8, debug: ?bool = null };
    const bytes = try toSlice(testing.allocator, Cfg{ .name = "app", .debug = true });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(?bool, true), val.debug);
}

test "roundtrip optional null" {
    const Cfg = struct { name: []const u8, debug: ?bool = null };
    const bytes = try toSlice(testing.allocator, Cfg{ .name = "app", .debug = null });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(?bool, null), val.debug);
}

test "roundtrip enum" {
    const Color = enum { red, green, blue };
    const Cfg = struct { color: Color };
    const bytes = try toSlice(testing.allocator, Cfg{ .color = .green });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqual(Color.green, val.color);
}

test "roundtrip serde rename" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = options.NamingConvention.camel_case,
        };
    };

    const bytes = try toSlice(testing.allocator, User{ .id = 1, .first_name = "Alice" });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "user_id") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "firstName") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 1), val.id);
    try testing.expectEqualStrings("Alice", val.first_name);
}

test "roundtrip serde skip" {
    const Secret = struct {
        name: []const u8,
        token: []const u8 = "",

        pub const serde = .{
            .skip = .{
                .token = options.SkipMode.always,
            },
        };
    };

    const bytes = try toSlice(testing.allocator, Secret{ .name = "test", .token = "secret123" });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "token") == null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Secret, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqualStrings("", val.token);
}

test "roundtrip default" {
    const Cfg = struct {
        name: []const u8,
        retries: i32 = 3,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), "name: app\n");
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(i32, 3), val.retries);
}

test "roundtrip slice of scalars" {
    const Cfg = struct { nums: []const i32 };
    const data: []const i32 = &.{ 1, 2, 3 };
    const bytes = try toSlice(testing.allocator, Cfg{ .nums = data });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 3), val.nums.len);
    try testing.expectEqual(@as(i32, 1), val.nums[0]);
    try testing.expectEqual(@as(i32, 2), val.nums[1]);
    try testing.expectEqual(@as(i32, 3), val.nums[2]);
}

test "roundtrip deeply nested struct" {
    const C = struct { val: i32 };
    const B = struct { c: C };
    const A = struct { b: B };

    const bytes = try toSlice(testing.allocator, A{ .b = .{ .c = .{ .val = 7 } } });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(A, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 7), val.b.c.val);
}

test "deserialize from handwritten YAML" {
    const Cfg = struct {
        title: []const u8,
        port: i32,
        debug: bool,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(),
        \\# Application config
        \\title: my app
        \\port: 8080
        \\debug: true
        \\
    );
    try testing.expectEqualStrings("my app", val.title);
    try testing.expectEqual(@as(i32, 8080), val.port);
    try testing.expectEqual(true, val.debug);
}

test "deserialize flow syntax" {
    const Point = struct { x: i32, y: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Point, arena.allocator(), "{x: 10, y: 20}\n");
    try testing.expectEqual(@as(i32, 10), val.x);
    try testing.expectEqual(@as(i32, 20), val.y);
}

test "deserialize sequence of structs" {
    const Item = struct { name: []const u8, val: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice([]const Item, arena.allocator(),
        \\- name: a
        \\  val: 1
        \\- name: b
        \\  val: 2
        \\
    );
    try testing.expectEqual(@as(usize, 2), val.len);
    try testing.expectEqualStrings("a", val[0].name);
    try testing.expectEqual(@as(i32, 2), val[1].val);
}

test "deserialize null and optional" {
    const Cfg = struct { a: ?i32 = null, b: ?i32 = null };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), "a: 42\nb: null\n");
    try testing.expectEqual(@as(?i32, 42), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "roundtrip string with escapes" {
    const Cfg = struct { msg: []const u8 };
    const bytes = try toSlice(testing.allocator, Cfg{ .msg = "line1\nline2" });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqualStrings("line1\nline2", val.msg);
}

test "roundtrip empty struct" {
    const Empty = struct {};
    const bytes = try toSlice(testing.allocator, Empty{});
    defer testing.allocator.free(bytes);
    // Should be parseable even if empty.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Empty struct from empty YAML is fine.
    _ = try fromSlice(Empty, arena.allocator(), "{}");
}

test "toWriter" {
    const Cfg = struct { x: i32 };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try toWriter(&aw.writer, Cfg{ .x = 42 });
    const bytes = try aw.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "x: 42") != null);
}

test "toSliceAlloc null-terminated" {
    const Cfg = struct { x: i32 };
    const bytes = try toSliceAlloc(testing.allocator, Cfg{ .x = 1 });
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u8, 0), bytes.ptr[bytes.len]);
}

test "toValue and fromValue" {
    const Cfg = struct { x: i32, y: i32 };
    const v = try toValue(testing.allocator, Cfg{ .x = 10, .y = 20 });
    defer v.deinit(testing.allocator);
    const result = try fromValue(Cfg, testing.allocator, v);
    try testing.expectEqual(@as(i32, 10), result.x);
    try testing.expectEqual(@as(i32, 20), result.y);
}

test "fromReader" {
    const Cfg = struct { x: i32 };
    const input = "x: 42\n";
    var reader: std.Io.Reader = .fixed(input);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromReader(Cfg, arena.allocator(), &reader);
    try testing.expectEqual(@as(i32, 42), val.x);
}

test "roundtrip union external tag with payload" {
    const Cmd = union(enum) { set: i32, ping: void };
    const Root = struct { cmd: Cmd };
    const bytes = try toSlice(testing.allocator, Root{ .cmd = .{ .set = 99 } });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(Cmd{ .set = 99 }, val.cmd);
}

test "roundtrip union void variant" {
    const Cmd = union(enum) { ping: void, quit: void };
    const Root = struct { cmd: Cmd };
    const bytes = try toSlice(testing.allocator, Root{ .cmd = .ping });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(Cmd.ping, val.cmd);
}

test "roundtrip union internal tagging" {
    const Shape = union(enum) {
        circle: struct { radius: i32 },
        rect: struct { w: i32, h: i32 },

        pub const serde = .{
            .tag = options.UnionTag.internal,
            .tag_field = "type",
        };
    };
    const Root = struct { shape: Shape };
    const val: Root = .{ .shape = .{ .circle = .{ .radius = 5 } } };
    const bytes = try toSlice(testing.allocator, val);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 5), result.shape.circle.radius);
}

test "roundtrip union adjacent tagging" {
    const Cmd = union(enum) {
        run: struct { script: []const u8 },
        stop: void,

        pub const serde = .{
            .tag = options.UnionTag.adjacent,
            .tag_field = "t",
            .content_field = "c",
        };
    };
    const Root = struct { cmd: Cmd };
    const val: Root = .{ .cmd = .{ .run = .{ .script = "deploy.sh" } } };
    const bytes = try toSlice(testing.allocator, val);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqualStrings("deploy.sh", result.cmd.run.script);
}

test "roundtrip union untagged" {
    const Val = union(enum) {
        num: struct { n: i32 },
        text: struct { s: []const u8 },

        pub const serde = .{
            .tag = options.UnionTag.untagged,
        };
    };
    const Root = struct { val: Val };
    const original: Root = .{ .val = .{ .num = .{ .n = 42 } } };
    const bytes = try toSlice(testing.allocator, original);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), result.val.num.n);
}

test "untagged scalar union deserializes bare scalar" {
    const ScalarUntagged = union(enum) {
        string: []const u8,
        int: i64,
        boolean: bool,

        pub const serde = .{
            .tag = options.UnionTag.untagged,
        };
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try fromSlice(ScalarUntagged, arena.allocator(), "hello");
    try testing.expectEqualStrings("hello", value.string);
}

test "untagged scalar union deserializes nested scalar" {
    const ScalarUntagged = union(enum) {
        string: []const u8,
        int: i64,
        boolean: bool,

        pub const serde = .{
            .tag = options.UnionTag.untagged,
        };
    };
    const Root = struct {
        value: ScalarUntagged,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Root, arena.allocator(), "value: hello");
    try testing.expectEqualStrings("hello", result.value.string);
}

test "external scalar union mapping still deserializes" {
    const ScalarExternal = union(enum) {
        string: []const u8,
        int: i64,
        boolean: bool,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try fromSlice(ScalarExternal, arena.allocator(), "string: hello");
    try testing.expectEqualStrings("hello", value.string);
}

test "schema: top-level enum rename deserializes" {
    const Mode = enum {
        read_only,
        write_only,
    };
    const schema = .{
        .rename = .{
            .read_only = "ro",
            .write_only = "wo",
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try fromSliceSchema(Mode, arena.allocator(), "ro", schema);
    try testing.expectEqual(Mode.read_only, value);
}

test "schema: top-level untagged union deserializes" {
    const Scalar = union(enum) {
        string: []const u8,
        int: i64,
    };
    const schema = .{
        .tag = options.UnionTag.untagged,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try fromSliceSchema(Scalar, arena.allocator(), "hello", schema);
    try testing.expectEqualStrings("hello", value.string);
}

test "roundtrip flatten" {
    const Metadata = struct {
        created_by: []const u8,
        version: i32 = 1,
    };
    const User = struct {
        name: []const u8,
        meta: Metadata,

        pub const serde = .{
            .flatten = &[_][]const u8{"meta"},
        };
    };

    const user: User = .{ .name = "Alice", .meta = .{ .created_by = "admin", .version = 2 } };
    const bytes = try toSlice(testing.allocator, user);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "created_by") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqualStrings("Alice", val.name);
    try testing.expectEqualStrings("admin", val.meta.created_by);
    try testing.expectEqual(@as(i32, 2), val.meta.version);
}

test "roundtrip with UnixTimestampMs" {
    const ts = @import("../../helpers/timestamp.zig");
    const Event = struct {
        name: []const u8,
        created_at: i64,

        pub const serde = .{
            .with = .{
                .created_at = ts.UnixTimestampMs,
            },
        };
    };

    const event: Event = .{ .name = "deploy", .created_at = 1700000 };
    const bytes = try toSlice(testing.allocator, event);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Event, arena.allocator(), bytes);
    try testing.expectEqualStrings("deploy", val.name);
    try testing.expectEqual(@as(i64, 1700000), val.created_at);
}

test "roundtrip enum integer repr" {
    const Status = enum(u8) {
        active = 0,
        inactive = 1,
        pending = 2,

        pub const serde = .{
            .enum_repr = options.EnumRepr.integer,
        };
    };
    const Root = struct { status: Status };
    const bytes = try toSlice(testing.allocator, Root{ .status = .inactive });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(Status.inactive, val.status);
}

test "roundtrip pointer" {
    const inner: i32 = 42;
    const Wrapper = struct { p: *const i32 };
    const wrapper = Wrapper{ .p = &inner };
    const bytes = try toSlice(testing.allocator, wrapper);
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Wrapper, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), val.p.*);
}

test "roundtrip custom zerdeSerialize/zerdeDeserialize" {
    const StringWrappedU64 = struct {
        inner: u64,

        pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
            var buf: [20]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{self.inner}) catch unreachable;
            try serializer.serializeString(s);
        }

        pub fn zerdeDeserialize(comptime _: type, allocator: std.mem.Allocator, deserializer: anytype) @TypeOf(deserializer.*).Error!@This() {
            const str = try deserializer.deserializeString(allocator);
            defer allocator.free(str);
            return .{ .inner = std.fmt.parseInt(u64, str, 10) catch return error.InvalidNumber };
        }
    };

    const Root = struct { val: StringWrappedU64 };
    const bytes = try toSlice(testing.allocator, Root{ .val = .{ .inner = 12345 } });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 12345), result.val.inner);
}

test "deny_unknown_fields" {
    const Strict = struct {
        x: i32,
        pub const serde = .{
            .deny_unknown_fields = true,
        };
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Strict, arena.allocator(), "x: 10\n");
    try testing.expectEqual(@as(i32, 10), val.x);

    const result = fromSlice(Strict, arena.allocator(), "x: 10\ny: 20\n");
    try testing.expectError(error.UnknownField, result);
}

test "serialize skip if null" {
    const Cfg = struct {
        name: []const u8,
        email: ?[]const u8,

        pub const serde = .{
            .skip = .{ .email = options.SkipMode.null },
        };
    };

    const bytes1 = try toSlice(testing.allocator, Cfg{ .name = "Alice", .email = null });
    defer testing.allocator.free(bytes1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "email") == null);

    const bytes2 = try toSlice(testing.allocator, Cfg{ .name = "Alice", .email = "a@b.c" });
    defer testing.allocator.free(bytes2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "email") != null);
}

test "serialize skip if empty" {
    const Cfg = struct {
        id: i32,
        tags: []const []const u8,

        pub const serde = .{
            .skip = .{ .tags = options.SkipMode.empty },
        };
    };

    const bytes1 = try toSlice(testing.allocator, Cfg{ .id = 1, .tags = &.{} });
    defer testing.allocator.free(bytes1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "tags") == null);

    const tags: []const []const u8 = &.{"a"};
    const bytes2 = try toSlice(testing.allocator, Cfg{ .id = 1, .tags = tags });
    defer testing.allocator.free(bytes2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "tags") != null);
}

test "roundtrip fixed array" {
    const Cfg = struct { arr: [3]i32 };
    const bytes = try toSlice(testing.allocator, Cfg{ .arr = .{ 10, 20, 30 } });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqual([3]i32{ 10, 20, 30 }, val.arr);
}

test "roundtrip unicode string" {
    const Cfg = struct { msg: []const u8 };
    const bytes = try toSlice(testing.allocator, Cfg{ .msg = "hello 🌍" });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello 🌍", val.msg);
}

test "roundtrip i128 within i64 range" {
    const Cfg = struct { val: i128 };
    const bytes = try toSlice(testing.allocator, Cfg{ .val = 123456 });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqual(@as(i128, 123456), val.val);
}

test "deserialize error: malformed input" {
    const Cfg = struct { x: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = fromSlice(Cfg, arena.allocator(), "{{invalid yaml");
    try testing.expect(std.meta.isError(result));
}

test "deserialize error: missing required field" {
    const Cfg = struct { x: i32, y: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = fromSlice(Cfg, arena.allocator(), "x: 1\n");
    try testing.expectError(error.MissingField, result);
}

test "deserialize error: type mismatch" {
    const Cfg = struct { x: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = fromSlice(Cfg, arena.allocator(), "x: not_a_number\n");
    try testing.expectError(error.WrongType, result);
}

test "toSliceWith explicit_start and explicit_end" {
    const Cfg = struct { x: i32 };
    const bytes = try toSliceWith(testing.allocator, Cfg{ .x = 1 }, .{
        .explicit_start = true,
        .explicit_end = true,
    });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, "---\n"));
    try testing.expect(std.mem.endsWith(u8, bytes, "...\n"));
}

test "toSliceWith null_repr tilde" {
    const Cfg = struct { name: []const u8, val: ?i32 = null };
    const bytes = try toSliceWith(testing.allocator, Cfg{ .name = "a", .val = null }, .{
        .null_repr = .tilde,
    });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "~") != null);
}

test "toSliceWith custom indent" {
    const Inner = struct { val: i32 };
    const Cfg = struct { inner: Inner };
    const bytes = try toSliceWith(testing.allocator, Cfg{ .inner = .{ .val = 1 } }, .{
        .indent = 4,
    });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "    val") != null);
}

test "parseValue" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parseValue(arena.allocator(), "x: 42\n");
    try testing.expect(val == .mapping);
}

test "parseAllValues multi-document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const docs = try parseAllValues(arena.allocator(),
        \\---
        \\x: 1
        \\---
        \\x: 2
        \\...
        \\
    );
    defer arena.allocator().free(docs);
    try testing.expectEqual(@as(usize, 2), docs.len);
}

test "parseAllValues single document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const docs = try parseAllValues(arena.allocator(), "x: 1\n");
    defer arena.allocator().free(docs);
    try testing.expectEqual(@as(usize, 1), docs.len);
}

test "deserialize StringHashMap" {
    const V = struct { foo: []const u8 };
    const T = struct { a: std.StringHashMap(V) };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try fromSlice(T, arena.allocator(),
        \\a:
        \\  b:
        \\    foo: bar
    );
    try testing.expectEqual(@as(usize, 1), parsed.a.count());
    const b = parsed.a.get("b") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("bar", b.foo);
}

test "roundtrip StringHashMap scalar values" {
    var map = std.StringHashMap(i32).init(testing.allocator);
    defer map.deinit();
    try map.put("x", 1);
    try map.put("y", 2);

    const Root = struct { data: std.StringHashMap(i32) };
    const bytes = try toSlice(testing.allocator, Root{ .data = map });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 1), result.data.get("x").?);
    try testing.expectEqual(@as(i32, 2), result.data.get("y").?);
}

test "roundtrip StringHashMap struct values" {
    const V = struct { val: i32 };
    var map = std.StringHashMap(V).init(testing.allocator);
    defer map.deinit();
    try map.put("a", .{ .val = 10 });
    try map.put("b", .{ .val = 20 });

    const Root = struct { data: std.StringHashMap(V) };
    const bytes = try toSlice(testing.allocator, Root{ .data = map });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 10), result.data.get("a").?.val);
    try testing.expectEqual(@as(i32, 20), result.data.get("b").?.val);
}
