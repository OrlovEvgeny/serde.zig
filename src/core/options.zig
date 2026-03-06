const std = @import("std");
const rename_mod = @import("../helpers/rename.zig");

pub const NamingConvention = rename_mod.NamingConvention;
pub const convertCase = rename_mod.convertCase;

pub const SkipMode = enum {
    always,
    @"null",
    empty,
};

pub const Direction = enum {
    serialize,
    deserialize,
};

/// Whether a type declares `pub const serde`.
pub fn hasSerdeOptions(comptime T: type) bool {
    return @hasDecl(T, "serde");
}

/// Resolve the wire name for a struct field, applying per-field rename
/// then rename_all convention.
pub fn wireFieldName(comptime T: type, comptime field_name: []const u8) []const u8 {
    if (hasSerdeOptions(T)) {
        const opts = T.serde;
        // Per-field rename takes priority.
        if (@hasDecl(@TypeOf(opts), "rename") or @hasField(@TypeOf(opts), "rename")) {
            const renames = opts.rename;
            if (@hasField(@TypeOf(renames), field_name)) {
                return @field(renames, field_name);
            }
        }
        // rename_all convention.
        if (@hasDecl(@TypeOf(opts), "rename_all") or @hasField(@TypeOf(opts), "rename_all")) {
            return convertCase(field_name, opts.rename_all);
        }
    }
    return field_name;
}

/// Whether a field should be completely skipped for the given direction.
pub fn shouldSkipField(comptime T: type, comptime field_name: []const u8, comptime _: Direction) bool {
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!@hasDecl(@TypeOf(opts), "skip") and !@hasField(@TypeOf(opts), "skip")) return false;
    const skip = opts.skip;
    if (!@hasField(@TypeOf(skip), field_name)) return false;
    return @field(skip, field_name) == .always;
}

/// Whether a field should be skipped during serialization when its value is null.
pub fn isSkipIfNull(comptime T: type, comptime field_name: []const u8) bool {
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!@hasDecl(@TypeOf(opts), "skip") and !@hasField(@TypeOf(opts), "skip")) return false;
    const skip = opts.skip;
    if (!@hasField(@TypeOf(skip), field_name)) return false;
    return @field(skip, field_name) == .@"null";
}

/// Whether a field should be skipped when empty.
pub fn isSkipIfEmpty(comptime T: type, comptime field_name: []const u8) bool {
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!@hasDecl(@TypeOf(opts), "skip") and !@hasField(@TypeOf(opts), "skip")) return false;
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
    const info = @typeInfo(T).@"struct";
    var count: usize = 0;
    for (info.fields) |field| {
        if (!shouldSkipField(T, field.name, .serialize))
            count += 1;
    }
    return count;
}

/// Whether unknown fields trigger an error during deserialization.
pub fn denyUnknownFields(comptime T: type) bool {
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (@hasDecl(@TypeOf(opts), "deny_unknown_fields") or @hasField(@TypeOf(opts), "deny_unknown_fields"))
        return opts.deny_unknown_fields;
    return false;
}

/// Whether a field has a serde default value.
pub fn hasSerdeDefault(comptime T: type, comptime field_name: []const u8) bool {
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!@hasDecl(@TypeOf(opts), "default") and !@hasField(@TypeOf(opts), "default")) return false;
    return @hasField(@TypeOf(opts.default), field_name);
}

/// Retrieve the serde default value for a field.
pub fn getSerdeDefault(comptime T: type, comptime field_name: []const u8) @TypeOf(@field(@as(T, undefined), field_name)) {
    return @field(T.serde.default, field_name);
}

/// Whether a field has a custom with module.
pub fn hasFieldWith(comptime T: type, comptime field_name: []const u8) bool {
    if (!hasSerdeOptions(T)) return false;
    const opts = T.serde;
    if (!@hasDecl(@TypeOf(opts), "with") and !@hasField(@TypeOf(opts), "with")) return false;
    return @hasField(@TypeOf(opts.with), field_name);
}

/// Get the with module for a field.
pub fn getFieldWith(comptime T: type, comptime field_name: []const u8) type {
    return @TypeOf(@field(T.serde.with, field_name));
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
