//! TOON serialization and deserialization.
//!
//! TOON encodes the JSON data model as indentation-based object fields,
//! explicit-length arrays, and compact tabular rows for uniform object arrays.

const std = @import("std");
const compat = @import("compat");
const json = @import("../json/mod.zig");
const serializer_mod = @import("serializer.zig");
const parser_mod = @import("parser.zig");
const deserializer_mod = @import("deserializer.zig");

pub const Value = serializer_mod.Value;
pub const Entry = serializer_mod.Entry;
pub const Options = serializer_mod.Options;
pub const DeserializeOptions = parser_mod.Options;
pub const Delimiter = serializer_mod.Delimiter;
pub const KeyFolding = serializer_mod.KeyFolding;
pub const PathExpansion = parser_mod.PathExpansion;

pub const parse = parser_mod.parse;
pub const validate = parser_mod.validate;

pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try toWriterWith(allocator, &aw.writer, value, opts);
    return aw.toOwnedSlice();
}

pub fn toWriter(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype) !void {
    return toWriterWith(allocator, writer, value, .{});
}

pub fn toWriterWith(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, opts: Options) !void {
    const tree = try valueFromJsonSerialized(allocator, try json.toSlice(allocator, value));
    defer tree.deinit(allocator);
    try serializer_mod.render(allocator, writer, tree, opts);
}

pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    return toSliceAllocWith(allocator, value, .{});
}

pub fn toSliceAllocWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![:0]u8 {
    const bytes = try toSliceWith(allocator, value, opts);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    return toSliceWithSchema(allocator, value, .{}, schema);
}

pub fn toSliceWithSchema(allocator: std.mem.Allocator, value: anytype, opts: Options, comptime schema: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try toWriterWithSchema(allocator, &aw.writer, value, opts, schema);
    return aw.toOwnedSlice();
}

pub fn toWriterSchema(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, comptime schema: anytype) !void {
    return toWriterWithSchema(allocator, writer, value, .{}, schema);
}

pub fn toWriterWithSchema(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, opts: Options, comptime schema: anytype) !void {
    const json_bytes = try json.toSliceWithSchema(allocator, value, .{}, schema);
    const tree = try valueFromJsonSerialized(allocator, json_bytes);
    defer tree.deinit(allocator);
    try serializer_mod.render(allocator, writer, tree, opts);
}

pub fn toSliceWithMap(allocator: std.mem.Allocator, value: anytype, comptime map: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try toWriterWithMap(allocator, &aw.writer, value, map);
    return aw.toOwnedSlice();
}

pub fn toWriterWithMap(allocator: std.mem.Allocator, writer: *compat.Io.Writer, value: anytype, comptime map: anytype) !void {
    const json_bytes = try json.toSliceWithMap(allocator, value, map);
    const tree = try valueFromJsonSerialized(allocator, json_bytes);
    defer tree.deinit(allocator);
    try serializer_mod.render(allocator, writer, tree, .{});
}

pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return fromSliceWith(T, allocator, input, .{});
}

pub fn fromSliceWith(comptime T: type, allocator: std.mem.Allocator, input: []const u8, opts: DeserializeOptions) !T {
    const tree = try parser_mod.parse(allocator, input, opts);
    defer tree.deinit(allocator);
    const json_bytes = try deserializer_mod.toJsonSlice(allocator, tree);
    defer allocator.free(json_bytes);
    return json.fromSlice(T, allocator, json_bytes);
}

pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    const tree = try parser_mod.parse(allocator, input, .{});
    defer tree.deinit(allocator);
    const json_bytes = try deserializer_mod.toJsonSlice(allocator, tree);
    defer allocator.free(json_bytes);
    return json.fromSliceSchema(T, allocator, json_bytes, schema);
}

pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

pub fn fromReaderWith(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, opts: DeserializeOptions) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceWith(T, allocator, buf, opts);
}

pub fn fromReaderSchema(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, comptime schema: anytype) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceSchema(T, allocator, buf, schema);
}

pub fn fromSliceWithMap(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime map: anytype) !T {
    const tree = try parser_mod.parse(allocator, input, .{});
    defer tree.deinit(allocator);
    const json_bytes = try deserializer_mod.toJsonSlice(allocator, tree);
    defer allocator.free(json_bytes);
    return json.fromSliceWithMap(T, allocator, json_bytes, map);
}

pub fn fromReaderWithMap(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, comptime map: anytype) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceWithMap(T, allocator, buf, map);
}

fn valueFromJsonSerialized(allocator: std.mem.Allocator, json_bytes: []u8) !Value {
    defer allocator.free(json_bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), json_bytes, .{});
    return serializer_mod.fromJsonValue(allocator, parsed);
}

fn readAll(allocator: std.mem.Allocator, reader: *compat.Io.Reader) ![]u8 {
    return reader.allocRemaining(allocator, compat.Io.Limit.limited(10 * 1024 * 1024)) catch return error.ReadFailed;
}

/// Parse into a result that owns a separate arena. Release it with `.deinit()`.
pub fn fromSliceManaged(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !@import("../../core/parsed.zig").Parsed(T) {
    return fromSliceManagedSchema(T, allocator, input, {});
}

/// Parse with an external schema into an owning result.
pub fn fromSliceManagedSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !@import("../../core/parsed.zig").Parsed(T) {
    return @import("../../core/parsed.zig").parse(T, allocator, input, schema, @This());
}

test "roundtrip struct" {
    const testing = std.testing;
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSlice(testing.allocator, Point{ .x = 1, .y = 2 });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("x: 1\ny: 2", bytes);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const point = try fromSlice(Point, arena.allocator(), bytes);
    try testing.expectEqual(@as(i32, 1), point.x);
    try testing.expectEqual(@as(i32, 2), point.y);
}

test "tabular array" {
    const testing = std.testing;
    const Item = struct { id: u32, name: []const u8 };
    const items: []const Item = &.{ .{ .id = 1, .name = "Ada" }, .{ .id = 2, .name = "Bob" } };
    const bytes = try toSlice(testing.allocator, items);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("[2]{id,name}:\n  1,Ada\n  2,Bob", bytes);
}
