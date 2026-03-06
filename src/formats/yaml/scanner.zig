const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ScalarStyle = enum {
    plain,
    single_quoted,
    double_quoted,
    literal,
    folded,
};

pub const Token = union(enum) {
    stream_start,
    stream_end,
    document_start,
    document_end,
    mapping_start,
    mapping_end,
    sequence_start,
    sequence_end,
    key_indicator,
    value_indicator,
    scalar: Scalar,
    anchor: []const u8,
    alias: []const u8,
    tag: []const u8,
};

pub const Scalar = struct {
    value: []const u8,
    style: ScalarStyle,
    owned: bool = false,
};

pub const ScanError = error{
    OutOfMemory,
    UnexpectedEof,
    InvalidYaml,
    InvalidEscape,
    InvalidUnicode,
};

pub const Scanner = struct {
    input: []const u8,
    pos: usize = 0,
    line: usize = 1,
    column: usize = 0,
    allocator: Allocator,
    indent_stack: [64]i32 = [_]i32{-1} ++ [_]i32{0} ** 63,
    indent_depth: usize = 0,
    // Pending synthetic tokens (mapping_end / sequence_end) from indent drops.
    pending_ends: usize = 0,
    pending_type: PendingType = .none,
    flow_level: u32 = 0,
    done: bool = false,
    had_document_start: bool = false,
    // Track context: in a mapping or sequence at each indent level.
    context_stack: [64]Context = [_]Context{.none} ** 64,

    const Context = enum { none, mapping, sequence };
    const PendingType = enum { none, mapping_end, sequence_end, mixed };

    pub fn init(allocator: Allocator, input: []const u8) Scanner {
        return .{ .input = input, .allocator = allocator };
    }

    pub fn next(self: *Scanner) ScanError!Token {
        // Drain pending close tokens from indent drops.
        if (self.pending_ends > 0) {
            self.pending_ends -= 1;
            const ctx = self.context_stack[self.indent_depth + self.pending_ends + 1];
            return switch (ctx) {
                .mapping => .mapping_end,
                .sequence => .sequence_end,
                .none => .mapping_end,
            };
        }

        if (self.done) return .stream_end;

        self.skipWhitespaceAndComments();

        if (self.pos >= self.input.len) {
            // Close all open contexts.
            if (self.indent_depth > 0) {
                self.pending_ends = self.indent_depth - 1;
                const ctx = self.context_stack[self.indent_depth];
                self.indent_depth = 0;
                return switch (ctx) {
                    .mapping => .mapping_end,
                    .sequence => .sequence_end,
                    .none => { self.done = true; return .stream_end; },
                };
            }
            self.done = true;
            return .stream_end;
        }

        const c = self.input[self.pos];

        // Document markers.
        if (self.column == 0) {
            if (self.startsWith("---") and self.isBreakOrEof(self.pos + 3)) {
                self.pos += 3;
                self.column += 3;
                self.had_document_start = true;
                return .document_start;
            }
            if (self.startsWith("...") and self.isBreakOrEof(self.pos + 3)) {
                self.pos += 3;
                self.column += 3;
                return .document_end;
            }
        }

        // Flow indicators.
        if (c == '{') {
            self.pos += 1;
            self.column += 1;
            self.flow_level += 1;
            return .mapping_start;
        }
        if (c == '}') {
            self.pos += 1;
            self.column += 1;
            if (self.flow_level > 0) self.flow_level -= 1;
            return .mapping_end;
        }
        if (c == '[') {
            self.pos += 1;
            self.column += 1;
            self.flow_level += 1;
            return .sequence_start;
        }
        if (c == ']') {
            self.pos += 1;
            self.column += 1;
            if (self.flow_level > 0) self.flow_level -= 1;
            return .sequence_end;
        }
        if (c == ',' and self.flow_level > 0) {
            self.pos += 1;
            self.column += 1;
            self.skipWhitespaceInline();
            return self.next();
        }

        // Anchor.
        if (c == '&') {
            self.pos += 1;
            self.column += 1;
            return .{ .anchor = self.scanAnchorAlias() };
        }

        // Alias.
        if (c == '*') {
            self.pos += 1;
            self.column += 1;
            return .{ .alias = self.scanAnchorAlias() };
        }

        // Tag.
        if (c == '!') {
            return .{ .tag = self.scanTag() };
        }

        // Block sequence indicator.
        if (c == '-' and self.flow_level == 0) {
            if (self.pos + 1 >= self.input.len or isWhitespaceOrBreak(self.input[self.pos + 1])) {
                const indent: i32 = @intCast(self.column);
                try self.adjustIndent(indent, .sequence);
                self.pos += 1;
                self.column += 1;
                self.skipWhitespaceInline();
                return .sequence_start;
            }
        }

        // Explicit key indicator.
        if (c == '?' and self.flow_level == 0) {
            if (self.pos + 1 >= self.input.len or isWhitespaceOrBreak(self.input[self.pos + 1])) {
                self.pos += 1;
                self.column += 1;
                self.skipWhitespaceInline();
                return .key_indicator;
            }
        }

        // Value indicator (colon).
        if (c == ':') {
            if (self.flow_level > 0 or self.pos + 1 >= self.input.len or isWhitespaceOrBreak(self.input[self.pos + 1])) {
                self.pos += 1;
                self.column += 1;
                self.skipWhitespaceInline();
                return .value_indicator;
            }
        }

        // Quoted scalars.
        if (c == '"') return .{ .scalar = try self.scanDoubleQuotedScalar() };
        if (c == '\'') return .{ .scalar = try self.scanSingleQuotedScalar() };

        // Block scalars.
        if (c == '|' or c == '>') return .{ .scalar = try self.scanBlockScalar(c) };

        // Plain scalar — also handle implicit mapping keys.
        if (self.flow_level == 0) {
            const indent: i32 = @intCast(self.column);
            if (indent > self.indent_stack[self.indent_depth]) {
                try self.pushIndent(indent, .mapping);
                const scalar = self.scanPlainScalar();
                return .{ .scalar = scalar };
            }
        }

        return .{ .scalar = self.scanPlainScalar() };
    }

    fn adjustIndent(self: *Scanner, indent: i32, ctx: Context) ScanError!void {
        if (indent > self.indent_stack[self.indent_depth]) {
            try self.pushIndent(indent, ctx);
        } else {
            // Pop indent levels until we match.
            while (self.indent_depth > 0 and indent < self.indent_stack[self.indent_depth]) {
                self.indent_depth -= 1;
                self.pending_ends += 1;
            }
        }
    }

    fn pushIndent(self: *Scanner, indent: i32, ctx: Context) ScanError!void {
        if (self.indent_depth + 1 >= self.indent_stack.len) return error.InvalidYaml;
        self.indent_depth += 1;
        self.indent_stack[self.indent_depth] = indent;
        self.context_stack[self.indent_depth] = ctx;
    }

    fn scanPlainScalar(self: *Scanner) Scalar {
        const start = self.pos;
        var end = self.pos;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];

            // Stop at flow indicators in flow context.
            if (self.flow_level > 0 and (ch == ',' or ch == '}' or ch == ']' or ch == '{' or ch == '['))
                break;

            // Stop at ': ' or ':\n' or ':\r'.
            if (ch == ':' and self.pos + 1 < self.input.len and
                (self.input[self.pos + 1] == ' ' or self.input[self.pos + 1] == '\n' or
                self.input[self.pos + 1] == '\r' or self.input[self.pos + 1] == '\t'))
                break;

            // Colon at end of input.
            if (ch == ':' and self.pos + 1 >= self.input.len) break;

            // Stop at comment (space + #).
            if (ch == '#' and self.pos > start and self.input[self.pos - 1] == ' ')
                break;

            // Stop at newline.
            if (ch == '\n' or ch == '\r') break;

            self.pos += 1;
            self.column += 1;
            // Track the end position, trimming trailing whitespace.
            if (ch != ' ' and ch != '\t') end = self.pos;
        }

        return .{ .value = self.input[start..end], .style = .plain };
    }

    fn scanDoubleQuotedScalar(self: *Scanner) ScanError!Scalar {
        self.pos += 1; // skip opening "
        self.column += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '"') {
                self.pos += 1;
                self.column += 1;
                return .{
                    .value = out.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                    .style = .double_quoted,
                    .owned = true,
                };
            }
            if (ch == '\\') {
                self.pos += 1;
                self.column += 1;
                try self.scanEscape(&out);
            } else if (ch == '\n') {
                out.append(self.allocator, '\n') catch return error.OutOfMemory;
                self.pos += 1;
                self.line += 1;
                self.column = 0;
            } else if (ch == '\r') {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n')
                    self.pos += 1;
                out.append(self.allocator, '\n') catch return error.OutOfMemory;
                self.line += 1;
                self.column = 0;
            } else {
                out.append(self.allocator, ch) catch return error.OutOfMemory;
                self.pos += 1;
                self.column += 1;
            }
        }
        return error.UnexpectedEof;
    }

    fn scanSingleQuotedScalar(self: *Scanner) ScanError!Scalar {
        self.pos += 1;
        self.column += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '\'') {
                // Doubled single quote = escaped.
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                    out.append(self.allocator, '\'') catch return error.OutOfMemory;
                    self.pos += 2;
                    self.column += 2;
                    continue;
                }
                self.pos += 1;
                self.column += 1;
                return .{
                    .value = out.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                    .style = .single_quoted,
                    .owned = true,
                };
            }
            if (ch == '\n') {
                out.append(self.allocator, '\n') catch return error.OutOfMemory;
                self.pos += 1;
                self.line += 1;
                self.column = 0;
            } else if (ch == '\r') {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n')
                    self.pos += 1;
                out.append(self.allocator, '\n') catch return error.OutOfMemory;
                self.line += 1;
                self.column = 0;
            } else {
                out.append(self.allocator, ch) catch return error.OutOfMemory;
                self.pos += 1;
                self.column += 1;
            }
        }
        return error.UnexpectedEof;
    }

    fn scanBlockScalar(self: *Scanner, indicator: u8) ScanError!Scalar {
        const is_literal = indicator == '|';
        self.pos += 1;
        self.column += 1;

        // Chomp indicator.
        var chomp: enum { clip, strip, keep } = .clip;
        var explicit_indent: ?u32 = null;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '-') {
                chomp = .strip;
                self.pos += 1;
                self.column += 1;
            } else if (ch == '+') {
                chomp = .keep;
                self.pos += 1;
                self.column += 1;
            } else if (ch >= '1' and ch <= '9') {
                explicit_indent = ch - '0';
                self.pos += 1;
                self.column += 1;
            } else {
                break;
            }
        }

        // Skip to end of line.
        self.skipToEndOfLine();
        self.skipLineBreak();

        // Determine content indent.
        const content_indent = if (explicit_indent) |ei|
            @as(i32, @intCast(self.indent_stack[self.indent_depth])) + @as(i32, @intCast(ei))
        else blk: {
            // Auto-detect from first non-empty line.
            const saved = self.pos;
            while (self.pos < self.input.len) {
                if (self.input[self.pos] == ' ') {
                    self.pos += 1;
                } else if (self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                    self.skipLineBreak();
                } else {
                    break;
                }
            }
            const detected: i32 = @intCast(self.pos - saved);
            // Re-count from the line start.
            var line_start = self.pos;
            while (line_start > 0 and self.input[line_start - 1] != '\n' and self.input[line_start - 1] != '\r') {
                line_start -= 1;
            }
            const indent: i32 = @intCast(self.pos - line_start);
            self.pos = saved;
            break :blk if (indent > 0) indent else detected;
        };

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        // Collect content lines.
        while (self.pos < self.input.len) {
            // Count leading spaces.
            var line_indent: i32 = 0;
            const line_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] == ' ') {
                self.pos += 1;
                line_indent += 1;
            }

            // Empty line.
            if (self.pos >= self.input.len or self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                out.append(self.allocator, '\n') catch return error.OutOfMemory;
                if (self.pos < self.input.len) self.skipLineBreak();
                continue;
            }

            // Dedented line ends the block.
            if (line_indent < content_indent) {
                self.pos = line_start;
                break;
            }

            // Keep extra indentation beyond content_indent.
            const extra: usize = @intCast(line_indent - content_indent);
            for (0..extra) |_| {
                out.append(self.allocator, ' ') catch return error.OutOfMemory;
            }

            // Read content until end of line.
            while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
                out.append(self.allocator, self.input[self.pos]) catch return error.OutOfMemory;
                self.pos += 1;
            }

            if (self.pos < self.input.len) {
                if (is_literal) {
                    out.append(self.allocator, '\n') catch return error.OutOfMemory;
                } else {
                    // Folded: replace single newline with space, keep double newlines.
                    out.append(self.allocator, '\n') catch return error.OutOfMemory;
                }
                self.skipLineBreak();
            }
        }

        // Apply chomping to trailing newlines.
        var result = out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        switch (chomp) {
            .strip => {
                var len = result.len;
                while (len > 0 and result[len - 1] == '\n') len -= 1;
                if (len != result.len) {
                    const trimmed = self.allocator.alloc(u8, len) catch {
                        self.allocator.free(result);
                        return error.OutOfMemory;
                    };
                    @memcpy(trimmed, result[0..len]);
                    self.allocator.free(result);
                    result = trimmed;
                }
            },
            .clip => {
                // Keep exactly one trailing newline.
                var len = result.len;
                while (len > 0 and result[len - 1] == '\n') len -= 1;
                if (len < result.len) {
                    const trimmed = self.allocator.alloc(u8, len + 1) catch {
                        self.allocator.free(result);
                        return error.OutOfMemory;
                    };
                    @memcpy(trimmed[0..len], result[0..len]);
                    trimmed[len] = '\n';
                    self.allocator.free(result);
                    result = trimmed;
                }
            },
            .keep => {}, // keep all trailing newlines as-is
        }

        self.column = 0;
        self.line += 1;

        return .{
            .value = result,
            .style = if (is_literal) .literal else .folded,
            .owned = true,
        };
    }

    fn scanEscape(self: *Scanner, out: *std.ArrayList(u8)) ScanError!void {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const ch = self.input[self.pos];
        self.pos += 1;
        self.column += 1;
        switch (ch) {
            '0' => out.append(self.allocator, 0) catch return error.OutOfMemory,
            'a' => out.append(self.allocator, 0x07) catch return error.OutOfMemory,
            'b' => out.append(self.allocator, 0x08) catch return error.OutOfMemory,
            't', '\t' => out.append(self.allocator, '\t') catch return error.OutOfMemory,
            'n' => out.append(self.allocator, '\n') catch return error.OutOfMemory,
            'v' => out.append(self.allocator, 0x0b) catch return error.OutOfMemory,
            'f' => out.append(self.allocator, 0x0c) catch return error.OutOfMemory,
            'r' => out.append(self.allocator, '\r') catch return error.OutOfMemory,
            'e' => out.append(self.allocator, 0x1b) catch return error.OutOfMemory,
            ' ' => out.append(self.allocator, ' ') catch return error.OutOfMemory,
            '"' => out.append(self.allocator, '"') catch return error.OutOfMemory,
            '/' => out.append(self.allocator, '/') catch return error.OutOfMemory,
            '\\' => out.append(self.allocator, '\\') catch return error.OutOfMemory,
            'x' => try self.scanUnicodeEscape(out, 2),
            'u' => try self.scanUnicodeEscape(out, 4),
            'U' => try self.scanUnicodeEscape(out, 8),
            '\n' => {
                self.line += 1;
                self.column = 0;
                self.skipWhitespaceInline();
            },
            '\r' => {
                if (self.pos < self.input.len and self.input[self.pos] == '\n')
                    self.pos += 1;
                self.line += 1;
                self.column = 0;
                self.skipWhitespaceInline();
            },
            else => return error.InvalidEscape,
        }
    }

    fn scanUnicodeEscape(self: *Scanner, out: *std.ArrayList(u8), comptime len: u8) ScanError!void {
        if (self.pos + len > self.input.len) return error.UnexpectedEof;
        var cp: u21 = 0;
        for (0..len) |_| {
            const d = hexDigit(self.input[self.pos]) orelse return error.InvalidUnicode;
            cp = cp * 16 + d;
            self.pos += 1;
            self.column += 1;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUnicode;
        out.appendSlice(self.allocator, buf[0..n]) catch return error.OutOfMemory;
    }

    fn scanAnchorAlias(self: *Scanner) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (isWhitespaceOrBreak(ch) or ch == ',' or ch == '}' or ch == ']' or
                ch == '{' or ch == '[' or ch == ':')
                break;
            self.pos += 1;
            self.column += 1;
        }
        return self.input[start..self.pos];
    }

    fn scanTag(self: *Scanner) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len and !isWhitespaceOrBreak(self.input[self.pos])) {
            self.pos += 1;
            self.column += 1;
        }
        return self.input[start..self.pos];
    }

    fn skipWhitespaceAndComments(self: *Scanner) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ' ' or ch == '\t') {
                self.pos += 1;
                self.column += 1;
            } else if (ch == '\n') {
                self.pos += 1;
                self.line += 1;
                self.column = 0;
            } else if (ch == '\r') {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n')
                    self.pos += 1;
                self.line += 1;
                self.column = 0;
            } else if (ch == '#') {
                while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r')
                    self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skipWhitespaceInline(self: *Scanner) void {
        while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) {
            self.pos += 1;
            self.column += 1;
        }
    }

    fn skipToEndOfLine(self: *Scanner) void {
        while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
            self.pos += 1;
        }
    }

    fn skipLineBreak(self: *Scanner) void {
        if (self.pos < self.input.len and self.input[self.pos] == '\r') {
            self.pos += 1;
        }
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        }
        self.line += 1;
        self.column = 0;
    }

    fn startsWith(self: *Scanner, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos..][0..prefix.len], prefix);
    }

    fn isBreakOrEof(self: *Scanner, pos: usize) bool {
        if (pos >= self.input.len) return true;
        return self.input[pos] == '\n' or self.input[pos] == '\r' or self.input[pos] == ' ';
    }
};

fn isWhitespaceOrBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn hexDigit(c: u8) ?u21 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

const testing = std.testing;

test "scan plain scalar" {
    var s = Scanner.init(testing.allocator, "hello");
    const tok = try s.next();
    try testing.expectEqualStrings("hello", tok.scalar.value);
    try testing.expectEqual(ScalarStyle.plain, tok.scalar.style);
}

test "scan double quoted scalar" {
    var s = Scanner.init(testing.allocator, "\"hello world\"");
    const tok = try s.next();
    defer testing.allocator.free(tok.scalar.value);
    try testing.expectEqualStrings("hello world", tok.scalar.value);
    try testing.expectEqual(ScalarStyle.double_quoted, tok.scalar.style);
}

test "scan double quoted escapes" {
    var s = Scanner.init(testing.allocator, "\"a\\nb\\t\"");
    const tok = try s.next();
    defer testing.allocator.free(tok.scalar.value);
    try testing.expectEqualStrings("a\nb\t", tok.scalar.value);
}

test "scan single quoted scalar" {
    var s = Scanner.init(testing.allocator, "'hello'");
    const tok = try s.next();
    defer testing.allocator.free(tok.scalar.value);
    try testing.expectEqualStrings("hello", tok.scalar.value);
}

test "scan single quoted escape" {
    var s = Scanner.init(testing.allocator, "'it''s'");
    const tok = try s.next();
    defer testing.allocator.free(tok.scalar.value);
    try testing.expectEqualStrings("it's", tok.scalar.value);
}

test "scan flow mapping" {
    var s = Scanner.init(testing.allocator, "{a: 1}");
    try testing.expectEqual(Token.mapping_start, try s.next());
    const key = try s.next();
    try testing.expectEqualStrings("a", key.scalar.value);
    try testing.expectEqual(Token.value_indicator, try s.next());
    const val = try s.next();
    try testing.expectEqualStrings("1", val.scalar.value);
    try testing.expectEqual(Token.mapping_end, try s.next());
}

test "scan flow sequence" {
    var s = Scanner.init(testing.allocator, "[1, 2, 3]");
    try testing.expectEqual(Token.sequence_start, try s.next());
    try testing.expectEqualStrings("1", (try s.next()).scalar.value);
    try testing.expectEqualStrings("2", (try s.next()).scalar.value);
    try testing.expectEqualStrings("3", (try s.next()).scalar.value);
    try testing.expectEqual(Token.sequence_end, try s.next());
}

test "scan unicode escape" {
    var s = Scanner.init(testing.allocator, "\"\\u0041\"");
    const tok = try s.next();
    defer testing.allocator.free(tok.scalar.value);
    try testing.expectEqualStrings("A", tok.scalar.value);
}

test "scan comment ignored" {
    var s = Scanner.init(testing.allocator, "hello # comment");
    const tok = try s.next();
    try testing.expectEqualStrings("hello", tok.scalar.value);
}

test "scan stream end" {
    var s = Scanner.init(testing.allocator, "");
    try testing.expectEqual(Token.stream_end, try s.next());
}
