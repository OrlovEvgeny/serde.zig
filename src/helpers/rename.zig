const std = @import("std");

pub const NamingConvention = enum {
    camel_case,
    snake_case,
    pascal_case,
    kebab_case,
    SCREAMING_SNAKE_CASE,
};

/// Convert a field name to the target naming convention at comptime.
pub fn convertCase(comptime name: []const u8, comptime convention: NamingConvention) []const u8 {
    return switch (convention) {
        .snake_case => toSnakeCase(name),
        .camel_case => toCamelCase(name),
        .pascal_case => toPascalCase(name),
        .kebab_case => toKebabCase(name),
        .SCREAMING_SNAKE_CASE => toScreamingSnakeCase(name),
    };
}

fn toSnakeCase(comptime name: []const u8) []const u8 {
    // Already snake_case by Zig convention — identity.
    return name;
}

fn toCamelCase(comptime name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = &.{};
        var capitalize_next = false;
        for (name) |c| {
            if (c == '_') {
                capitalize_next = true;
            } else if (capitalize_next) {
                result = result ++ &[1]u8{toUpper(c)};
                capitalize_next = false;
            } else {
                result = result ++ &[1]u8{c};
            }
        }
        return result;
    }
}

fn toPascalCase(comptime name: []const u8) []const u8 {
    comptime {
        const camel = toCamelCase(name);
        if (camel.len == 0) return camel;
        return &[1]u8{toUpper(camel[0])} ++ camel[1..];
    }
}

fn toKebabCase(comptime name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = &.{};
        for (name) |c| {
            if (c == '_') {
                result = result ++ "-";
            } else {
                result = result ++ &[1]u8{c};
            }
        }
        return result;
    }
}

fn toScreamingSnakeCase(comptime name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = &.{};
        for (name) |c| {
            result = result ++ &[1]u8{toUpper(c)};
        }
        return result;
    }
}

fn toUpper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

// Tests.

const testing = std.testing;

test "camelCase" {
    try testing.expectEqualStrings("firstName", comptime convertCase("first_name", .camel_case));
    try testing.expectEqualStrings("id", comptime convertCase("id", .camel_case));
    try testing.expectEqualStrings("createdAt", comptime convertCase("created_at", .camel_case));
}

test "PascalCase" {
    try testing.expectEqualStrings("FirstName", comptime convertCase("first_name", .pascal_case));
    try testing.expectEqualStrings("Id", comptime convertCase("id", .pascal_case));
}

test "kebab-case" {
    try testing.expectEqualStrings("first-name", comptime convertCase("first_name", .kebab_case));
}

test "SCREAMING_SNAKE_CASE" {
    try testing.expectEqualStrings("FIRST_NAME", comptime convertCase("first_name", .SCREAMING_SNAKE_CASE));
}

test "snake_case identity" {
    try testing.expectEqualStrings("first_name", comptime convertCase("first_name", .snake_case));
}
