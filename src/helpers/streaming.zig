const std = @import("std");
const compat = @import("compat");
const json_mod = @import("../formats/json/mod.zig");

const Allocator = std.mem.Allocator;

/// Line-delimited streaming deserializer (NDJSON).
/// Reads one line at a time from a type-erased reader and deserializes each line as JSON.
pub fn StreamingDeserializer(comptime T: type) type {
    return struct {
        reader: *compat.Io.Reader,
        allocator: Allocator,
        buf: std.ArrayListUnmanaged(u8) = .empty,

        const Self = @This();

        pub fn init(allocator: Allocator, reader: *compat.Io.Reader) Self {
            return .{ .reader = reader, .allocator = allocator };
        }

        /// Return the next deserialized value, or null at end of input.
        /// Caller is responsible for managing lifetime of returned values
        /// (use an ArenaAllocator if the values contain allocated strings/slices).
        pub fn next(self: *Self) !?T {
            while (true) {
                self.buf.clearRetainingCapacity();
                const got_line = try self.readLine();
                if (!got_line) {
                    if (self.buf.items.len == 0) return null;
                }
                const line = std.mem.trim(u8, self.buf.items, &.{ ' ', '\t', '\r' });
                if (line.len == 0) {
                    if (!got_line) return null;
                    continue;
                }

                return try json_mod.fromSlice(T, self.allocator, line);
            }
        }

        // Read until newline or end-of-stream. Returns true if newline found, false if EOF.
        fn readLine(self: *Self) !bool {
            while (true) {
                if (self.reader.bufferedLen() == 0) {
                    _ = self.reader.peek(1) catch |err| switch (err) {
                        error.EndOfStream => return false,
                        else => return error.ReadFailed,
                    };
                }
                const available = self.reader.buffered();
                const newline = std.mem.indexOfScalar(u8, available, '\n');
                const n = newline orelse available.len;
                try self.buf.appendSlice(self.allocator, available[0..n]);
                self.reader.toss(n + @intFromBool(newline != null));
                if (newline != null) return true;
            }
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
        }
    };
}

// Tests.

const testing = std.testing;

test "streaming NDJSON" {
    const Entry = struct { id: i32 };
    const input = "{\"id\":1}\n{\"id\":2}\n{\"id\":3}\n";
    var reader: compat.Io.Reader = .fixed(input);
    var sd = StreamingDeserializer(Entry).init(testing.allocator, &reader);
    defer sd.deinit();

    const e1 = (try sd.next()).?;
    try testing.expectEqual(@as(i32, 1), e1.id);
    const e2 = (try sd.next()).?;
    try testing.expectEqual(@as(i32, 2), e2.id);
    const e3 = (try sd.next()).?;
    try testing.expectEqual(@as(i32, 3), e3.id);
    try testing.expectEqual(@as(?Entry, null), try sd.next());
}

test "streaming skips blank lines" {
    const Entry = struct { v: i32 };
    const input = "\n{\"v\":1}\n\n{\"v\":2}\n\n";
    var reader: compat.Io.Reader = .fixed(input);
    var sd = StreamingDeserializer(Entry).init(testing.allocator, &reader);
    defer sd.deinit();

    try testing.expectEqual(@as(i32, 1), (try sd.next()).?.v);
    try testing.expectEqual(@as(i32, 2), (try sd.next()).?.v);
    try testing.expectEqual(@as(?Entry, null), try sd.next());
}

test "streaming with strings" {
    const Msg = struct { text: []const u8 };
    const input = "{\"text\":\"hello\"}\n{\"text\":\"world\"}\n";
    var reader: compat.Io.Reader = .fixed(input);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sd = StreamingDeserializer(Msg).init(arena.allocator(), &reader);
    defer sd.deinit();

    try testing.expectEqualStrings("hello", (try sd.next()).?.text);
    try testing.expectEqualStrings("world", (try sd.next()).?.text);
    try testing.expectEqual(@as(?Msg, null), try sd.next());
}

const ChunkedReader = struct {
    input: []const u8,
    pos: usize = 0,
    calls: usize = 0,
    reader: compat.Io.Reader,
    fn stream(r: *compat.Io.Reader, writer: *compat.Io.Writer, limit: compat.Io.Limit) compat.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("reader", r);
        if (self.pos == self.input.len) return error.EndOfStream;
        const n = limit.minInt(@min(@as(usize, 7), self.input.len - self.pos));
        try writer.writeAll(self.input[self.pos..][0..n]);
        self.pos += n;
        self.calls += 1;
        return n;
    }
};

test "streaming handles short reads CRLF and final line without newline" {
    var buf: [16]u8 = undefined;
    var source = ChunkedReader{
        .input = "\r\n  \t\n{\"id\":123}\r\n{\"id\":456}",
        .reader = .{ .vtable = &.{ .stream = ChunkedReader.stream }, .buffer = &buf, .seek = 0, .end = 0 },
    };
    const T = struct { id: u32 };
    var stream = StreamingDeserializer(T).init(testing.allocator, &source.reader);
    defer stream.deinit();
    try testing.expectEqual(@as(u32, 123), (try stream.next()).?.id);
    const capacity = stream.buf.capacity;
    try testing.expectEqual(@as(u32, 456), (try stream.next()).?.id);
    try testing.expectEqual(capacity, stream.buf.capacity);
    try testing.expectEqual(@as(?T, null), try stream.next());
    try testing.expect(source.calls > 1);
}
