const std = @import("std");
const builtin = @import("builtin");

comptime {
    const v = builtin.zig_version;
    if (!(v.major == 0 and v.minor == 15 and v.patch >= 2)) {
        @compileError("src/compat.zig requires Zig 0.15.2");
    }
}

pub const Io = std.io;
pub const File = std.fs.File;
pub const Reader = Io.Reader;
pub const Writer = Io.Writer;
pub const Limit = Io.Limit;
pub const AllocatingWriter = Writer.Allocating;
pub const ArrayList = std.ArrayList;
pub const ArrayListUnmanaged = std.ArrayListUnmanaged;
pub const StringHashMap = std.StringHashMap;

pub fn StringArrayHashMap(comptime V: type) type {
    return std.StringArrayHashMapUnmanaged(V);
}

pub fn intToEnum(comptime T: type, value: anytype) ?T {
    return std.meta.intToEnum(T, value) catch null;
}

pub fn trimEnd(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    return std.mem.trimRight(T, slice, values_to_strip);
}

pub fn openFileForRead(path: []const u8) !File {
    return std.fs.cwd().openFile(path, .{});
}

pub fn closeFile(file: File) void {
    file.close();
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

pub fn deleteFile(path: []const u8) !void {
    try std.fs.cwd().deleteFile(path);
}

pub fn fileReaderStreaming(file: File, buffer: []u8) @TypeOf(file.readerStreaming(buffer)) {
    return file.readerStreaming(buffer);
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
