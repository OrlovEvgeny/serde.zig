const std = @import("std");
const serde = @import("serde");

/// Wraps a u64 that is transmitted as a JSON/TOML string on the wire.
/// Common for APIs where IDs exceed JavaScript's safe integer range (>2^53).
const StringId = struct {
    value: u64,

    pub fn zerdeSerialize(self: @This(), serializer: anytype) @TypeOf(serializer.*).Error!void {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable;
        try serializer.serializeString(s);
    }

    pub fn zerdeDeserialize(
        comptime _: type,
        allocator: std.mem.Allocator,
        deserializer: anytype,
    ) @TypeOf(deserializer.*).Error!@This() {
        const str = try deserializer.deserializeString(allocator);
        defer serde.core.releaseString(deserializer, allocator, str);
        return .{
            .value = std.fmt.parseInt(u64, str, 10) catch return deserializer.raiseError(error.InvalidNumber),
        };
    }
};

/// A SHA-256 checksum has exactly 32 bytes and 64 hexadecimal characters.
const Sha256Digest = struct {
    bytes: [32]u8,

    pub fn zerdeSerialize(self: @This(), serializer: anytype) @TypeOf(serializer.*).Error!void {
        var hex: [64]u8 = undefined;
        const digits = "0123456789abcdef";
        for (self.bytes, 0..) |byte, i| {
            hex[2 * i] = digits[byte >> 4];
            hex[2 * i + 1] = digits[byte & 15];
        }
        try serializer.serializeString(&hex);
    }

    pub fn zerdeDeserialize(
        comptime _: type,
        allocator: std.mem.Allocator,
        deserializer: anytype,
    ) @TypeOf(deserializer.*).Error!@This() {
        const hex = try deserializer.deserializeString(allocator);
        defer serde.core.releaseString(deserializer, allocator, hex);
        if (hex.len != 64) return deserializer.raiseError(error.InvalidNumber);
        var result: @This() = undefined;
        for (&result.bytes, 0..) |*byte, i| {
            byte.* = std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16) catch
                return deserializer.raiseError(error.InvalidNumber);
        }
        return result;
    }
};

const Artifact = struct {
    id: StringId,
    filename: []const u8,
    size_bytes: u64,
    sha256: Sha256Digest,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const content = "invoice_id,total_cents\nord-1042,2995\n";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    const artifact = Artifact{
        .id = .{ .value = 9223372036854775807 },
        .filename = "invoice.csv",
        .size_bytes = content.len,
        .sha256 = .{ .bytes = digest },
    };
    const json = try serde.json.toSliceWith(allocator, artifact, .{ .pretty = true });
    defer allocator.free(json);

    var parsed = try serde.json.fromSliceManaged(Artifact, allocator, json);
    defer parsed.deinit();
    if (parsed.value.size_bytes != content.len or
        !std.mem.eql(u8, &parsed.value.sha256.bytes, &digest)) return error.ChecksumMismatch;
    if (parsed.value.id.value != artifact.id.value) return error.ArtifactIdMismatch;
    std.debug.print("Verified {s}: {d} bytes, id {d}\n", .{
        parsed.value.filename, parsed.value.size_bytes, parsed.value.id.value,
    });
    try serde.compat.writeStdout(json);
    try serde.compat.writeStdout("\n");
}
