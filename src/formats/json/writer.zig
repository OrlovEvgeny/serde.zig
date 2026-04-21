const std = @import("std");

/// Write a JSON-escaped string (including surrounding quotes) to the writer.
pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    try writeJsonStringContents(writer, value);
    try writer.writeByte('"');
}

fn writeJsonStringContents(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    for (value, 0..) |c, i| {
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
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    try writeJsonString(&aw.writer, input);
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
