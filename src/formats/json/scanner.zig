const std = @import("std");

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
};

pub const Scanner = struct {
    input: []const u8,
    pos: usize = 0,

    pub fn next(self: *Scanner) ScanError!Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        const c = self.input[self.pos];
        switch (c) {
            '{' => {
                self.pos += 1;
                return .object_begin;
            },
            '}' => {
                self.pos += 1;
                return .object_end;
            },
            '[' => {
                self.pos += 1;
                return .array_begin;
            },
            ']' => {
                self.pos += 1;
                return .array_end;
            },
            '"' => return .{ .string = try self.scanString() },
            '-', '0'...'9' => return .{ .number = try self.scanNumber() },
            't' => return self.scanLiteral("true", .true_lit),
            'f' => return self.scanLiteral("false", .false_lit),
            'n' => return self.scanLiteral("null", .null_lit),
            ',' => {
                self.pos += 1;
                return self.next();
            },
            ':' => {
                self.pos += 1;
                return self.next();
            },
            else => return error.UnexpectedToken,
        }
    }

    pub fn peek(self: *Scanner) ScanError!Token {
        const saved = self.pos;
        const tok = try self.next();
        self.pos = saved;
        return tok;
    }

    /// Skip an entire value subtree (object, array, or single token).
    pub fn skipValue(self: *Scanner) ScanError!void {
        const tok = try self.next();
        switch (tok) {
            .object_begin => {
                while (true) {
                    self.skipWhitespace();
                    if (self.pos >= self.input.len) return error.UnexpectedEof;
                    if (self.input[self.pos] == '}') {
                        self.pos += 1;
                        return;
                    }
                    // Skip comma.
                    if (self.input[self.pos] == ',') self.pos += 1;
                    // key
                    _ = try self.next();
                    // colon
                    self.skipWhitespace();
                    if (self.pos < self.input.len and self.input[self.pos] == ':') self.pos += 1;
                    // value
                    try self.skipValue();
                }
            },
            .array_begin => {
                while (true) {
                    self.skipWhitespace();
                    if (self.pos >= self.input.len) return error.UnexpectedEof;
                    if (self.input[self.pos] == ']') {
                        self.pos += 1;
                        return;
                    }
                    if (self.input[self.pos] == ',') self.pos += 1;
                    try self.skipValue();
                }
            },
            else => {}, // scalar token already consumed
        }
    }

    /// Whether the string at `index` contains escape sequences.
    /// Used to decide zero-copy vs allocated path.
    pub fn stringHasEscapes(value: []const u8) bool {
        for (value) |c| {
            if (c == '\\') return true;
        }
        return false;
    }

    // Internal scanning methods.

    fn scanString(self: *Scanner) ScanError![]const u8 {
        std.debug.assert(self.input[self.pos] == '"');
        self.pos += 1; // skip opening quote
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '"') {
                const result = self.input[start..self.pos];
                self.pos += 1; // skip closing quote
                return result;
            }
            if (c == '\\') {
                self.pos += 1; // skip backslash
                if (self.pos >= self.input.len) return error.UnexpectedEof;
                const esc = self.input[self.pos];
                switch (esc) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        self.pos += 1;
                    },
                    'u' => {
                        self.pos += 1;
                        if (self.pos + 4 > self.input.len) return error.UnexpectedEof;
                        self.pos += 4;
                    },
                    else => return error.InvalidEscape,
                }
            } else {
                self.pos += 1;
            }
        }
        return error.UnexpectedEof;
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
    try testing.expectEqualStrings("1", (try s.next()).number);
    try testing.expectEqual(Token.object_end, try s.next());
}

test "scan array" {
    var s = Scanner{ .input = "[1, 2, 3]" };
    try testing.expectEqual(Token.array_begin, try s.next());
    try testing.expectEqualStrings("1", (try s.next()).number);
    try testing.expectEqualStrings("2", (try s.next()).number);
    try testing.expectEqualStrings("3", (try s.next()).number);
    try testing.expectEqual(Token.array_end, try s.next());
}

test "scan literals" {
    var s = Scanner{ .input = "[true, false, null]" };
    try testing.expectEqual(Token.array_begin, try s.next());
    try testing.expectEqual(Token.true_lit, try s.next());
    try testing.expectEqual(Token.false_lit, try s.next());
    try testing.expectEqual(Token.null_lit, try s.next());
    try testing.expectEqual(Token.array_end, try s.next());
}

test "scan string with escapes" {
    var s = Scanner{ .input = "\"hello\\nworld\"" };
    const tok = try s.next();
    try testing.expectEqualStrings("hello\\nworld", tok.string);
    try testing.expect(Scanner.stringHasEscapes(tok.string));
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
    try s.skipValue(); // skip the nested {"b": [1,2,3]}
    try testing.expectEqualStrings("c", (try s.next()).string);
    try testing.expectEqualStrings("4", (try s.next()).number);
    try testing.expectEqual(Token.object_end, try s.next());
}

test "unexpected eof" {
    var s = Scanner{ .input = "" };
    try testing.expectError(error.UnexpectedEof, s.next());
}

test "unexpected token" {
    var s = Scanner{ .input = "xyz" };
    try testing.expectError(error.UnexpectedToken, s.next());
}
