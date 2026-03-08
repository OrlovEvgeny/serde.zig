const std = @import("std");

/// Write XML-escaped text content to the writer. Escapes &, <, >.
pub fn writeXmlEscaped(writer: *std.io.Writer, value: []const u8) std.io.Writer.Error!void {
    var start: usize = 0;
    for (value, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => continue,
        };
        if (i > start) try writer.writeAll(value[start..i]);
        try writer.writeAll(escape.?);
        start = i + 1;
    }
    if (start < value.len) try writer.writeAll(value[start..]);
}

/// Write an XML-escaped attribute value wrapped in double quotes.
/// Escapes &, <, >, ", '.
pub fn writeXmlAttrEscaped(writer: *std.io.Writer, value: []const u8) std.io.Writer.Error!void {
    try writer.writeByte('"');
    var start: usize = 0;
    for (value, 0..) |c, i| {
        const escape: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => continue,
        };
        if (i > start) try writer.writeAll(value[start..i]);
        try writer.writeAll(escape.?);
        start = i + 1;
    }
    if (start < value.len) try writer.writeAll(value[start..]);
    try writer.writeByte('"');
}

// Tests.

const testing = std.testing;

fn testEscapeText(input: []const u8, expected: []const u8) !void {
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    try writeXmlEscaped(&aw.writer, input);
    const result = try aw.toOwnedSlice();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

fn testEscapeAttr(input: []const u8, expected: []const u8) !void {
    var aw: std.io.Writer.Allocating = .init(testing.allocator);
    try writeXmlAttrEscaped(&aw.writer, input);
    const result = try aw.toOwnedSlice();
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "plain text" {
    try testEscapeText("hello", "hello");
}

test "empty text" {
    try testEscapeText("", "");
}

test "text entities" {
    try testEscapeText("a&b", "a&amp;b");
    try testEscapeText("a<b", "a&lt;b");
    try testEscapeText("a>b", "a&gt;b");
}

test "multiple entities" {
    try testEscapeText("<a&b>", "&lt;a&amp;b&gt;");
}

test "utf-8 passthrough" {
    try testEscapeText("héllo 日本語", "héllo 日本語");
}

test "attr escaping" {
    try testEscapeAttr("hello", "\"hello\"");
    try testEscapeAttr("a\"b", "\"a&quot;b\"");
    try testEscapeAttr("a'b", "\"a&apos;b\"");
    try testEscapeAttr("a&b", "\"a&amp;b\"");
}

test "empty attr" {
    try testEscapeAttr("", "\"\"");
}
