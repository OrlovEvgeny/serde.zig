//! TOML serialization and deserialization.
//!
//! Serialize structs to TOML with `toSlice` / `toWriter`, and deserialize
//! with `fromSlice` / `fromReader`. The top-level value must be a struct
//! (TOML requires a table at the document root).

const std = @import("std");
const compat = @import("compat");
const parser_mod = @import("parser.zig");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");
const kind_mod = @import("../../core/kind.zig");

pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;
pub const Value = parser_mod.Value;
pub const Table = parser_mod.Table;
pub const parse = parser_mod.parse;

/// Serialize a struct value to a TOML byte slice. Caller owns the returned memory.
/// The top-level value must be a struct (TOML requires a table at the root).
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try toWriter(allocator, &aw.writer, value);
    return aw.toOwnedSlice();
}

/// Serialize a struct value to a null-terminated TOML byte slice. Caller owns the returned memory.
pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    const bytes = try toSlice(allocator, value);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

/// Serialize a value to a writer in TOML format.
/// Requires an allocator for section path tracking during serialization.
pub fn toWriter(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype) !void {
    const T = @TypeOf(value);
    if (comptime kind_mod.typeKind(T) != .@"struct")
        @compileError("TOML top-level value must be a struct, got: " ++ @typeName(T));

    var ser = Serializer.init(writer, allocator);
    try core_serialize.serialize(T, value, &ser, .{});
}

// Schema-aware API.

/// Serialize a value to a TOML byte slice with an external schema.
pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try toWriterSchema(allocator, &aw.writer, value, schema);
    return aw.toOwnedSlice();
}

/// Serialize a value to a writer in TOML format with an external schema.
pub fn toWriterSchema(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, comptime schema: anytype) !void {
    const T = @TypeOf(value);
    if (comptime kind_mod.typeKind(T) != .@"struct")
        @compileError("TOML top-level value must be a struct, got: " ++ @typeName(T));

    var ser = Serializer.init(writer, allocator);
    try core_serialize.serializeSchema(T, value, &ser, schema, .{});
}

/// Deserialize a struct of type T from a TOML byte slice with an external schema.
pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    if (comptime kind_mod.typeKind(T) != .@"struct")
        @compileError("TOML top-level type must be a struct, got: " ++ @typeName(T));

    const table = try parser_mod.parse(allocator, input);
    var deser = Deserializer.init(&table);
    return core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
}

/// Deserialize from a reader with an external schema.
pub fn fromReaderSchema(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, comptime schema: anytype) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceSchema(T, allocator, buf, schema);
}

/// Deserialize a struct of type T from a TOML byte slice.
/// Allocates copies of all strings and slices. Use an ArenaAllocator for easy cleanup.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    if (comptime kind_mod.typeKind(T) != .@"struct")
        @compileError("TOML top-level type must be a struct, got: " ++ @typeName(T));

    const table = try parser_mod.parse(allocator, input);
    var deser = Deserializer.init(&table);
    return core_deserialize.deserialize(T, allocator, &deser, .{});
}

/// Deserialize a value of type T from a reader.
pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

/// Deserialize a value of type T from a file path.
pub fn fromFilePath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const content = try compat.readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(content);
    return fromSlice(T, allocator, content);
}

fn readAll(allocator: std.mem.Allocator, reader: *compat.Io.Reader) ![]u8 {
    return reader.allocRemaining(allocator, compat.Io.Limit.limited(10 * 1024 * 1024)) catch return error.ReadFailed;
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

// Tests.

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

test "roundtrip inline array" {
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

test "roundtrip array of tables" {
    const Item = struct { id: i32 };
    const Root = struct { items: []const Item };
    const items: []const Item = &.{ .{ .id = 1 }, .{ .id = 2 } };
    const bytes = try toSlice(testing.allocator, Root{ .items = items });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), val.items.len);
    try testing.expectEqual(@as(i32, 1), val.items[0].id);
    try testing.expectEqual(@as(i32, 2), val.items[1].id);
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

        const opts = @import("../../core/options.zig");
        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = opts.NamingConvention.camel_case,
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
    const opts = @import("../../core/options.zig");
    const Secret = struct {
        name: []const u8,
        token: []const u8 = "",

        pub const serde = .{
            .skip = .{
                .token = opts.SkipMode.always,
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
    const val = try fromSlice(Cfg, arena.allocator(), "name = \"app\"\n");
    try testing.expectEqualStrings("app", val.name);
    try testing.expectEqual(@as(i32, 3), val.retries);
}

test "roundtrip empty struct" {
    const Empty = struct {};
    const bytes = try toSlice(testing.allocator, Empty{});
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Empty, arena.allocator(), bytes);
    _ = val;
}

test "roundtrip string with escapes" {
    const Cfg = struct { msg: []const u8 };
    const bytes = try toSlice(testing.allocator, Cfg{ .msg = "line1\nline2\ttab" });
    defer testing.allocator.free(bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(), bytes);
    try testing.expectEqualStrings("line1\nline2\ttab", val.msg);
}

test "deserialize from handwritten TOML" {
    const Cfg = struct {
        title: []const u8,
        port: i32,
        debug: bool,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Cfg, arena.allocator(),
        \\# Application config
        \\title = "my app"
        \\port = 8080
        \\debug = true
        \\
    );
    try testing.expectEqualStrings("my app", val.title);
    try testing.expectEqual(@as(i32, 8080), val.port);
    try testing.expectEqual(true, val.debug);
}

test "toWriter" {
    const Cfg = struct { x: i32 };
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    try toWriter(testing.allocator, &aw.writer, Cfg{ .x = 42 });
    const bytes = try aw.toOwnedSlice();
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "x = 42") != null);
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
    const input = "x = 42\n";
    var reader: compat.Io.Reader = .fixed(input);
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
    // Flattened: created_by and version appear at top level.
    try testing.expect(std.mem.indexOf(u8, bytes, "created_by") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "meta") == null or
        std.mem.indexOf(u8, bytes, "[meta]") == null);

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
    const opts = @import("../../core/options.zig");
    const Status = enum(u8) {
        active = 0,
        inactive = 1,
        pending = 2,

        pub const serde = .{
            .enum_repr = opts.EnumRepr.integer,
        };
    };
    const Root = struct { status: Status };
    const bytes = try toSlice(testing.allocator, Root{ .status = .inactive });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "status = 1") != null);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(Status.inactive, val.status);
}

test "roundtrip union internal tagging" {
    const opts = @import("../../core/options.zig");
    const Shape = union(enum) {
        circle: struct { radius: i32 },
        rect: struct { w: i32, h: i32 },

        pub const serde = .{
            .tag = opts.UnionTag.internal,
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
    const opts = @import("../../core/options.zig");
    const Cmd = union(enum) {
        run: struct { script: []const u8 },
        stop: void,

        pub const serde = .{
            .tag = opts.UnionTag.adjacent,
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
    const opts = @import("../../core/options.zig");
    const Val = union(enum) {
        num: struct { n: i32 },
        text: struct { s: []const u8 },

        pub const serde = .{
            .tag = opts.UnionTag.untagged,
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

test "roundtrip pointer" {
    const Cfg = struct { val: i32 };
    const inner: i32 = 42;
    const ptr: *const i32 = &inner;
    // Pointers serialize as their pointee, so wrap in struct for TOML.
    _ = ptr;
    // TOML requires struct at top level, so test pointer field inside struct.
    const Wrapper = struct { p: *const i32 };
    const wrapper = Wrapper{ .p = &inner };
    const bytes = try toSlice(testing.allocator, wrapper);
    defer testing.allocator.free(bytes);

    _ = Cfg;
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
    // Known field only — succeeds.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Strict, arena.allocator(), "x = 10\n");
    try testing.expectEqual(@as(i32, 10), val.x);

    // Extra field — fails.
    const result = fromSlice(Strict, arena.allocator(), "x = 10\ny = 20\n");
    try testing.expectError(error.UnknownField, result);
}

test "serialize skip if null" {
    const serde_opts = @import("../../core/options.zig");
    const Cfg = struct {
        name: []const u8,
        email: ?[]const u8,

        pub const serde = .{
            .skip = .{ .email = serde_opts.SkipMode.null },
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
    const serde_opts = @import("../../core/options.zig");
    const Cfg = struct {
        id: i32,
        tags: []const []const u8,

        pub const serde = .{
            .skip = .{ .tags = serde_opts.SkipMode.empty },
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
    const result = fromSlice(Cfg, arena.allocator(), "= missing key\n");
    try testing.expectError(error.UnexpectedToken, result);
}

test "deserialize error: missing required field" {
    const Cfg = struct { x: i32, y: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = fromSlice(Cfg, arena.allocator(), "x = 1\n");
    try testing.expectError(error.MissingField, result);
}

test "deserialize error: type mismatch" {
    const Cfg = struct { x: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = fromSlice(Cfg, arena.allocator(), "x = \"not a number\"\n");
    try testing.expectError(error.WrongType, result);
}

test "deserialize StringHashMap" {
    const V = struct { foo: []const u8 };
    const T = struct { a: std.StringHashMap(V) };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try fromSlice(T, arena.allocator(),
        \\[a.b]
        \\foo = "bar"
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
