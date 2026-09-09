const std = @import("std");
const compat = @import("compat");

pub const StringWriteOptions = struct {
    escape_js_unsafe: bool = false,
};

/// Write a JSON-escaped string (including surrounding quotes) to the writer.
pub fn writeJsonString(writer: *compat.Io.Writer, value: []const u8) compat.Io.Writer.Error!void {
    try writeJsonStringWith(writer, value, .{});
}

pub fn writeJsonStringWith(writer: *compat.Io.Writer, value: []const u8, opts: StringWriteOptions) compat.Io.Writer.Error!void {
    try writer.writeByte('"');
    try writeJsonStringContents(writer, value, opts);
    try writer.writeByte('"');
}

fn writeJsonStringContents(writer: *compat.Io.Writer, value: []const u8, opts: StringWriteOptions) compat.Io.Writer.Error!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        while (i + 16 <= value.len) {
            const bytes: @Vector(16, u8) = value[i..][0..16].*;
            var special = (bytes == @as(@Vector(16, u8), @splat('"'))) | (bytes == @as(@Vector(16, u8), @splat('\\'))) | (bytes < @as(@Vector(16, u8), @splat(0x20)));
            if (opts.escape_js_unsafe) special |= bytes == @as(@Vector(16, u8), @splat(0xE2));
            if (@reduce(.Or, special)) break;
            i += 16;
        }
        if (i == value.len) break;
        const c = value[i];

        if (opts.escape_js_unsafe and c == 0xE2 and i + 2 < value.len and value[i + 1] == 0x80) {
            const third = value[i + 2];
            if (third == 0xA8 or third == 0xA9) {
                if (i > start) try writer.writeAll(value[start..i]);
                try writer.writeAll(if (third == 0xA8) "\\u2028" else "\\u2029");
                i += 2;
                start = i + 1;
                continue;
            }
        }

        const escape: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            0x00...0x07, 0x0b, 0x0e...0x1f => null,
            else => continue,
        };

        if (i > start) try writer.writeAll(value[start..i]);

        if (escape) |esc| {
            try writer.writeAll(esc);
        } else {
            try writer.writeAll("\\u00");
            const hex = "0123456789abcdef";
            try writer.writeByte(hex[c >> 4]);
            try writer.writeByte(hex[c & 0x0f]);
        }
        start = i + 1;
    }
    if (start < value.len) try writer.writeAll(value[start..]);
}

// Tests.

const testing = std.testing;

fn testEscape(input: []const u8, expected: []const u8) !void {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    try writeJsonString(&aw.writer, input);
    const result = try aw.toOwnedSlice();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

fn testEscapeWith(input: []const u8, expected: []const u8, opts: StringWriteOptions) !void {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    try writeJsonStringWith(&aw.writer, input, opts);
    const result = try aw.toOwnedSlice();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "plain string" {
    try testEscape("hello", "\"hello\"");
}

test "empty string" {
    try testEscape("", "\"\"");
}

test "escapes" {
    try testEscape("a\"b", "\"a\\\"b\"");
    try testEscape("a\\b", "\"a\\\\b\"");
    try testEscape("a\nb", "\"a\\nb\"");
    try testEscape("a\rb", "\"a\\rb\"");
    try testEscape("a\tb", "\"a\\tb\"");
}

test "control characters" {
    try testEscape("\x00", "\"\\u0000\"");
    try testEscape("\x1f", "\"\\u001f\"");
    try testEscape("\x0b", "\"\\u000b\"");
}

test "unicode passthrough" {
    try testEscape("héllo", "\"héllo\"");
    try testEscape("日本語", "\"日本語\"");
}

test "U+2028 passthrough by default" {
    try testEscape("a\u{2028}b", "\"a\u{2028}b\"");
    try testEscape("a\u{2029}b", "\"a\u{2029}b\"");
}

test "U+2028 escaped with escape_js_unsafe" {
    try testEscapeWith("a\u{2028}b", "\"a\\u2028b\"", .{ .escape_js_unsafe = true });
    try testEscapeWith("a\u{2029}b", "\"a\\u2029b\"", .{ .escape_js_unsafe = true });
}

test "non-2028 e2 sequences pass through with escape_js_unsafe" {
    // U+2026 (HORIZONTAL ELLIPSIS) shares the e2 80 prefix; should not be escaped.
    try testEscapeWith("a\u{2026}b", "\"a\u{2026}b\"", .{ .escape_js_unsafe = true });
}
