const std = @import("std");
const value_mod = @import("value.zig");
const serializer = @import("serializer.zig");

pub const Value = value_mod.Value;
pub const Entry = value_mod.Entry;
pub const Delimiter = serializer.Delimiter;

pub const PathExpansion = enum { off, safe };

pub const Options = struct {
    indent: u8 = 2,
    strict: bool = true,
    expand_paths: PathExpansion = .off,
};

pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
    InvalidHeader,
    InvalidIndentation,
    DuplicateKey,
    InvalidEscape,
    InvalidUnicode,
    UnexpectedEof,
    CountMismatch,
    WidthMismatch,
    ExpansionConflict,
};

const Line = struct {
    raw: []const u8,
    content: []const u8,
    depth: usize,
    blank: bool,
};

const Header = struct {
    key: ?[]u8,
    key_quoted: bool,
    len: usize,
    delimiter: Delimiter,
    fields: ?[][]u8,
    rest: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8, opts: Options) ParseError!Value {
    var p = Parser{
        .allocator = allocator,
        .input = input,
        .options = opts,
    };
    defer p.lines.deinit(allocator);
    try p.scanLines();

    var value = try p.parseRoot();
    errdefer value.deinit(allocator);

    if (opts.expand_paths == .safe and value == .object) {
        const expanded = try expandObject(allocator, value.object, opts.strict);
        value.deinit(allocator);
        value = .{ .object = expanded };
    }
    return value;
}

pub fn validate(allocator: std.mem.Allocator, input: []const u8, opts: Options) ParseError!void {
    const value = try parse(allocator, input, opts);
    value.deinit(allocator);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    options: Options,
    lines: std.ArrayList(Line) = .empty,
    index: usize = 0,

    fn scanLines(self: *Parser) ParseError!void {
        var it = std.mem.splitScalar(u8, self.input, '\n');
        while (it.next()) |raw_line_in| {
            var raw_line = raw_line_in;
            if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r') {
                raw_line = raw_line[0 .. raw_line.len - 1];
            }
            var spaces: usize = 0;
            while (spaces < raw_line.len and raw_line[spaces] == ' ') : (spaces += 1) {}
            if (spaces < raw_line.len and raw_line[spaces] == '\t' and self.options.strict) {
                return error.InvalidIndentation;
            }
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (trimmed.len == 0) {
                try self.lines.append(self.allocator, .{ .raw = raw_line, .content = "", .depth = 0, .blank = true });
                continue;
            }
            if (self.options.strict and spaces % self.options.indent != 0) return error.InvalidIndentation;
            try self.lines.append(self.allocator, .{
                .raw = raw_line,
                .content = raw_line[spaces..],
                .depth = spaces / self.options.indent,
                .blank = false,
            });
        }
    }

    fn parseRoot(self: *Parser) ParseError!Value {
        self.skipBlanks();
        if (self.index >= self.lines.items.len) return emptyObject(self.allocator);

        const first_idx = self.index;
        const single = self.countNonBlank() == 1;
        const content = self.lines.items[first_idx].content;
        if (single and std.mem.eql(u8, std.mem.trim(u8, content, " \t"), "[]")) return emptyArray(self.allocator);

        if (try self.tryParseHeader(content)) |h| {
            defer self.freeHeaderFieldsOnly(h);
            if (h.key == null) {
                var owned = h;
                owned.fields = if (h.fields) |fields| try cloneFieldList(self.allocator, fields) else null;
                const value = try self.parseArrayFromHeader(owned, self.lines.items[first_idx].depth, null);
                errdefer value.deinit(self.allocator);
                self.skipBlanks();
                if (self.index < self.lines.items.len) return error.InvalidSyntax;
                return value;
            }
            self.freeHeaderKey(h);
        }

        if (single and firstUnquotedColon(content) == null) {
            self.index += 1;
            return try self.parseToken(std.mem.trim(u8, content, " \t"));
        }

        return try self.parseObject(0);
    }

    fn parseObject(self: *Parser, depth: usize) ParseError!Value {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            deinitEntries(self.allocator, entries.items);
            entries.deinit(self.allocator);
        }

        while (self.index < self.lines.items.len) {
            const line = self.lines.items[self.index];
            if (line.blank) {
                self.index += 1;
                continue;
            }
            if (line.depth < depth) break;
            if (line.depth > depth) return error.InvalidIndentation;
            if (std.mem.startsWith(u8, line.content, "-")) break;

            const entry = try self.parseFieldAt(line.content, depth, false);
            try appendEntry(self.allocator, &entries, entry, self.options.strict);
        }

        return .{ .object = try entries.toOwnedSlice(self.allocator) };
    }

    fn parseFieldAt(self: *Parser, content: []const u8, depth: usize, tabular_on_hyphen: bool) ParseError!Entry {
        if (try self.tryParseHeader(content)) |h| {
            if (h.key == null) {
                self.freeHeader(h);
                return error.InvalidSyntax;
            }
            const key = h.key.?;
            const quoted = h.key_quoted;
            errdefer self.allocator.free(key);
            var owned = h;
            owned.key = null;
            const value = try self.parseArrayFromHeader(owned, depth, if (tabular_on_hyphen) depth + 2 else null);
            return .{ .key = key, .value = value, .quoted = quoted };
        }

        const colon = firstUnquotedColon(content) orelse return error.InvalidSyntax;
        const key_token = std.mem.trim(u8, content[0..colon], " \t");
        const parsed_key = try self.parseKey(key_token);
        errdefer self.allocator.free(parsed_key.key);
        const raw_value = trimStart(content[colon + 1 ..], " \t");

        self.index += 1;
        if (raw_value.len == 0) {
            const value = if (self.peekNonBlankDepth()) |next_depth|
                if (next_depth > depth) try self.parseObject(depth + 1) else try emptyObject(self.allocator)
            else
                try emptyObject(self.allocator);
            return .{ .key = parsed_key.key, .value = value, .quoted = parsed_key.quoted };
        }
        if (std.mem.eql(u8, raw_value, "[]")) {
            return .{ .key = parsed_key.key, .value = try emptyArray(self.allocator), .quoted = parsed_key.quoted };
        }
        return .{ .key = parsed_key.key, .value = try self.parseToken(raw_value), .quoted = parsed_key.quoted };
    }

    fn parseArrayFromHeader(self: *Parser, h: Header, header_depth: usize, row_depth_override: ?usize) ParseError!Value {
        defer self.freeHeaderFieldsOnly(h);
        const delimiter = h.delimiter;

        if (h.fields) |fields| {
            self.index += 1;
            const row_depth = row_depth_override orelse (header_depth + 1);
            var rows: std.ArrayList(Value) = .empty;
            errdefer {
                for (rows.items) |row| row.deinit(self.allocator);
                rows.deinit(self.allocator);
            }
            while (self.index < self.lines.items.len) {
                const line = self.lines.items[self.index];
                if (line.blank) {
                    if (self.options.strict) {
                        if (rows.items.len < h.len) return error.InvalidSyntax;
                        break;
                    }
                    self.index += 1;
                    continue;
                }
                if (line.depth < row_depth) break;
                if (line.depth > row_depth) return error.InvalidIndentation;
                if (!isTabularRow(line.content, delimiter)) break;
                const parts = try splitTokens(self.allocator, line.content, delimiter);
                defer freeStringList(self.allocator, parts);
                if (self.options.strict and parts.len != fields.len) return error.WidthMismatch;

                var object_entries = try self.allocator.alloc(Entry, fields.len);
                errdefer {
                    for (object_entries[0..]) |entry| {
                        self.allocator.free(entry.key);
                        entry.value.deinit(self.allocator);
                    }
                    self.allocator.free(object_entries);
                }
                for (fields, 0..) |field, i| {
                    const token = if (i < parts.len) parts[i] else "";
                    object_entries[i] = .{
                        .key = try value_mod.dupe(self.allocator, field),
                        .value = try self.parseToken(token),
                        .quoted = false,
                    };
                }
                try rows.append(self.allocator, .{ .object = object_entries });
                self.index += 1;
            }
            if (self.options.strict and rows.items.len != h.len) return error.CountMismatch;
            return .{ .array = try rows.toOwnedSlice(self.allocator) };
        }

        if (h.rest.len > 0) {
            self.index += 1;
            const parts = try splitTokens(self.allocator, h.rest, delimiter);
            defer freeStringList(self.allocator, parts);
            if (self.options.strict and parts.len != h.len) return error.CountMismatch;
            var items = try self.allocator.alloc(Value, parts.len);
            errdefer {
                for (items[0..]) |item| item.deinit(self.allocator);
                self.allocator.free(items);
            }
            for (parts, 0..) |part, i| items[i] = try self.parseToken(part);
            return .{ .array = items };
        }

        self.index += 1;
        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        if (h.len == 0) return .{ .array = try items.toOwnedSlice(self.allocator) };

        const item_depth = header_depth + 1;
        while (self.index < self.lines.items.len) {
            const line = self.lines.items[self.index];
            if (line.blank) {
                if (self.options.strict) {
                    if (items.items.len < h.len) return error.InvalidSyntax;
                    break;
                }
                self.index += 1;
                continue;
            }
            if (line.depth < item_depth) break;
            if (line.depth > item_depth) return error.InvalidIndentation;
            if (!std.mem.startsWith(u8, line.content, "-")) break;
            try items.append(self.allocator, try self.parseListItem(item_depth));
        }
        if (self.options.strict and items.items.len != h.len) return error.CountMismatch;
        return .{ .array = try items.toOwnedSlice(self.allocator) };
    }

    fn parseListItem(self: *Parser, item_depth: usize) ParseError!Value {
        const content = self.lines.items[self.index].content;
        if (std.mem.eql(u8, content, "-")) {
            self.index += 1;
            return emptyObject(self.allocator);
        }
        if (!std.mem.startsWith(u8, content, "- ")) return error.InvalidSyntax;
        const rest = trimStart(content[2..], " \t");
        if (try self.tryParseHeader(rest)) |h| {
            if (h.key == null) {
                return try self.parseArrayFromHeader(h, item_depth, null);
            }
            self.freeHeader(h);
        }

        if (firstUnquotedColon(rest) == null) {
            self.index += 1;
            return try self.parseToken(rest);
        }

        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            deinitEntries(self.allocator, entries.items);
            entries.deinit(self.allocator);
        }
        const first = try self.parseFieldAt(rest, item_depth, true);
        try appendEntry(self.allocator, &entries, first, self.options.strict);

        while (self.index < self.lines.items.len) {
            const line = self.lines.items[self.index];
            if (line.blank) {
                self.index += 1;
                continue;
            }
            if (line.depth <= item_depth) break;
            if (line.depth != item_depth + 1) return error.InvalidIndentation;
            const entry = try self.parseFieldAt(line.content, item_depth + 1, false);
            try appendEntry(self.allocator, &entries, entry, self.options.strict);
        }
        return .{ .object = try entries.toOwnedSlice(self.allocator) };
    }

    fn parseToken(self: *Parser, raw: []const u8) ParseError!Value {
        const token = std.mem.trim(u8, raw, " \t");
        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
            return .{ .string = try unescape(self.allocator, token[1 .. token.len - 1]) };
        }
        if (std.mem.indexOfScalar(u8, token, '"') != null) return error.InvalidSyntax;
        if (std.mem.eql(u8, token, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, token, "false")) return .{ .bool = false };
        if (std.mem.eql(u8, token, "null")) return .null;
        if (isJsonNumber(token) and !hasForbiddenLeadingZero(token)) {
            if (std.mem.indexOfAny(u8, token, ".eE") != null) {
                const f = std.fmt.parseFloat(f64, token) catch return .{ .string = try value_mod.dupe(self.allocator, token) };
                return .{ .float = f };
            }
            if (token.len > 0 and token[0] == '-') {
                const i = std.fmt.parseInt(i64, token, 10) catch return .{ .number_string = try value_mod.dupe(self.allocator, token) };
                return .{ .int = i };
            }
            const u = std.fmt.parseInt(u64, token, 10) catch return .{ .number_string = try value_mod.dupe(self.allocator, token) };
            return .{ .uint = u };
        }
        return .{ .string = try value_mod.dupe(self.allocator, token) };
    }

    const ParsedKey = struct { key: []u8, quoted: bool };

    fn parseKey(self: *Parser, token: []const u8) ParseError!ParsedKey {
        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
            return .{ .key = try unescape(self.allocator, token[1 .. token.len - 1]), .quoted = true };
        }
        return .{ .key = try value_mod.dupe(self.allocator, token), .quoted = false };
    }

    fn tryParseHeader(self: *Parser, content: []const u8) ParseError!?Header {
        const bracket_pos = firstUnquotedByte(content, '[') orelse return null;
        var key: ?[]u8 = null;
        var key_quoted = false;
        var fields: ?[][]u8 = null;
        if (bracket_pos > 0) {
            const key_token = content[0..bracket_pos];
            const parsed = try self.parseKey(key_token);
            key = parsed.key;
            key_quoted = parsed.quoted;
        }
        errdefer if (key) |k| self.allocator.free(k);
        errdefer if (fields) |f| freeStringList(self.allocator, f);

        const close = std.mem.indexOfScalarPos(u8, content, bracket_pos + 1, ']') orelse return self.invalidHeader(key, fields);
        var inner = content[bracket_pos + 1 .. close];
        var delimiter: Delimiter = .comma;
        if (inner.len > 0 and inner[inner.len - 1] == '|') {
            delimiter = .pipe;
            inner = inner[0 .. inner.len - 1];
        } else if (inner.len > 0 and inner[inner.len - 1] == '\t') {
            delimiter = .tab;
            inner = inner[0 .. inner.len - 1];
        }
        if (!validLength(inner)) return self.invalidHeader(key, fields);
        const len = std.fmt.parseInt(usize, inner, 10) catch return self.invalidHeader(key, fields);

        var pos = close + 1;
        if (pos < content.len and content[pos] == '{') {
            const end = findMatchingBrace(content, pos) orelse return self.invalidHeader(key, fields);
            const field_content = content[pos + 1 .. end];
            if (delimiterMismatch(field_content, delimiter)) return self.invalidHeader(key, fields);
            fields = try splitKeys(self.allocator, field_content, delimiter);
            pos = end + 1;
        }
        if (pos >= content.len or content[pos] != ':') return self.invalidHeader(key, fields);
        const rest = trimStart(content[pos + 1 ..], " \t");
        return .{
            .key = key,
            .key_quoted = key_quoted,
            .len = len,
            .delimiter = delimiter,
            .fields = fields,
            .rest = rest,
        };
    }

    fn invalidHeader(self: *Parser, key: ?[]u8, fields: ?[][]u8) ParseError!?Header {
        if (self.options.strict) return error.InvalidHeader;
        if (key) |k| self.allocator.free(k);
        if (fields) |f| freeStringList(self.allocator, f);
        return null;
    }

    fn freeHeader(self: *Parser, h: Header) void {
        self.freeHeaderKey(h);
        self.freeHeaderFieldsOnly(h);
    }

    fn freeHeaderKey(self: *Parser, h: Header) void {
        if (h.key) |k| self.allocator.free(k);
    }

    fn freeHeaderFieldsOnly(self: *Parser, h: Header) void {
        if (h.fields) |f| freeStringList(self.allocator, f);
    }

    fn skipBlanks(self: *Parser) void {
        while (self.index < self.lines.items.len and self.lines.items[self.index].blank) self.index += 1;
    }

    fn countNonBlank(self: *Parser) usize {
        var n: usize = 0;
        for (self.lines.items) |line| {
            if (!line.blank) n += 1;
        }
        return n;
    }

    fn peekNonBlankDepth(self: *Parser) ?usize {
        var i = self.index;
        while (i < self.lines.items.len) : (i += 1) {
            if (!self.lines.items[i].blank) return self.lines.items[i].depth;
        }
        return null;
    }
};

fn appendEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry), entry: Entry, strict: bool) ParseError!void {
    for (entries.items) |*existing| {
        if (std.mem.eql(u8, existing.key, entry.key)) {
            if (strict) {
                var owned = entry;
                allocator.free(owned.key);
                owned.value.deinit(allocator);
                return error.DuplicateKey;
            }
            allocator.free(existing.key);
            existing.value.deinit(allocator);
            existing.* = entry;
            return;
        }
    }
    try entries.append(allocator, entry);
}

fn emptyArray(allocator: std.mem.Allocator) !Value {
    return .{ .array = try allocator.alloc(Value, 0) };
}

fn emptyObject(allocator: std.mem.Allocator) !Value {
    return .{ .object = try allocator.alloc(Entry, 0) };
}

fn deinitEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| {
        allocator.free(entry.key);
        entry.value.deinit(allocator);
    }
}

fn firstUnquotedColon(s: []const u8) ?usize {
    return firstUnquotedByte(s, ':');
}

fn firstUnquotedByte(s: []const u8, needle: u8) ?usize {
    var in_quote = false;
    var escaped = false;
    for (s, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_quote and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (!in_quote and c == needle) return i;
    }
    return null;
}

fn isTabularRow(s: []const u8, delimiter: Delimiter) bool {
    const colon = firstUnquotedByte(s, ':');
    const delim = firstUnquotedByte(s, delimiterByte(delimiter));
    if (colon == null) return true;
    if (delim) |d| return d < colon.?;
    return false;
}

fn splitTokens(allocator: std.mem.Allocator, s: []const u8, delimiter: Delimiter) ParseError![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(allocator, out.items);
    const delim = delimiterByte(delimiter);
    var start: usize = 0;
    var in_quote = false;
    var escaped = false;
    for (s, 0..) |c, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_quote and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (!in_quote and c == delim) {
            try out.append(allocator, try value_mod.dupe(allocator, std.mem.trim(u8, s[start..i], " \t")));
            start = i + 1;
        }
    }
    if (in_quote) return error.InvalidSyntax;
    try out.append(allocator, try value_mod.dupe(allocator, std.mem.trim(u8, s[start..], " \t")));
    return out.toOwnedSlice(allocator);
}

fn splitKeys(allocator: std.mem.Allocator, s: []const u8, delimiter: Delimiter) ParseError![][]u8 {
    const parts = try splitTokens(allocator, s, delimiter);
    errdefer freeStringList(allocator, parts);
    for (parts) |*part| {
        if (part.*.len >= 2 and part.*[0] == '"' and part.*[part.*.len - 1] == '"') {
            const unescaped = try unescape(allocator, part.*[1 .. part.*.len - 1]);
            allocator.free(part.*);
            part.* = unescaped;
        }
    }
    return parts;
}

fn cloneFieldList(allocator: std.mem.Allocator, fields: [][]u8) ![][]u8 {
    var out = try allocator.alloc([]u8, fields.len);
    errdefer freeStringList(allocator, out);
    for (fields, 0..) |field, i| out[i] = try value_mod.dupe(allocator, field);
    return out;
}

fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

fn findMatchingBrace(s: []const u8, open: usize) ?usize {
    var in_quote = false;
    var escaped = false;
    var i = open + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_quote and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (!in_quote and c == '}') return i;
    }
    return null;
}

fn delimiterMismatch(s: []const u8, delimiter: Delimiter) bool {
    if (delimiter == .comma) return false;
    var in_quote = false;
    var escaped = false;
    for (s) |c| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_quote and c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (!in_quote and (c == ',' or c == '\t' or c == '|') and c != delimiterByte(delimiter)) {
            return true;
        }
    }
    return false;
}

fn validLength(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len > 1 and s[0] == '0') return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn isJsonNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-') {
        i += 1;
        if (i == s.len) return false;
    }
    if (i >= s.len or !std.ascii.isDigit(s[i])) return false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i < s.len and s[i] == '.') {
        i += 1;
        var n: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) n += 1;
        if (n == 0) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var n: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) n += 1;
        if (n == 0) return false;
    }
    return i == s.len;
}

fn hasForbiddenLeadingZero(s: []const u8) bool {
    const i: usize = if (s.len > 0 and s[0] == '-') 1 else 0;
    if (i + 1 >= s.len) return false;
    if (s[i] != '0') return false;
    const next = s[i + 1];
    return std.ascii.isDigit(next);
}

fn unescape(allocator: std.mem.Allocator, raw: []const u8) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try out.append(allocator, raw[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) return error.InvalidEscape;
        switch (raw[i]) {
            '\\' => try out.append(allocator, '\\'),
            '"' => try out.append(allocator, '"'),
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            'u' => {
                i += 1;
                if (i + 4 > raw.len) return error.InvalidEscape;
                const cp = parseHex4(raw[i..][0..4]) orelse return error.InvalidUnicode;
                if (cp >= 0xD800 and cp <= 0xDFFF) return error.InvalidUnicode;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch return error.InvalidUnicode;
                try out.appendSlice(allocator, buf[0..len]);
                i += 3;
            },
            else => return error.InvalidEscape,
        }
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn parseHex4(hex: *const [4]u8) ?u16 {
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

fn expandObject(allocator: std.mem.Allocator, entries: []Entry, strict: bool) ParseError![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        deinitEntries(allocator, out.items);
        out.deinit(allocator);
    }

    for (entries) |entry| {
        if (!entry.quoted and std.mem.indexOfScalar(u8, entry.key, '.') != null and allIdentifierSegments(entry.key)) {
            try insertPath(allocator, &out, entry.key, try entry.value.clone(allocator), strict);
        } else {
            try appendExpandedEntry(allocator, &out, .{
                .key = try value_mod.dupe(allocator, entry.key),
                .value = try entry.value.clone(allocator),
                .quoted = entry.quoted,
            }, strict);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn insertPath(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry), path: []const u8, leaf: Value, strict: bool) ParseError!void {
    const dot = std.mem.indexOfScalar(u8, path, '.');
    if (dot == null) {
        try appendExpandedEntry(allocator, entries, .{
            .key = try value_mod.dupe(allocator, path),
            .value = leaf,
            .quoted = false,
        }, strict);
        return;
    }
    const head = path[0..dot.?];
    const tail = path[dot.? + 1 ..];
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, head)) {
            if (entry.value != .object) {
                if (strict) {
                    leaf.deinit(allocator);
                    return error.ExpansionConflict;
                }
                entry.value.deinit(allocator);
                entry.value = try emptyObject(allocator);
            }
            var list: std.ArrayList(Entry) = .empty;
            defer list.deinit(allocator);
            const old_entries = entry.value.object;
            try list.appendSlice(allocator, entry.value.object);
            insertPath(allocator, &list, tail, leaf, strict) catch |err| return err;
            entry.value.object = try list.toOwnedSlice(allocator);
            allocator.free(old_entries);
            return;
        }
    }

    var child: std.ArrayList(Entry) = .empty;
    errdefer {
        deinitEntries(allocator, child.items);
        child.deinit(allocator);
    }
    try insertPath(allocator, &child, tail, leaf, strict);
    const child_entries = try child.toOwnedSlice(allocator);
    appendExpandedEntry(allocator, entries, .{
        .key = try value_mod.dupe(allocator, head),
        .value = .{ .object = child_entries },
        .quoted = false,
    }, strict) catch |err| {
        if (err == error.OutOfMemory) {
            deinitEntries(allocator, child_entries);
            allocator.free(child_entries);
        }
        return err;
    };
}

fn appendExpandedEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry), entry: Entry, strict: bool) ParseError!void {
    for (entries.items) |*existing| {
        if (std.mem.eql(u8, existing.key, entry.key)) {
            if (strict) {
                var owned = entry;
                allocator.free(owned.key);
                owned.value.deinit(allocator);
                return error.ExpansionConflict;
            }
            allocator.free(existing.key);
            existing.value.deinit(allocator);
            existing.* = entry;
            return;
        }
    }
    try entries.append(allocator, entry);
}

fn allIdentifierSegments(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |segment| {
        if (!isIdentifierSegment(segment)) return false;
    }
    return true;
}

fn isIdentifierSegment(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn delimiterByte(delimiter: Delimiter) u8 {
    return switch (delimiter) {
        .comma => ',',
        .tab => '\t',
        .pipe => '|',
    };
}

fn trimStart(slice: []const u8, values_to_strip: []const u8) []const u8 {
    var start: usize = 0;
    while (start < slice.len and std.mem.indexOfScalar(u8, values_to_strip, slice[start]) != null) {
        start += 1;
    }
    return slice[start..];
}
