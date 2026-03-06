const std = @import("std");

pub const Dialect = struct {
    delimiter: u8 = ',',
    quote: u8 = '"',
    has_header: bool = true,
    trim_whitespace: bool = false,
};

pub const tsv_dialect: Dialect = .{ .delimiter = '\t' };
pub const excel_dialect: Dialect = .{ .delimiter = ',', .quote = '"' };
pub const unix_dialect: Dialect = .{ .delimiter = ',', .quote = '"', .trim_whitespace = true };

pub const Field = struct {
    raw: []const u8,
    quoted: bool,
};

pub const ScanError = error{
    UnexpectedEof,
    InvalidQuoting,
};

pub const Scanner = struct {
    input: []const u8,
    pos: usize = 0,
    dialect: Dialect,
    at_row_start: bool = true,

    pub fn init(input: []const u8, dialect: Dialect) Scanner {
        var pos: usize = 0;
        // Skip UTF-8 BOM.
        if (input.len >= 3 and input[0] == 0xEF and input[1] == 0xBB and input[2] == 0xBF) {
            pos = 3;
        }
        return .{ .input = input, .pos = pos, .dialect = dialect };
    }

    pub fn isEof(self: *const Scanner) bool {
        return self.pos >= self.input.len;
    }

    /// Advance past the current row's remaining fields until the next line or EOF.
    pub fn skipRow(self: *Scanner) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\n') {
                self.pos += 1;
                return;
            }
            if (c == '\r') {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n')
                    self.pos += 1;
                return;
            }
            if (c == self.dialect.quote) {
                self.pos += 1;
                // Skip quoted content.
                while (self.pos < self.input.len) {
                    if (self.input[self.pos] == self.dialect.quote) {
                        self.pos += 1;
                        if (self.pos < self.input.len and self.input[self.pos] == self.dialect.quote) {
                            self.pos += 1;
                            continue;
                        }
                        break;
                    }
                    self.pos += 1;
                }
            } else {
                self.pos += 1;
            }
        }
    }

    /// Read the next field in the current row. Returns null at end-of-row or EOF.
    /// After returning null, the scanner is positioned at the start of the next row.
    pub fn nextField(self: *Scanner) ScanError!?Field {
        if (self.pos >= self.input.len) {
            if (!self.at_row_start) {
                self.at_row_start = true;
                return null;
            }
            return null;
        }

        const c = self.input[self.pos];

        // End of row.
        if (c == '\n') {
            self.pos += 1;
            self.at_row_start = true;
            return null;
        }
        if (c == '\r') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '\n')
                self.pos += 1;
            self.at_row_start = true;
            return null;
        }

        if (!self.at_row_start) {
            // Expect a delimiter between fields.
            if (c != self.dialect.delimiter) return error.InvalidQuoting;
            self.pos += 1;
        }
        self.at_row_start = false;

        // Empty field at end of input or before newline.
        if (self.pos >= self.input.len) return .{ .raw = "", .quoted = false };
        const next = self.input[self.pos];
        if (next == '\n' or next == '\r') return .{ .raw = "", .quoted = false };

        if (next == self.dialect.quote) {
            return @as(?Field, try self.scanQuotedField());
        }
        var f = self.scanUnquotedField();
        if (self.dialect.trim_whitespace) {
            f.raw = std.mem.trim(u8, f.raw, " \t");
        }
        return @as(?Field, f);
    }

    /// Read all fields of the current row into a caller-provided list.
    pub fn readRow(self: *Scanner, allocator: std.mem.Allocator) ScanError!?[]Field {
        if (self.isEof()) return null;

        // Check for blank line.
        if (self.input[self.pos] == '\n') {
            self.pos += 1;
            self.at_row_start = true;
            var empty: std.ArrayList(Field) = .empty;
            return empty.toOwnedSlice(allocator) catch return error.UnexpectedEof;
        }
        if (self.input[self.pos] == '\r') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '\n')
                self.pos += 1;
            self.at_row_start = true;
            var empty: std.ArrayList(Field) = .empty;
            return empty.toOwnedSlice(allocator) catch return error.UnexpectedEof;
        }

        var fields: std.ArrayList(Field) = .empty;
        errdefer fields.deinit(allocator);

        self.at_row_start = true;
        while (true) {
            const field = try self.nextField();
            if (field) |f| {
                fields.append(allocator, f) catch return error.UnexpectedEof;
            } else {
                break;
            }
        }

        return fields.toOwnedSlice(allocator) catch return error.UnexpectedEof;
    }

    fn scanUnquotedField(self: *Scanner) Field {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == self.dialect.delimiter or c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        return .{ .raw = self.input[start..self.pos], .quoted = false };
    }

    fn scanQuotedField(self: *Scanner) ScanError!Field {
        self.pos += 1; // skip opening quote
        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == self.dialect.quote) {
                // Doubled quote -> escaped quote, continue scanning.
                if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == self.dialect.quote) {
                    self.pos += 2;
                    continue;
                }
                // Closing quote.
                const raw = self.input[start..self.pos];
                self.pos += 1;
                return .{ .raw = raw, .quoted = true };
            }
            self.pos += 1;
        }
        return error.UnexpectedEof;
    }
};

/// Unescape a quoted field: replace doubled quotes with single quotes.
pub fn unquoteField(allocator: std.mem.Allocator, raw: []const u8, quote: u8) ![]const u8 {
    // Fast path: no doubled quotes present.
    if (std.mem.indexOf(u8, raw, &.{ quote, quote }) == null) {
        return allocator.dupe(u8, raw);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == quote and i + 1 < raw.len and raw[i + 1] == quote) {
            out.append(allocator, quote) catch return error.OutOfMemory;
            i += 2;
        } else {
            out.append(allocator, raw[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const testing = std.testing;

test "scan simple row" {
    var s = Scanner.init("a,b,c\n", .{});
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("a", f1.raw);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("b", f2.raw);
    const f3 = (try s.nextField()).?;
    try testing.expectEqualStrings("c", f3.raw);
    try testing.expectEqual(@as(?Field, null), try s.nextField());
}

test "scan quoted field" {
    var s = Scanner.init("\"hello, world\",b\n", .{});
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("hello, world", f1.raw);
    try testing.expect(f1.quoted);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("b", f2.raw);
}

test "scan doubled quotes" {
    var s = Scanner.init("\"he said \"\"hi\"\"\",b\n", .{});
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("he said \"\"hi\"\"", f1.raw);
    try testing.expect(f1.quoted);
    const unquoted = try unquoteField(testing.allocator, f1.raw, '"');
    defer testing.allocator.free(unquoted);
    try testing.expectEqualStrings("he said \"hi\"", unquoted);
}

test "scan CRLF" {
    var s = Scanner.init("a,b\r\nc,d\r\n", .{});
    _ = (try s.nextField()).?;
    _ = (try s.nextField()).?;
    try testing.expectEqual(@as(?Field, null), try s.nextField());
    const f3 = (try s.nextField()).?;
    try testing.expectEqualStrings("c", f3.raw);
}

test "scan empty fields" {
    var s = Scanner.init(",b,\n", .{});
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("", f1.raw);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("b", f2.raw);
    const f3 = (try s.nextField()).?;
    try testing.expectEqualStrings("", f3.raw);
}

test "scan TSV" {
    var s = Scanner.init("a\tb\tc\n", tsv_dialect);
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("a", f1.raw);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("b", f2.raw);
    const f3 = (try s.nextField()).?;
    try testing.expectEqualStrings("c", f3.raw);
}

test "scan BOM" {
    var s = Scanner.init("\xEF\xBB\xBFa,b\n", .{});
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("a", f1.raw);
}

test "scan no trailing newline" {
    var s = Scanner.init("a,b", .{});
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("a", f1.raw);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("b", f2.raw);
    try testing.expectEqual(@as(?Field, null), try s.nextField());
}

test "scan trim whitespace" {
    var s = Scanner.init("  a , b , c \n", unix_dialect);
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("a", f1.raw);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("b", f2.raw);
    const f3 = (try s.nextField()).?;
    try testing.expectEqualStrings("c", f3.raw);
}

test "excel dialect is default CSV" {
    var s = Scanner.init("a,b\n", excel_dialect);
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("a", f1.raw);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("b", f2.raw);
}

test "unix dialect trims" {
    var s = Scanner.init(" x , y \n", unix_dialect);
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("x", f1.raw);
    const f2 = (try s.nextField()).?;
    try testing.expectEqualStrings("y", f2.raw);
}

test "readRow" {
    var s = Scanner.init("a,b,c\n1,2,3\n", .{});
    const row1 = (try s.readRow(testing.allocator)).?;
    defer testing.allocator.free(row1);
    try testing.expectEqual(@as(usize, 3), row1.len);
    try testing.expectEqualStrings("a", row1[0].raw);
    try testing.expectEqualStrings("b", row1[1].raw);
    try testing.expectEqualStrings("c", row1[2].raw);

    const row2 = (try s.readRow(testing.allocator)).?;
    defer testing.allocator.free(row2);
    try testing.expectEqualStrings("1", row2[0].raw);
}

test "scan quoted field with newline" {
    var s = Scanner.init("\"line1\nline2\",b\n", .{});
    const f1 = (try s.nextField()).?;
    try testing.expectEqualStrings("line1\nline2", f1.raw);
    try testing.expect(f1.quoted);
}
