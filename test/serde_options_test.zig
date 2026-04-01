const std = @import("std");
const testing = std.testing;
const sz = @import("serde");

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
    try testing.expect(std.mem.indexOf(u8, bytes, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "firstName") != null);
    const r = try sz.json.fromSlice(RenamedUser, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 42), r.user_id);
    try testing.expectEqualStrings("Alice", r.first_name);
}

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
    const v1 = SkipMix{ .name = "test", .email = null };
    const bytes1 = try sz.json.toSlice(arena.allocator(), v1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "email") == null);

    const v2 = SkipMix{ .name = "test", .email = "a@b.c" };
    const bytes2 = try sz.json.toSlice(arena.allocator(), v2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "email") != null);
}

test "options: skip empty conditional" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v1 = SkipMix{ .name = "test", .tags = &.{} };
    const bytes1 = try sz.json.toSlice(arena.allocator(), v1);
    try testing.expect(std.mem.indexOf(u8, bytes1, "tags") == null);

    const tags: []const []const u8 = &.{"x"};
    const v2 = SkipMix{ .name = "test", .tags = tags };
    const bytes2 = try sz.json.toSlice(arena.allocator(), v2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "tags") != null);
}

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

test "options: deny_unknown_fields rejects extra keys" {
    const r = sz.json.fromSlice(StrictType, testing.allocator, "{\"x\":1,\"y\":2,\"z\":3}");
    try testing.expectError(error.UnknownField, r);
}

test "options: deny_unknown_fields accepts known keys" {
    const r = try sz.json.fromSlice(StrictType, testing.allocator, "{\"x\":1,\"y\":2}");
    try testing.expectEqual(@as(i32, 1), r.x);
    try testing.expectEqual(@as(i32, 2), r.y);
}

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

test "options: rename_all consistent across JSON and msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const CamelStruct = struct {
        first_name: []const u8,
        pub const serde = .{ .rename_all = sz.NamingConvention.camel_case };
    };
    const v = CamelStruct{ .first_name = "Alice" };

    const json_bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, json_bytes, "firstName") != null);
    const json_r = try sz.json.fromSlice(CamelStruct, arena.allocator(), json_bytes);
    try testing.expectEqualStrings("Alice", json_r.first_name);

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

    const toml_bytes = try sz.toml.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, toml_bytes, "maxRetries") != null);
    const toml_r = try sz.toml.fromSlice(CamelCfg, arena.allocator(), toml_bytes);
    try testing.expectEqual(@as(i32, 3), toml_r.max_retries);

    const yaml_bytes = try sz.yaml.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, yaml_bytes, "maxRetries") != null);
    const yaml_r = try sz.yaml.fromSlice(CamelCfg, arena.allocator(), yaml_bytes);
    try testing.expectEqual(@as(i32, 3), yaml_r.max_retries);
}

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
    try testing.expect(std.mem.indexOf(u8, bytes, "\"created_by\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"meta\"") == null);
    const r = try sz.json.fromSlice(Record, arena.allocator(), bytes);
    try testing.expectEqualStrings("admin", r.meta.created_by);
    try testing.expectEqual(@as(i32, 2), r.meta.version);
}

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
    try testing.expect(std.mem.indexOf(u8, bytes, "userName") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "xyz") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "email") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "count") != null);

    const r = try sz.json.fromSlice(Complex, arena.allocator(), bytes);
    try testing.expectEqualStrings("alice", r.user_name);
    try testing.expectEqualStrings("", r.secret);
    try testing.expectEqual(@as(i32, 5), r.count);
    try testing.expectEqual(@as(?[]const u8, null), r.email);
}

test "options: internal tagged union roundtrip msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: InternalTagged = .{ .result = .{ .rows = 42 } };
    const bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(InternalTagged, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 42), r.result.rows);
}

test "options: adjacent tagged union roundtrip msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v: AdjacentTagged = .{ .stop = 99 };
    const bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(AdjacentTagged, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 99), r.stop);
}

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

test "options: rename_serialize writes new name, deserialize reads original" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const User = struct {
        user_id: u64,
        name: []const u8,
        pub const serde = .{
            .rename_serialize = .{ .user_id = "id" },
        };
    };
    const v = User{ .user_id = 42, .name = "Alice" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"user_id\"") == null);
    const r = try sz.json.fromSlice(User, arena.allocator(),
        \\{"user_id":42,"name":"Alice"}
    );
    try testing.expectEqual(@as(u64, 42), r.user_id);
}

test "options: rename_deserialize accepts alternative name on input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct {
        endpoint: []const u8,
        pub const serde = .{
            .rename_deserialize = .{ .endpoint = "url" },
        };
    };
    const v = Config{ .endpoint = "https://api.test" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"endpoint\"") != null);
    const r = try sz.json.fromSlice(Config, arena.allocator(),
        \\{"url":"https://api.test"}
    );
    try testing.expectEqualStrings("https://api.test", r.endpoint);
}

test "options: asymmetric rename_serialize + rename_deserialize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Item = struct {
        name: []const u8,
        pub const serde = .{
            .rename_serialize = .{ .name = "title" },
            .rename_deserialize = .{ .name = "label" },
        };
    };
    const v = Item{ .name = "Widget" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"title\"") != null);
    const r = try sz.json.fromSlice(Item, arena.allocator(),
        \\{"label":"Widget"}
    );
    try testing.expectEqualStrings("Widget", r.name);
}

test "options: rename_all_serialize vs rename_all_deserialize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Rec = struct {
        first_name: []const u8,
        last_name: []const u8,
        pub const serde = .{
            .rename_all_serialize = sz.NamingConvention.camel_case,
            .rename_all_deserialize = sz.NamingConvention.kebab_case,
        };
    };
    const v = Rec{ .first_name = "John", .last_name = "Doe" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "firstName") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "lastName") != null);
    const r = try sz.json.fromSlice(Rec, arena.allocator(),
        \\{"first-name":"John","last-name":"Doe"}
    );
    try testing.expectEqualStrings("John", r.first_name);
    try testing.expectEqualStrings("Doe", r.last_name);
}

test "options: alias accepts alternative field names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct {
        endpoint: []const u8,
        pub const serde = .{
            .alias = .{ .endpoint = &.{ "url", "uri" } },
        };
    };
    const r1 = try sz.json.fromSlice(Config, arena.allocator(),
        \\{"endpoint":"https://a.com"}
    );
    try testing.expectEqualStrings("https://a.com", r1.endpoint);
    const r2 = try sz.json.fromSlice(Config, arena.allocator(),
        \\{"url":"https://b.com"}
    );
    try testing.expectEqualStrings("https://b.com", r2.endpoint);
    const r3 = try sz.json.fromSlice(Config, arena.allocator(),
        \\{"uri":"https://c.com"}
    );
    try testing.expectEqualStrings("https://c.com", r3.endpoint);
    const v = Config{ .endpoint = "https://d.com" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"endpoint\"") != null);
}

test "options: alias with rename — accepts renamed name plus aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const User = struct {
        user_id: u64,
        pub const serde = .{
            .rename = .{ .user_id = "id" },
            .alias = .{ .user_id = &.{ "user_id", "userId", "uid" } },
        };
    };
    const r1 = try sz.json.fromSlice(User, arena.allocator(), "{\"id\":1}");
    try testing.expectEqual(@as(u64, 1), r1.user_id);
    const r2 = try sz.json.fromSlice(User, arena.allocator(), "{\"user_id\":2}");
    try testing.expectEqual(@as(u64, 2), r2.user_id);
    const r3 = try sz.json.fromSlice(User, arena.allocator(), "{\"userId\":3}");
    try testing.expectEqual(@as(u64, 3), r3.user_id);
    const r4 = try sz.json.fromSlice(User, arena.allocator(), "{\"uid\":4}");
    try testing.expectEqual(@as(u64, 4), r4.user_id);
}

test "options: rolling upgrade scenario — old and new clients" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const User = struct {
        user_id: u64,
        name: []const u8,
        pub const serde = .{
            .rename_serialize = .{ .user_id = "id" },
            .rename_deserialize = .{ .user_id = "id" },
            .alias = .{ .user_id = &.{ "user_id", "userId" } },
        };
    };
    const v = User{ .user_id = 42, .name = "Alice" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"id\"") != null);
    const r1 = try sz.json.fromSlice(User, arena.allocator(),
        \\{"id":42,"name":"Alice"}
    );
    try testing.expectEqual(@as(u64, 42), r1.user_id);
    const r2 = try sz.json.fromSlice(User, arena.allocator(),
        \\{"user_id":42,"name":"Alice"}
    );
    try testing.expectEqual(@as(u64, 42), r2.user_id);
    const r3 = try sz.json.fromSlice(User, arena.allocator(),
        \\{"userId":42,"name":"Alice"}
    );
    try testing.expectEqual(@as(u64, 42), r3.user_id);
}

test "options: schema-level alias override" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Point = struct { x: i32, y: i32 };
    const schema = .{
        .rename = .{ .x = "X", .y = "Y" },
        .alias = .{ .x = &.{"horizontal"}, .y = &.{"vertical"} },
    };
    const r = try sz.json.fromSliceSchema(Point, arena.allocator(),
        \\{"horizontal":10,"vertical":20}
    , schema);
    try testing.expectEqual(@as(i32, 10), r.x);
    try testing.expectEqual(@as(i32, 20), r.y);
}

test "options: schema-level asymmetric rename_all" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Rec = struct { max_retries: i32, base_url: []const u8 };
    const schema = .{
        .rename_all_serialize = sz.NamingConvention.pascal_case,
        .rename_all_deserialize = sz.NamingConvention.camel_case,
    };
    const v = Rec{ .max_retries = 3, .base_url = "http://x" };
    const bytes = try sz.json.toSliceSchema(arena.allocator(), v, schema);
    try testing.expect(std.mem.indexOf(u8, bytes, "MaxRetries") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "BaseUrl") != null);
    const r = try sz.json.fromSliceSchema(Rec, arena.allocator(),
        \\{"maxRetries":3,"baseUrl":"http://x"}
    , schema);
    try testing.expectEqual(@as(i32, 3), r.max_retries);
    try testing.expectEqualStrings("http://x", r.base_url);
}

test "options: alias with deny_unknown_fields — alias is not unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Strict = struct {
        endpoint: []const u8,
        pub const serde = .{
            .deny_unknown_fields = true,
            .alias = .{ .endpoint = &.{"url"} },
        };
    };
    const r = try sz.json.fromSlice(Strict, arena.allocator(),
        \\{"url":"https://test.com"}
    );
    try testing.expectEqualStrings("https://test.com", r.endpoint);
    const err = sz.json.fromSlice(Strict, arena.allocator(),
        \\{"endpoint":"ok","bogus":1}
    );
    try testing.expectError(error.UnknownField, err);
}

test "options: internal tagged union variant rename serialize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Command = union(enum) {
        ping: void,
        execute: struct { query: []const u8 },
        pub const serde = .{
            .tag = sz.UnionTag.internal,
            .tag_field = "type",
            .rename = .{ .execute = "exec" },
        };
    };
    const v: Command = .{ .execute = .{ .query = "SELECT 1" } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"exec\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"execute\"") == null);
}

test "options: internal tagged union variant rename roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Command = union(enum) {
        ping: void,
        execute: struct { query: []const u8 },
        pub const serde = .{
            .tag = sz.UnionTag.internal,
            .tag_field = "type",
            .rename = .{ .execute = "exec" },
        };
    };
    const v: Command = .{ .execute = .{ .query = "SELECT 1" } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    const r = try sz.json.fromSlice(Command, arena.allocator(), bytes);
    try testing.expectEqualStrings("SELECT 1", r.execute.query);
}

test "options: internal tagged union variant alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Command = union(enum) {
        ping: void,
        execute: struct { query: []const u8 },
        pub const serde = .{
            .tag = sz.UnionTag.internal,
            .tag_field = "type",
            .rename = .{ .execute = "exec" },
            .alias = .{ .execute = &.{ "execute", "run" } },
        };
    };
    const r1 = try sz.json.fromSlice(Command, arena.allocator(),
        \\{"type":"exec","query":"Q1"}
    );
    try testing.expectEqualStrings("Q1", r1.execute.query);
    const r2 = try sz.json.fromSlice(Command, arena.allocator(),
        \\{"type":"execute","query":"Q2"}
    );
    try testing.expectEqualStrings("Q2", r2.execute.query);
    const r3 = try sz.json.fromSlice(Command, arena.allocator(),
        \\{"type":"run","query":"Q3"}
    );
    try testing.expectEqualStrings("Q3", r3.execute.query);
}

test "options: adjacent tagged union variant rename roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Event = union(enum) {
        start: void,
        data: struct { payload: []const u8 },
        pub const serde = .{
            .tag = sz.UnionTag.adjacent,
            .tag_field = "kind",
            .content_field = "value",
            .rename = .{ .data = "d" },
        };
    };
    const v: Event = .{ .data = .{ .payload = "hello" } };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"d\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"data\"") == null);
    const r = try sz.json.fromSlice(Event, arena.allocator(), bytes);
    try testing.expectEqualStrings("hello", r.data.payload);
}

test "options: adjacent tagged void variant rename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Event = union(enum) {
        start: void,
        stop: void,
        pub const serde = .{
            .tag = sz.UnionTag.adjacent,
            .tag_field = "kind",
            .content_field = "value",
            .rename = .{ .start = "begin" },
        };
    };
    const v: Event = .start;
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"begin\"") != null);
    const r = try sz.json.fromSlice(Event, arena.allocator(), bytes);
    try testing.expectEqual(Event.start, r);
}

test "options: external tagged union variant rename serialize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cmd = union(enum) {
        ping: void,
        set: i32,
        pub const serde = .{
            .rename = .{ .set = "SET" },
        };
    };
    const bytes1 = try sz.json.toSlice(arena.allocator(), Cmd.ping);
    try testing.expectEqualStrings("\"ping\"", bytes1);
    const v2 = Cmd{ .set = 42 };
    const bytes2 = try sz.json.toSlice(arena.allocator(), v2);
    try testing.expect(std.mem.indexOf(u8, bytes2, "\"SET\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes2, "\"set\"") == null);
}

test "options: external tagged union variant rename roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cmd = union(enum) {
        ping: void,
        set: i32,
        pub const serde = .{
            .rename = .{ .ping = "PING", .set = "SET" },
        };
    };
    // workaround: Zig 0.15 codegen bug misresolves comptime strings in
    // inline-for over union fields when called via toSlice→serialize chain.
    // toSliceSchema with empty schema (.{}) avoids the extra indirection.
    const bytes1 = try sz.json.toSliceSchema(arena.allocator(), @as(Cmd, .ping), .{});
    try testing.expectEqualStrings("\"PING\"", bytes1);
    const r1 = try sz.json.fromSliceSchema(Cmd, arena.allocator(), bytes1, .{});
    try testing.expectEqual(Cmd.ping, r1);
    const v2 = Cmd{ .set = 42 };
    const bytes2 = try sz.json.toSliceSchema(arena.allocator(), v2, .{});
    const r2 = try sz.json.fromSliceSchema(Cmd, arena.allocator(), bytes2, .{});
    try testing.expectEqual(@as(i32, 42), r2.set);
}

test "options: external tagged union variant alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Cmd = union(enum) {
        ping: void,
        set: i32,
        pub const serde = .{
            .rename = .{ .set = "SET" },
            .alias = .{ .set = &.{ "set", "assign" } },
        };
    };
    const r1 = try sz.json.fromSlice(Cmd, arena.allocator(),
        \\{"SET":42}
    );
    try testing.expectEqual(@as(i32, 42), r1.set);
    const r2 = try sz.json.fromSlice(Cmd, arena.allocator(),
        \\{"set":99}
    );
    try testing.expectEqual(@as(i32, 99), r2.set);
    const r3 = try sz.json.fromSlice(Cmd, arena.allocator(),
        \\{"assign":7}
    );
    try testing.expectEqual(@as(i32, 7), r3.set);
}

test "options: enum rename serialize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Status = enum {
        active,
        inactive,
        pending,
        pub const serde = .{
            .rename = .{ .active = "ACTIVE", .inactive = "INACTIVE", .pending = "PENDING" },
        };
    };
    const bytes = try sz.json.toSlice(arena.allocator(), Status.active);
    try testing.expectEqualStrings("\"ACTIVE\"", bytes);
    const bytes2 = try sz.json.toSlice(arena.allocator(), Status.pending);
    try testing.expectEqualStrings("\"PENDING\"", bytes2);
}

test "options: enum rename roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Status = enum {
        active,
        inactive,
        pub const serde = .{
            .rename = .{ .active = "ACTIVE", .inactive = "INACTIVE" },
        };
    };
    const bytes = try sz.json.toSlice(arena.allocator(), Status.inactive);
    try testing.expectEqualStrings("\"INACTIVE\"", bytes);
    const r = try sz.json.fromSlice(Status, arena.allocator(), bytes);
    try testing.expectEqual(Status.inactive, r);
}

test "options: enum alias accepts alternative names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Color = enum {
        red,
        green,
        blue,
        pub const serde = .{
            .alias = .{ .red = &.{ "RED", "r" }, .green = &.{ "GREEN", "g" } },
        };
    };
    const r1 = try sz.json.fromSlice(Color, arena.allocator(), "\"red\"");
    try testing.expectEqual(Color.red, r1);
    const r2 = try sz.json.fromSlice(Color, arena.allocator(), "\"RED\"");
    try testing.expectEqual(Color.red, r2);
    const r3 = try sz.json.fromSlice(Color, arena.allocator(), "\"g\"");
    try testing.expectEqual(Color.green, r3);
    const r4 = try sz.json.fromSlice(Color, arena.allocator(), "\"blue\"");
    try testing.expectEqual(Color.blue, r4);
}

test "options: enum rename_all_serialize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Action = enum {
        create_user,
        delete_user,
        pub const serde = .{
            .rename_all_serialize = sz.NamingConvention.SCREAMING_SNAKE_CASE,
        };
    };
    const bytes = try sz.json.toSlice(arena.allocator(), Action.create_user);
    try testing.expectEqualStrings("\"CREATE_USER\"", bytes);
}

test "options: union variant rename_all_serialize" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Command = union(enum) {
        create_item: struct { name: []const u8 },
        delete_item: void,
        pub const serde = .{
            .tag = sz.UnionTag.internal,
            .tag_field = "action",
            .rename_all_serialize = sz.NamingConvention.camel_case,
        };
    };
    const v: Command = .delete_item;
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"deleteItem\"") != null);
}

test "options: asymmetric rename roundtrip msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const User = struct {
        user_id: u64,
        name: []const u8,
        pub const serde = .{
            .rename_serialize = .{ .user_id = "id" },
            .alias = .{ .user_id = &.{"id"} },
        };
    };
    const v = User{ .user_id = 42, .name = "Alice" };
    const mp_bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(User, arena.allocator(), mp_bytes);
    try testing.expectEqual(@as(u64, 42), r.user_id);
    try testing.expectEqualStrings("Alice", r.name);
}

test "options: rename_all_serialize consistent across msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Rec = struct {
        first_name: []const u8,
        last_name: []const u8,
        pub const serde = .{
            .rename_all_serialize = sz.NamingConvention.camel_case,
            .rename_all_deserialize = sz.NamingConvention.camel_case,
        };
    };
    const v = Rec{ .first_name = "John", .last_name = "Doe" };
    const mp_bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(Rec, arena.allocator(), mp_bytes);
    try testing.expectEqualStrings("John", r.first_name);
    try testing.expectEqualStrings("Doe", r.last_name);
}

test "options: alias roundtrip TOML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct {
        endpoint: []const u8,
        pub const serde = .{
            .alias = .{ .endpoint = &.{"url"} },
        };
    };
    const v = Config{ .endpoint = "https://api.test" };
    const toml_bytes = try sz.toml.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, toml_bytes, "endpoint") != null);
    const r = try sz.toml.fromSlice(Config, arena.allocator(), toml_bytes);
    try testing.expectEqualStrings("https://api.test", r.endpoint);
}

test "options: alias roundtrip YAML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct {
        endpoint: []const u8,
        pub const serde = .{
            .alias = .{ .endpoint = &.{"url"} },
        };
    };
    const v = Config{ .endpoint = "https://api.test" };
    const yaml_bytes = try sz.yaml.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, yaml_bytes, "endpoint") != null);
    const r = try sz.yaml.fromSlice(Config, arena.allocator(), yaml_bytes);
    try testing.expectEqualStrings("https://api.test", r.endpoint);
}

test "options: internal tagged union variant rename roundtrip msgpack" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Command = union(enum) {
        ping: void,
        execute: struct { query: []const u8 },
        pub const serde = .{
            .tag = sz.UnionTag.internal,
            .tag_field = "type",
            .rename = .{ .execute = "exec" },
        };
    };
    const v: Command = .{ .execute = .{ .query = "SELECT 1" } };
    const mp_bytes = try sz.msgpack.toSlice(arena.allocator(), v);
    const r = try sz.msgpack.fromSlice(Command, arena.allocator(), mp_bytes);
    try testing.expectEqualStrings("SELECT 1", r.execute.query);
}

test "options: rename_all + per-field rename_serialize + alias combined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ApiResponse = struct {
        user_id: u64,
        first_name: []const u8,
        last_name: []const u8,
        pub const serde = .{
            .rename_all_serialize = sz.NamingConvention.camel_case,
            .rename_serialize = .{ .user_id = "id" },
            .alias = .{ .user_id = &.{ "user_id", "userId", "uid" } },
        };
    };
    const v = ApiResponse{ .user_id = 42, .first_name = "Alice", .last_name = "Smith" };
    const bytes = try sz.json.toSlice(arena.allocator(), v);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"firstName\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"lastName\"") != null);

    const r1 = try sz.json.fromSlice(ApiResponse, arena.allocator(),
        \\{"user_id":1,"first_name":"A","last_name":"B"}
    );
    try testing.expectEqual(@as(u64, 1), r1.user_id);

    const r2 = try sz.json.fromSlice(ApiResponse, arena.allocator(),
        \\{"userId":2,"first_name":"C","last_name":"D"}
    );
    try testing.expectEqual(@as(u64, 2), r2.user_id);

    const r3 = try sz.json.fromSlice(ApiResponse, arena.allocator(),
        \\{"uid":3,"first_name":"E","last_name":"F"}
    );
    try testing.expectEqual(@as(u64, 3), r3.user_id);
}

test "options: flatten + alias combined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Metadata = struct {
        created_by: []const u8,
        version: i32 = 1,
        pub const serde = .{
            .alias = .{ .created_by = &.{ "author", "creator" } },
        };
    };
    const Record = struct {
        name: []const u8,
        meta: Metadata,
        pub const serde = .{ .flatten = &[_][]const u8{"meta"} };
    };
    // Flatten puts "created_by" at top level; alias "author" should work
    const r = try sz.json.fromSlice(Record, arena.allocator(),
        \\{"name":"test","author":"admin","version":2}
    );
    try testing.expectEqualStrings("test", r.name);
    try testing.expectEqualStrings("admin", r.meta.created_by);
    try testing.expectEqual(@as(i32, 2), r.meta.version);
}

test "options: enum rename_all + alias combined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Status = enum {
        active,
        in_review,
        archived,
        pub const serde = .{
            .rename_all_serialize = sz.NamingConvention.SCREAMING_SNAKE_CASE,
            .rename_all_deserialize = sz.NamingConvention.SCREAMING_SNAKE_CASE,
            .alias = .{ .in_review = &.{ "in_review", "pending_review" } },
        };
    };
    // Serialize as SCREAMING_SNAKE_CASE
    const bytes = try sz.json.toSlice(arena.allocator(), Status.in_review);
    try testing.expectEqualStrings("\"IN_REVIEW\"", bytes);
    // Deserialize from SCREAMING_SNAKE_CASE
    const r1 = try sz.json.fromSlice(Status, arena.allocator(), "\"IN_REVIEW\"");
    try testing.expectEqual(Status.in_review, r1);
    // Deserialize from alias
    const r2 = try sz.json.fromSlice(Status, arena.allocator(), "\"pending_review\"");
    try testing.expectEqual(Status.in_review, r2);
}
