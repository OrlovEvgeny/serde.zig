const std = @import("std");

pub const Token = union(enum) {
    element_open: []const u8,
    element_close: []const u8,
    self_closing: []const u8,
    attribute: struct { name: []const u8, value: []const u8 },
    tag_end,
    text: []const u8,
    cdata: []const u8,
    eof,
};

pub const ScanError = error{
    UnexpectedToken,
    UnexpectedEof,
    MalformedXml,
};

pub const Scanner = struct {
    input: []const u8,
    pos: usize = 0,
    state: State = .content,

    const State = enum { content, in_tag };

    pub fn next(self: *Scanner) ScanError!Token {
        switch (self.state) {
            .content => return self.scanContent(),
            .in_tag => return self.scanInTag(),
        }
    }

    pub fn peek(self: *Scanner) ScanError!Token {
        const saved_pos = self.pos;
        const saved_state = self.state;
        const tok = try self.next();
        self.pos = saved_pos;
        self.state = saved_state;
        return tok;
    }

    /// Skip an entire element subtree including its closing tag.
    pub fn skipElement(self: *Scanner) ScanError!void {
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = try self.next();
            switch (tok) {
                .element_open => {
                    // If scanner returned to content state, the > was already consumed
                    // and there are no attributes. Otherwise consume attributes/tag_end.
                    if (self.state == .in_tag) {
                        while (true) {
                            const inner = try self.next();
                            switch (inner) {
                                .attribute => continue,
                                .tag_end => break,
                                .self_closing => {
                                    // Self-closing with attributes: doesn't add depth.
                                    depth -= 1;
                                    break;
                                },
                                else => break,
                            }
                        }
                    }
                    depth += 1;
                },
                .self_closing => {},
                .element_close => depth -= 1,
                .text, .cdata => continue,
                .eof => return error.UnexpectedEof,
                else => continue,
            }
        }
    }

    /// Unescape XML entities in a text or attribute value.
    /// Returns the input directly when no entities are present (zero-copy).
    pub fn unescapeEntities(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        if (!textHasEntities(raw)) {
            const copy = try allocator.alloc(u8, raw.len);
            @memcpy(copy, raw);
            return copy;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '&') {
                const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';') orelse
                    return error.MalformedXml;
                const entity = raw[i + 1 .. semi];
                if (std.mem.eql(u8, entity, "amp")) {
                    out.append(allocator, '&') catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, entity, "lt")) {
                    out.append(allocator, '<') catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, entity, "gt")) {
                    out.append(allocator, '>') catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, entity, "quot")) {
                    out.append(allocator, '"') catch return error.OutOfMemory;
                } else if (std.mem.eql(u8, entity, "apos")) {
                    out.append(allocator, '\'') catch return error.OutOfMemory;
                } else if (entity.len > 1 and entity[0] == '#') {
                    const cp = parseCharRef(entity[1..]) orelse return error.MalformedXml;
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return error.MalformedXml;
                    out.appendSlice(allocator, buf[0..len]) catch return error.OutOfMemory;
                } else {
                    return error.MalformedXml;
                }
                i = semi + 1;
            } else {
                out.append(allocator, raw[i]) catch return error.OutOfMemory;
                i += 1;
            }
        }
        return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    pub fn textHasEntities(value: []const u8) bool {
        return std.mem.indexOfScalar(u8, value, '&') != null;
    }

    fn parseCharRef(s: []const u8) ?u21 {
        if (s.len == 0) return null;
        if (s[0] == 'x') {
            if (s.len < 2) return null;
            const val = std.fmt.parseInt(u21, s[1..], 16) catch return null;
            return val;
        }
        return std.fmt.parseInt(u21, s, 10) catch null;
    }

    // Content state: between tags.
    fn scanContent(self: *Scanner) ScanError!Token {
        self.skipWhitespaceAndDecls();
        if (self.pos >= self.input.len) return .eof;

        if (self.input[self.pos] != '<') {
            return self.scanText();
        }

        // CDATA section.
        if (self.startsWith("<![CDATA[")) {
            self.pos += 9;
            const end = std.mem.indexOf(u8, self.input[self.pos..], "]]>") orelse
                return error.UnexpectedEof;
            const data = self.input[self.pos .. self.pos + end];
            self.pos += end + 3;
            return .{ .cdata = data };
        }

        // Comment: skip.
        if (self.startsWith("<!--")) {
            const end = std.mem.indexOf(u8, self.input[self.pos + 4 ..], "-->") orelse
                return error.UnexpectedEof;
            self.pos += 4 + end + 3;
            return self.scanContent();
        }

        // Closing tag.
        if (self.startsWith("</")) {
            self.pos += 2;
            const name_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != '>') : (self.pos += 1) {}
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            const name = std.mem.trim(u8, self.input[name_start..self.pos], " \t\r\n");
            self.pos += 1; // skip >
            return .{ .element_close = name };
        }

        // Opening tag.
        self.pos += 1; // skip <
        const name_start = self.pos;
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r', '>', '/' => break,
                else => self.pos += 1,
            }
        }
        if (self.pos == name_start) return error.MalformedXml;
        const name = self.input[name_start..self.pos];
        self.state = .in_tag;

        // Check for immediate self-closing or end.
        self.skipWs();
        if (self.pos < self.input.len and self.input[self.pos] == '/') {
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
                self.pos += 2;
                self.state = .content;
                return .{ .self_closing = name };
            }
        }
        if (self.pos < self.input.len and self.input[self.pos] == '>') {
            self.pos += 1;
            self.state = .content;
            // Return open + implicit tag_end as separate tokens. Re-read as element_open
            // followed by tag_end. We return element_open now; the caller will get content next.
            // Since there are no attributes, switch back to content.
            return .{ .element_open = name };
        }

        return .{ .element_open = name };
    }

    fn scanText(self: *Scanner) ScanError!Token {
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '<') : (self.pos += 1) {}
        const raw = self.input[start..self.pos];
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return self.scanContent();
        return .{ .text = trimmed };
    }

    // In-tag state: scanning attributes or tag end.
    fn scanInTag(self: *Scanner) ScanError!Token {
        self.skipWs();
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        // Self-closing.
        if (self.input[self.pos] == '/' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
            self.pos += 2;
            self.state = .content;
            // We already returned element_open; now yield the self-closing name.
            // The caller sees element_open, attributes, then needs to know it was self-closed.
            // We represent this as tag_end since element_open was already returned.
            // Actually, let's return a special self_closing token. But we already emitted
            // element_open... Revise: in_tag yields .self_closing with empty name to signal
            // that the previously opened element is self-closing.
            return .{ .self_closing = "" };
        }

        // Tag end.
        if (self.input[self.pos] == '>') {
            self.pos += 1;
            self.state = .content;
            return .tag_end;
        }

        // Attribute: name="value" or name='value'.
        const name_start = self.pos;
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                '=', ' ', '\t', '\n', '\r', '>', '/' => break,
                else => self.pos += 1,
            }
        }
        const attr_name = self.input[name_start..self.pos];
        if (attr_name.len == 0) return error.MalformedXml;

        self.skipWs();
        if (self.pos >= self.input.len or self.input[self.pos] != '=') return error.MalformedXml;
        self.pos += 1; // skip =
        self.skipWs();
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        const quote = self.input[self.pos];
        if (quote != '"' and quote != '\'') return error.MalformedXml;
        self.pos += 1;
        const val_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != quote) : (self.pos += 1) {}
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const attr_val = self.input[val_start..self.pos];
        self.pos += 1; // skip closing quote

        return .{ .attribute = .{ .name = attr_name, .value = attr_val } };
    }

    fn skipWs(self: *Scanner) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    /// Skip whitespace, XML declarations (<?...?>), and DOCTYPE declarations.
    fn skipWhitespaceAndDecls(self: *Scanner) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '<' => {
                    // XML declaration or processing instruction.
                    if (self.startsWith("<?")) {
                        if (std.mem.indexOf(u8, self.input[self.pos + 2 ..], "?>")) |end| {
                            self.pos += 2 + end + 2;
                            continue;
                        }
                        break;
                    }
                    // DOCTYPE.
                    if (self.startsWith("<!DOCTYPE")) {
                        if (std.mem.indexOfScalar(u8, self.input[self.pos..], '>')) |end| {
                            self.pos += end + 1;
                            continue;
                        }
                        break;
                    }
                    break;
                },
                else => break,
            }
        }
    }

    fn startsWith(self: *Scanner, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos..][0..prefix.len], prefix);
    }
};

// Tests.

const testing = std.testing;

test "simple element" {
    var s = Scanner{ .input = "<name>Alice</name>" };
    const open = try s.next();
    try testing.expectEqualStrings("name", open.element_open);
    const text = try s.next();
    try testing.expectEqualStrings("Alice", text.text);
    const close = try s.next();
    try testing.expectEqualStrings("name", close.element_close);
    try testing.expectEqual(Token.eof, try s.next());
}

test "self-closing element" {
    var s = Scanner{ .input = "<br/>" };
    const tok = try s.next();
    try testing.expectEqualStrings("br", tok.self_closing);
}

test "element with attributes" {
    var s = Scanner{ .input = "<user id=\"42\" name='Alice'>text</user>" };
    const open = try s.next();
    try testing.expectEqualStrings("user", open.element_open);
    const attr1 = try s.next();
    try testing.expectEqualStrings("id", attr1.attribute.name);
    try testing.expectEqualStrings("42", attr1.attribute.value);
    const attr2 = try s.next();
    try testing.expectEqualStrings("name", attr2.attribute.name);
    try testing.expectEqualStrings("Alice", attr2.attribute.value);
    try testing.expectEqual(Token.tag_end, try s.next());
    const text = try s.next();
    try testing.expectEqualStrings("text", text.text);
    const close = try s.next();
    try testing.expectEqualStrings("user", close.element_close);
}

test "self-closing with attributes" {
    var s = Scanner{ .input = "<img src=\"a.png\" />" };
    const open = try s.next();
    try testing.expectEqualStrings("img", open.element_open);
    const attr = try s.next();
    try testing.expectEqualStrings("src", attr.attribute.name);
    const sc = try s.next();
    try testing.expectEqualStrings("", sc.self_closing);
}

test "xml declaration skipped" {
    var s = Scanner{ .input = "<?xml version=\"1.0\"?><root>hi</root>" };
    const open = try s.next();
    try testing.expectEqualStrings("root", open.element_open);
    const text = try s.next();
    try testing.expectEqualStrings("hi", text.text);
}

test "comment skipped" {
    var s = Scanner{ .input = "<!-- comment --><root/>" };
    const tok = try s.next();
    try testing.expectEqualStrings("root", tok.self_closing);
}

test "CDATA" {
    var s = Scanner{ .input = "<data><![CDATA[<not xml>]]></data>" };
    _ = try s.next(); // element_open
    const cdata = try s.next();
    try testing.expectEqualStrings("<not xml>", cdata.cdata);
}

test "nested elements" {
    var s = Scanner{ .input = "<a><b>1</b><c>2</c></a>" };
    try testing.expectEqualStrings("a", (try s.next()).element_open);
    try testing.expectEqualStrings("b", (try s.next()).element_open);
    try testing.expectEqualStrings("1", (try s.next()).text);
    try testing.expectEqualStrings("b", (try s.next()).element_close);
    try testing.expectEqualStrings("c", (try s.next()).element_open);
    try testing.expectEqualStrings("2", (try s.next()).text);
    try testing.expectEqualStrings("c", (try s.next()).element_close);
    try testing.expectEqualStrings("a", (try s.next()).element_close);
}

test "entity unescaping" {
    const result = try Scanner.unescapeEntities(testing.allocator, "a&amp;b&lt;c&gt;d");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a&b<c>d", result);
}

test "entity char ref decimal" {
    const result = try Scanner.unescapeEntities(testing.allocator, "&#65;&#66;");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("AB", result);
}

test "entity char ref hex" {
    const result = try Scanner.unescapeEntities(testing.allocator, "&#x41;&#x42;");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("AB", result);
}

test "no entities passthrough" {
    const result = try Scanner.unescapeEntities(testing.allocator, "hello");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "skipElement" {
    var s = Scanner{ .input = "<root><child><deep>val</deep></child><next/></root>" };
    try testing.expectEqualStrings("root", (try s.next()).element_open);
    try testing.expectEqualStrings("child", (try s.next()).element_open);
    // Skip the <child> element (already consumed the open tag, so skip reads to </child>).
    try s.skipElement();
    // After skip, we should see <next/>
    const tok = try s.next();
    try testing.expectEqualStrings("next", tok.self_closing);
}
