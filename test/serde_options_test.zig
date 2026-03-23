const std = @import("std");
const testing = std.testing;
const sz = @import("serde");

// Types with various serde option combinations.

const RenamedUser = struct {
    user_id: u64,
    first_name: []const u8,
    last_name: []const u8,
    email_address: ?[]const u8,

    pub const serde = .{
        .rename = .{
            .user_id = "id",
        },
        .rename_all = sz.NamingConvention.camel_case,
    };
};

const SkipMix = struct {
    name: []const u8,
    token: []const u8 = "",
    email: ?[]const u8 = null,
    tags: []const []const u8 = &.{},

    pub const serde = .{
        .skip = .{
            .token = sz.SkipMode.always,
            .email = sz.SkipMode.null,
            .tags = sz.SkipMode.empty,
        },
    };
};

const WithDefaults = struct {
    name: []const u8,
    count: i32 = 10,
    label: []const u8 = "default",
};

const StrictType = struct {
    x: i32,
    y: i32,

    pub const serde = .{
        .deny_unknown_fields = true,
    };
};

const InternalTagged = union(enum) {
    ping: void,
    execute: struct { query: []const u8 },
    result: struct { rows: i32 },

    pub const serde = .{
        .tag = sz.UnionTag.internal,
        .tag_field = "type",
    };
};

const AdjacentTagged = union(enum) {
    start: void,
    data: struct { payload: []const u8 },
    stop: i32,

    pub const serde = .{
        .tag = sz.UnionTag.adjacent,
        .tag_field = "kind",
        .content_field = "value",
    };
};

const IntEnum = enum(u8) {
    active = 0,
    inactive = 1,
    pending = 2,

    pub const serde = .{
        .enum_repr = sz.EnumRepr.integer,
    };
};

const StringEnum = enum { red, green, blue };

// Naming convention tests.

test "options: camelCase rename_all JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const CamelStruct = struct {
        first_name: []const u8,
        last_name: []const u8,
        pub const serde = .{ .rename_all = sz.NamingConvention.camel_case };
    };
    const v = CamelStruct{ .first_name = "John", .last_name = "Doe" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "firstName") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "lastName") != null);
    const r = try sz.json.fromSlice(CamelStruct, arena.allocator(), bytes);
    try testing.expectEqualStrings("John", r.first_name);
}

test "options: PascalCase rename_all JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const PascalStruct = struct {
        first_name: []const u8,
        pub const serde = .{ .rename_all = sz.NamingConvention.pascal_case };
    };
    const v = PascalStruct{ .first_name = "John" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "FirstName") != null);
    const r = try sz.json.fromSlice(PascalStruct, arena.allocator(), bytes);
    try testing.expectEqualStrings("John", r.first_name);
}

test "options: kebab-case rename_all JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const KebabStruct = struct {
        max_retries: i32,
        pub const serde = .{ .rename_all = sz.NamingConvention.kebab_case };
    };
    const v = KebabStruct{ .max_retries = 3 };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "max-retries") != null);
    const r = try sz.json.fromSlice(KebabStruct, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 3), r.max_retries);
}

test "options: SCREAMING_SNAKE_CASE rename_all JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ScreamStruct = struct {
        max_retries: i32,
        pub const serde = .{ .rename_all = sz.NamingConvention.SCREAMING_SNAKE_CASE };
    };
    const v = ScreamStruct{ .max_retries = 3 };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "MAX_RETRIES") != null);
    const r = try sz.json.fromSlice(ScreamStruct, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 3), r.max_retries);
}

// Per-field rename takes priority over rename_all.

test "options: per-field rename overrides rename_all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = RenamedUser{
        .user_id = 42,
        .first_name = "Alice",
        .last_name = "Smith",
        .email_address = "alice@test.com",
    };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    // user_id renamed to "id" (per-field), not "userId" (rename_all).
    try testing.expect(std.mem.indexOf(u8, bytes, "\"id\"") != null);
    // first_name becomes "firstName" via rename_all.
    try testing.expect(std.mem.indexOf(u8, bytes, "firstName") != null);
    const r = try sz.json.fromSlice(RenamedUser, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 42), r.user_id);
    try testing.expectEqualStrings("Alice", r.first_name);
}

// Skip tests.

test "options: skip always omits field from output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = SkipMix{ .name = "test", .token = "secret123", .email = "a@b.c", .tags = &.{"x"} };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "token") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
}

test "options: skip null conditional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // null email -> skip.
    const v1 = SkipMix{ .name = "test", .email = null };
    const bytes1 = try sz.json.toSlice(arena.allocator(), v1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "email") == null);

    // non-null email -> include.
    const v2 = SkipMix{ .name = "test", .email = "a@b.c" };
    const bytes2 = try sz.json.toSlice(arena.allocator(), v2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "email") != null);
}

test "options: skip empty conditional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // empty tags -> skip.
    const v1 = SkipMix{ .name = "test", .tags = &.{} };
    const bytes1 = try sz.json.toSlice(arena.allocator(), v1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "tags") == null);

    // non-empty tags -> include.
    const tags: []const []const u8 = &.{"x"};
    const v2 = SkipMix{ .name = "test", .tags = tags };
    const bytes2 = try sz.json.toSlice(arena.allocator(), v2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "tags") != null);
}

// Default tests.

test "options: Zig field default when absent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try sz.json.fromSlice(WithDefaults, arena.allocator(), "{\"name\":\"test\"}");
    try testing.expectEqualStrings("test", r.name);
    try testing.expectEqual(@as(i32, 10), r.count);
    try testing.expectEqualStrings("default", r.label);
}

test "options: default overridden by input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try sz.json.fromSlice(WithDefaults, arena.allocator(),
        \\{"name":"test","count":99,"label":"custom"}
    );
    try testing.expectEqual(@as(i32, 99), r.count);
    try testing.expectEqualStrings("custom", r.label);
}

// deny_unknown_fields tests.

test "options: deny_unknown_fields rejects extra keys" {
    const r = sz.json.fromSlice(StrictType, testing.allocator, "{\"x\":1,\"y\":2,\"z\":3}");
    try testing.expectError(error.UnknownField, r);
}

test "options: deny_unknown_fields accepts known keys" {
    const r = try sz.json.fromSlice(StrictType, testing.allocator, "{\"x\":1,\"y\":2}");
    try testing.expectEqual(@as(i32, 1), r.x);
    try testing.expectEqual(@as(i32, 2), r.y);
}

// Union tag representation tests.

test "options: internal tagged union serialize JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: InternalTagged = .{ .execute = .{ .query = "SELECT 1" } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"type\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"execute\"") != null);
}

test "options: internal tagged union roundtrip JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: InternalTagged = .{ .execute = .{ .query = "SELECT 1" } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(InternalTagged, arena.allocator(), bytes);
    try testing.expectEqualStrings("SELECT 1", r.execute.query);
}

test "options: internal tagged void variant roundtrip JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: InternalTagged = .ping;
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(InternalTagged, arena.allocator(), bytes);
    try testing.expectEqual(InternalTagged.ping, r);
}

test "options: adjacent tagged union roundtrip JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: AdjacentTagged = .{ .data = .{ .payload = "hello" } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"kind\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"value\"") != null);
    const r = try sz.json.fromSlice(AdjacentTagged, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello", r.data.payload);
}

test "options: adjacent tagged void variant roundtrip JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: AdjacentTagged = .start;
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(AdjacentTagged, arena.allocator(), bytes);
    try testing.expectEqual(AdjacentTagged.start, r);
}

test "options: external tagged union (default) roundtrip JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cmd = union(enum) { ping: void, set: i32 };
    const v = Cmd{ .set = 42 };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(Cmd, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), r.set);
}

// Enum representation tests.

test "options: enum integer repr roundtrip JSON" {
    const bytes = try sz.json.toSlice(testing.allocator, IntEnum.inactive);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("1", bytes);
    const r = try sz.json.fromSlice(IntEnum, testing.allocator, bytes);
    try testing.expectEqual(IntEnum.inactive, r);
}

test "options: enum string repr (default) roundtrip JSON" {
    const bytes = try sz.json.toSlice(testing.allocator, StringEnum.green);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\"green\"", bytes);
    const r = try sz.json.fromSlice(StringEnum, testing.allocator, bytes);
    try testing.expectEqual(StringEnum.green, r);
}

test "options: enum integer repr roundtrip msgpack" {
    const bytes = try sz.msgpack.toSlice(testing.allocator, IntEnum.pending);
    defer testing.allocator.free(bytes);
    const r = try sz.msgpack.fromSlice(IntEnum, testing.allocator, bytes);
    try testing.expectEqual(IntEnum.pending, r);
}

// Schema override tests.

test "options: schema rename on plain struct JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Point = struct { x: i32, y: i32 };
    const schema = .{ .rename = .{ .x = "X", .y = "Y" } };
    const bytes = try sz.json.toSliceSchema(arena.allocator(), Point{ .x = 1, .y = 2 }, schema);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"X\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"Y\"") != null);
    const r = try sz.json.fromSliceSchema(Point, arena.allocator(), bytes, schema);
    try testing.expectEqual(@as(i32, 1), r.x);
    try testing.expectEqual(@as(i32, 2), r.y);
}

test "options: schema deny_unknown_fields on plain struct" {
    const Point = struct { x: i32, y: i32 };
    const schema = .{ .deny_unknown_fields = true };
    const r = sz.json.fromSliceSchema(Point, testing.allocator, "{\"x\":1,\"y\":2,\"z\":3}", schema);
    try testing.expectError(error.UnknownField, r);
}

test "options: same type different schema produces different output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Point = struct { x: i32, y: i32 };
    const schema1 = .{ .rename = .{ .x = "X" } };
    const schema2 = .{ .rename = .{ .x = "horizontal" } };
    const v = Point{ .x = 1, .y = 2 };
    const bytes1 = try sz.json.toSliceSchema(arena.allocator(), v, schema1);
    const bytes2 = try sz.json.toSliceSchema(arena.allocator(), v, schema2);
    try testing.expect(!std.mem.eql(u8, bytes1, bytes2));
    try testing.expect(std.mem.indexOf(u8, bytes1, "\"X\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2, "\"horizontal\"") != null);
}

// Cross-format rename consistency.

test "options: rename_all consistent across JSON and msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const CamelStruct = struct {
        first_name: []const u8,
        pub const serde = .{ .rename_all = sz.NamingConvention.camel_case };
    };
    const v = CamelStruct{ .first_name = "Alice" };

    // JSON.
    const json_bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "firstName") != null);
    const json_r = try sz.json.fromSlice(CamelStruct, arena.allocator(), json_bytes);
    try testing.expectEqualStrings("Alice", json_r.first_name);

    // MsgPack.
    const mp_bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const mp_r = try sz.msgpack.fromSlice(CamelStruct, arena.allocator(), mp_bytes);
    try testing.expectEqualStrings("Alice", mp_r.first_name);
}

test "options: rename_all consistent across TOML and YAML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const CamelCfg = struct {
        max_retries: i32,
        pub const serde = .{ .rename_all = sz.NamingConvention.camel_case };
    };
    const v = CamelCfg{ .max_retries = 3 };

    // TOML.
    const toml_bytes = try sz.toml.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, toml_bytes, "maxRetries") != null);
    const toml_r = try sz.toml.fromSlice(CamelCfg, arena.allocator(), toml_bytes);
    try testing.expectEqual(@as(i32, 3), toml_r.max_retries);

    // YAML.
    const yaml_bytes = try sz.yaml.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, yaml_bytes, "maxRetries") != null);
    const yaml_r = try sz.yaml.fromSlice(CamelCfg, arena.allocator(), yaml_bytes);
    try testing.expectEqual(@as(i32, 3), yaml_r.max_retries);
}

// Flatten tests.

test "options: flatten roundtrip JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Metadata = struct { created_by: []const u8, version: i32 = 1 };
    const Record = struct {
        name: []const u8,
        meta: Metadata,
        pub const serde = .{ .flatten = &[_][]const u8{"meta"} };
    };
    const v = Record{ .name = "test", .meta = .{ .created_by = "admin", .version = 2 } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    // Flattened: created_by should be at top level, not nested under "meta".
    try testing.expect(std.mem.indexOf(u8, bytes, "\"created_by\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"meta\"") == null);
    const r = try sz.json.fromSlice(Record, arena.allocator(), bytes);
    try testing.expectEqualStrings("admin", r.meta.created_by);
    try testing.expectEqual(@as(i32, 2), r.meta.version);
}

// Combined options.

test "options: rename + skip + default combined JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Complex = struct {
        user_name: []const u8,
        secret: []const u8 = "",
        count: i32 = 0,
        email: ?[]const u8 = null,

        pub const serde = .{
            .rename_all = sz.NamingConvention.camel_case,
            .skip = .{
                .secret = sz.SkipMode.always,
                .email = sz.SkipMode.null,
            },
        };
    };
    const v = Complex{ .user_name = "alice", .secret = "xyz", .count = 5, .email = null };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    // "userName" via rename_all, not "user_name".
    try testing.expect(std.mem.indexOf(u8, bytes, "userName") != null);
    // "secret" skipped always.
    try testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "xyz") == null);
    // "email" skipped because null.
    try testing.expect(std.mem.indexOf(u8, bytes, "email") == null);
    // "count" present.
    try testing.expect(std.mem.indexOf(u8, bytes, "count") != null);

    // Deserialize back — secret gets default, email gets null.
    const r = try sz.json.fromSlice(Complex, arena.allocator(), bytes);
    try testing.expectEqualStrings("alice", r.user_name);
    try testing.expectEqualStrings("", r.secret);
    try testing.expectEqual(@as(i32, 5), r.count);
    try testing.expectEqual(@as(?[]const u8, null), r.email);
}

// Union internal tag roundtrip in msgpack.

test "options: internal tagged union roundtrip msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: InternalTagged = .{ .result = .{ .rows = 42 } };
    const bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(InternalTagged, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), r.result.rows);
}

// Adjacent tagged union roundtrip in msgpack.

test "options: adjacent tagged union roundtrip msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: AdjacentTagged = .{ .stop = 99 };
    const bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(AdjacentTagged, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 99), r.stop);
}

// CSV with serde options.

test "options: CSV rename roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Row = struct {
        user_id: u64,
        first_name: []const u8,
        pub const serde = .{
            .rename = .{ .user_id = "id" },
            .rename_all = sz.NamingConvention.camel_case,
        };
    };
    const data: []const Row = &.{.{ .user_id = 1, .first_name = "Alice" }};
    const bytes = try sz.csv.toSlice(arena.allocator(), data);
    try testing.expect(std.mem.indexOf(u8, bytes, "id") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "firstName") != null);
    const r = try sz.csv.fromSlice([]const Row, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 1), r[0].user_id);
}

test "options: CSV skip always" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Row = struct {
        name: []const u8,
        secret: []const u8 = "",
        pub const serde = .{ .skip = .{ .secret = sz.SkipMode.always } };
    };
    const data: []const Row = &.{.{ .name = "test", .secret = "hidden" }};
    const bytes = try sz.csv.toSlice(arena.allocator(), data);
    try testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "hidden") == null);
}
