const std = @import("std");
const rename_mod = @import("../helpers/rename.zig");

pub const NamingConvention = rename_mod.NamingConvention;
pub const convertCase = rename_mod.convertCase;

pub const SkipMode = enum {
    always,
    null,
    empty,
};

pub const EnumRepr = enum {
    string,
    integer,
};

pub const UnionTag = enum {
    external,
    internal,
    adjacent,
    untagged,
};

pub const Direction = enum {
    serialize,
    deserialize,
};

pub fn hasSerdeOptions(comptime T: type) bool {
    return @hasDecl(T, "serde");
}

fn hasFieldOrDecl(comptime S: type, comptime name: []const u8) bool {
    return @hasDecl(S, name) or @hasField(S, name);
}

// Priority: schema > T.serde. Void schema ({}) means no schema.

pub fn wireFieldName(comptime T: type, comptime field_name: []const u8) []const u8 {
    return wireFieldNameSchema(T, field_name, {});
}

pub fn wireFieldNameSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) []const u8 {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "rename")) {
            const renames = schema.rename;
            if (@hasField(@TypeOf(renames), field_name))
                return @field(renames, field_name);
        }
        if (@hasField(S, "rename_all"))
            return convertCase(field_name, schema.rename_all);
    }
    if (hasSerdeOptions(T)) {
        const opts = T.serde;
        if (hasFieldOrDecl(@TypeOf(opts), "rename")) {
            const renames = opts.rename;
            if (@hasField(@TypeOf(renames), field_name))
                return @field(renames, field_name);
        }
        if (hasFieldOrDecl(@TypeOf(opts), "rename_all"))
            return convertCase(field_name, opts.rename_all);
    }
    return field_name;
}

/// Like wireFieldNameSchema, but checks direction-specific options first
/// (e.g. rename_serialize) before falling through to symmetric ones.
pub fn wireFieldNameForDir(comptime T: type, comptime field_name: []const u8, comptime schema: anytype, comptime dir: Direction) []const u8 {
    const dir_rename = if (dir == .serialize) "rename_serialize" else "rename_deserialize";
    const dir_all = if (dir == .serialize) "rename_all_serialize" else "rename_all_deserialize";

    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, dir_rename)) {
            const renames = @field(schema, dir_rename);
            if (@hasField(@TypeOf(renames), field_name))
                return @field(renames, field_name);
        }
        if (@hasField(S, "rename")) {
            if (@hasField(@TypeOf(schema.rename), field_name))
                return @field(schema.rename, field_name);
        }
        if (@hasField(S, dir_all))
            return convertCase(field_name, @field(schema, dir_all));
        if (@hasField(S, "rename_all"))
            return convertCase(field_name, schema.rename_all);
    }

    if (hasSerdeOptions(T)) {
        const o = T.serde;
        if (hasFieldOrDecl(@TypeOf(o), dir_rename)) {
            const renames = @field(o, dir_rename);
            if (@hasField(@TypeOf(renames), field_name))
                return @field(renames, field_name);
        }
        if (hasFieldOrDecl(@TypeOf(o), "rename")) {
            if (@hasField(@TypeOf(o.rename), field_name))
                return @field(o.rename, field_name);
        }
        if (hasFieldOrDecl(@TypeOf(o), dir_all))
            return convertCase(field_name, @field(o, dir_all));
        if (hasFieldOrDecl(@TypeOf(o), "rename_all"))
            return convertCase(field_name, o.rename_all);
    }

    return field_name;
}

pub fn getFieldAliases(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) []const []const u8 {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "alias")) {
            if (@hasField(@TypeOf(schema.alias), field_name))
                return @field(schema.alias, field_name);
        }
    }
    if (hasSerdeOptions(T)) {
        const o = T.serde;
        if (hasFieldOrDecl(@TypeOf(o), "alias")) {
            if (@hasField(@TypeOf(o.alias), field_name))
                return @field(o.alias, field_name);
        }
    }
    return &.{};
}

/// True if key equals the deserialized wire name or any alias for this field.
pub fn matchesDeserializeName(comptime T: type, comptime field_name: []const u8, key: []const u8, comptime schema: anytype) bool {
    const primary = comptime wireFieldNameForDir(T, field_name, schema, .deserialize);
    if (std.mem.eql(u8, key, primary)) return true;
    const aliases = comptime getFieldAliases(T, field_name, schema);
    inline for (aliases) |a| {
        if (std.mem.eql(u8, key, a)) return true;
    }
    return false;
}

/// True if any rename or alias option exists on T or the schema.
pub fn hasNameOverrides(comptime T: type, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "rename") or @hasField(S, "rename_serialize") or
            @hasField(S, "rename_deserialize") or @hasField(S, "rename_all") or
            @hasField(S, "rename_all_serialize") or @hasField(S, "rename_all_deserialize") or
            @hasField(S, "alias")) return true;
    }
    if (hasSerdeOptions(T)) {
        const O = @TypeOf(T.serde);
        if (hasFieldOrDecl(O, "rename") or hasFieldOrDecl(O, "rename_serialize") or
            hasFieldOrDecl(O, "rename_deserialize") or hasFieldOrDecl(O, "rename_all") or
            hasFieldOrDecl(O, "rename_all_serialize") or hasFieldOrDecl(O, "rename_all_deserialize") or
            hasFieldOrDecl(O, "alias")) return true;
    }
    return false;
}

pub fn shouldSkipField(comptime T: type, comptime field_name: []const u8, comptime dir: Direction) bool {
    return shouldSkipFieldSchema(T, field_name, dir, {});
}

pub fn shouldSkipFieldSchema(comptime T: type, comptime field_name: []const u8, comptime _: Direction, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "skip")) {
            const skip = schema.skip;
            if (@hasField(@TypeOf(skip), field_name))
                return @field(skip, field_name) == .always;
        }
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "skip")) return false;
    const skip = opts.skip;
    if (!@hasField(@TypeOf(skip), field_name)) return false;
    return @field(skip, field_name) == .always;
}

pub fn isSkipIfNull(comptime T: type, comptime field_name: []const u8) bool {
    return isSkipIfNullSchema(T, field_name, {});
}

pub fn isSkipIfNullSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "skip")) {
            const skip = schema.skip;
            if (@hasField(@TypeOf(skip), field_name))
                return @field(skip, field_name) == .null;
        }
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "skip")) return false;
    const skip = opts.skip;
    if (!@hasField(@TypeOf(skip), field_name)) return false;
    return @field(skip, field_name) == .null;
}

pub fn isSkipIfEmpty(comptime T: type, comptime field_name: []const u8) bool {
    return isSkipIfEmptySchema(T, field_name, {});
}

pub fn isSkipIfEmptySchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "skip")) {
            const skip = schema.skip;
            if (@hasField(@TypeOf(skip), field_name))
                return @field(skip, field_name) == .empty;
        }
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "skip")) return false;
    const skip = opts.skip;
    if (!@hasField(@TypeOf(skip), field_name)) return false;
    return @field(skip, field_name) == .empty;
}

pub fn hasCustomSerializer(comptime T: type) bool {
    return hasDeclSafe(T, "zerdeSerialize");
}

pub fn hasCustomDeserializer(comptime T: type) bool {
    return hasDeclSafe(T, "zerdeDeserialize");
}

fn hasDeclSafe(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

pub fn countSerializableFields(comptime T: type) usize {
    return countSerializableFieldsSchema(T, {});
}

pub fn countSerializableFieldsSchema(comptime T: type, comptime schema: anytype) usize {
    const info = @typeInfo(T).@"struct";
    var count: usize = 0;
    for (info.fields) |field| {
        if (!shouldSkipFieldSchema(T, field.name, .serialize, schema))
            count += 1;
    }
    return count;
}

pub fn denyUnknownFields(comptime T: type) bool {
    return denyUnknownFieldsSchema(T, {});
}

pub fn denyUnknownFieldsSchema(comptime T: type, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "deny_unknown_fields"))
            return schema.deny_unknown_fields;
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (hasFieldOrDecl(@TypeOf(opts), "deny_unknown_fields"))
        return opts.deny_unknown_fields;
    return false;
}

pub fn hasSerdeDefault(comptime T: type, comptime field_name: []const u8) bool {
    return hasSerdeDefaultSchema(T, field_name, {});
}

pub fn hasSerdeDefaultSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "default")) {
            if (@hasField(@TypeOf(schema.default), field_name))
                return true;
        }
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "default")) return false;
    return @hasField(@TypeOf(opts.default), field_name);
}

pub fn getSerdeDefault(comptime T: type, comptime field_name: []const u8) @TypeOf(@field(@as(T, undefined), field_name)) {
    return getSerdeDefaultSchema(T, field_name, {});
}

pub fn getSerdeDefaultSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) @TypeOf(@field(@as(T, undefined), field_name)) {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "default")) {
            if (@hasField(@TypeOf(schema.default), field_name))
                return @field(schema.default, field_name);
        }
    }
    return @field(T.serde.default, field_name);
}

pub fn getEnumRepr(comptime T: type) EnumRepr {
    return getEnumReprSchema(T, {});
}

pub fn getEnumReprSchema(comptime T: type, comptime schema: anytype) EnumRepr {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "enum_repr"))
            return schema.enum_repr;
    }
    if (!hasSerdeOptions(T)) return .string;
    const opts = T.serde;
    if (hasFieldOrDecl(@TypeOf(opts), "enum_repr"))
        return opts.enum_repr;
    return .string;
}

pub fn getUnionTag(comptime T: type) UnionTag {
    return getUnionTagSchema(T, {});
}

pub fn getUnionTagSchema(comptime T: type, comptime schema: anytype) UnionTag {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "tag"))
            return schema.tag;
    }
    if (!hasSerdeOptions(T)) return .external;
    const opts = T.serde;
    if (hasFieldOrDecl(@TypeOf(opts), "tag"))
        return opts.tag;
    return .external;
}

pub fn getTagField(comptime T: type) []const u8 {
    return getTagFieldSchema(T, {});
}

pub fn getTagFieldSchema(comptime T: type, comptime schema: anytype) []const u8 {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "tag_field"))
            return schema.tag_field;
    }
    if (hasSerdeOptions(T)) {
        const opts = T.serde;
        if (hasFieldOrDecl(@TypeOf(opts), "tag_field"))
            return opts.tag_field;
    }
    return "type";
}

pub fn getContentField(comptime T: type) []const u8 {
    return getContentFieldSchema(T, {});
}

pub fn getContentFieldSchema(comptime T: type, comptime schema: anytype) []const u8 {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "content_field"))
            return schema.content_field;
    }
    if (hasSerdeOptions(T)) {
        const opts = T.serde;
        if (hasFieldOrDecl(@TypeOf(opts), "content_field"))
            return opts.content_field;
    }
    return "content";
}

pub fn isFlattenedField(comptime T: type, comptime field_name: []const u8) bool {
    return isFlattenedFieldSchema(T, field_name, {});
}

pub fn isFlattenedFieldSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "flatten")) {
            const flatten = schema.flatten;
            for (flatten) |f| {
                if (std.mem.eql(u8, f, field_name)) return true;
            }
            return false;
        }
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "flatten")) return false;
    const flatten = opts.flatten;
    for (flatten) |f| {
        if (std.mem.eql(u8, f, field_name)) return true;
    }
    return false;
}

pub fn getFlattenFields(comptime T: type) []const []const u8 {
    return getFlattenFieldsSchema(T, {});
}

pub fn getFlattenFieldsSchema(comptime T: type, comptime schema: anytype) []const []const u8 {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "flatten"))
            return schema.flatten;
    }
    if (!hasSerdeOptions(T)) return &.{};
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "flatten")) return &.{};
    return opts.flatten;
}

pub fn hasFieldWith(comptime T: type, comptime field_name: []const u8) bool {
    return hasFieldWithSchema(T, field_name, {});
}

pub fn hasFieldWithSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "with")) {
            if (@hasField(@TypeOf(schema.with), field_name))
                return true;
        }
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "with")) return false;
    return @hasField(@TypeOf(opts.with), field_name);
}

pub fn getFieldWith(comptime T: type, comptime field_name: []const u8) type {
    return getFieldWithSchema(T, field_name, {});
}

pub fn getFieldWithSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) type {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "with")) {
            if (@hasField(@TypeOf(schema.with), field_name))
                return @field(schema.with, field_name);
        }
    }
    return @field(T.serde.with, field_name);
}

const testing = std.testing;

test "wireFieldName with rename" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{
                .id = "user_id",
            },
        };
    };
    try testing.expectEqualStrings("user_id", comptime wireFieldName(User, "id"));
    try testing.expectEqualStrings("first_name", comptime wireFieldName(User, "first_name"));
}

test "wireFieldName with rename_all" {
    const Config = struct {
        max_retries: u32,
        base_url: []const u8,

        pub const serde = .{
            .rename_all = NamingConvention.camel_case,
        };
    };
    try testing.expectEqualStrings("maxRetries", comptime wireFieldName(Config, "max_retries"));
    try testing.expectEqualStrings("baseUrl", comptime wireFieldName(Config, "base_url"));
}

test "shouldSkipField" {
    const Secret = struct {
        name: []const u8,
        token: []const u8,

        pub const serde = .{
            .skip = .{
                .token = SkipMode.always,
            },
        };
    };
    try testing.expect(!comptime shouldSkipField(Secret, "name", .serialize));
    try testing.expect(comptime shouldSkipField(Secret, "token", .serialize));
}

test "isSkipIfNull" {
    const Partial = struct {
        required: u32,
        optional_val: ?u32,

        pub const serde = .{
            .skip = .{
                .optional_val = SkipMode.null,
            },
        };
    };
    try testing.expect(!comptime isSkipIfNull(Partial, "required"));
    try testing.expect(comptime isSkipIfNull(Partial, "optional_val"));
}

test "countSerializableFields" {
    const Mix = struct {
        a: u32,
        b: u32,
        c: u32,

        pub const serde = .{
            .skip = .{
                .b = SkipMode.always,
            },
        };
    };
    try testing.expectEqual(2, comptime countSerializableFields(Mix));
}

test "denyUnknownFields" {
    const Strict = struct {
        x: u32,
        pub const serde = .{
            .deny_unknown_fields = true,
        };
    };
    const Loose = struct { x: u32 };
    try testing.expect(comptime denyUnknownFields(Strict));
    try testing.expect(!comptime denyUnknownFields(Loose));
}

test "no serde options" {
    const Plain = struct { x: u32, y: u32 };
    try testing.expectEqualStrings("x", comptime wireFieldName(Plain, "x"));
    try testing.expect(!comptime shouldSkipField(Plain, "x", .serialize));
    try testing.expect(!comptime denyUnknownFields(Plain));
    try testing.expectEqual(2, comptime countSerializableFields(Plain));
}

test "schema wireFieldName overrides T.serde" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
        };
    };
    const schema = .{ .rename = .{ .id = "ID" } };
    try testing.expectEqualStrings("ID", comptime wireFieldNameSchema(User, "id", schema));
    // Not in schema.rename, not in T.serde.rename → identity.
    try testing.expectEqualStrings("first_name", comptime wireFieldNameSchema(User, "first_name", schema));
}

test "schema rename_all" {
    const Plain = struct { max_retries: u32, base_url: []const u8 };
    const schema = .{ .rename_all = NamingConvention.camel_case };
    try testing.expectEqualStrings("maxRetries", comptime wireFieldNameSchema(Plain, "max_retries", schema));
    try testing.expectEqualStrings("baseUrl", comptime wireFieldNameSchema(Plain, "base_url", schema));
}

test "schema skip overrides T.serde" {
    const S = struct {
        a: u32,
        b: u32,
        c: u32,

        pub const serde = .{
            .skip = .{ .b = SkipMode.always },
        };
    };
    const schema = .{ .skip = .{ .a = SkipMode.always } };
    try testing.expect(comptime shouldSkipFieldSchema(S, "a", .serialize, schema));
    // 'b' not in schema, but T.serde.skip still applies.
    try testing.expect(comptime shouldSkipFieldSchema(S, "b", .serialize, schema));
    try testing.expect(!comptime shouldSkipFieldSchema(S, "c", .serialize, schema));
}

test "schema deny_unknown_fields" {
    const Plain = struct { x: u32 };
    const schema = .{ .deny_unknown_fields = true };
    try testing.expect(comptime denyUnknownFieldsSchema(Plain, schema));
    try testing.expect(!comptime denyUnknownFieldsSchema(Plain, {}));
}

test "empty schema matches original behavior" {
    const User = struct {
        id: u64,
        first_name: []const u8,

        pub const serde = .{
            .rename = .{ .id = "user_id" },
            .rename_all = NamingConvention.camel_case,
        };
    };
    try testing.expectEqualStrings("user_id", comptime wireFieldNameSchema(User, "id", {}));
    try testing.expectEqualStrings("firstName", comptime wireFieldNameSchema(User, "first_name", {}));
}

test "schema on plain type with no T.serde" {
    const Point = struct { x: f64, y: f64, z: f64 };
    const schema = .{
        .rename = .{ .x = "X", .y = "Y" },
        .skip = .{ .z = SkipMode.always },
    };
    try testing.expectEqualStrings("X", comptime wireFieldNameSchema(Point, "x", schema));
    try testing.expectEqualStrings("Y", comptime wireFieldNameSchema(Point, "y", schema));
    try testing.expect(comptime shouldSkipFieldSchema(Point, "z", .serialize, schema));
    try testing.expectEqual(@as(usize, 2), comptime countSerializableFieldsSchema(Point, schema));
}

test "wireFieldNameForDir: symmetric rename returns same for both directions" {
    const User = struct {
        id: u64,
        pub const serde = .{ .rename = .{ .id = "user_id" } };
    };
    try testing.expectEqualStrings("user_id", comptime wireFieldNameForDir(User, "id", {}, .serialize));
    try testing.expectEqualStrings("user_id", comptime wireFieldNameForDir(User, "id", {}, .deserialize));
}

test "wireFieldNameForDir: rename_serialize only affects serialize" {
    const User = struct {
        user_id: u64,
        pub const serde = .{
            .rename_serialize = .{ .user_id = "id" },
        };
    };
    try testing.expectEqualStrings("id", comptime wireFieldNameForDir(User, "user_id", {}, .serialize));
    try testing.expectEqualStrings("user_id", comptime wireFieldNameForDir(User, "user_id", {}, .deserialize));
}

test "wireFieldNameForDir: rename_deserialize only affects deserialize" {
    const Config = struct {
        endpoint: []const u8,
        pub const serde = .{
            .rename_deserialize = .{ .endpoint = "url" },
        };
    };
    try testing.expectEqualStrings("endpoint", comptime wireFieldNameForDir(Config, "endpoint", {}, .serialize));
    try testing.expectEqualStrings("url", comptime wireFieldNameForDir(Config, "endpoint", {}, .deserialize));
}

test "wireFieldNameForDir: dir-specific overrides symmetric rename" {
    const Item = struct {
        name: []const u8,
        pub const serde = .{
            .rename = .{ .name = "title" },
            .rename_serialize = .{ .name = "label" },
        };
    };
    try testing.expectEqualStrings("label", comptime wireFieldNameForDir(Item, "name", {}, .serialize));
    try testing.expectEqualStrings("title", comptime wireFieldNameForDir(Item, "name", {}, .deserialize));
}

test "wireFieldNameForDir: rename_all_serialize / rename_all_deserialize" {
    const Rec = struct {
        first_name: []const u8,
        pub const serde = .{
            .rename_all_serialize = NamingConvention.camel_case,
            .rename_all_deserialize = NamingConvention.kebab_case,
        };
    };
    try testing.expectEqualStrings("firstName", comptime wireFieldNameForDir(Rec, "first_name", {}, .serialize));
    try testing.expectEqualStrings("first-name", comptime wireFieldNameForDir(Rec, "first_name", {}, .deserialize));
}

test "wireFieldNameForDir: dir rename_all overrides symmetric rename_all" {
    const Rec = struct {
        max_retries: u32,
        pub const serde = .{
            .rename_all = NamingConvention.camel_case,
            .rename_all_deserialize = NamingConvention.kebab_case,
        };
    };
    try testing.expectEqualStrings("maxRetries", comptime wireFieldNameForDir(Rec, "max_retries", {}, .serialize));
    try testing.expectEqualStrings("max-retries", comptime wireFieldNameForDir(Rec, "max_retries", {}, .deserialize));
}

test "wireFieldNameForDir: per-field rename beats rename_all in same direction" {
    const Rec = struct {
        id: u64,
        first_name: []const u8,
        pub const serde = .{
            .rename_all_serialize = NamingConvention.camel_case,
            .rename_serialize = .{ .id = "ID" },
        };
    };
    try testing.expectEqualStrings("ID", comptime wireFieldNameForDir(Rec, "id", {}, .serialize));
    try testing.expectEqualStrings("firstName", comptime wireFieldNameForDir(Rec, "first_name", {}, .serialize));
}

test "wireFieldNameForDir: schema overrides T.serde" {
    const User = struct {
        id: u64,
        pub const serde = .{ .rename_serialize = .{ .id = "user_id" } };
    };
    const schema = .{ .rename_serialize = .{ .id = "ID" } };
    try testing.expectEqualStrings("ID", comptime wireFieldNameForDir(User, "id", schema, .serialize));
}

test "wireFieldNameForDir: works on union types" {
    const Cmd = union(enum) {
        ping: void,
        set: i32,
        pub const serde = .{
            .rename = .{ .ping = "PING", .set = "SET" },
        };
    };
    try testing.expectEqualStrings("PING", comptime wireFieldNameForDir(Cmd, "ping", {}, .serialize));
    try testing.expectEqualStrings("SET", comptime wireFieldNameForDir(Cmd, "set", {}, .serialize));
    try testing.expectEqualStrings("PING", comptime wireFieldNameForDir(Cmd, "ping", {}, .deserialize));
}

test "wireFieldNameForDir: no options returns identity" {
    const Plain = struct { x: u32 };
    try testing.expectEqualStrings("x", comptime wireFieldNameForDir(Plain, "x", {}, .serialize));
    try testing.expectEqualStrings("x", comptime wireFieldNameForDir(Plain, "x", {}, .deserialize));
}

test "getFieldAliases: no alias returns empty" {
    const Plain = struct { x: u32 };
    const aliases = comptime getFieldAliases(Plain, "x", {});
    try testing.expectEqual(@as(usize, 0), aliases.len);
}

test "getFieldAliases: T.serde alias" {
    const Config = struct {
        endpoint: []const u8,
        pub const serde = .{
            .alias = .{ .endpoint = &.{ "url", "uri" } },
        };
    };
    const aliases = comptime getFieldAliases(Config, "endpoint", {});
    try testing.expectEqual(@as(usize, 2), aliases.len);
    try testing.expectEqualStrings("url", aliases[0]);
    try testing.expectEqualStrings("uri", aliases[1]);
}

test "getFieldAliases: schema alias overrides T.serde" {
    const Config = struct {
        endpoint: []const u8,
        pub const serde = .{
            .alias = .{ .endpoint = &.{"url"} },
        };
    };
    const schema = .{ .alias = .{ .endpoint = &.{ "addr", "host" } } };
    const aliases = comptime getFieldAliases(Config, "endpoint", schema);
    try testing.expectEqual(@as(usize, 2), aliases.len);
    try testing.expectEqualStrings("addr", aliases[0]);
}

test "matchesDeserializeName: primary name matches" {
    const User = struct {
        id: u64,
        pub const serde = .{ .rename = .{ .id = "user_id" } };
    };
    try testing.expect(matchesDeserializeName(User, "id", "user_id", {}));
    try testing.expect(!matchesDeserializeName(User, "id", "id", {}));
}

test "matchesDeserializeName: alias matches" {
    const User = struct {
        user_id: u64,
        pub const serde = .{
            .rename_deserialize = .{ .user_id = "userId" },
            .alias = .{ .user_id = &.{ "user_id", "uid" } },
        };
    };
    try testing.expect(matchesDeserializeName(User, "user_id", "userId", {}));
    try testing.expect(matchesDeserializeName(User, "user_id", "user_id", {}));
    try testing.expect(matchesDeserializeName(User, "user_id", "uid", {}));
    try testing.expect(!matchesDeserializeName(User, "user_id", "ID", {}));
}

test "matchesDeserializeName: dir-specific deser name + alias" {
    const Rec = struct {
        name: []const u8,
        pub const serde = .{
            .rename_serialize = .{ .name = "title" },
            .rename_deserialize = .{ .name = "label" },
            .alias = .{ .name = &.{ "name", "n" } },
        };
    };
    try testing.expect(matchesDeserializeName(Rec, "name", "label", {}));
    try testing.expect(matchesDeserializeName(Rec, "name", "name", {}));
    try testing.expect(matchesDeserializeName(Rec, "name", "n", {}));
    // ser name must NOT match deser direction
    try testing.expect(!matchesDeserializeName(Rec, "name", "title", {}));
}
