const std = @import("std");
const compat = @import("compat");

const Allocator = std.mem.Allocator;

pub const ParseError = error{
    OutOfMemory,
    UnexpectedEof,
    InvalidYaml,
    InvalidEscape,
    InvalidUnicode,
    DuplicateKey,
    AliasDepthExceeded,
};

pub const Value = union(enum) {
    null_val: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    sequence: []const Value,
    mapping: Mapping,

    pub fn deinit(self: *const Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .sequence => |arr| {
                for (arr) |*elem| elem.deinit(allocator);
                allocator.free(arr);
            },
            .mapping => |*m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                var mut: Mapping = m.*;
                mut.deinit(allocator);
            },
            .null_val, .boolean, .integer, .float => {},
        }
    }
};

pub const Mapping = compat.StringArrayHashMap(Value);

/// Parse YAML input into a Value tree.
pub fn parse(allocator: Allocator, input: []const u8) ParseError!Value {
    var p = Parser{
        .input = input,
        .pos = 0,
        .allocator = allocator,
        .anchors = std.StringHashMap(Value).init(allocator),
    };
    defer p.anchors.deinit();
    return p.parseDocument();
}

/// Parse multi-document YAML input. Documents are separated by `---`
/// and optionally terminated by `...`.
pub fn parseAll(allocator: Allocator, input: []const u8) ParseError![]Value {
    var docs: std.ArrayList(Value) = .empty;
    errdefer {
        for (docs.items) |*v| v.deinit(allocator);
        docs.deinit(allocator);
    }
    var p = Parser{
        .input = input,
        .pos = 0,
        .allocator = allocator,
        .anchors = std.StringHashMap(Value).init(allocator),
    };
    defer p.anchors.deinit();

    while (true) {
        p.skipWhitespaceAndComments();
        if (p.pos >= p.input.len) break;

        // Skip document end marker.
        if (p.startsWith("...")) {
            p.pos += 3;
            p.skipWhitespaceInline();
            if (p.pos < p.input.len and (p.input[p.pos] == '\n' or p.input[p.pos] == '\r'))
                p.skipLineBreak();
            continue;
        }

        const doc = try p.parseDocument();
        docs.append(allocator, doc) catch return error.OutOfMemory;
    }

    return docs.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: Allocator,
    anchors: std.StringHashMap(Value),

    fn parseDocument(self: *Parser) ParseError!Value {
        self.skipWhitespaceAndComments();

        // Skip document start marker.
        if (self.startsWith("---")) {
            self.pos += 3;
            self.skipWhitespaceInline();
            if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r'))
                self.skipLineBreak();
        }

        self.skipWhitespaceAndComments();

        if (self.pos >= self.input.len) return .null_val;

        return self.parseNode(0);
    }

    fn parseNode(self: *Parser, min_indent: i32) ParseError!Value {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.input.len) return .null_val;

        // Handle anchor.
        var anchor_name: ?[]const u8 = null;
        if (self.input[self.pos] == '&') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and !isWhitespaceOrBreak(self.input[self.pos]))
                self.pos += 1;
            anchor_name = self.input[start..self.pos];
            self.skipWhitespaceInline();
        }

        // Handle alias.
        if (self.pos < self.input.len and self.input[self.pos] == '*') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and !isWhitespaceOrBreak(self.input[self.pos]) and
                self.input[self.pos] != ',' and self.input[self.pos] != '}' and self.input[self.pos] != ']')
                self.pos += 1;
            const alias_name = self.input[start..self.pos];
            const val = self.anchors.get(alias_name) orelse return error.InvalidYaml;
            return try self.deepClone(&val, 0);
        }

        // Skip tag.
        if (self.pos < self.input.len and self.input[self.pos] == '!') {
            while (self.pos < self.input.len and !isWhitespaceOrBreak(self.input[self.pos]))
                self.pos += 1;
            self.skipWhitespaceInline();
        }

        if (self.pos >= self.input.len) return .null_val;

        const c = self.input[self.pos];

        var result: Value = undefined;

        if (c == '{') {
            result = try self.parseFlowMapping();
        } else if (c == '[') {
            result = try self.parseFlowSequence();
        } else if (c == '-' and self.isBlockSequenceIndicator()) {
            result = try self.parseBlockSequence(min_indent);
        } else if (c == '"') {
            result = try self.parseDoubleQuotedScalar();
        } else if (c == '\'') {
            result = try self.parseSingleQuotedScalar();
        } else if (c == '|' or c == '>') {
            result = try self.parseBlockScalar();
        } else {
            // Plain scalar — but check if this is a mapping key (has ': ' after it).
            const saved_pos = self.pos;
            const plain = self.scanPlainScalar();

            self.skipWhitespaceInline();

            if (self.pos < self.input.len and self.input[self.pos] == ':' and
                (self.pos + 1 >= self.input.len or isWhitespaceOrBreak(self.input[self.pos + 1])))
            {
                // This is a mapping key — rewind and parse as block mapping.
                self.pos = saved_pos;
                result = try self.parseBlockMapping(min_indent);
            } else {
                result = resolveScalarType(plain, .plain);
            }
        }

        if (anchor_name) |name| {
            self.anchors.put(name, result) catch return error.OutOfMemory;
        }

        return result;
    }

    fn parseBlockMapping(self: *Parser, min_indent: i32) ParseError!Value {
        var map: Mapping = .empty;
        errdefer freeMapping(self.allocator, &map);

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.input.len) break;

            const indent = self.currentIndent();
            if (indent < min_indent) break;

            // Document end marker.
            if (self.startsWith("---") or self.startsWith("...")) break;

            // Parse key.
            const key = try self.parseScalarKey();
            self.skipWhitespaceInline();

            // Expect ':'.
            if (self.pos >= self.input.len or self.input[self.pos] != ':')
                break;
            self.pos += 1;
            self.skipWhitespaceInline();

            // Parse value.
            var value: Value = undefined;
            if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                // Value is on the next line(s).
                self.skipLineBreak();
                self.skipWhitespaceAndComments();
                if (self.pos < self.input.len) {
                    const val_indent = self.currentIndent();
                    if (val_indent > indent) {
                        value = try self.parseNode(val_indent);
                    } else {
                        value = .null_val;
                    }
                } else {
                    value = .null_val;
                }
            } else if (self.pos >= self.input.len) {
                value = .null_val;
            } else {
                value = try self.parseInlineValue();
            }

            // Handle merge key.
            if (std.mem.eql(u8, key, "<<")) {
                if (value == .mapping) {
                    var it = value.mapping.iterator();
                    while (it.next()) |entry| {
                        const gop = map.getOrPut(self.allocator, entry.key_ptr.*) catch return error.OutOfMemory;
                        if (!gop.found_existing) {
                            const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                            gop.key_ptr.* = key_copy;
                            gop.value_ptr.* = try self.deepClone(entry.value_ptr, 0);
                        }
                    }
                    self.allocator.free(key);
                    value.deinit(self.allocator);
                    continue;
                }
            }

            const gop = map.getOrPut(self.allocator, key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                self.allocator.free(key);
                gop.value_ptr.deinit(self.allocator);
                gop.value_ptr.* = value;
            } else {
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }
        }

        return .{ .mapping = map };
    }

    fn parseBlockSequence(self: *Parser, min_indent: i32) ParseError!Value {
        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |*v| v.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.input.len) break;

            const indent = self.currentIndent();
            if (indent < min_indent) break;

            if (self.input[self.pos] != '-' or !self.isBlockSequenceIndicator()) break;

            self.pos += 1; // skip '-'
            self.skipWhitespaceInline();

            // Column of content after "- ".
            const content_col = self.columnOf(self.pos);

            var value: Value = undefined;
            if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                self.skipLineBreak();
                self.skipWhitespaceAndComments();
                if (self.pos < self.input.len) {
                    const val_indent = self.currentIndent();
                    if (val_indent > indent) {
                        value = try self.parseNode(val_indent);
                    } else {
                        value = .null_val;
                    }
                } else {
                    value = .null_val;
                }
            } else if (self.pos >= self.input.len) {
                value = .null_val;
            } else {
                // Inline content after "- ": check if it's a mapping key.
                value = try self.parseSequenceItemValue(content_col);
            }

            items.append(self.allocator, value) catch return error.OutOfMemory;
        }

        return .{ .sequence = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }

    fn parseInlineValue(self: *Parser) ParseError!Value {
        if (self.pos >= self.input.len) return .null_val;

        const c = self.input[self.pos];

        if (c == '{') return self.parseFlowMapping();
        if (c == '[') return self.parseFlowSequence();
        if (c == '"') return self.parseDoubleQuotedScalar();
        if (c == '\'') return self.parseSingleQuotedScalar();
        if (c == '|' or c == '>') return self.parseBlockScalar();

        // Handle anchor in inline value.
        if (c == '&') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and !isWhitespaceOrBreak(self.input[self.pos]))
                self.pos += 1;
            const anchor_name = self.input[start..self.pos];
            self.skipWhitespaceInline();
            const val = try self.parseInlineValue();
            self.anchors.put(anchor_name, val) catch return error.OutOfMemory;
            return val;
        }

        // Handle alias.
        if (c == '*') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and !isWhitespaceOrBreak(self.input[self.pos]) and
                self.input[self.pos] != ',' and self.input[self.pos] != '}' and self.input[self.pos] != ']')
                self.pos += 1;
            const alias_name = self.input[start..self.pos];
            const val = self.anchors.get(alias_name) orelse return error.InvalidYaml;
            return try self.deepClone(&val, 0);
        }

        const plain = self.scanPlainScalar();
        self.skipToEndOfLine();
        return resolveScalarType(plain, .plain);
    }

    fn parseFlowMapping(self: *Parser) ParseError!Value {
        self.pos += 1; // skip '{'
        self.skipWhitespaceAndComments();

        var map: Mapping = .empty;
        errdefer freeMapping(self.allocator, &map);

        if (self.pos < self.input.len and self.input[self.pos] == '}') {
            self.pos += 1;
            return .{ .mapping = map };
        }

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();
            if (self.pos < self.input.len and self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }

            // Skip comma.
            if (self.pos < self.input.len and self.input[self.pos] == ',') {
                self.pos += 1;
                self.skipWhitespaceAndComments();
                if (self.pos < self.input.len and self.input[self.pos] == '}') {
                    self.pos += 1;
                    break;
                }
            }

            const key = try self.parseFlowKey();
            self.skipWhitespaceAndComments();

            if (self.pos >= self.input.len or self.input[self.pos] != ':')
                return error.InvalidYaml;
            self.pos += 1;
            self.skipWhitespaceAndComments();

            const value = try self.parseFlowValue();

            const gop = map.getOrPut(self.allocator, key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                self.allocator.free(key);
                gop.value_ptr.deinit(self.allocator);
                gop.value_ptr.* = value;
            } else {
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }
        }

        return .{ .mapping = map };
    }

    fn parseFlowSequence(self: *Parser) ParseError!Value {
        self.pos += 1; // skip '['
        self.skipWhitespaceAndComments();

        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |*v| v.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        if (self.pos < self.input.len and self.input[self.pos] == ']') {
            self.pos += 1;
            return .{ .sequence = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
        }

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();
            if (self.pos < self.input.len and self.input[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            if (self.pos < self.input.len and self.input[self.pos] == ',') {
                self.pos += 1;
                self.skipWhitespaceAndComments();
                if (self.pos < self.input.len and self.input[self.pos] == ']') {
                    self.pos += 1;
                    break;
                }
                continue;
            }

            const val = try self.parseFlowValue();
            items.append(self.allocator, val) catch return error.OutOfMemory;
        }

        return .{ .sequence = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
    }

    fn parseFlowKey(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] == '"') {
            const sv = try self.parseDoubleQuotedScalar();
            if (sv != .string) return error.InvalidYaml;
            return sv.string;
        }
        if (self.input[self.pos] == '\'') {
            const sv = try self.parseSingleQuotedScalar();
            if (sv != .string) return error.InvalidYaml;
            return sv.string;
        }
        // Plain key.
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ':' or ch == ',' or ch == '}' or ch == ']' or ch == '{' or ch == '[' or ch == '\n' or ch == '\r') break;
            self.pos += 1;
        }
        const raw = compat.trimEnd(u8, self.input[start..self.pos], " \t");
        return self.allocator.dupe(u8, raw) catch return error.OutOfMemory;
    }

    fn parseFlowValue(self: *Parser) ParseError!Value {
        if (self.pos >= self.input.len) return .null_val;
        const c = self.input[self.pos];
        if (c == '{') return self.parseFlowMapping();
        if (c == '[') return self.parseFlowSequence();
        if (c == '"') return self.parseDoubleQuotedScalar();
        if (c == '\'') return self.parseSingleQuotedScalar();

        // Handle alias in flow context.
        if (c == '*') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and !isWhitespaceOrBreak(self.input[self.pos]) and
                self.input[self.pos] != ',' and self.input[self.pos] != '}' and self.input[self.pos] != ']')
                self.pos += 1;
            const alias_name = self.input[start..self.pos];
            const val = self.anchors.get(alias_name) orelse return error.InvalidYaml;
            return try self.deepClone(&val, 0);
        }

        // Plain scalar in flow context.
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ',' or ch == '}' or ch == ']' or ch == '\n' or ch == '\r') break;
            // Colon followed by space/flow indicator in flow context.
            if (ch == ':' and self.pos + 1 < self.input.len) {
                const n = self.input[self.pos + 1];
                if (n == ' ' or n == ',' or n == '}' or n == ']') break;
            }
            self.pos += 1;
        }
        const raw = compat.trimEnd(u8, self.input[start..self.pos], " \t");
        return resolveScalarType(raw, .plain);
    }

    fn parseDoubleQuotedScalar(self: *Parser) ParseError!Value {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '"') {
                self.pos += 1;
                return .{ .string = out.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
            }
            if (ch == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) return error.UnexpectedEof;
                try self.parseEscape(&out);
            } else {
                out.append(self.allocator, ch) catch return error.OutOfMemory;
                self.pos += 1;
            }
        }
        return error.UnexpectedEof;
    }

    fn parseSingleQuotedScalar(self: *Parser) ParseError!Value {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '\'') {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\'') {
                    out.append(self.allocator, '\'') catch return error.OutOfMemory;
                    self.pos += 2;
                    continue;
                }
                self.pos += 1;
                return .{ .string = out.toOwnedSlice(self.allocator) catch return error.OutOfMemory };
            }
            out.append(self.allocator, ch) catch return error.OutOfMemory;
            self.pos += 1;
        }
        return error.UnexpectedEof;
    }

    fn parseBlockScalar(self: *Parser) ParseError!Value {
        const is_literal = self.input[self.pos] == '|';
        self.pos += 1;

        var chomp: enum { clip, strip, keep } = .clip;
        var explicit_indent: ?u32 = null;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '-') {
                chomp = .strip;
                self.pos += 1;
            } else if (ch == '+') {
                chomp = .keep;
                self.pos += 1;
            } else if (ch >= '1' and ch <= '9') {
                explicit_indent = ch - '0';
                self.pos += 1;
            } else {
                break;
            }
        }
        self.skipToEndOfLine();
        self.skipLineBreak();

        // Detect content indent.
        var content_indent: usize = 0;
        if (explicit_indent) |ei| {
            content_indent = ei;
        } else {
            const saved = self.pos;
            // Skip empty lines.
            while (self.pos < self.input.len) {
                var spaces: usize = 0;
                while (self.pos < self.input.len and self.input[self.pos] == ' ') {
                    self.pos += 1;
                    spaces += 1;
                }
                if (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
                    content_indent = spaces;
                    break;
                }
                if (self.pos < self.input.len) self.skipLineBreak();
            }
            self.pos = saved;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            var line_spaces: usize = 0;
            const line_start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] == ' ') {
                self.pos += 1;
                line_spaces += 1;
            }

            // Empty line.
            if (self.pos >= self.input.len or self.input[self.pos] == '\n' or self.input[self.pos] == '\r') {
                out.append(self.allocator, '\n') catch return error.OutOfMemory;
                if (self.pos < self.input.len) self.skipLineBreak();
                continue;
            }

            if (line_spaces < content_indent) {
                self.pos = line_start;
                break;
            }

            // Extra indentation.
            const extra = line_spaces - content_indent;
            for (0..extra) |_| {
                out.append(self.allocator, ' ') catch return error.OutOfMemory;
            }

            while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r') {
                out.append(self.allocator, self.input[self.pos]) catch return error.OutOfMemory;
                self.pos += 1;
            }

            if (self.pos < self.input.len) {
                if (is_literal) {
                    out.append(self.allocator, '\n') catch return error.OutOfMemory;
                } else {
                    out.append(self.allocator, '\n') catch return error.OutOfMemory;
                }
                self.skipLineBreak();
            }
        }

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
            .keep => {},
        }

        return .{ .string = result };
    }

    fn parseScalarKey(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] == '"') {
            const v = try self.parseDoubleQuotedScalar();
            if (v != .string) return error.InvalidYaml;
            return v.string;
        }
        if (self.input[self.pos] == '\'') {
            const v = try self.parseSingleQuotedScalar();
            if (v != .string) return error.InvalidYaml;
            return v.string;
        }
        // Plain scalar key.
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ':' and (self.pos + 1 >= self.input.len or isWhitespaceOrBreak(self.input[self.pos + 1]))) break;
            if (ch == '\n' or ch == '\r') break;
            self.pos += 1;
        }
        const raw = compat.trimEnd(u8, self.input[start..self.pos], " \t");
        return self.allocator.dupe(u8, raw) catch return error.OutOfMemory;
    }

    fn scanPlainScalar(self: *Parser) []const u8 {
        const start = self.pos;
        var end = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ':' and self.pos + 1 < self.input.len and
                (self.input[self.pos + 1] == ' ' or isBreak(self.input[self.pos + 1])))
                break;
            if (ch == ':' and self.pos + 1 >= self.input.len) break;
            if (ch == '#' and self.pos > start and self.input[self.pos - 1] == ' ') break;
            if (ch == '\n' or ch == '\r') break;
            self.pos += 1;
            if (ch != ' ' and ch != '\t') end = self.pos;
        }
        return self.input[start..end];
    }

    fn parseEscape(self: *Parser, out: *std.ArrayList(u8)) ParseError!void {
        const ch = self.input[self.pos];
        self.pos += 1;
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
            'x' => try self.parseUnicodeEscape(out, 2),
            'u' => try self.parseUnicodeEscape(out, 4),
            'U' => try self.parseUnicodeEscape(out, 8),
            '\n', '\r' => {
                // Escaped line break.
                if (ch == '\r' and self.pos < self.input.len and self.input[self.pos] == '\n')
                    self.pos += 1;
            },
            else => return error.InvalidEscape,
        }
    }

    fn parseUnicodeEscape(self: *Parser, out: *std.ArrayList(u8), comptime len: u8) ParseError!void {
        if (self.pos + len > self.input.len) return error.UnexpectedEof;
        var cp: u21 = 0;
        for (0..len) |_| {
            const d = hexDigit(self.input[self.pos]) orelse return error.InvalidUnicode;
            cp = cp * 16 + d;
            self.pos += 1;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidUnicode;
        out.appendSlice(self.allocator, buf[0..n]) catch return error.OutOfMemory;
    }

    fn deepClone(self: *Parser, val: *const Value, depth: usize) ParseError!Value {
        if (depth > 64) return error.AliasDepthExceeded;
        return switch (val.*) {
            .null_val => .null_val,
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = self.allocator.dupe(u8, s) catch return error.OutOfMemory },
            .sequence => |arr| {
                var items = self.allocator.alloc(Value, arr.len) catch return error.OutOfMemory;
                for (arr, 0..) |*elem, i| {
                    items[i] = try self.deepClone(elem, depth + 1);
                }
                return .{ .sequence = items };
            },
            .mapping => |*m| {
                var map: Mapping = .empty;
                var it = m.iterator();
                while (it.next()) |entry| {
                    const k = self.allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                    const v = try self.deepClone(entry.value_ptr, depth + 1);
                    map.put(self.allocator, k, v) catch return error.OutOfMemory;
                }
                return .{ .mapping = map };
            },
        };
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ' ' or ch == '\t') {
                self.pos += 1;
            } else if (ch == '\n' or ch == '\r') {
                self.skipLineBreak();
            } else if (ch == '#') {
                while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r')
                    self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skipWhitespaceInline(self: *Parser) void {
        while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t'))
            self.pos += 1;
    }

    fn skipToEndOfLine(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] != '\n' and self.input[self.pos] != '\r')
            self.pos += 1;
    }

    fn skipLineBreak(self: *Parser) void {
        if (self.pos < self.input.len and self.input[self.pos] == '\r')
            self.pos += 1;
        if (self.pos < self.input.len and self.input[self.pos] == '\n')
            self.pos += 1;
    }

    fn currentIndent(self: *Parser) i32 {
        // Find the start of the current line and count spaces.
        var line_start = self.pos;
        while (line_start > 0 and self.input[line_start - 1] != '\n' and self.input[line_start - 1] != '\r')
            line_start -= 1;
        var indent: i32 = 0;
        var p = line_start;
        while (p < self.input.len and self.input[p] == ' ') {
            p += 1;
            indent += 1;
        }
        return indent;
    }

    fn columnOf(self: *Parser, pos: usize) i32 {
        var line_start = pos;
        while (line_start > 0 and self.input[line_start - 1] != '\n' and self.input[line_start - 1] != '\r')
            line_start -= 1;
        return @intCast(pos - line_start);
    }

    /// Parse the inline value after "- " in a block sequence.
    /// Detects mapping keys (e.g., "- name: a\n  val: 1") and handles them
    /// as block mappings with `content_col` as the indent level.
    fn parseSequenceItemValue(self: *Parser, content_col: i32) ParseError!Value {
        if (self.pos >= self.input.len) return .null_val;

        const c = self.input[self.pos];
        if (c == '{') return self.parseFlowMapping();
        if (c == '[') return self.parseFlowSequence();
        if (c == '"') return self.parseDoubleQuotedScalar();
        if (c == '\'') return self.parseSingleQuotedScalar();
        if (c == '|' or c == '>') return self.parseBlockScalar();

        // Check for mapping key pattern: scan plain scalar, then look for ": ".
        const saved_pos = self.pos;
        const plain = self.scanPlainScalar();
        self.skipWhitespaceInline();

        if (self.pos < self.input.len and self.input[self.pos] == ':' and
            (self.pos + 1 >= self.input.len or isWhitespaceOrBreak(self.input[self.pos + 1])))
        {
            // Mapping key detected. Rewind and parse as block mapping using
            // content_col so continuation lines at the same column are included.
            self.pos = saved_pos;
            return self.parseBlockMappingAtCol(content_col);
        }

        self.skipToEndOfLine();
        return resolveScalarType(plain, .plain);
    }

    /// Block mapping parser that uses a column check instead of currentIndent().
    /// Needed for sequence-inline mappings where the first key is on the same
    /// line as "- " and currentIndent() returns the line indent, not content column.
    fn parseBlockMappingAtCol(self: *Parser, content_col: i32) ParseError!Value {
        var map: Mapping = .empty;
        errdefer freeMapping(self.allocator, &map);

        var first = true;
        while (self.pos < self.input.len) {
            if (!first) {
                self.skipWhitespaceAndComments();
            }
            first = false;
            if (self.pos >= self.input.len) break;

            // On first iteration, skip currentIndent check (we're mid-line).
            const col = self.columnOf(self.pos);
            if (col < content_col) break;
            if (col > content_col) break; // sub-indent belongs to the previous value

            if (self.startsWith("---") or self.startsWith("...")) break;
            // Stop at sequence indicators at this or lesser indent.
            if (self.input[self.pos] == '-' and self.isBlockSequenceIndicator()) break;

            const key = try self.parseScalarKey();
            self.skipWhitespaceInline();

            if (self.pos >= self.input.len or self.input[self.pos] != ':') {
                self.allocator.free(key);
                break;
            }
            self.pos += 1;
            self.skipWhitespaceInline();

            var value: Value = undefined;
            if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                self.skipLineBreak();
                self.skipWhitespaceAndComments();
                if (self.pos < self.input.len) {
                    const val_indent = self.currentIndent();
                    if (val_indent > content_col) {
                        value = try self.parseNode(val_indent);
                    } else {
                        value = .null_val;
                    }
                } else {
                    value = .null_val;
                }
            } else if (self.pos >= self.input.len) {
                value = .null_val;
            } else {
                value = try self.parseInlineValue();
            }

            // Handle merge key.
            if (std.mem.eql(u8, key, "<<")) {
                if (value == .mapping) {
                    var it = value.mapping.iterator();
                    while (it.next()) |entry| {
                        const gop = map.getOrPut(self.allocator, entry.key_ptr.*) catch return error.OutOfMemory;
                        if (!gop.found_existing) {
                            const key_copy = self.allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
                            gop.key_ptr.* = key_copy;
                            gop.value_ptr.* = try self.deepClone(entry.value_ptr, 0);
                        }
                    }
                    self.allocator.free(key);
                    value.deinit(self.allocator);
                    continue;
                }
            }

            const gop = map.getOrPut(self.allocator, key) catch return error.OutOfMemory;
            if (gop.found_existing) {
                self.allocator.free(key);
                gop.value_ptr.deinit(self.allocator);
                gop.value_ptr.* = value;
            } else {
                gop.key_ptr.* = key;
                gop.value_ptr.* = value;
            }
        }

        return .{ .mapping = map };
    }

    fn isBlockSequenceIndicator(self: *Parser) bool {
        if (self.input[self.pos] != '-') return false;
        if (self.pos + 1 >= self.input.len) return true;
        return isWhitespaceOrBreak(self.input[self.pos + 1]);
    }

    fn startsWith(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        return std.mem.eql(u8, self.input[self.pos..][0..prefix.len], prefix);
    }
};

/// Resolve YAML Core Schema types from a plain scalar.
pub fn resolveScalarType(raw: []const u8, style: @import("scanner.zig").ScalarStyle) Value {
    // Quoted scalars are always strings.
    if (style == .single_quoted or style == .double_quoted or style == .literal or style == .folded) {
        return .{ .string = raw };
    }

    if (raw.len == 0) return .null_val;

    // Null.
    if (std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "Null") or
        std.mem.eql(u8, raw, "NULL") or std.mem.eql(u8, raw, "~"))
        return .null_val;

    // Boolean.
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "True") or std.mem.eql(u8, raw, "TRUE"))
        return .{ .boolean = true };
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "False") or std.mem.eql(u8, raw, "FALSE"))
        return .{ .boolean = false };

    // Float specials.
    if (std.mem.eql(u8, raw, ".inf") or std.mem.eql(u8, raw, ".Inf") or std.mem.eql(u8, raw, ".INF"))
        return .{ .float = std.math.inf(f64) };
    if (std.mem.eql(u8, raw, "-.inf") or std.mem.eql(u8, raw, "-.Inf") or std.mem.eql(u8, raw, "-.INF"))
        return .{ .float = -std.math.inf(f64) };
    if (std.mem.eql(u8, raw, ".nan") or std.mem.eql(u8, raw, ".NaN") or std.mem.eql(u8, raw, ".NAN"))
        return .{ .float = std.math.nan(f64) };

    // Integer with hex/octal prefix.
    if (raw.len > 2) {
        const has_sign = raw[0] == '+' or raw[0] == '-';
        const prefix_start: usize = if (has_sign) 1 else 0;
        if (prefix_start + 2 <= raw.len and raw[prefix_start] == '0') {
            const p = raw[prefix_start + 1];
            if (p == 'x' or p == 'X') {
                if (std.fmt.parseInt(i64, raw, 0) catch null) |v| return .{ .integer = v };
            }
            if (p == 'o' or p == 'O') {
                if (std.fmt.parseInt(i64, raw, 0) catch null) |v| return .{ .integer = v };
            }
        }
    }

    // Integer (decimal).
    if (std.fmt.parseInt(i64, raw, 10) catch null) |v| return .{ .integer = v };

    // Float.
    if (std.fmt.parseFloat(f64, raw) catch null) |v| {
        // Only accept if it has a decimal point or exponent, to avoid int-like strings.
        for (raw) |ch| {
            if (ch == '.' or ch == 'e' or ch == 'E') return .{ .float = v };
        }
    }

    return .{ .string = raw };
}

fn freeMapping(allocator: Allocator, map: *Mapping) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit(allocator);
}

fn isWhitespaceOrBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isBreak(c: u8) bool {
    return c == '\n' or c == '\r';
}

fn hexDigit(c: u8) ?u21 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

const testing = std.testing;

test "parse flat mapping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "x: 10\ny: 20\n");
    try testing.expectEqual(@as(i64, 10), val.mapping.get("x").?.integer);
    try testing.expectEqual(@as(i64, 20), val.mapping.get("y").?.integer);
}

test "parse string values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "name: hello world\n");
    try testing.expectEqualStrings("hello world", val.mapping.get("name").?.string);
}

test "parse booleans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "a: true\nb: false\nc: True\n");
    try testing.expectEqual(true, val.mapping.get("a").?.boolean);
    try testing.expectEqual(false, val.mapping.get("b").?.boolean);
    try testing.expectEqual(true, val.mapping.get("c").?.boolean);
}

test "parse null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "a: null\nb: ~\nc:\n");
    try testing.expectEqual(Value.null_val, val.mapping.get("a").?);
    try testing.expectEqual(Value.null_val, val.mapping.get("b").?);
    try testing.expectEqual(Value.null_val, val.mapping.get("c").?);
}

test "parse float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "pi: 3.14\n");
    try testing.expect(@abs(val.mapping.get("pi").?.float - 3.14) < 0.001);
}

test "parse float specials" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "a: .inf\nb: -.inf\nc: .nan\n");
    try testing.expect(std.math.isInf(val.mapping.get("a").?.float));
    const b = val.mapping.get("b").?.float;
    try testing.expect(std.math.isInf(b) and b < 0);
    try testing.expect(std.math.isNan(val.mapping.get("c").?.float));
}

test "parse nested mapping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\outer:
        \\  inner: 42
        \\
    );
    const outer = val.mapping.get("outer").?;
    try testing.expectEqual(@as(i64, 42), outer.mapping.get("inner").?.integer);
}

test "parse block sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\items:
        \\  - 1
        \\  - 2
        \\  - 3
        \\
    );
    const items = val.mapping.get("items").?.sequence;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(i64, 1), items[0].integer);
    try testing.expectEqual(@as(i64, 3), items[2].integer);
}

test "parse flow mapping" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "{a: 1, b: 2}\n");
    try testing.expectEqual(@as(i64, 1), val.mapping.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), val.mapping.get("b").?.integer);
}

test "parse flow sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "[1, 2, 3]\n");
    try testing.expectEqual(@as(usize, 3), val.sequence.len);
    try testing.expectEqual(@as(i64, 1), val.sequence[0].integer);
}

test "parse double quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "msg: \"hello\\nworld\"\n");
    try testing.expectEqualStrings("hello\nworld", val.mapping.get("msg").?.string);
}

test "parse single quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "msg: 'it''s'\n");
    try testing.expectEqualStrings("it's", val.mapping.get("msg").?.string);
}

test "parse comments ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\# top comment
        \\key: val # inline comment
        \\
    );
    try testing.expectEqualStrings("val", val.mapping.get("key").?.string);
}

test "parse literal block scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\msg: |
        \\  line1
        \\  line2
        \\
    );
    try testing.expectEqualStrings("line1\nline2\n", val.mapping.get("msg").?.string);
}

test "parse folded block scalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\msg: >
        \\  line1
        \\  line2
        \\
    );
    try testing.expectEqualStrings("line1\nline2\n", val.mapping.get("msg").?.string);
}

test "parse empty document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "");
    try testing.expectEqual(Value.null_val, val);
}

test "parse sequence of mappings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(),
        \\- name: a
        \\  val: 1
        \\- name: b
        \\  val: 2
        \\
    );
    try testing.expectEqual(@as(usize, 2), val.sequence.len);
    try testing.expectEqualStrings("a", val.sequence[0].mapping.get("name").?.string);
    try testing.expectEqual(@as(i64, 2), val.sequence[1].mapping.get("val").?.integer);
}

test "parse unicode escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try parse(arena.allocator(), "msg: \"\\u0041\"\n");
    try testing.expectEqualStrings("A", val.mapping.get("msg").?.string);
}

test "scalar type resolution" {
    try testing.expectEqual(Value.null_val, resolveScalarType("null", .plain));
    try testing.expectEqual(Value.null_val, resolveScalarType("~", .plain));
    try testing.expectEqual(Value.null_val, resolveScalarType("", .plain));
    try testing.expectEqual(true, resolveScalarType("true", .plain).boolean);
    try testing.expectEqual(false, resolveScalarType("false", .plain).boolean);
    try testing.expectEqual(@as(i64, 42), resolveScalarType("42", .plain).integer);
    try testing.expectEqual(@as(i64, -7), resolveScalarType("-7", .plain).integer);
    try testing.expect(@abs(resolveScalarType("3.14", .plain).float - 3.14) < 0.001);
    try testing.expectEqualStrings("hello", resolveScalarType("hello", .plain).string);
    // Quoted always string.
    try testing.expectEqualStrings("true", resolveScalarType("true", .single_quoted).string);
}
