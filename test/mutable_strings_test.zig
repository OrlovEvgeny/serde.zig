const std = @import("std");
const serde = @import("serde");
const testing = std.testing;
const A = testing.allocator;
const Allocator = std.mem.Allocator;
const Foo = struct { string: []u8 };
const ownership = serde.core.deserialize_mod.ownership;

fn roundtrip(comptime format: type, comptime T: type, value: T) !void {
    const bytes = try format.toSlice(A, value);
    defer A.free(bytes);
    const parsed = try format.fromSlice(T, A, bytes);
    defer serde.core.freeAllocated(T, parsed, A);
    const text = if (T == Foo) parsed.string else parsed[0].string;
    try testing.expectEqualStrings("hello", text);
    text[0] = 'H';
    const saved = try format.toSlice(A, parsed);
    defer A.free(saved);
    var managed = try format.fromSliceManaged(T, A, saved);
    defer managed.deinit();
    const managed_text = if (T == Foo) managed.value.string else managed.value[0].string;
    try testing.expectEqualStrings("Hello", managed_text);
    managed_text[0] = 'J';
    var reader = serde.compat.Io.Reader.fixed(saved);
    const streamed = try format.fromReader(T, A, &reader);
    defer serde.core.freeAllocated(T, streamed, A);
    const streamed_text = if (T == Foo) streamed.string else streamed[0].string;
    streamed_text[0] = 'Y';
    try testing.expectEqualStrings("Yello", streamed_text);
}

test "mutable strings parse edit and serialize through all nine formats and readers" {
    var text = "hello".*;
    const value = Foo{ .string = &text };
    inline for (.{ serde.json, serde.zon, serde.xml, serde.toml, serde.yaml, serde.toon, serde.msgpack, serde.etf }) |format| {
        try roundtrip(format, Foo, value);
    }
    try roundtrip(serde.csv, []const Foo, &.{value});
}

test "mutable strings through Value tokens nested containers and schemas" {
    const value = serde.Value{ .string = "hello" };
    const text = try value.toType([]u8, A);
    defer A.free(text);
    text[0] = 'H';
    try testing.expectEqualStrings("hello", value.string);
    var tokens = serde.testing.TokenDeserializer.init(&.{.{ .string = "hello" }});
    const token_text = try serde.deserialize([]u8, A, &tokens, .{});
    defer A.free(token_text);
    token_text[0] = 'H';
    try tokens.finish();

    const T = struct { optional: ?[]u8, array: [2][]u8, slice: [][]u8, map: std.StringHashMap([]u8), tagged: union(enum) { text: []u8 } };
    const parsed = try serde.json.fromSlice(T, A,
        \\{"optional":"yes","array":["a","b"],"slice":["c","d"],"map":{"k":"v"},"tagged":{"text":"u"}}
    );
    defer serde.core.freeAllocated(T, parsed, A);
    parsed.optional.?[0] = 'Y';
    parsed.array[0][0] = 'A';
    parsed.slice[0][0] = 'C';
    parsed.map.get("k").?[0] = 'V';
    parsed.tagged.text[0] = 'U';
    const schema = .{ .rename = .{ .string = "name" } };
    const renamed = try serde.json.fromSliceSchema(Foo, A, "{\"name\":\"hi\"}", schema);
    defer serde.core.freeAllocatedSchema(Foo, renamed, A, schema);
    renamed.string[0] = 'H';
    try testing.expectEqualStrings("Hi", renamed.string);
    const absent = try serde.json.fromSlice(?[]u8, A, "null");
    try testing.expect(absent == null);
    const empty = try serde.json.fromSlice([]u8, A, "null");
    defer A.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

const Mixed = struct { constant: []const u8, mutable: []u8, empty: []u8 };
fn checkMixed(comptime format: type, allocator: Allocator, input: []const u8, expected: []const u8) !void {
    const parsed = try format.fromSliceBorrowed(Mixed, allocator, input);
    defer ownership.free(Mixed, parsed, allocator, .{}, input);
    try testing.expectEqualStrings("borrowed", parsed.constant);
    const start = @intFromPtr(input.ptr);
    try testing.expect(@intFromPtr(parsed.constant.ptr) >= start and @intFromPtr(parsed.constant.ptr) < start + input.len);
    try testing.expectEqualStrings(expected, parsed.mutable);
    try testing.expect(@intFromPtr(parsed.mutable.ptr) < start or @intFromPtr(parsed.mutable.ptr) >= start + input.len);
    try testing.expectEqual(@as(usize, 0), parsed.empty.len);
    parsed.mutable[0] = 'X';
    try testing.expectEqualStrings("borrowed", parsed.constant);
}
fn borrowedPaths(allocator: Allocator) !void {
    inline for (.{ serde.json, serde.zon }) |format| {
        const input = if (format == serde.json)
            "{\"constant\":\"borrowed\",\"mutable\":\"a\\n世界\",\"empty\":\"\"}"
        else
            ".{ .constant = \"borrowed\", .mutable = \"a\\n世界\", .empty = \"\" }";
        try checkMixed(format, allocator, input, "a\n世界");
    }
    try checkMixed(serde.xml, allocator, "<root><constant>borrowed</constant><mutable>a&amp;&#x4e16;</mutable><empty></empty></root>", "a&世");
    try checkMixed(serde.xml, allocator, "<root constant=\"borrowed\" mutable=\"a&amp;&#x4e16;\" empty=\"\"/>", "a&世");
}

test "borrowed const strings coexist with owned mutable strings and decoded escapes" {
    try borrowedPaths(A);
    try testing.checkAllAllocationFailures(A, borrowedPaths, .{});
    inline for (.{ serde.json, serde.zon }) |format| {
        const text = try format.fromSliceBorrowed([]u8, A, "\"plain\"");
        defer A.free(text);
        text[0] = 'P';
        const unicode = try format.fromSliceBorrowed([]u8, A, if (format == serde.json) "\"\\u0041\"" else "\"\\x41\"");
        defer A.free(unicode);
        try testing.expectEqualStrings("A", unicode);
        try testing.expectError(error.InvalidEscape, format.fromSliceBorrowed([]const u8, A, "\"a\\nb\""));
    }
    try testing.expectError(error.MalformedXml, serde.xml.fromSliceBorrowed(FooConst, A, "<root><string>a&amp;b</string></root>"));
    const attr = try serde.xml.fromSliceBorrowed(Foo, A, "<root string=\"plain\"/>");
    defer A.free(attr.string);
    attr.string[0] = 'P';
}
const FooConst = struct { string: []const u8 };

fn ownedPaths(allocator: Allocator) !void {
    const T = struct { a: []u8, b: [][]u8 };
    const parsed = try serde.json.fromSlice(T, allocator, "{\"a\":\"a\\nb\",\"b\":[\"one\",\"two\"]}");
    defer serde.core.freeAllocated(T, parsed, allocator);
    var managed = try serde.json.fromSliceManaged(T, allocator, "{\"a\":\"a\\nb\",\"b\":[\"one\",\"two\"]}");
    defer managed.deinit();
}
fn expectParseError(comptime format: type, comptime T: type, allocator: Allocator, comptime borrowed: bool, input: []const u8, expected: anyerror) !void {
    const parse = if (borrowed) format.fromSliceBorrowed else format.fromSlice;
    const parsed = parse(T, allocator, input) catch |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expectEqual(expected, err);
        return;
    };
    defer ownership.free(T, parsed, allocator, .{}, if (borrowed) input else null);
    return error.TestExpectedError;
}
fn errorPaths(allocator: Allocator) !void {
    const Required = struct { mutable: []u8, constant: []const u8, missing: bool };
    inline for (.{ false, true }) |borrowed| {
        try expectParseError(serde.json, Required, allocator, borrowed, "{\"mutable\":\"a\\nb\",\"constant\":\"view\"}", error.MissingField);
        try expectParseError(serde.json, Foo, allocator, borrowed, "{\"string\":\"a\",\"string\":\"b\"}", error.DuplicateField);
        try expectParseError(serde.json, Foo, allocator, borrowed, "{\"string\":\"a\"}x", error.TrailingData);
        try expectParseError(serde.json, [][]u8, allocator, borrowed, "[\"a\",false]", error.WrongType);
        try expectParseError(serde.zon, Required, allocator, borrowed, ".{ .mutable = \"a\\nb\", .constant = \"view\" }", error.MissingField);
        try expectParseError(serde.zon, Foo, allocator, borrowed, ".{ .string = \"a\", .string = \"b\" }", error.DuplicateField);
        try expectParseError(serde.zon, Foo, allocator, borrowed, ".{ .string = \"a\" }x", error.TrailingData);
        try expectParseError(serde.xml, Required, allocator, borrowed, "<root><mutable>a&amp;b</mutable><constant>view</constant></root>", error.MissingField);
        try expectParseError(serde.xml, Required, allocator, borrowed, "<root mutable=\"a&amp;b\" constant=\"view\"/>", error.MissingField);
        try expectParseError(serde.xml, Foo, allocator, borrowed, "<root><string>a</string><string>b</string></root>", error.DuplicateField);
    }
}

test "mutable strings release partial results and survive allocation failures" {
    try testing.checkAllAllocationFailures(A, ownedPaths, .{});
    try errorPaths(A);
    try testing.checkAllAllocationFailures(A, errorPaths, .{});
}

// These backends predate deserializeStringOwned. Their const return type still
// transfers allocations, while the borrowing protocol identifies input views.
fn Legacy(comptime explicit: bool) type {
    return struct {
        const Self = @This();
        pub const Error = error{OutOfMemory};
        input: []const u8,
        borrow_strings: bool = true,
        owned: bool = false,
        last_owned: ?[]const u8 = null,
        pub fn deserializeString(self: *Self, allocator: Allocator) Error![]const u8 {
            if (self.owned) {
                const result = try allocator.dupe(u8, self.input);
                self.last_owned = result;
                return result;
            }
            return self.input;
        }
        pub const serde_protocol = if (explicit) struct {
            pub fn borrowedInput(self: *const Self) ?[]const u8 {
                return self.input;
            }
        } else struct {};
    };
}
const LegacyFields = struct {
    pub const Error = error{OutOfMemory};
    input: []const u8,
    borrow_strings: bool = true,
    pub fn deserializeString(self: *@This(), _: Allocator) Error![]const u8 {
        return self.input;
    }
};

test "legacy string backends copy views and reuse owned allocations" {
    var old = LegacyFields{ .input = "borrowed" };
    const copy = try serde.deserialize([]u8, A, &old, .{});
    defer A.free(copy);
    copy[0] = 'B';
    try testing.expectEqualStrings("borrowed", old.input);
    var d = Legacy(true){ .input = "hello" };
    const borrowed = try serde.deserialize([]u8, A, &d, .{});
    defer A.free(borrowed);
    borrowed[0] = 'H';
    try testing.expectEqualStrings("hello", d.input);
    d.owned = true;
    const owned = try serde.deserialize([]u8, A, &d, .{});
    defer A.free(owned);
    try testing.expectEqual(d.last_owned.?.ptr, owned.ptr);
    owned[0] = 'H';
    // Zero-length literals have no writable storage and need no pointer test.
    old.input = "";
    const empty = try serde.deserialize([]u8, A, &old, .{});
    defer A.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "CSV quoted mutable fields and XML mutable attributes roundtrip" {
    const rows = try serde.csv.fromSlice([]Foo, A, "string\n\"a,\"\"b\"\n");
    defer serde.core.freeAllocated([]Foo, rows, A);
    try testing.expectEqualStrings("a,\"b", rows[0].string);
    rows[0].string[0] = 'A';
    const Attr = struct {
        string: []u8,
        pub const serde = .{ .xml_attribute = .{.string} };
    };
    const attr = try serde.xml.fromSlice(Attr, A, "<root string=\"a&amp;b\"/>");
    defer serde.core.freeAllocated(Attr, attr, A);
    try testing.expectEqualStrings("a&b", attr.string);
    attr.string[0] = 'A';
    const saved = try serde.xml.toSlice(A, attr);
    defer A.free(saved);
    const reparsed = try serde.xml.fromSlice(Attr, A, saved);
    defer serde.core.freeAllocated(Attr, reparsed, A);
    try testing.expectEqualStrings("A&b", reparsed.string);
}

fn legacyPaths(allocator: Allocator) !void {
    var d = Legacy(true){ .input = "hello" };
    const borrowed = try serde.deserialize([]u8, allocator, &d, .{});
    defer allocator.free(borrowed);
    d.owned = true;
    const owned = try serde.deserialize([]u8, allocator, &d, .{});
    defer allocator.free(owned);
    try testing.expectEqual(d.last_owned.?.ptr, owned.ptr);
}

test "legacy fallback allocates only for borrowed views" {
    try testing.checkAllAllocationFailures(A, legacyPaths, .{});
    // There is space for exactly one string. A redundant copy would fail.
    var buffer: [5]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var d = Legacy(false){ .input = "hello", .owned = true };
    const value = try serde.deserialize([]u8, fba.allocator(), &d, .{});
    try testing.expectEqual(d.last_owned.?.ptr, value.ptr);
    try testing.expectEqual(@as(usize, 5), fba.end_index);
    value[0] = 'H';
}

test "owned string method allocates once and leaves borrowed mode intact" {
    inline for (.{ serde.json, serde.zon, serde.xml }) |format| {
        const input = if (format == serde.xml) "hello" else "\"hello\"";
        var d = format.Deserializer.initBorrowed(input);
        var buffer: [5]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const text = try d.deserializeStringOwned(fba.allocator());
        text[0] = 'H';
        try testing.expectEqualStrings("Hello", text);
        try testing.expect(d.borrow_strings);
        try testing.expectEqual(@as(usize, 5), fba.end_index);
    }
}

const MutableAdapter = struct {
    pub fn deserialize(comptime _: type, allocator: Allocator, _: anytype) error{OutOfMemory}![]u8 {
        return allocator.dupe(u8, "adapter");
    }
};
test "external mutable string adapter takes precedence" {
    var d = serde.json.Deserializer.init("false");
    const text = try serde.deserialize([]u8, A, &d, .{.{ []u8, MutableAdapter }});
    defer A.free(text);
    try testing.expectEqualStrings("adapter", text);
}
