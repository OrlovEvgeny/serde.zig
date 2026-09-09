const std = @import("std");
const serde = @import("serde");
const testing = std.testing;
const A = testing.allocator;

fn expectFailure(comptime T: type, input: []const u8, err: anyerror, path: []const u8, offset: usize) !void {
    var buffer: [256]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    try testing.expectError(err, serde.json.fromSliceManagedWithDiagnostics(T, A, input, .{}, &diagnostics));
    try testing.expectEqual(err, diagnostics.original_error.?);
    try testing.expectEqualStrings(path, diagnostics.path);
    try testing.expectEqual(offset, diagnostics.byte_offset);
    try testing.expectError(err, serde.json.fromSliceManaged(T, A, input));
}

test "diagnostics nested path and byte location" {
    const T = struct { users: []struct { age: u8 } };
    const input = "{\"users\":[{\"age\":1},{\"age\":\"bad\"}]}";
    try expectFailure(T, input, error.WrongType, "/users/1/age", 27);
    var buffer: [80]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    try testing.expectError(error.WrongType, serde.json.fromSliceManagedWithDiagnostics(T, A, input, .{}, &diagnostics));
    try testing.expectEqualStrings("u8", diagnostics.expected.?);
    try testing.expectEqual(.string, diagnostics.actual.?);
}

test "diagnostics missing unknown duplicate and escaped keys" {
    const T = struct {
        @"a/b~c": u8,
        pub const serde = .{ .deny_unknown_fields = true };
    };
    try expectFailure(T, "{}", error.MissingField, "/a~1b~0c", 1);
    try expectFailure(T, "{\"x\":0}", error.UnknownField, "/x", 1);
    try expectFailure(T, "{\"a/b~c\":0,\"a/b~c\":1}", error.DuplicateField, "/a~1b~0c", 11);
    try expectFailure(T, "{\"a\\u002fb~c\":false}", error.WrongType, "/a~1b~0c", 14);
}

test "diagnostics syntax EOF trailing data and empty buffer" {
    try expectFailure([]u16, "[1,]", error.UnexpectedToken, "", 3);
    try expectFailure([]u16, "[1", error.UnexpectedEof, "", 2);
    try expectFailure(u8, "1 false", error.TrailingData, "", 2);
    try expectFailure([]const u8, "\"bad\\q\"", error.InvalidEscape, "", 5);
    for (0..8) |len| {
        var buffer: [8]u8 = undefined;
        var diagnostics = serde.json.Diagnostics.init(buffer[0..len]);
        try testing.expectError(error.WrongType, serde.json.fromSliceManagedWithDiagnostics(struct { long: u8 }, A, "{\"long\":false}", .{}, &diagnostics));
        try testing.expectEqual(len < 5, diagnostics.path_truncated);
        try testing.expectEqualStrings("/long"[0..@min(len, 5)], diagnostics.path);
    }
}

test "diagnostics union rollback and external payload" {
    const U = union(enum) {
        a: u8,
        b: []const u8,
        pub const serde = .{ .tag = .untagged };
    };
    var buffer: [100]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    var parsed = try serde.json.fromSliceManagedWithDiagnostics(U, A, "\"hello\"", .{}, &diagnostics);
    defer parsed.deinit();
    try testing.expectEqualStrings("hello", parsed.value.b);
    try testing.expectEqual(null, diagnostics.original_error);
    try expectFailure(struct { u: U }, "{\"u\":false}", error.UnexpectedToken, "/u", 5);
    const External = union(enum) { a: struct { n: u8 }, b: void };
    try expectFailure(External, "{\"a\":{\"n\":false}}", error.WrongType, "/a/n", 10);
}

test "diagnostics Unicode CRLF and owned path" {
    const input = try A.dupe(u8, "{\r\n\"é\":false}");
    var buffer: [100]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    try testing.expectError(error.WrongType, serde.json.fromSliceManagedWithDiagnostics(struct { @"é": u8 }, A, input, .{}, &diagnostics));
    @memset(input, 0);
    A.free(input);
    try testing.expectEqualStrings("/é", diagnostics.path);
    try testing.expectEqual(@as(usize, 2), diagnostics.line);
    try testing.expectEqual(@as(usize, 6), diagnostics.column);
}

const Leaf = struct {
    n: u8,
    pub const serde = .{ .rename = .{ .n = "number" }, .alias = .{ .n = &.{"old"} } };
};
const Flat = struct {
    inner: Leaf,
    pub const serde = .{ .flatten = &.{"inner"} };
};
const Internal = union(enum) {
    item: Flat,
    pub const serde = .{ .tag = .internal, .tag_field = "kind" };
};
const Adjacent = union(enum) {
    item: Leaf,
    pub const serde = .{ .tag = .adjacent, .tag_field = "kind", .content_field = "data" };
};

test "diagnostics aliases flatten and replayed tag layouts" {
    try expectFailure(Flat, "{\"old\":false}", error.WrongType, "/old", 7);
    try expectFailure(Flat, "{}", error.MissingField, "/number", 1);
    try expectFailure(Internal, "{\"kind\":\"item\"}", error.MissingField, "/number", 14);
    try expectFailure(Adjacent, "{\"kind\":\"item\",\"data\":{}}", error.MissingField, "/data/number", 23);
    try expectFailure(Internal, "{\"number\":false,\"kind\":\"item\"}", error.WrongType, "/number", 10);
    try expectFailure([]const u8, "\"\\uD800\"", error.InvalidUnicode, "", 7);
    try expectFailure(bool, "trXe", error.UnexpectedToken, "", 2);
}

const Custom = struct {
    n: u8,
    pub fn zerdeDeserialize(comptime _: type, a: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!@This() {
        const text = try d.deserializeString(a);
        defer serde.core.releaseString(d, a, text);
        return .{ .n = std.fmt.parseInt(u8, text, 10) catch return error.WithFailed };
    }
};
const Adapter = struct {
    pub fn deserialize(comptime _: type, a: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!Leaf {
        _ = a;
        return .{ .n = try d.deserializeInt(u8) };
    }
};
test "diagnostics custom hooks external adapters and schemas" {
    try expectFailure(struct { item: Custom }, "{\"item\":\"x\"}", error.WithFailed, "/item", 8);
    var buffer: [64]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    var d = serde.json.DeserializerWithDiagnostics.init("{\"wire\":false}", .{}, &diagnostics);
    try testing.expectError(error.WrongType, serde.deserializeSchema(struct { n: Leaf }, A, &d, .{ .rename = .{ .n = "wire" } }, .{.{ Leaf, Adapter }}));
    try testing.expectEqualStrings("/wire", diagnostics.path);
}

fn allocationCases(allocator: std.mem.Allocator) !void {
    const T = struct { names: []const []const u8, item: Custom };
    var buffer: [64]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    var result = try serde.json.fromSliceManagedWithDiagnostics(T, allocator, "{\"names\":[\"one\",\"two\"],\"item\":\"3\"}", .{}, &diagnostics);
    defer result.deinit();
    var d = serde.json.DeserializerWithDiagnostics.init("{\"names\":[\"one\",\"two\"],\"item\":\"x\"}", .{}, &diagnostics);
    if (serde.deserialize(T, allocator, &d, .{})) |_| return error.TestUnexpectedResult else |err| {
        if (err == error.OutOfMemory) return err;
        try testing.expectEqual(error.WithFailed, err);
    }
}
test "diagnostics partial cleanup and allocation failures" {
    try testing.checkAllAllocationFailures(A, allocationCases, .{});
    var empty: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&empty);
    var buffer: [64]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    var d = serde.json.DeserializerWithDiagnostics.init("{\"value\":false}", .{}, &diagnostics);
    try testing.expectError(error.WrongType, serde.deserialize(struct { value: u8 }, fba.allocator(), &d, .{}));
    try testing.expectEqualStrings("/value", diagnostics.path);
    try testing.expectEqual(@as(usize, 0), fba.end_index);
}

fn parity(comptime T: type, input: []const u8) !void {
    var buffer: [16]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    if (serde.json.fromSliceManaged(T, A, input)) |v| {
        var ordinary = v;
        defer ordinary.deinit();
        var diagnostic = try serde.json.fromSliceManagedWithDiagnostics(T, A, input, .{}, &diagnostics);
        defer diagnostic.deinit();
        try testing.expectEqualDeep(ordinary.value, diagnostic.value);
        try testing.expectEqual(null, diagnostics.original_error);
    } else |err| {
        try testing.expectError(err, serde.json.fromSliceManagedWithDiagnostics(T, A, input, .{}, &diagnostics));
        try testing.expectEqual(err, diagnostics.original_error.?);
    }
}
test "ordinary and diagnostic parsing agree on corpus and every prefix" {
    const U = union(enum) { item: struct { n: u8 }, none: void };
    const inputs = [_][]const u8{ "", "null", "true", "false", "1", "1e+", "\"str\"", "\"\\uD800\"", "[]", "[1,2]", "[1,]", "{}", "{\"n\":2}", "{\"item\":{\"n\":1}}", "{\"item\":{\"n\":1},2}", "{\"none\":null}", "{\"none\":false}", "{\"kind\":\"item\",\"data\":{\"number\":3}}", "{\"number\":1,\"kind\":\"item\"}" };
    inline for (.{ bool, i16, f64, []const u8, ?u16, [2]u16, []const u16, U, Internal, Adjacent, Flat }) |T| {
        for (inputs) |input| for (0..input.len + 1) |end| try parity(T, input[0..end]);
    }
}

test "diagnostics missing union discriminator and content" {
    try expectFailure(Internal, "{}", error.MissingField, "/kind", 1);
    try expectFailure(Adjacent, "{\"kind\":\"item\"}", error.MissingField, "/data", 14);
    try expectFailure(Internal, "{\"kind\":\"item\",\"kind\":\"item\"}", error.DuplicateField, "/kind", 15);
}

test "diagnostics preserve custom error normalization and parse options" {
    const Failing = struct {
        pub fn zerdeDeserialize(comptime _: type, _: std.mem.Allocator, d: anytype) @TypeOf(d.*).Error!@This() {
            return d.raiseError(error.CustomFailure);
        }
    };
    try expectFailure(Failing, "null", error.WrongType, "", 0);
    var buffer: [16]u8 = undefined;
    var diagnostics = serde.json.Diagnostics.init(&buffer);
    var parsed = try serde.json.fromSliceManagedWithDiagnostics(u8, A, "null", .{ .lenient_null_to_zero = true }, &diagnostics);
    defer parsed.deinit();
    try testing.expectEqual(@as(u8, 0), parsed.value);
    try testing.expectError(error.MaxDepthExceeded, serde.json.fromSliceManagedWithDiagnostics([]const []const u16, A, "[[1]]", .{ .max_depth = 1 }, &diagnostics));
    try testing.expectEqualStrings("/0", diagnostics.path);
    // Failed alternatives may overwrite the suffix but must retain the union prefix.
    const U = union(enum) {
        first: struct { very_long_field_name: bool },
        second: struct { v: u8 },
        pub const serde = .{ .tag = .untagged };
    };
    for (0..buffer.len) |size| {
        diagnostics = serde.json.Diagnostics.init(buffer[0..size]);
        var result = try serde.json.fromSliceManagedWithDiagnostics(struct { u: U }, A, "{\"u\":{\"v\":1}}", .{}, &diagnostics);
        defer result.deinit();
        try testing.expectEqual(@as(u8, 1), result.value.u.second.v);
        try testing.expectEqual(null, diagnostics.original_error);
        try testing.expect(!diagnostics.path_truncated);
    }
}
