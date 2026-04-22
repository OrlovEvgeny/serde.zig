const std = @import("std");
const builtin = @import("builtin");

comptime {
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 15 or v.patch < 2) {
        @compileError("serde.zig compat layer targets Zig 0.15.2+; saw " ++
            std.fmt.comptimePrint("{d}.{d}.{d}", .{ v.major, v.minor, v.patch }));
    }
}

pub const Reader = std.io.Reader;
pub const Writer = std.io.Writer;
pub const Limit = std.io.Limit;
pub const AllocatingWriter = std.io.Writer.Allocating;

pub const ArrayList = std.ArrayList;
pub const ArrayListUnmanaged = std.ArrayListUnmanaged;
pub const StringHashMap = std.StringHashMap;
pub const StringArrayHashMap = std.StringArrayHashMap;

pub inline fn readerFixed(buf: []const u8) Reader {
    return Reader.fixed(buf);
}

pub inline fn openFileForRead(dir: std.fs.Dir, path: []const u8) !std.fs.File {
    return dir.openFile(path, .{});
}

pub inline fn fileReader(file: *std.fs.File) @TypeOf(file.reader()) {
    return file.reader();
}

pub inline fn fileReaderAny(file: *std.fs.File) @TypeOf(file.reader().any()) {
    return file.reader().any();
}

pub inline fn fileReaderStreaming(file: *std.fs.File, buf: []u8) @TypeOf(file.readerStreaming(buf)) {
    return file.readerStreaming(buf);
}

pub inline fn readFileAllAlloc(file: *std.fs.File, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    return file.reader().readAllAlloc(allocator, max_bytes);
}

pub inline fn readerAllocRemaining(reader: *Reader, allocator: std.mem.Allocator, limit: Limit) ![]u8 {
    return reader.allocRemaining(allocator, limit);
}
