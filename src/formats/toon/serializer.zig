const std = @import("std");
const compat = @import("compat");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const Entry = value_mod.Entry;

pub const Delimiter = enum { comma, tab, pipe };
pub const KeyFolding = enum { off, safe };

pub const Options = struct {
    indent: u8 = 2,
    delimiter: Delimiter = .comma,
    key_folding: KeyFolding = .off,
    flatten_depth: usize = std.math.maxInt(usize),
};

pub const SerializeError = error{ OutOfMemory, WriteFailed };

pub fn fromJsonValue(allocator: std.mem.Allocator, src: std.json.Value) !Value {
    switch (src) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| {
            if (i < 0) return .{ .int = i };
            return .{ .uint = @intCast(i) };
        },
        .float => |f| return .{ .float = f },
        .number_string => |s| return .{ .number_string = try value_mod.dupe(allocator, s) },
        .string => |s| return .{ .string = try value_mod.dupe(allocator, s) },
        .array => |arr| {
            var out = try allocator.alloc(Value, arr.items.len);
            @memset(out, .null);
            errdefer {
                for (out[0..]) |item| item.deinit(allocator);
                allocator.free(out);
            }
            for (arr.items, 0..) |item, i| out[i] = try fromJsonValue(allocator, item);
            return .{ .array = out };
        },
        .object => |obj| {
            var out = try allocator.alloc(Entry, obj.count());
            @memset(out, .{ .key = &.{}, .value = .null, .quoted = false });
            errdefer {
                for (out[0..]) |entry| {
                    allocator.free(entry.key);
                    entry.value.deinit(allocator);
                }
                allocator.free(out);
            }
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                const key = try value_mod.dupe(allocator, entry.key_ptr.*);
                errdefer allocator.free(key);
                const child = try fromJsonValue(allocator, entry.value_ptr.*);
                out[i] = .{
                    .key = key,
                    .value = child,
                    .quoted = false,
                };
            }
            return .{ .object = out };
        },
    }
}

pub fn render(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: Value, opts: Options) SerializeError!void {
    var r = Renderer{ .allocator = allocator, .writer = writer, .options = opts };
    try r.renderRoot(value);
}

const Renderer = struct {
    allocator: std.mem.Allocator,
    writer: *compat.Io.Writer,
    options: Options,
    wrote_line: bool = false,

    fn renderRoot(self: *Renderer, value: Value) SerializeError!void {
        switch (value) {
            .object => |entries| try self.renderObjectEntries(entries, 0),
            .array => |items| {
                if (items.len == 0) {
                    try self.writeRawLine(0, "[]");
                } else if (isPrimitiveArray(items)) {
                    try self.writeHeaderLine(null, items.len, null, 0, true);
                    try self.writeInlineArray(items);
                } else if (try tabularFields(self.allocator, items)) |fields| {
                    defer self.allocator.free(fields);
                    try self.writeHeaderLine(null, items.len, fields, 0, false);
                    for (items) |item| try self.writeTableRow(item.object, fields, 1);
                } else {
                    try self.writeHeaderLine(null, items.len, null, 0, false);
                    try self.renderExpandedItems(items, 1);
                }
            },
            else => {
                try self.writeIndentLine(0);
                try self.writePrimitive(value, self.options.delimiter);
            },
        }
    }

    fn renderObjectEntries(self: *Renderer, entries: []Entry, depth: usize) SerializeError!void {
        for (entries, 0..) |entry, i| {
            if (self.foldCandidate(entries, i)) |folded| {
                defer self.allocator.free(folded.key);
                try self.renderField(folded.key, folded.value, depth);
            } else {
                try self.renderField(entry.key, entry.value, depth);
            }
        }
    }

    const Folded = struct { key: []const u8, value: Value };

    fn foldCandidate(self: *Renderer, siblings: []Entry, index: usize) ?Folded {
        if (self.options.key_folding != .safe or self.options.flatten_depth < 2) return null;
        const first = siblings[index];
        if (!isIdentifierSegment(first.key)) return null;

        var value = first.value;
        var count: usize = 1;
        var needed = first.key.len;
        while (count < self.options.flatten_depth) {
            if (value != .object or value.object.len != 1) break;
            const next = value.object[0];
            if (!isIdentifierSegment(next.key)) break;
            count += 1;
            needed += 1 + next.key.len;
            value = next.value;
        }
        if (count < 2) return null;

        var buf = self.allocator.alloc(u8, needed) catch return null;
        var pos: usize = 0;
        @memcpy(buf[pos..][0..first.key.len], first.key);
        pos += first.key.len;
        value = first.value;
        var emitted: usize = 1;
        while (emitted < count) : (emitted += 1) {
            const next = value.object[0];
            buf[pos] = '.';
            pos += 1;
            @memcpy(buf[pos..][0..next.key.len], next.key);
            pos += next.key.len;
            value = next.value;
        }

        for (siblings, 0..) |sib, i| {
            if (i != index and std.mem.eql(u8, sib.key, buf)) {
                self.allocator.free(buf);
                return null;
            }
        }
        return .{ .key = buf, .value = value };
    }

    fn renderField(self: *Renderer, key: []const u8, value: Value, depth: usize) SerializeError!void {
        switch (value) {
            .object => |entries| {
                try self.writeIndentLine(depth);
                try writeKey(self.writer, key);
                self.writer.writeByte(':') catch return error.WriteFailed;
                if (entries.len > 0) try self.renderObjectEntries(entries, depth + 1);
            },
            .array => |items| try self.renderArrayField(key, items, depth),
            else => {
                try self.writeIndentLine(depth);
                try writeKey(self.writer, key);
                self.writer.writeAll(": ") catch return error.WriteFailed;
                try self.writePrimitive(value, self.options.delimiter);
            },
        }
    }

    fn renderArrayField(self: *Renderer, key: []const u8, items: []Value, depth: usize) SerializeError!void {
        if (items.len == 0) {
            try self.writeIndentLine(depth);
            try writeKey(self.writer, key);
            self.writer.writeAll(": []") catch return error.WriteFailed;
        } else if (isPrimitiveArray(items)) {
            try self.writeHeaderLine(key, items.len, null, depth, true);
            try self.writeInlineArray(items);
        } else if (try tabularFields(self.allocator, items)) |fields| {
            defer self.allocator.free(fields);
            try self.writeHeaderLine(key, items.len, fields, depth, false);
            for (items) |item| try self.writeTableRow(item.object, fields, depth + 1);
        } else {
            try self.writeHeaderLine(key, items.len, null, depth, false);
            try self.renderExpandedItems(items, depth + 1);
        }
    }

    fn renderExpandedItems(self: *Renderer, items: []Value, depth: usize) SerializeError!void {
        for (items) |item| {
            switch (item) {
                .object => |entries| {
                    try self.writeIndentLine(depth);
                    if (entries.len == 0) {
                        self.writer.writeByte('-') catch return error.WriteFailed;
                    } else {
                        self.writer.writeAll("- ") catch return error.WriteFailed;
                        try writeKey(self.writer, entries[0].key);
                        switch (entries[0].value) {
                            .array => |arr| {
                                if (arr.len == 0) {
                                    self.writer.writeAll(": []") catch return error.WriteFailed;
                                } else if (isPrimitiveArray(arr)) {
                                    try self.writeHeaderSuffix(arr.len, null, true);
                                    try self.writeInlineArray(arr);
                                } else if (try tabularFields(self.allocator, arr)) |fields| {
                                    defer self.allocator.free(fields);
                                    try self.writeHeaderSuffix(arr.len, fields, false);
                                    for (arr) |row| try self.writeTableRow(row.object, fields, depth + 2);
                                } else {
                                    try self.writeHeaderSuffix(arr.len, null, false);
                                    try self.renderExpandedItems(arr, depth + 2);
                                }
                            },
                            .object => |obj| {
                                self.writer.writeByte(':') catch return error.WriteFailed;
                                if (obj.len > 0) try self.renderObjectEntries(obj, depth + 2);
                            },
                            else => {
                                self.writer.writeAll(": ") catch return error.WriteFailed;
                                try self.writePrimitive(entries[0].value, self.options.delimiter);
                            },
                        }
                        if (entries.len > 1) try self.renderObjectEntries(entries[1..], depth + 1);
                    }
                },
                .array => |arr| {
                    try self.writeIndentLine(depth);
                    self.writer.writeAll("- ") catch return error.WriteFailed;
                    try self.writeHeaderSuffix(arr.len, null, isPrimitiveArray(arr));
                    if (isPrimitiveArray(arr)) {
                        try self.writeInlineArray(arr);
                    } else {
                        try self.renderExpandedItems(arr, depth + 1);
                    }
                },
                else => {
                    try self.writeIndentLine(depth);
                    self.writer.writeAll("- ") catch return error.WriteFailed;
                    try self.writePrimitive(item, self.options.delimiter);
                },
            }
        }
    }

    fn writeTableRow(self: *Renderer, entries: []Entry, fields: []const []const u8, depth: usize) SerializeError!void {
        try self.writeIndentLine(depth);
        for (fields, 0..) |field, i| {
            if (i != 0) try self.writeDelimiter();
            const value = findField(entries, field) orelse Value.null;
            try self.writePrimitive(value, self.options.delimiter);
        }
    }

    fn writeHeaderLine(self: *Renderer, key: ?[]const u8, len: usize, fields: ?[]const []const u8, depth: usize, inline_values: bool) SerializeError!void {
        try self.writeIndentLine(depth);
        if (key) |k| try writeKey(self.writer, k);
        try self.writeHeaderSuffix(len, fields, inline_values);
    }

    fn writeHeaderSuffix(self: *Renderer, len: usize, fields: ?[]const []const u8, inline_values: bool) SerializeError!void {
        self.writer.writeByte('[') catch return error.WriteFailed;
        self.writer.print("{d}", .{len}) catch return error.WriteFailed;
        switch (self.options.delimiter) {
            .comma => {},
            .tab => self.writer.writeByte('\t') catch return error.WriteFailed,
            .pipe => self.writer.writeByte('|') catch return error.WriteFailed,
        }
        self.writer.writeByte(']') catch return error.WriteFailed;
        if (fields) |names| {
            self.writer.writeByte('{') catch return error.WriteFailed;
            for (names, 0..) |name, i| {
                if (i != 0) try self.writeDelimiter();
                try writeKey(self.writer, name);
            }
            self.writer.writeByte('}') catch return error.WriteFailed;
        }
        self.writer.writeByte(':') catch return error.WriteFailed;
        if (inline_values and len > 0) self.writer.writeByte(' ') catch return error.WriteFailed;
    }

    fn writeInlineArray(self: *Renderer, items: []Value) SerializeError!void {
        for (items, 0..) |item, i| {
            if (i != 0) try self.writeDelimiter();
            try self.writePrimitive(item, self.options.delimiter);
        }
    }

    fn writePrimitive(self: *Renderer, value: Value, delimiter: Delimiter) SerializeError!void {
        switch (value) {
            .null => self.writer.writeAll("null") catch return error.WriteFailed,
            .bool => |b| self.writer.writeAll(if (b) "true" else "false") catch return error.WriteFailed,
            .int => |i| self.writer.print("{d}", .{i}) catch return error.WriteFailed,
            .uint => |u| self.writer.print("{d}", .{u}) catch return error.WriteFailed,
            .float => |f| {
                if (!std.math.isFinite(f)) {
                    self.writer.writeAll("null") catch return error.WriteFailed;
                } else if (f == 0) {
                    self.writer.writeByte('0') catch return error.WriteFailed;
                } else {
                    self.writer.print("{d}", .{f}) catch return error.WriteFailed;
                }
            },
            .number_string => |s| self.writer.writeAll(s) catch return error.WriteFailed,
            .string => |s| try writeStringValue(self.writer, s, delimiter),
            .array, .object => return error.WriteFailed,
        }
    }

    fn writeDelimiter(self: *Renderer) SerializeError!void {
        self.writer.writeByte(delimiterByte(self.options.delimiter)) catch return error.WriteFailed;
    }

    fn writeIndentLine(self: *Renderer, depth: usize) SerializeError!void {
        if (self.wrote_line) self.writer.writeByte('\n') catch return error.WriteFailed;
        self.wrote_line = true;
        for (0..depth * self.options.indent) |_| self.writer.writeByte(' ') catch return error.WriteFailed;
    }

    fn writeRawLine(self: *Renderer, depth: usize, bytes: []const u8) SerializeError!void {
        try self.writeIndentLine(depth);
        self.writer.writeAll(bytes) catch return error.WriteFailed;
    }
};

fn findField(entries: []Entry, key: []const u8) ?Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn tabularFields(allocator: std.mem.Allocator, items: []Value) SerializeError!?[]const []const u8 {
    if (items.len == 0 or items[0] != .object or items[0].object.len == 0) return null;
    const first = items[0].object;
    for (first) |entry| if (!isPrimitive(entry.value)) return null;
    for (items[1..]) |item| {
        if (item != .object or item.object.len != first.len) return null;
        for (first) |entry| {
            const found = findField(item.object, entry.key) orelse return null;
            if (!isPrimitive(found)) return null;
        }
    }
    var fields = allocator.alloc([]const u8, first.len) catch return error.OutOfMemory;
    for (first, 0..) |entry, i| fields[i] = entry.key;
    return fields;
}

fn isPrimitiveArray(items: []Value) bool {
    for (items) |item| if (!isPrimitive(item)) return false;
    return true;
}

fn isPrimitive(value: Value) bool {
    return switch (value) {
        .null, .bool, .int, .uint, .float, .number_string, .string => true,
        .array, .object => false,
    };
}

fn writeKey(writer: *compat.Io.Writer, key: []const u8) SerializeError!void {
    if (isKeyBare(key)) {
        writer.writeAll(key) catch return error.WriteFailed;
    } else {
        try writeQuoted(writer, key);
    }
}

fn writeStringValue(writer: *compat.Io.Writer, s: []const u8, delimiter: Delimiter) SerializeError!void {
    if (mustQuoteString(s, delimiter)) {
        try writeQuoted(writer, s);
    } else {
        writer.writeAll(s) catch return error.WriteFailed;
    }
}

fn writeQuoted(writer: *compat.Io.Writer, s: []const u8) SerializeError!void {
    writer.writeByte('"') catch return error.WriteFailed;
    for (s) |c| {
        switch (c) {
            '\\' => writer.writeAll("\\\\") catch return error.WriteFailed,
            '"' => writer.writeAll("\\\"") catch return error.WriteFailed,
            '\n' => writer.writeAll("\\n") catch return error.WriteFailed,
            '\r' => writer.writeAll("\\r") catch return error.WriteFailed,
            '\t' => writer.writeAll("\\t") catch return error.WriteFailed,
            0...7, 0x0b, 0x0c, 0x0e...0x1f => writer.print("\\u{x:0>4}", .{c}) catch return error.WriteFailed,
            else => writer.writeByte(c) catch return error.WriteFailed,
        }
    }
    writer.writeByte('"') catch return error.WriteFailed;
}

fn mustQuoteString(s: []const u8, delimiter: Delimiter) bool {
    if (s.len == 0) return true;
    if (std.ascii.isWhitespace(s[0]) or std.ascii.isWhitespace(s[s.len - 1])) return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) return true;
    if (isNumericLike(s)) return true;
    if (s[0] == '-') return true;
    for (s) |c| {
        if (c == ':' or c == '"' or c == '\\' or c == '[' or c == ']' or c == '{' or c == '}') return true;
        if (c < 0x20) return true;
        if (c == delimiterByte(delimiter)) return true;
    }
    return false;
}

fn isNumericLike(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-') {
        i += 1;
        if (i == s.len) return false;
    }
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (digits == 0) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var frac: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) frac += 1;
        if (frac == 0) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var exp: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) exp += 1;
        if (exp == 0) return false;
    }
    return i == s.len;
}

fn isKeyBare(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) return false;
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
