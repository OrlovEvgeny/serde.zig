const std = @import("std");
const builtin = @import("builtin");

comptime {
    const v = builtin.zig_version;
    if (!(v.major == 0 and v.minor >= 16)) {
        @compileError("src/compat_0_16.zig requires Zig 0.16+");
    }
}

pub const Io = std.Io;
pub const File = Io.File;
pub const Reader = Io.Reader;
pub const Writer = Io.Writer;
pub const Limit = Io.Limit;
pub const AllocatingWriter = Writer.Allocating;
pub const ArrayList = std.ArrayList;
pub const ArrayListUnmanaged = std.ArrayListUnmanaged;
pub const StringHashMap = std.StringHashMap;

pub fn StringArrayHashMap(comptime V: type) type {
    return std.array_hash_map.String(V);
}

pub fn intToEnum(comptime T: type, value: anytype) ?T {
    return std.enums.fromInt(T, value);
}

pub fn trimEnd(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    return std.mem.trimEnd(T, slice, values_to_strip);
}

pub fn openFileForRead(path: []const u8) !File {
    return std.Io.Dir.cwd().openFile(std.Options.debug_io, path, .{});
}

pub fn closeFile(file: File) void {
    file.close(std.Options.debug_io);
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.Options.debug_io, .{ .sub_path = path, .data = data });
}

pub fn writeStdout(data: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, data);
}

pub fn deleteFile(path: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(std.Options.debug_io, path);
}

pub fn fileReaderStreaming(file: File, buffer: []u8) @TypeOf(file.readerStreaming(std.Options.debug_io, buffer)) {
    return file.readerStreaming(std.Options.debug_io, buffer);
}

pub fn readerAllocRemaining(reader: anytype, allocator: std.mem.Allocator, limit: Limit) ![]u8 {
    return reader.interface.allocRemaining(allocator, limit);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openFileForRead(path);
    defer closeFile(file);

    var buffer: [4096]u8 = undefined;
    var reader = fileReaderStreaming(file, &buffer);
    return readerAllocRemaining(&reader, allocator, Limit.limited(max_bytes));
}
