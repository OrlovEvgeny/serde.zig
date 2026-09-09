//! Erlang External Term Format (ETF) and OTP 29 distribution primitives.
//!
//! Typed serialization follows a canonical profile while `Term` preserves the
//! complete Erlang data model. Networking, EPMD, handshakes, cookies and TLS
//! intentionally remain outside this module.

const std = @import("std");
const compat = @import("compat");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");
const codec = @import("codec.zig");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");

pub const Term = @import("term.zig").Term;
pub const BigInteger = @import("term.zig").BigInteger;
pub const Pid = @import("term.zig").Pid;
pub const Port = @import("term.zig").Port;
pub const Reference = @import("term.zig").Reference;
pub const BitBinary = @import("term.zig").BitBinary;
pub const List = @import("term.zig").List;
pub const MapEntry = @import("term.zig").MapEntry;
pub const NewFun = @import("term.zig").NewFun;
pub const LegacyFun = @import("term.zig").LegacyFun;
pub const Export = @import("term.zig").Export;
pub const Record = @import("term.zig").Record;
pub const Tag = codec.Tag;
pub const Compression = codec.Compression;
pub const EncodeOptions = codec.EncodeOptions;
pub const DecodeOptions = codec.DecodeOptions;
pub const EncodeError = codec.EncodeError;
pub const DecodeError = codec.DecodeError;
pub const SerializeError = serializer_mod.SerializeError;
pub const DeserializeError = deserializer_mod.DeserializeError;
pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;

pub const encodeTerm = codec.encodeTerm;
pub const encodeTermToWriter = codec.encodeTermToWriter;
pub const decodeTerm = codec.decodeTerm;

pub const distribution = @import("distribution.zig");

pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions) ![]u8 {
    return serializeTyped(allocator, value, options, {}, {});
}

pub fn toWriter(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype) !void {
    return toWriterWith(allocator, writer, value, .{});
}

pub fn toWriterWith(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, options: EncodeOptions) !void {
    const bytes = try toSliceWith(allocator, value, options);
    defer allocator.free(bytes);
    writer.writeAll(bytes) catch return error.WriteFailed;
}

pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    return toSliceWithSchema(allocator, value, .{}, schema);
}

pub fn toSliceWithSchema(allocator: std.mem.Allocator, value: anytype, options: EncodeOptions, comptime schema: anytype) ![]u8 {
    return serializeTyped(allocator, value, options, schema, {});
}

pub fn toWriterSchema(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, comptime schema: anytype) !void {
    return toWriterWithSchema(allocator, writer, value, .{}, schema);
}

pub fn toWriterWithSchema(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, options: EncodeOptions, comptime schema: anytype) !void {
    const bytes = try toSliceWithSchema(allocator, value, options, schema);
    defer allocator.free(bytes);
    writer.writeAll(bytes) catch return error.WriteFailed;
}

pub fn toSliceWithMap(allocator: std.mem.Allocator, value: anytype, comptime map: anytype) ![]u8 {
    return serializeTyped(allocator, value, .{}, {}, map);
}

pub fn toWriterWithMap(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, comptime map: anytype) !void {
    const bytes = try toSliceWithMap(allocator, value, map);
    defer allocator.free(bytes);
    writer.writeAll(bytes) catch return error.WriteFailed;
}

pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return fromSliceWith(T, allocator, input, .{});
}

pub fn fromSliceWith(comptime T: type, allocator: std.mem.Allocator, input: []const u8, options: DecodeOptions) !T {
    return deserializeTyped(T, allocator, input, options, {}, {});
}

pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    return fromSliceWithSchema(T, allocator, input, .{}, schema);
}

pub fn fromSliceWithSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, options: DecodeOptions, comptime schema: anytype) !T {
    return deserializeTyped(T, allocator, input, options, schema, {});
}

pub fn fromSliceWithMap(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime map: anytype) !T {
    return deserializeTyped(T, allocator, input, .{}, {}, map);
}

pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader) !T {
    return fromReaderWith(T, allocator, reader, .{});
}

pub fn fromReaderWith(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, options: DecodeOptions) !T {
    const input = reader.allocRemaining(allocator, compat.Io.Limit.limited(options.max_input_size)) catch return error.ReadFailed;
    defer allocator.free(input);
    return fromSliceWith(T, allocator, input, options);
}

pub fn fromReaderSchema(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, comptime schema: anytype) !T {
    return fromReaderWithSchema(T, allocator, reader, .{}, schema);
}

pub fn fromReaderWithSchema(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, options: DecodeOptions, comptime schema: anytype) !T {
    const input = reader.allocRemaining(allocator, compat.Io.Limit.limited(options.max_input_size)) catch return error.ReadFailed;
    defer allocator.free(input);
    return fromSliceWithSchema(T, allocator, input, options, schema);
}

pub fn fromReaderWithMap(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, comptime map: anytype) !T {
    const input = reader.allocRemaining(allocator, compat.Io.Limit.limited(10 * 1024 * 1024)) catch return error.ReadFailed;
    defer allocator.free(input);
    return fromSliceWithMap(T, allocator, input, map);
}

fn serializeTyped(
    allocator: std.mem.Allocator,
    value: anytype,
    options: EncodeOptions,
    comptime schema: anytype,
    comptime map: anytype,
) ![]u8 {
    var body_writer: compat.Io.Writer.Allocating = .init(allocator);
    errdefer body_writer.deinit();
    var serializer = Serializer.init(&body_writer.writer, allocator, options);
    try core_serialize.serializeSchema(@TypeOf(value), value, &serializer, schema, map);
    const body = try body_writer.toOwnedSlice();
    defer allocator.free(body);
    if (body.len > options.max_size) return error.SizeLimit;

    const compress = switch (options.compression) {
        .never => false,
        .always => true,
        .threshold => |threshold| body.len >= threshold,
    };
    var output: compat.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    output.writer.writeByte(codec.version) catch return error.WriteFailed;
    if (!compress) {
        output.writer.writeAll(body) catch return error.WriteFailed;
    } else {
        if (body.len > std.math.maxInt(u32)) return error.LengthOverflow;
        const compressed = compat.zlibCompress(allocator, body, options.zlib_level) catch return error.CompressionFailed;
        defer allocator.free(compressed);
        output.writer.writeByte(@intFromEnum(Tag.compressed_ext)) catch return error.WriteFailed;
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(body.len), .big);
        output.writer.writeAll(&size) catch return error.WriteFailed;
        output.writer.writeAll(compressed) catch return error.WriteFailed;
    }
    if (output.writer.end > options.max_size) return error.SizeLimit;
    return output.toOwnedSlice();
}

fn deserializeTyped(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    options: DecodeOptions,
    comptime schema: anytype,
    comptime map: anytype,
) !T {
    var prepared = try PreparedInput.init(allocator, input, options);
    defer prepared.deinit(allocator);
    var deserializer = Deserializer.init(prepared.body, options);
    const result = try core_deserialize.deserializeSchema(T, allocator, &deserializer, schema, map);
    if (deserializer.pos != deserializer.input.len) {
        core_deserialize.freeAllocatedSchema(T, result, allocator, schema);
        return error.TrailingData;
    }
    return result;
}

const PreparedInput = struct {
    body: []const u8,
    owned: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, input: []const u8, options: DecodeOptions) !PreparedInput {
        if (input.len > options.max_input_size) return error.SizeLimit;
        if (input.len == 0 or input[0] != codec.version) return error.InvalidVersion;
        if (input.len < 2) return error.UnexpectedEof;
        if (input[1] != @intFromEnum(Tag.compressed_ext)) return .{ .body = input[1..] };
        if (input.len < 6) return error.UnexpectedEof;
        const expected = std.mem.readInt(u32, input[2..6], .big);
        if (expected > options.max_uncompressed_size) return error.SizeLimit;
        const plain = compat.zlibDecompress(allocator, input[6..], expected) catch return error.DecompressionFailed;
        return .{ .body = plain, .owned = plain };
    }

    fn deinit(self: *PreparedInput, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

/// Parse into a result that owns a separate arena. Release it with `.deinit()`.
pub fn fromSliceManaged(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !@import("../../core/parsed.zig").Parsed(T) {
    return fromSliceManagedSchema(T, allocator, input, {});
}

/// Parse with an external schema into an owning result.
pub fn fromSliceManagedSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !@import("../../core/parsed.zig").Parsed(T) {
    return @import("../../core/parsed.zig").parse(T, allocator, input, schema, @This());
}

test "typed canonical profile roundtrip" {
    const testing = std.testing;
    const Value = struct {
        ok: bool,
        name: []const u8,
        count: i64,
        optional: ?u8,
        values: []const u16,
    };
    const original = Value{ .ok = true, .name = "beam", .count = -42, .optional = null, .values = &.{ 1, 256 } };
    const encoded = try toSlice(testing.allocator, original);
    defer testing.allocator.free(encoded);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const decoded = try fromSlice(Value, arena.allocator(), encoded);
    try testing.expect(decoded.ok);
    try testing.expectEqualStrings(original.name, decoded.name);
    try testing.expectEqual(original.count, decoded.count);
    try testing.expectEqual(original.optional, decoded.optional);
    try testing.expectEqualSlices(u16, original.values, decoded.values);
}

test "lenient string and null coercions; strict rejects them" {
    const testing = std.testing;
    const string_ext = [_]u8{ codec.version, @intFromEnum(Tag.string_ext), 0, 2, 'o', 'k' };
    const value = try fromSlice([]const u8, testing.allocator, &string_ext);
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("ok", value);
    try testing.expectError(error.WrongType, fromSliceWith([]const u8, testing.allocator, &string_ext, .{ .strict = true }));

    const nil = [_]u8{ codec.version, @intFromEnum(Tag.nil_ext) };
    try testing.expectEqual(@as(?u8, null), try fromSlice(?u8, testing.allocator, &nil));
    try testing.expectError(error.WrongType, fromSliceWith(?u8, testing.allocator, &nil, .{ .strict = true }));
}
