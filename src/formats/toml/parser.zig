const std = @import("std");
const compat = @import("compat");

const Allocator = std.mem.Allocator;

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    DuplicateKey,
    InvalidEscape,
    InvalidUnicode,
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
    table: Table,

    pub fn deinit(self: *const Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |*elem| elem.deinit(allocator);
                allocator.free(arr);
            },
            .table => |*t| {
                var it = t.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                var mut: Table = t.*;
                mut.deinit(allocator);
            },
            .boolean, .integer, .float => {},
        }
    }
};

pub const Table = compat.StringArrayHashMap(Value);

pub fn parse(allocator: Allocator, input: []const u8) ParseError!Table {
    var p = Parser{
        .input = input,
        .pos = 0,
        .allocator = allocator,
    };
    return p.parseDocument();
}

const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: Allocator,

    fn parseDocument(self: *Parser) ParseError!Table {
        var root: Table = .empty;
        errdefer freeTable(self.allocator, &root);

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.input.len) break;

            const c = self.input[self.pos];
            if (c == '#') {
                self.skipComment();
                continue;
            }
            if (c == '[') {
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '[') {
                    try self.parseArrayOfTables(&root);
                } else {
                    try self.parseTableHeader(&root);
                }
                continue;
            }
            // Key-value pair at current table level.
            try self.parseKeyValue(&root);
        }

        return root;
    }

    fn parseTableHeader(self: *Parser, root: *Table) ParseError!void {
        self.pos += 1; // skip '['
        self.skipWhitespace();
        const path = try self.parseDottedKey();
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != ']')
            return error.UnexpectedToken;
        self.pos += 1;
        self.skipWhitespace();
        self.skipOptionalComment();
        self.expectNewlineOrEof();

        // Navigate/create the path.
        var target = root;
        for (path, 0..) |segment, i| {
            defer self.allocator.free(segment);
            if (i == path.len - 1) {
                // Last segment: create or get the table.
                const gop = target.getOrPut(self.allocator, segment) catch return error.OutOfMemory;
                if (gop.found_existing) {
                    if (gop.value_ptr.* != .table) return error.DuplicateKey;
                } else {
                    const key_copy = self.allocator.dupe(u8, segment) catch return error.OutOfMemory;
                    gop.key_ptr.* = key_copy;
                    gop.value_ptr.* = .{ .table = .empty };
                }
                target = &gop.value_ptr.table;
            } else {
                const gop = target.getOrPut(self.allocator, segment) catch return error.OutOfMemory;
                if (!gop.found_existing) {
                    const key_copy = self.allocator.dupe(u8, segment) catch return error.OutOfMemory;
                    gop.key_ptr.* = key_copy;
                    gop.value_ptr.* = .{ .table = .empty };
                }
                if (gop.value_ptr.* != .table) return error.DuplicateKey;
                target = &gop.value_ptr.table;
            }
        }
        self.allocator.free(path);

        // Parse key-value pairs into the target table.
        while (self.pos < self.input.len) {
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.input.len) break;
            const c = self.input[self.pos];
            if (c == '[') break;
            if (c == '#') {
                self.skipComment();
                continue;
            }
            try self.parseKeyValue(target);
        }
    }

    fn parseArrayOfTables(self: *Parser, root: *Table) ParseError!void {
        self.pos += 2; // skip '[['
        self.skipWhitespace();
        const path = try self.parseDottedKey();
        self.skipWhitespace();
        if (self.pos + 1 >= self.input.len or self.input[self.pos] != ']' or self.input[self.pos + 1] != ']')
            return error.UnexpectedToken;
        self.pos += 2;
        self.skipWhitespace();
        self.skipOptionalComment();
        self.expectNewlineOrEof();

        // Navigate to parent, create array entry.
        var target = root;
        for (path, 0..) |segment, i| {
            defer self.allocator.free(segment);
            if (i == path.len - 1) {
                // Last segment: append a new table to the array.
                const gop = target.getOrPut(self.allocator, segment) catch return error.OutOfMemory;
                if (!gop.found_existing) {
                    const key_copy = self.allocator.dupe(u8, segment) catch return error.OutOfMemory;
                    gop.key_ptr.* = key_copy;
                    gop.value_ptr.* = .{ .array = &.{} };
                }
                if (gop.value_ptr.* != .array) return error.DuplicateKey;

                // Append a new table to the array.
                var new_table: Table = .empty;

                // Parse key-value pairs into the new table.
                while (self.pos < self.input.len) {
                    self.skipWhitespaceAndNewlines();
                    if (self.pos >= self.input.len) break;
                    const ch = self.input[self.pos];
                    if (ch == '[') break;
                    if (ch == '#') {
                        self.skipComment();
                        continue;
                    }
                    try self.parseKeyValue(&new_table);
                }

                const old = gop.value_ptr.array;
                const new_arr = self.allocator.alloc(Value, old.len + 1) catch return error.OutOfMemory;
                @memcpy(new_arr[0..old.len], old);
                new_arr[old.len] = .{ .table = new_table };
                if (old.len > 0) self.allocator.free(old);
                gop.value_ptr.* = .{ .array = new_arr };
            } else {
                const gop = target.getOrPut(self.allocator, segment) catch return error.OutOfMemory;
                if (!gop.found_existing) {
                    const key_copy = self.allocator.dupe(u8, segment) catch return error.OutOfMemory;
                    gop.key_ptr.* = key_copy;
                    gop.value_ptr.* = .{ .table = .empty };
                }
                switch (gop.value_ptr.*) {
                    .table => {
                        target = &gop.value_ptr.table;
                    },
                    .array => |arr| {
                        // Navigate into the last element of the array.
                        if (arr.len == 0) return error.UnexpectedToken;
                        const mut_arr: []Value = @constCast(arr);
                        const last = &mut_arr[arr.len - 1];
                        if (last.* != .table) return error.DuplicateKey;
                        target = &last.table;
                    },
                    else => return error.DuplicateKey,
                }
            }
        }
        self.allocator.free(path);
    }

    fn parseKeyValue(self: *Parser, table: *Table) ParseError!void {
        const path = try self.parseDottedKey();
        defer {
            for (path) |seg| self.allocator.free(seg);
            self.allocator.free(path);
        }
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '=')
            return error.UnexpectedToken;
        self.pos += 1;
        self.skipWhitespace();
        const value = try self.parseValue();
        self.skipWhitespace();
        self.skipOptionalComment();
        self.expectNewlineOrEof();

        // Navigate dotted key path, creating intermediate tables.
        var target = table;
        for (path[0 .. path.len - 1]) |segment| {
            const gop = target.getOrPut(self.allocator, segment) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                const key_copy = self.allocator.dupe(u8, segment) catch return error.OutOfMemory;
                gop.key_ptr.* = key_copy;
                gop.value_ptr.* = .{ .table = .empty };
            }
            if (gop.value_ptr.* != .table) return error.DuplicateKey;
            target = &gop.value_ptr.table;
        }

        const final_key = path[path.len - 1];
        const gop = target.getOrPut(self.allocator, final_key) catch return error.OutOfMemory;
        if (gop.found_existing) return error.DuplicateKey;
        const key_copy = self.allocator.dupe(u8, final_key) catch return error.OutOfMemory;
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = value;
    }

    fn parseDottedKey(self: *Parser) ParseError![]const []const u8 {
        var segments: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (segments.items) |s| self.allocator.free(s);
            segments.deinit(self.allocator);
        }

        const first = try self.parseKey();
        segments.append(self.allocator, first) catch return error.OutOfMemory;

        while (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            self.skipWhitespace();
            const seg = try self.parseKey();
            segments.append(self.allocator, seg) catch return error.OutOfMemory;
        }

        return segments.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    fn parseKey(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const c = self.input[self.pos];
        if (c == '"') return self.parseBasicString();
        if (c == '\'') return self.parseLiteralString();
        return self.parseBareKey();
    }

    fn parseBareKey(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (isBareKeyChar(c)) {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (self.pos == start) return error.UnexpectedToken;
        const key = self.input[start..self.pos];
        return self.allocator.dupe(u8, key) catch return error.OutOfMemory;
    }

    fn parseValue(self: *Parser) ParseError!Value {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const c = self.input[self.pos];

        if (c == '"') {
            // Could be basic string or multiline basic string.
            if (self.pos + 2 < self.input.len and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                const s = try self.parseMultilineBasicString();
                return .{ .string = s };
            }
            const s = try self.parseBasicString();
            return .{ .string = s };
        }
        if (c == '\'') {
            if (self.pos + 2 < self.input.len and self.input[self.pos + 1] == '\'' and self.input[self.pos + 2] == '\'') {
                const s = try self.parseMultilineLiteralString();
                return .{ .string = s };
            }
            const s = try self.parseLiteralString();
            return .{ .string = s };
        }
        if (c == 't') return self.parseTrueLiteral();
        if (c == 'f') return self.parseFalseLiteral();
        if (c == '[') return self.parseInlineArray();
        if (c == '{') return self.parseInlineTable();
        if (c == 'i' or c == 'n') return self.parseSpecialFloat();
        if (c == '+' or c == '-') {
            if (self.pos + 1 < self.input.len) {
                const next = self.input[self.pos + 1];
                if (next == 'i' or next == 'n') return self.parseSpecialFloat();
            }
        }
        // Number (integer or float).
        return self.parseNumber();
    }

    fn parseBasicString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // skip opening "
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '"') {
                self.pos += 1;
                return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            }
            if (c == '\\') {
                self.pos += 1;
                try self.parseEscape(&out);
            } else {
                out.append(self.allocator, c) catch return error.OutOfMemory;
                self.pos += 1;
            }
        }
        return error.UnexpectedEof;
    }

    fn parseLiteralString(self: *Parser) ParseError![]const u8 {
        self.pos += 1; // skip opening '
        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '\'') {
                const result = self.allocator.dupe(u8, self.input[start..self.pos]) catch return error.OutOfMemory;
                self.pos += 1;
                return result;
            }
            self.pos += 1;
        }
        return error.UnexpectedEof;
    }

    fn parseMultilineBasicString(self: *Parser) ParseError![]const u8 {
        self.pos += 3; // skip """
        // Skip immediate newline after opening delimiter.
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        } else if (self.pos + 1 < self.input.len and self.input[self.pos] == '\r' and self.input[self.pos + 1] == '\n') {
            self.pos += 2;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            if (self.pos + 2 < self.input.len and self.input[self.pos] == '"' and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                self.pos += 3;
                return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            }
            const c = self.input[self.pos];
            if (c == '\\') {
                self.pos += 1;
                if (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r')) {
                    // Line-ending backslash: skip whitespace and newlines.
                    while (self.pos < self.input.len and (self.input[self.pos] == '\n' or self.input[self.pos] == '\r' or self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) {
                        self.pos += 1;
                    }
                } else {
                    try self.parseEscape(&out);
                }
            } else {
                out.append(self.allocator, c) catch return error.OutOfMemory;
                self.pos += 1;
            }
        }
        return error.UnexpectedEof;
    }

    fn parseMultilineLiteralString(self: *Parser) ParseError![]const u8 {
        self.pos += 3; // skip '''
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        } else if (self.pos + 1 < self.input.len and self.input[self.pos] == '\r' and self.input[self.pos + 1] == '\n') {
            self.pos += 2;
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (self.pos < self.input.len) {
            if (self.pos + 2 < self.input.len and self.input[self.pos] == '\'' and self.input[self.pos + 1] == '\'' and self.input[self.pos + 2] == '\'') {
                self.pos += 3;
                return out.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            }
            out.append(self.allocator, self.input[self.pos]) catch return error.OutOfMemory;
            self.pos += 1;
        }
        return error.UnexpectedEof;
    }

    fn parseEscape(self: *Parser, out: *std.ArrayList(u8)) ParseError!void {
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const c = self.input[self.pos];
        self.pos += 1;
        switch (c) {
            'b' => out.append(self.allocator, 0x08) catch return error.OutOfMemory,
            't' => out.append(self.allocator, '\t') catch return error.OutOfMemory,
            'n' => out.append(self.allocator, '\n') catch return error.OutOfMemory,
            'f' => out.append(self.allocator, 0x0c) catch return error.OutOfMemory,
            'r' => out.append(self.allocator, '\r') catch return error.OutOfMemory,
            '"' => out.append(self.allocator, '"') catch return error.OutOfMemory,
            '\\' => out.append(self.allocator, '\\') catch return error.OutOfMemory,
            'u' => try self.parseUnicodeEscape(out, 4),
            'U' => try self.parseUnicodeEscape(out, 8),
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

    fn parseTrueLiteral(self: *Parser) ParseError!Value {
        if (self.pos + 4 > self.input.len or !std.mem.eql(u8, self.input[self.pos..][0..4], "true"))
            return error.UnexpectedToken;
        self.pos += 4;
        return .{ .boolean = true };
    }

    fn parseFalseLiteral(self: *Parser) ParseError!Value {
        if (self.pos + 5 > self.input.len or !std.mem.eql(u8, self.input[self.pos..][0..5], "false"))
            return error.UnexpectedToken;
        self.pos += 5;
        return .{ .boolean = false };
    }

    fn parseSpecialFloat(self: *Parser) ParseError!Value {
        // inf, +inf, -inf, nan, +nan, -nan
        const remaining = self.input[self.pos..];
        const cases = [_]struct { prefix: []const u8, val: f64 }{
            .{ .prefix = "+inf", .val = std.math.inf(f64) },
            .{ .prefix = "-inf", .val = -std.math.inf(f64) },
            .{ .prefix = "inf", .val = std.math.inf(f64) },
            .{ .prefix = "+nan", .val = std.math.nan(f64) },
            .{ .prefix = "-nan", .val = std.math.nan(f64) },
            .{ .prefix = "nan", .val = std.math.nan(f64) },
        };
        for (cases) |case| {
            if (remaining.len >= case.prefix.len and std.mem.eql(u8, remaining[0..case.prefix.len], case.prefix)) {
                self.pos += case.prefix.len;
                return .{ .float = case.val };
            }
        }
        return error.UnexpectedToken;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;
        var has_sign = false;

        // Optional sign.
        if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
            has_sign = true;
            self.pos += 1;
        }

        if (self.pos >= self.input.len) return error.UnexpectedEof;

        // Check for 0x, 0o, 0b prefixed integers.
        if (self.input[self.pos] == '0' and self.pos + 1 < self.input.len) {
            const prefix = self.input[self.pos + 1];
            if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
                self.pos += 2;
                const base: u8 = switch (prefix) {
                    'x' => 16,
                    'o' => 8,
                    'b' => 2,
                    else => unreachable,
                };
                return self.parseBaseInteger(start, base);
            }
        }

        // Scan digits.
        var is_float = false;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c >= '0' and c <= '9' or c == '_') {
                self.pos += 1;
            } else if (c == '.' or c == 'e' or c == 'E') {
                is_float = true;
                self.pos += 1;
                // After 'e'/'E' there might be a sign.
                if ((c == 'e' or c == 'E') and self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }

        const raw = self.input[start..self.pos];
        if (is_float) {
            return self.parseFloatFromRaw(raw);
        }
        return self.parseIntFromRaw(raw, has_sign);
    }

    fn parseBaseInteger(self: *Parser, start: usize, base: u8) ParseError!Value {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            const valid = switch (base) {
                16 => (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '_',
                8 => (c >= '0' and c <= '7') or c == '_',
                2 => c == '0' or c == '1' or c == '_',
                else => false,
            };
            if (valid) {
                self.pos += 1;
            } else {
                break;
            }
        }
        const raw = self.input[start..self.pos];
        // Strip sign and prefix (e.g., "+0x"), then underscores.
        var stripped: [256]u8 = undefined;
        var slen: usize = 0;
        // Find where digits start (skip optional sign and "0x"/"0o"/"0b").
        var digit_start: usize = 0;
        if (raw.len > 0 and (raw[0] == '+' or raw[0] == '-')) digit_start = 1;
        digit_start += 2; // skip "0x"/"0o"/"0b"
        const is_negative = raw.len > 0 and raw[0] == '-';

        for (raw[digit_start..]) |c| {
            if (c != '_') {
                if (slen >= stripped.len) return error.InvalidNumber;
                stripped[slen] = c;
                slen += 1;
            }
        }
        if (slen == 0) return error.InvalidNumber;

        const val = std.fmt.parseInt(i64, stripped[0..slen], base) catch return error.InvalidNumber;
        return .{ .integer = if (is_negative) -val else val };
    }

    fn parseIntFromRaw(self: *Parser, raw: []const u8, has_sign: bool) ParseError!Value {
        _ = has_sign;
        // Strip underscores.
        var stripped: [256]u8 = undefined;
        var slen: usize = 0;
        for (raw) |c| {
            if (c != '_') {
                if (slen >= stripped.len) return error.InvalidNumber;
                stripped[slen] = c;
                slen += 1;
            }
        }
        if (slen == 0) return error.InvalidNumber;
        _ = self;
        const val = std.fmt.parseInt(i64, stripped[0..slen], 10) catch return error.InvalidNumber;
        return .{ .integer = val };
    }

    fn parseFloatFromRaw(self: *Parser, raw: []const u8) ParseError!Value {
        var stripped: [256]u8 = undefined;
        var slen: usize = 0;
        for (raw) |c| {
            if (c != '_') {
                if (slen >= stripped.len) return error.InvalidNumber;
                stripped[slen] = c;
                slen += 1;
            }
        }
        if (slen == 0) return error.InvalidNumber;
        _ = self;
        const val = std.fmt.parseFloat(f64, stripped[0..slen]) catch return error.InvalidNumber;
        return .{ .float = val };
    }

    fn parseInlineArray(self: *Parser) ParseError!Value {
        self.pos += 1; // skip '['
        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |*v| v.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        self.skipWhitespaceAndNewlines();
        if (self.pos < self.input.len and self.input[self.pos] == ']') {
            self.pos += 1;
            const empty = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
            return .{ .array = empty };
        }

        while (true) {
            self.skipWhitespaceAndNewlines();
            self.skipOptionalComment();
            self.skipWhitespaceAndNewlines();
            const val = try self.parseValue();
            items.append(self.allocator, val) catch return error.OutOfMemory;
            self.skipWhitespaceAndNewlines();
            self.skipOptionalComment();
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            if (self.input[self.pos] == ',') {
                self.pos += 1;
                self.skipWhitespaceAndNewlines();
                self.skipOptionalComment();
                self.skipWhitespaceAndNewlines();
                if (self.pos < self.input.len and self.input[self.pos] == ']') {
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (self.input[self.pos] == ']') {
                self.pos += 1;
                break;
            }
            return error.UnexpectedToken;
        }

        const arr = items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        return .{ .array = arr };
    }

    fn parseInlineTable(self: *Parser) ParseError!Value {
        self.pos += 1; // skip '{'
        var table: Table = .empty;
        errdefer freeTable(self.allocator, &table);

        self.skipWhitespace();
        if (self.pos < self.input.len and self.input[self.pos] == '}') {
            self.pos += 1;
            return .{ .table = table };
        }

        while (true) {
            self.skipWhitespace();
            try self.parseInlineKeyValue(&table);
            self.skipWhitespace();
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            if (self.input[self.pos] == ',') {
                self.pos += 1;
                continue;
            }
            if (self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }
            return error.UnexpectedToken;
        }

        return .{ .table = table };
    }

    fn parseInlineKeyValue(self: *Parser, table: *Table) ParseError!void {
        const path = try self.parseDottedKey();
        defer {
            for (path) |seg| self.allocator.free(seg);
            self.allocator.free(path);
        }
        self.skipWhitespace();
        if (self.pos >= self.input.len or self.input[self.pos] != '=')
            return error.UnexpectedToken;
        self.pos += 1;
        self.skipWhitespace();
        const value = try self.parseValue();

        var target = table;
        for (path[0 .. path.len - 1]) |segment| {
            const gop = target.getOrPut(self.allocator, segment) catch return error.OutOfMemory;
            if (!gop.found_existing) {
                const key_copy = self.allocator.dupe(u8, segment) catch return error.OutOfMemory;
                gop.key_ptr.* = key_copy;
                gop.value_ptr.* = .{ .table = .empty };
            }
            if (gop.value_ptr.* != .table) return error.DuplicateKey;
            target = &gop.value_ptr.table;
        }

        const final_key = path[path.len - 1];
        const gop = target.getOrPut(self.allocator, final_key) catch return error.OutOfMemory;
        if (gop.found_existing) return error.DuplicateKey;
        const key_copy = self.allocator.dupe(u8, final_key) catch return error.OutOfMemory;
        gop.key_ptr.* = key_copy;
        gop.value_ptr.* = value;
    }

    // Whitespace and comment helpers.

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn skipComment(self: *Parser) void {
        while (self.pos < self.input.len and self.input[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    fn skipOptionalComment(self: *Parser) void {
        if (self.pos < self.input.len and self.input[self.pos] == '#') {
            self.skipComment();
        }
    }

    fn expectNewlineOrEof(self: *Parser) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\r') self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
        }
    }
};

fn freeTable(allocator: Allocator, table: *Table) void {
    var it = table.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    table.deinit(allocator);
}

fn isBareKeyChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

fn hexDigit(c: u8) ?u21 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

// Tests.

const testing = std.testing;

fn expectString(table: Table, key: []const u8, expected: []const u8) !void {
    const val = table.get(key) orelse return error.MissingField;
    try testing.expectEqualStrings(expected, val.string);
}

fn expectInt(table: Table, key: []const u8, expected: i64) !void {
    const val = table.get(key) orelse return error.MissingField;
    try testing.expectEqual(expected, val.integer);
}

fn expectFloat(table: Table, key: []const u8, expected: f64) !void {
    const val = table.get(key) orelse return error.MissingField;
    try testing.expect(@abs(val.float - expected) < 0.001);
}

fn expectBool(table: Table, key: []const u8, expected: bool) !void {
    const val = table.get(key) orelse return error.MissingField;
    try testing.expectEqual(expected, val.boolean);
}

const MissingField = error{MissingField};

test "basic key-value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "key = \"value\"\n");
    try expectString(t, "key", "value");
}

test "integer values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = 42\nb = -17\nc = +99\n");
    try expectInt(t, "a", 42);
    try expectInt(t, "b", -17);
    try expectInt(t, "c", 99);
}

test "integer with underscores" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = 1_000_000\n");
    try expectInt(t, "a", 1_000_000);
}

test "hex octal binary integers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "hex = 0xFF\noct = 0o77\nbin = 0b1010\n");
    try expectInt(t, "hex", 255);
    try expectInt(t, "oct", 63);
    try expectInt(t, "bin", 10);
}

test "float values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = 3.14\nb = -0.5\nc = 1e10\nd = 1.5e-3\n");
    try expectFloat(t, "a", 3.14);
    try expectFloat(t, "b", -0.5);
    try expectFloat(t, "c", 1e10);
    try expectFloat(t, "d", 1.5e-3);
}

test "special float values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = inf\nb = -inf\nc = nan\n");
    const a = t.get("a") orelse return error.MissingField;
    try testing.expect(std.math.isInf(a.float));
    const b = t.get("b") orelse return error.MissingField;
    try testing.expect(std.math.isInf(b.float) and b.float < 0);
    const cv = t.get("c") orelse return error.MissingField;
    try testing.expect(std.math.isNan(cv.float));
}

test "boolean values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = true\nb = false\n");
    try expectBool(t, "a", true);
    try expectBool(t, "b", false);
}

test "basic string escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = \"hello\\nworld\"\n");
    try expectString(t, "a", "hello\nworld");
}

test "literal string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = 'no\\escapes'\n");
    try expectString(t, "a", "no\\escapes");
}

test "multiline basic string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = \"\"\"\nhello\nworld\"\"\"\n");
    try expectString(t, "a", "hello\nworld");
}

test "multiline literal string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = '''\nhello\nworld'''\n");
    try expectString(t, "a", "hello\nworld");
}

test "unicode escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = \"\\u0041\"\n");
    try expectString(t, "a", "A");
}

test "large unicode escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = \"\\U0001F600\"\n");
    try expectString(t, "a", "\u{1F600}");
}

test "dotted keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a.b.c = 42\n");
    const a = t.get("a") orelse return error.MissingField;
    const b = a.table.get("b") orelse return error.MissingField;
    try testing.expectEqual(@as(i64, 42), b.table.get("c").?.integer);
}

test "table header" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
    );
    const server = t.get("server") orelse return error.MissingField;
    try expectString(server.table, "host", "localhost");
    try expectInt(server.table, "port", 8080);
}

test "nested table headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\[a.b]
        \\c = 1
        \\
    );
    const a = t.get("a") orelse return error.MissingField;
    const b = a.table.get("b") orelse return error.MissingField;
    try expectInt(b.table, "c", 1);
}

test "array of tables" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\[[items]]
        \\name = "a"
        \\
        \\[[items]]
        \\name = "b"
        \\
    );
    const items = t.get("items") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 2), items.array.len);
    try expectString(items.array[0].table, "name", "a");
    try expectString(items.array[1].table, "name", "b");
}

test "inline table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "point = {x = 1, y = 2}\n");
    const point = t.get("point") orelse return error.MissingField;
    try expectInt(point.table, "x", 1);
    try expectInt(point.table, "y", 2);
}

test "inline array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "nums = [1, 2, 3]\n");
    const nums = t.get("nums") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 3), nums.array.len);
    try testing.expectEqual(@as(i64, 1), nums.array[0].integer);
    try testing.expectEqual(@as(i64, 2), nums.array[1].integer);
    try testing.expectEqual(@as(i64, 3), nums.array[2].integer);
}

test "empty inline array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = []\n");
    const a = t.get("a") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 0), a.array.len);
}

test "comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\# A comment
        \\key = "val" # inline comment
        \\
    );
    try expectString(t, "key", "val");
}

test "duplicate key error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parse(arena.allocator(), "a = 1\na = 2\n");
    try testing.expectError(error.DuplicateKey, result);
}

test "quoted keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "\"key with spaces\" = 42\n");
    try expectInt(t, "key with spaces", 42);
}

test "empty string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = \"\"\n");
    try expectString(t, "a", "");
}

test "trailing comma in array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "a = [1, 2,]\n");
    const a = t.get("a") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 2), a.array.len);
}

test "multiline array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\a = [
        \\  1,
        \\  2,
        \\  3,
        \\]
        \\
    );
    const a = t.get("a") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 3), a.array.len);
}

test "root keys and table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(),
        \\title = "config"
        \\
        \\[db]
        \\host = "localhost"
        \\
    );
    try expectString(t, "title", "config");
    const db = t.get("db") orelse return error.MissingField;
    try expectString(db.table, "host", "localhost");
}

test "empty document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "empty table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const t = try parse(arena.allocator(), "[empty]\n");
    const empty = t.get("empty") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 0), empty.table.count());
}
