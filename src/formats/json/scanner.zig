const std = @import("std");

// String scan classes: 1 means "stop the fast run and handle byte by byte".
// The default table flags `"`, `\`, and control characters; the relaxed one
// leaves controls alone (allow_unescaped_control_chars).
const string_char_table = blk: {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.* = if (byte < 0x20 or byte == '"' or byte == '\\' or byte >= 0x80) 1 else 0;
    }
    break :blk table;
};

const string_char_table_relaxed = blk: {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.* = if (byte == '"' or byte == '\\' or byte >= 0x80) 1 else 0;
    }
    break :blk table;
};

pub const Token = union(enum) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    string: []const u8,
    number: []const u8,
    true_lit,
    false_lit,
    null_lit,
};

pub const ScanError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidUnicode,
    InvalidEscape,
    InvalidControlCharacter,
    MaxDepthExceeded,
};

pub const Scanner = struct {
    input: []const u8,
    pos: usize = 0,
    /// When false (default), reject unescaped control characters U+0000..U+001F
    /// inside strings per RFC 8259 §7.
    allow_unescaped_control_chars: bool = false,
    /// Currently open container nesting level (arrays + objects).
    depth: u32 = 0,
    /// Maximum allowed nesting depth. Default 256.
    max_depth: u32 = 256,
    /// Whether the last string token contained escape sequences. Only valid
    /// immediately after `next()` returned a `.string`; any later scan,
    /// including one made by `skipValue`, overwrites it. `peek()` restores it.
    last_string_has_escape: bool = false,

    pub fn next(self: *Scanner) ScanError!Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        const c = self.input[self.pos];
        switch (c) {
            '{' => {
                if (self.depth >= self.max_depth) return error.MaxDepthExceeded;
                self.depth += 1;
                self.pos += 1;
                return .object_begin;
            },
            '}' => {
                if (self.depth > 0) self.depth -= 1;
                self.pos += 1;
                return .object_end;
            },
            '[' => {
                if (self.depth >= self.max_depth) return error.MaxDepthExceeded;
                self.depth += 1;
                self.pos += 1;
                return .array_begin;
            },
            ']' => {
                if (self.depth > 0) self.depth -= 1;
                self.pos += 1;
                return .array_end;
            },
            '"' => return .{ .string = try self.scanString() },
            '-', '0'...'9' => return .{ .number = try self.scanNumber() },
            't' => return self.scanLiteral("true", .true_lit),
            'f' => return self.scanLiteral("false", .false_lit),
            'n' => return self.scanLiteral("null", .null_lit),
            else => return error.UnexpectedToken,
        }
    }

    pub fn peek(self: *Scanner) ScanError!Token {
        const saved_pos = self.pos;
        const saved_depth = self.depth;
        const saved_last_string_has_escape = self.last_string_has_escape;
        const tok = try self.next();
        self.pos = saved_pos;
        self.depth = saved_depth;
        self.last_string_has_escape = saved_last_string_has_escape;
        return tok;
    }

    /// Consume a `:` separator between a key and value in an object. Errors
    /// if the next non-whitespace byte is not `:`.
    pub fn expectColon(self: *Scanner) ScanError!void {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != ':') return error.UnexpectedToken;
        self.pos += 1;
    }

    pub const ContainerStep = enum { end, more };

    /// After reading an element (or before reading the first element), advance
    /// to the next position in a `[...]` / `{...}` container. Returns `.end`
    /// when the container terminator was consumed, `.more` after consuming a
    /// `,` separator. Trailing commas (`,` immediately followed by terminator)
    /// are rejected as `error.UnexpectedToken`.
    pub fn finishContainer(self: *Scanner, end: u8) ScanError!ContainerStep {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const c = self.input[self.pos];
        if (c == end) {
            if (self.depth > 0) self.depth -= 1;
            self.pos += 1;
            return .end;
        }
        if (c == ',') {
            self.pos += 1;
            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            if (self.input[self.pos] == end) return error.UnexpectedToken;
            return .more;
        }
        return error.UnexpectedToken;
    }

    /// At the start of a container, peek whether the very next non-whitespace
    /// byte is the terminator (empty container). Does not consume.
    pub fn isContainerEmpty(self: *Scanner, end: u8) ScanError!bool {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        return self.input[self.pos] == end;
    }

    /// Skip an entire value subtree (object, array, or single token).
    pub fn skipValue(self: *Scanner) ScanError!void {
        const tok = try self.next();
        switch (tok) {
            .object_begin => {
                if (try self.isContainerEmpty('}')) {
                    _ = try self.next();
                    return;
                }
                while (true) {
                    const key_tok = try self.next();
                    if (key_tok != .string) return error.UnexpectedToken;
                    try self.expectColon();
                    try self.skipValue();
                    switch (try self.finishContainer('}')) {
                        .end => return,
                        .more => {},
                    }
                }
            },
            .array_begin => {
                if (try self.isContainerEmpty(']')) {
                    _ = try self.next();
                    return;
                }
                while (true) {
                    try self.skipValue();
                    switch (try self.finishContainer(']')) {
                        .end => return,
                        .more => {},
                    }
                }
            },
            else => {}, // scalar token already consumed
        }
    }

    // Internal scanning methods.

    fn scanString(self: *Scanner) ScanError![]const u8 {
        std.debug.assert(self.input[self.pos] == '"');
        const input = self.input;
        var pos = self.pos + 1; // skip opening quote
        const start = pos;
        var has_escape = false;
        // The loops below track the cursor locally, so publish it on the error
        // paths too: callers reading `pos` after a failure expect it to point at
        // the offending byte, not back at the opening quote.
        errdefer self.pos = pos;

        // Fast path: skip plain runs in chunks of four.
        const table = if (self.allow_unescaped_control_chars)
            &string_char_table_relaxed
        else
            &string_char_table;

        runs: while (pos < input.len) {
            const run_start = pos;
            var used_blocks = false;
            if (input[pos] != '\\') {
                while (pos + 4 <= input.len) {
                    const a = input[pos];
                    const b = input[pos + 1];
                    const c = input[pos + 2];
                    const d = input[pos + 3];
                    if ((table[a] | table[b] | table[c] | table[d]) != 0) break;
                    pos += 4;
                    if (!used_blocks and pos - run_start >= 16) {
                        pos = if (self.allow_unescaped_control_chars) skipPlainBlocks(input, pos, true) else skipPlainBlocks(input, pos, false);
                        used_blocks = true;
                    }
                }
            }
            while (pos < input.len) {
                const c = input[pos];
                if (c == '"') {
                    const result = input[start..pos];
                    self.pos = pos + 1; // skip closing quote
                    self.last_string_has_escape = has_escape;
                    return result;
                }
                if (c == '\\') {
                    has_escape = true;
                    pos += 1; // skip backslash
                    if (pos >= input.len) return error.UnexpectedEof;
                    const esc = input[pos];
                    switch (esc) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                            pos += 1;
                        },
                        'u' => {
                            pos += 1;
                            if (pos + 4 > input.len) return error.UnexpectedEof;
                            const cp = parseHex4(input[pos..][0..4]) orelse return error.InvalidUnicode;
                            pos += 4;
                            if (cp >= 0xD800 and cp <= 0xDBFF) {
                                if (pos + 6 > input.len or input[pos] != '\\' or input[pos + 1] != 'u') return error.InvalidUnicode;
                                const low = parseHex4(input[pos + 2 ..][0..4]) orelse return error.InvalidUnicode;
                                if (low < 0xDC00 or low > 0xDFFF) return error.InvalidUnicode;
                                pos += 6;
                            } else if (cp >= 0xDC00 and cp <= 0xDFFF) return error.InvalidUnicode;
                        },
                        else => return error.InvalidEscape,
                    }
                } else {
                    if (c < 0x20 and !self.allow_unescaped_control_chars) return error.InvalidControlCharacter;
                    if (c >= 0x80) {
                        const len = std.unicode.utf8ByteSequenceLength(c) catch return error.InvalidUnicode;
                        if (pos + len > input.len) return error.InvalidUnicode;
                        _ = std.unicode.utf8Decode(input[pos..][0..len]) catch return error.InvalidUnicode;
                        pos += len;
                    } else {
                        if (has_escape and pos + 4 <= input.len and
                            (table[c] | table[input[pos + 1]] | table[input[pos + 2]] | table[input[pos + 3]]) == 0) continue :runs;
                        pos += 1;
                    }
                }
            }
        }
        return error.UnexpectedEof;
    }

    // Keep vector setup outside the short-name scanner's register/branch path.
    noinline fn skipPlainBlocks(input: []const u8, start: usize, comptime relaxed: bool) usize {
        var pos = start;
        while (pos + 16 <= input.len) {
            const bytes: @Vector(16, u8) = input[pos..][0..16].*;
            var special = (bytes >= @as(@Vector(16, u8), @splat(0x80))) | (bytes == @as(@Vector(16, u8), @splat('"'))) | (bytes == @as(@Vector(16, u8), @splat('\\')));
            if (!relaxed) special |= bytes < @as(@Vector(16, u8), @splat(0x20));
            if (@reduce(.Or, special)) break;
            pos += 16;
        }
        return pos;
    }

    fn scanNumber(self: *Scanner) ScanError![]const u8 {
        const start = self.pos;
        // Optional minus.
        if (self.pos < self.input.len and self.input[self.pos] == '-') self.pos += 1;
        // Integer part.
        if (self.pos >= self.input.len) return error.InvalidNumber;
        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9')
                self.pos += 1;
        } else {
            return error.InvalidNumber;
        }
        // Fractional part.
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            if (self.pos >= self.input.len or self.input[self.pos] < '0' or self.input[self.pos] > '9')
                return error.InvalidNumber;
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9')
                self.pos += 1;
        }
        // Exponent.
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-'))
                self.pos += 1;
            if (self.pos >= self.input.len or self.input[self.pos] < '0' or self.input[self.pos] > '9')
                return error.InvalidNumber;
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9')
                self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn scanLiteral(self: *Scanner, comptime expected: []const u8, token: Token) ScanError!Token {
        if (self.pos + expected.len > self.input.len)
            return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.input[self.pos..][0..expected.len], expected))
            return error.UnexpectedToken;
        self.pos += expected.len;
        return token;
    }

    pub fn skipWhitespace(self: *Scanner) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }
};

// Tests.

const testing = std.testing;

test "scan simple object" {
    var s = Scanner{ .input = "{\"a\": 1}" };
    try testing.expectEqual(Token.object_begin, try s.next());
    try testing.expectEqualStrings("a", (try s.next()).string);
    try s.expectColon();
    try testing.expectEqualStrings("1", (try s.next()).number);
    try testing.expectEqual(Scanner.ContainerStep.end, try s.finishContainer('}'));
}

test "scan array" {
    var s = Scanner{ .input = "[1, 2, 3]" };
    try testing.expectEqual(Token.array_begin, try s.next());
    try testing.expectEqualStrings("1", (try s.next()).number);
    try testing.expectEqual(Scanner.ContainerStep.more, try s.finishContainer(']'));
    try testing.expectEqualStrings("2", (try s.next()).number);
    try testing.expectEqual(Scanner.ContainerStep.more, try s.finishContainer(']'));
    try testing.expectEqualStrings("3", (try s.next()).number);
    try testing.expectEqual(Scanner.ContainerStep.end, try s.finishContainer(']'));
}

test "scan literals" {
    var s = Scanner{ .input = "[true, false, null]" };
    try testing.expectEqual(Token.array_begin, try s.next());
    try testing.expectEqual(Token.true_lit, try s.next());
    try testing.expectEqual(Scanner.ContainerStep.more, try s.finishContainer(']'));
    try testing.expectEqual(Token.false_lit, try s.next());
    try testing.expectEqual(Scanner.ContainerStep.more, try s.finishContainer(']'));
    try testing.expectEqual(Token.null_lit, try s.next());
    try testing.expectEqual(Scanner.ContainerStep.end, try s.finishContainer(']'));
}

test "scan string with escapes" {
    var s = Scanner{ .input = "\"hello\\nworld\"" };
    const tok = try s.next();
    try testing.expectEqualStrings("hello\\nworld", tok.string);
    try testing.expect(s.last_string_has_escape);
}

test "scan string without escapes" {
    var s = Scanner{ .input = "\"hello\"" };
    const tok = try s.next();
    try testing.expectEqualStrings("hello", tok.string);
    try testing.expect(!s.last_string_has_escape);
}

test "string scan errors leave pos at the offending byte" {
    var eof = Scanner{ .input = "\"abcdefgh" };
    try testing.expectError(error.UnexpectedEof, eof.next());
    try testing.expectEqual(@as(usize, 9), eof.pos);

    var bad_escape = Scanner{ .input = "\"abcdefgh\\q\"" };
    try testing.expectError(error.InvalidEscape, bad_escape.next());
    try testing.expectEqual(@as(usize, 10), bad_escape.pos);

    var control = Scanner{ .input = "\"abcdefgh\x01\"" };
    try testing.expectError(error.InvalidControlCharacter, control.next());
    try testing.expectEqual(@as(usize, 9), control.pos);
}

test "peek restores escape flag" {
    var s = Scanner{ .input = "\"c\" \"a\\nb\"" };
    _ = try s.next();
    try testing.expect(!s.last_string_has_escape);
    _ = try s.peek();
    try testing.expect(!s.last_string_has_escape);
    const tok = try s.next();
    try testing.expectEqualStrings("a\\nb", tok.string);
    try testing.expect(s.last_string_has_escape);
}

test "scan number formats" {
    const cases = [_][]const u8{ "42", "-7", "3.14", "1e10", "1.5E-3", "0" };
    for (cases) |num| {
        var s = Scanner{ .input = num };
        try testing.expectEqualStrings(num, (try s.next()).number);
    }
}

test "skip value" {
    var s = Scanner{ .input = "{\"a\": {\"b\": [1,2,3]}, \"c\": 4}" };
    try testing.expectEqual(Token.object_begin, try s.next());
    try testing.expectEqualStrings("a", (try s.next()).string);
    try s.expectColon();
    try s.skipValue(); // skip the nested {"b": [1,2,3]}
    try testing.expectEqual(Scanner.ContainerStep.more, try s.finishContainer('}'));
    try testing.expectEqualStrings("c", (try s.next()).string);
    try s.expectColon();
    try testing.expectEqualStrings("4", (try s.next()).number);
    try testing.expectEqual(Scanner.ContainerStep.end, try s.finishContainer('}'));
}

test "trailing comma rejected in array" {
    var s = Scanner{ .input = "[1,]" };
    try testing.expectEqual(Token.array_begin, try s.next());
    try testing.expectEqualStrings("1", (try s.next()).number);
    try testing.expectError(error.UnexpectedToken, s.finishContainer(']'));
}

test "trailing comma rejected in object" {
    var s = Scanner{ .input = "{\"a\":1,}" };
    try testing.expectEqual(Token.object_begin, try s.next());
    try testing.expectEqualStrings("a", (try s.next()).string);
    try s.expectColon();
    try testing.expectEqualStrings("1", (try s.next()).number);
    try testing.expectError(error.UnexpectedToken, s.finishContainer('}'));
}

test "unexpected eof" {
    var s = Scanner{ .input = "" };
    try testing.expectError(error.UnexpectedEof, s.next());
}

test "unexpected token" {
    var s = Scanner{ .input = "xyz" };
    try testing.expectError(error.UnexpectedToken, s.next());
}

pub fn parseHex4(hex: *const [4]u8) ?u16 {
    var result: u16 = 0;
    for (hex) |c| {
        const digit: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        result = result * 16 + digit;
    }
    return result;
}
