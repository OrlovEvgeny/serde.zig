const std = @import("std");
const Allocator = std.mem.Allocator;

/// Base64 helper for `serde.with`. Encodes []const u8 as base64 string on the wire.
pub const Base64 = struct {
    pub const WireType = []const u8;

    const encoder = std.base64.standard.Encoder;
    const decoder = std.base64.standard.Decoder;

    /// Encode bytes to base64 string.
    pub fn serializeAlloc(value: []const u8, allocator: Allocator) ![]const u8 {
        const len = encoder.calcSize(value.len);
        const buf = try allocator.alloc(u8, len);
        return encoder.encode(buf, value);
    }

    /// Decode base64 string to bytes.
    pub fn deserializeAlloc(raw: []const u8, allocator: Allocator) ![]const u8 {
        const len = decoder.calcSizeForSlice(raw) catch return error.InvalidBase64;
        const buf = try allocator.alloc(u8, len);
        decoder.decode(buf, raw) catch {
            allocator.free(buf);
            return error.InvalidBase64;
        };
        return buf;
    }

    pub const Error = error{ OutOfMemory, InvalidBase64 };
};

const testing = std.testing;

test "Base64 roundtrip" {
    const original = "Hello, World!";
    const encoded = try Base64.serializeAlloc(original, testing.allocator);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("SGVsbG8sIFdvcmxkIQ==", encoded);

    const decoded = try Base64.deserializeAlloc(encoded, testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings(original, decoded);
}

test "Base64 empty" {
    const encoded = try Base64.serializeAlloc("", testing.allocator);
    defer testing.allocator.free(encoded);
    try testing.expectEqualStrings("", encoded);

    const decoded = try Base64.deserializeAlloc("", testing.allocator);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("", decoded);
}
