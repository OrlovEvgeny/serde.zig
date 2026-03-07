const std = @import("std");
const rename_mod = @import("../helpers/rename.zig");

pub const NamingConvention = rename_mod.NamingConvention;
pub const convertCase = rename_mod.convertCase;

pub const SkipMode = enum {
    always,
    @"null",
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

/// Whether a type declares `pub const serde`.
pub fn hasSerdeOptions(comptime T: type) bool {
    return @hasDecl(T, "serde");
}

fn hasFieldOrDecl(comptime S: type, comptime name: []const u8) bool {
    return @hasDecl(S, name) or @hasField(S, name);
}

// Schema resolution: checks schema first, then falls back to T.serde.
// When schema is `void` (passed as `{}`), only T.serde is consulted.

/// Resolve the wire name for a struct field, applying per-field rename
/// then rename_all convention.
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

/// Whether a field should be completely skipped for the given direction.
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

/// Whether a field should be skipped during serialization when its value is null.
pub fn isSkipIfNull(comptime T: type, comptime field_name: []const u8) bool {
    return isSkipIfNullSchema(T, field_name, {});
}

pub fn isSkipIfNullSchema(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "skip")) {
            const skip = schema.skip;
            if (@hasField(@TypeOf(skip), field_name))
                return @field(skip, field_name) == .@"null";
        }
    }
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!hasFieldOrDecl(@TypeOf(opts), "skip")) return false;
    const skip = opts.skip;
    if (!@hasField(@TypeOf(skip), field_name)) return false;
    return @field(skip, field_name) == .@"null";
}

/// Whether a field should be skipped when empty.
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

/// Detect `zerdeSerialize` decl on a type.
pub fn hasCustomSerializer(comptime T: type) bool {
    return hasDeclSafe(T, "zerdeSerialize");
}

/// Detect `zerdeDeserialize` decl on a type.
pub fn hasCustomDeserializer(comptime T: type) bool {
    return hasDeclSafe(T, "zerdeDeserialize");
}

fn hasDeclSafe(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

/// Count non-skipped fields for serialization.
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

/// Whether unknown fields trigger an error during deserialization.
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

/// Whether a field has a serde default value.
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

/// Retrieve the serde default value for a field.
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

/// Resolve the enum representation for a type (string or integer).
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

/// Resolve the union tag representation.
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

/// Get the tag field name for internal/adjacent tagged unions.
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

/// Get the content field name for adjacent tagged unions.
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

/// Whether a field should be flattened into the parent struct.
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

/// Get the list of flattened field names.
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

/// Whether a field has a custom with module.
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

/// Get the with module type for a field.
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

// Tests.

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
                .optional_val = SkipMode.@"null",
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

// Schema override tests.

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
    // Field not in schema falls through to T.serde — but T.serde.rename doesn't
    // have first_name either, so it's just the field name.
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
    // Schema skips 'a' instead of 'b'.
    const schema = .{ .skip = .{ .a = SkipMode.always } };
    try testing.expect(comptime shouldSkipFieldSchema(S, "a", .serialize, schema));
    // 'b' is skipped via T.serde, but schema doesn't mention it — T.serde still applies.
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
