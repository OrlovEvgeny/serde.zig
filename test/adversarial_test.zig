const std = @import("std");
const testing = std.testing;
const serde = @import("serde");

const SimpleStruct = struct { a: i32, b: []const u8 };

test "adversarial: JSON empty input" {
    const r = serde.json.fromSlice(i32, testing.allocator, "");
    try testing.expectError(error.UnexpectedEof, r);
}

test "adversarial: JSON whitespace only" {
    const r = serde.json.fromSlice(i32, testing.allocator, "   \n\t ");
    try testing.expectError(error.UnexpectedEof, r);
}

test "adversarial: JSON truncated string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"hello");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON truncated object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice(SimpleStruct, arena.allocator(), "{\"a\":1");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON truncated array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const i32, arena.allocator(), "[1,2");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON unquoted key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice(SimpleStruct, arena.allocator(), "{a:1}");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON single quoted string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "'hello'");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON trailing comma object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { a: i32 };
    const r = serde.json.fromSlice(S, arena.allocator(), "{\"a\":1,}");
    // Trailing commas may or may not be accepted; just don't crash.
    _ = r catch {};
}

test "adversarial: JSON deeply nested arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [200]u8 = undefined;
    for (buf[0..100]) |*b| b.* = '[';
    for (buf[100..200]) |*b| b.* = ']';
    const r = serde.json.fromSlice([]const u8, arena.allocator(), &buf);
    // May error, but must not crash.
    _ = r catch {};
}

test "adversarial: JSON very long number" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const long_num = "9" ** 500;
    const r = serde.json.fromSlice(i64, arena.allocator(), long_num);
    // Overflow expected.
    _ = r catch {};
}

test "adversarial: JSON number with multiple dots" {
    const r = serde.json.fromSlice(f64, testing.allocator, "1.2.3");
    try testing.expectError(error.TrailingData, r);
}

test "adversarial: JSON double sign" {
    const r = serde.json.fromSlice(i32, testing.allocator, "--1");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON backslash at end of string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"hello\\");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON invalid escape \\x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"\\x41\"");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON incomplete unicode escape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"\\u00\"");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON invalid unicode hex" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"\\uGGGG\"");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON wrong type bool for int field" {
    const S = struct { val: i32 };
    const r = serde.json.fromSlice(S, testing.allocator, "{\"val\":true}");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON string for int field" {
    const S = struct { val: i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice(S, arena.allocator(), "{\"val\":\"hello\"}");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON array for struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice(SimpleStruct, arena.allocator(), "[1,2]");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON object for array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const i32, arena.allocator(), "{\"a\":1}");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON just null" {
    const r = serde.json.fromSlice(i32, testing.allocator, "null");
    // null for non-optional should error.
    _ = r catch {};
}

test "adversarial: JSON just true for struct" {
    const r = serde.json.fromSlice(SimpleStruct, testing.allocator, "true");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON number for bool field" {
    const S = struct { flag: bool };
    const r = serde.json.fromSlice(S, testing.allocator, "{\"flag\":1}");
    try testing.expect(std.meta.isError(r));
}

// MsgPack adversarial inputs.

test "adversarial: msgpack empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.msgpack.fromSlice(i32, arena.allocator(), "");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: msgpack truncated input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Start of a fixstr but not enough bytes.
    const r = serde.msgpack.fromSlice([]const u8, arena.allocator(), &[_]u8{ 0xa5, 0x68, 0x65 });
    try testing.expect(std.meta.isError(r));
}

test "adversarial: msgpack invalid type tag 0xC1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.msgpack.fromSlice(i32, arena.allocator(), &[_]u8{0xc1});
    try testing.expect(std.meta.isError(r));
}

test "adversarial: msgpack length overflow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // str32 with length claiming 1000 bytes but only 5 present.
    const input = [_]u8{ 0xdb, 0x00, 0x00, 0x03, 0xe8, 0x41 };
    const r = serde.msgpack.fromSlice([]const u8, arena.allocator(), &input);
    try testing.expect(std.meta.isError(r));
}

test "adversarial: msgpack single byte inputs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Try every single byte as input for struct deserialization.
    var crash_count: usize = 0;
    for (0..256) |i| {
        const byte = [_]u8{@intCast(i)};
        _ = serde.msgpack.fromSlice(SimpleStruct, arena.allocator(), &byte) catch {
            crash_count += 1;
            continue;
        };
    }
    // Most should error.
    try testing.expect(crash_count > 200);
}

// TOML adversarial inputs.

test "adversarial: TOML empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { x: i32 = 0 };
    // Empty TOML is valid — just no keys.
    const r = try serde.toml.fromSlice(S, arena.allocator(), "");
    try testing.expectEqual(@as(i32, 0), r.x);
}

test "adversarial: TOML unterminated string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { x: []const u8 };
    const r = serde.toml.fromSlice(S, arena.allocator(), "x = \"hello\n");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: TOML invalid bare key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { x: i32 = 0 };
    const r = serde.toml.fromSlice(S, arena.allocator(), "  = 42\n");
    // Depends on parser strictness.
    _ = r catch {};
}

// YAML adversarial inputs.

test "adversarial: YAML empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { x: i32 = 0 };
    const r = serde.yaml.fromSlice(S, arena.allocator(), "");
    // Empty YAML might error or produce defaults.
    _ = r catch {};
}

test "adversarial: YAML malformed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const S = struct { x: i32 };
    const r = serde.yaml.fromSlice(S, arena.allocator(), "{{{{invalid");
    try testing.expect(std.meta.isError(r));
}

// CSV adversarial inputs.

test "adversarial: CSV no data rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Row = struct { x: i32 };
    const r = try serde.csv.fromSlice([]const Row, arena.allocator(), "x\n");
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "adversarial: CSV empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Row = struct { x: i32 };
    const r = try serde.csv.fromSlice([]const Row, arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), r.len);
}

test "adversarial: CSV type mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Row = struct { x: i32 };
    const r = serde.csv.fromSlice([]const Row, arena.allocator(), "x\nnot_a_number\n");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: CSV unterminated quote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Row = struct { name: []const u8 };
    const r = serde.csv.fromSlice([]const Row, arena.allocator(), "name\n\"unterminated\n");
    // Should error or handle gracefully.
    _ = r catch {};
}

// Memory leak detection on error paths.
// Using testing.allocator which panics on leak.

test "adversarial: JSON parse error no leak" {
    const S = struct { a: []const u8, b: i32 };
    const r = serde.json.fromSlice(S, testing.allocator, "{\"a\":\"hello\",\"b\":\"not_int\"}");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON missing field no leak" {
    const S = struct { a: i32, b: i32 };
    const r = serde.json.fromSlice(S, testing.allocator, "{\"a\":1}");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: msgpack parse error no leak" {
    // Map header says 2 entries, but only 1 key-value pair provided.
    const input = [_]u8{
        0x82, // fixmap with 2 entries
        0xa1, 0x61, // "a"
        0x01, // 1
        // Second entry missing.
    };
    const S = struct { a: i32, b: i32 };
    const r = serde.msgpack.fromSlice(S, testing.allocator, &input);
    try testing.expect(std.meta.isError(r));
}

// ZON adversarial inputs.

test "adversarial: ZON empty input" {
    const r = serde.zon.fromSlice(i32, testing.allocator, "");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: ZON malformed" {
    const r = serde.zon.fromSlice(i32, testing.allocator, ".{.x = ");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: ZON wrong type" {
    const r = serde.zon.fromSlice(bool, testing.allocator, "42");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: ZON missing field no leak" {
    const S = struct { a: i32, b: i32 };
    const r = serde.zon.fromSlice(S, testing.allocator, ".{.a = 1}");
    try testing.expect(std.meta.isError(r));
}

// JSON string edge cases that must not crash.

test "adversarial: JSON null byte in string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"hello\\u0000world\"");
    // May succeed or error depending on implementation.
    _ = r catch {};
}

test "adversarial: JSON lone high surrogate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"\\uD800\"");
    // Lone surrogate should ideally error.
    _ = r catch {};
}

test "adversarial: JSON lone low surrogate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"\\uDC00\"");
    _ = r catch {};
}

test "adversarial: JSON surrogate pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Valid surrogate pair for U+10000.
    const r = serde.json.fromSlice([]const u8, arena.allocator(), "\"\\uD800\\uDC00\"");
    _ = r catch {};
}

test "adversarial: JSON leading zeros in number" {
    const r = serde.json.fromSlice(i32, testing.allocator, "01");
    // RFC 8259: leading zeros are not allowed. Should error or parse as 1.
    _ = r catch {};
}

test "adversarial: JSON number with plus sign" {
    const r = serde.json.fromSlice(i32, testing.allocator, "+1");
    // JSON doesn't allow leading +.
    _ = r catch {};
}

test "adversarial: JSON bare keywords wrong" {
    const r = serde.json.fromSlice(bool, testing.allocator, "True");
    try testing.expect(std.meta.isError(r));
}

test "adversarial: JSON multiple values" {
    const r = serde.json.fromSlice(i32, testing.allocator, "1 2");
    try testing.expectError(error.TrailingData, r);
}
