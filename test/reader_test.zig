//! Reader-entry-point coverage.
//!
//! Every format exposes `fromReader`, but those functions are generic: their
//! bodies are only analyzed once instantiated. Without a call site a broken
//! `readAll` compiles clean and ships. These tests instantiate the reader path
//! of every format so a regression is a build failure, and they drive XML
//! through readers that answer in several short reads, fail mid-stream, end
//! immediately, or never end at all.

const std = @import("std");
const testing = std.testing;
const serde = @import("serde");
const compat = serde.compat;

const Io = compat.Io;

/// Hands out at most `chunk` bytes per `stream` call, so `readAll` has to loop.
/// `Reader.fixed` publishes the whole document in its buffer and is drained in
/// a single call, which never exercises that loop.
const ChunkedReader = struct {
    interface: Io.Reader,
    data: []const u8,
    pos: usize = 0,
    chunk: usize,
    calls: usize = 0,

    const vtable: Io.Reader.VTable = .{ .stream = stream };

    fn init(data: []const u8, buffer: []u8, chunk: usize) ChunkedReader {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
            .data = data,
            .chunk = chunk,
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.pos == self.data.len) return error.EndOfStream;
        const rest = self.data[self.pos..];
        const n = try w.write(limit.sliceConst(rest[0..@min(self.chunk, rest.len)]));
        self.pos += n;
        self.calls += 1;
        return n;
    }
};

/// Delivers `prefix_len` bytes, then reports a transport failure.
const FailingReader = struct {
    interface: Io.Reader,
    data: []const u8,
    pos: usize = 0,
    prefix_len: usize,

    const vtable: Io.Reader.VTable = .{ .stream = stream };

    fn init(data: []const u8, buffer: []u8, prefix_len: usize) FailingReader {
        return .{
            .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
            .data = data,
            .prefix_len = prefix_len,
        };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *FailingReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.pos >= self.prefix_len) return error.ReadFailed;
        const rest = self.data[self.pos..self.prefix_len];
        const n = try w.write(limit.sliceConst(rest));
        self.pos += n;
        return n;
    }
};

/// Never signals end of stream. Only the read limit can stop it.
const EndlessReader = struct {
    interface: Io.Reader,
    filler: u8 = ' ',

    const vtable: Io.Reader.VTable = .{ .stream = stream };
    const block_len = 64 * 1024;

    fn init(buffer: []u8) EndlessReader {
        return .{ .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 } };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *EndlessReader = @alignCast(@fieldParentPtr("interface", r));
        var block: [block_len]u8 = undefined;
        @memset(&block, self.filler);
        return w.write(limit.sliceConst(&block));
    }
};

const Point = struct { x: i32, y: i32 };
const Nested = struct { name: []const u8, inner: Point };

// XML: the reader path that PR #39 repaired.

test "xml fromReader: chunked reader is drained across many stream calls" {
    const doc = "<Point><x>10</x><y>20</y></Point>";
    var buffer: [16]u8 = undefined;
    var reader = ChunkedReader.init(doc, &buffer, 7);
    const point = try serde.xml.fromReader(Point, testing.allocator, &reader.interface);
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
    // 33 bytes at 7 per call: the document cannot have arrived in one read.
    try testing.expect(reader.calls > 1);
}

test "xml fromReader: single-byte reads still assemble the document" {
    const doc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Point><x>-7</x><y>13</y></Point>";
    var buffer: [8]u8 = undefined;
    var reader = ChunkedReader.init(doc, &buffer, 1);
    const point = try serde.xml.fromReader(Point, testing.allocator, &reader.interface);
    try testing.expectEqual(@as(i32, -7), point.x);
    try testing.expectEqual(@as(i32, 13), point.y);
    try testing.expectEqual(doc.len, reader.calls);
}

test "xml fromReader: nested struct with strings and entities" {
    const doc = "<Nested><name>a &amp; b</name><inner><x>1</x><y>2</y></inner></Nested>";
    var buffer: [16]u8 = undefined;
    var reader = ChunkedReader.init(doc, &buffer, 5);
    const value = try serde.xml.fromReader(Nested, testing.allocator, &reader.interface);
    // Strings must be copies. `fromReader` frees its scratch buffer before
    // returning, so a borrowed slice would dangle and this free would fault.
    defer serde.core.freeAllocated(Nested, value, testing.allocator);
    try testing.expectEqualStrings("a & b", value.name);
    try testing.expectEqual(@as(i32, 1), value.inner.x);
    try testing.expectEqual(@as(i32, 2), value.inner.y);
}

test "xml fromReader: slice of structs spanning many chunks" {
    const List = struct { items: []const Point };
    const doc = "<List><items>" ++
        "<item><x>1</x><y>2</y></item>" ++
        "<item><x>3</x><y>4</y></item>" ++
        "<item><x>5</x><y>6</y></item>" ++
        "</items></List>";
    var buffer: [16]u8 = undefined;
    var reader = ChunkedReader.init(doc, &buffer, 9);
    const value = try serde.xml.fromReader(List, testing.allocator, &reader.interface);
    defer testing.allocator.free(value.items);
    try testing.expectEqualDeep(@as([]const Point, &.{
        .{ .x = 1, .y = 2 },
        .{ .x = 3, .y = 4 },
        .{ .x = 5, .y = 6 },
    }), value.items);
    try testing.expect(reader.calls > 1);
}

test "xml fromReader matches fromSlice on the same bytes" {
    const doc = "<Nested><name>hello</name><inner><x>5</x><y>6</y></inner></Nested>";
    const from_slice = try serde.xml.fromSlice(Nested, testing.allocator, doc);
    defer serde.core.freeAllocated(Nested, from_slice, testing.allocator);

    var buffer: [16]u8 = undefined;
    var reader = ChunkedReader.init(doc, &buffer, 3);
    const from_reader = try serde.xml.fromReader(Nested, testing.allocator, &reader.interface);
    defer serde.core.freeAllocated(Nested, from_reader, testing.allocator);

    try testing.expectEqualStrings(from_slice.name, from_reader.name);
    try testing.expectEqual(from_slice.inner, from_reader.inner);
}

test "xml fromReaderSchema: schema path shares readAll and must work too" {
    const Mode = enum { read_only, write_only };
    const schema = .{ .rename = .{ .read_only = "ro", .write_only = "wo" } };
    const doc = "<value>wo</value>";
    var buffer: [8]u8 = undefined;
    var reader = ChunkedReader.init(doc, &buffer, 4);
    const mode = try serde.xml.fromReaderSchema(Mode, testing.allocator, &reader.interface, schema);
    try testing.expectEqual(Mode.write_only, mode);
    try testing.expect(reader.calls > 1);
}

test "xml fromReader: transport failure surfaces as ReadFailed" {
    const doc = "<Point><x>10</x><y>20</y></Point>";
    var buffer: [16]u8 = undefined;
    var reader = FailingReader.init(doc, &buffer, 10);
    try testing.expectError(error.ReadFailed, serde.xml.fromReader(Point, testing.allocator, &reader.interface));
}

test "xml fromReader: empty stream reports a parse error, not a hang" {
    var buffer: [8]u8 = undefined;
    var reader = ChunkedReader.init("", &buffer, 4);
    try testing.expectError(error.MalformedXml, serde.xml.fromReader(Point, testing.allocator, &reader.interface));
    try testing.expectError(error.MalformedXml, serde.xml.fromSlice(Point, testing.allocator, ""));
}

test "xml fromReader: truncated document reports the same error as fromSlice" {
    // A stream cut short is currently indistinguishable from a document that
    // legitimately omits a field: both surface as MissingField. Pinning it here
    // so a future change to truncation diagnostics is a deliberate one.
    const doc = "<Point><x>10</x>";
    var buffer: [8]u8 = undefined;
    var reader = ChunkedReader.init(doc, &buffer, 4);
    try testing.expectError(error.MissingField, serde.xml.fromReader(Point, testing.allocator, &reader.interface));
    try testing.expectError(error.MissingField, serde.xml.fromSlice(Point, testing.allocator, doc));
}

test "xml fromReader: endless stream is capped by the read limit" {
    var buffer: [64]u8 = undefined;
    var reader = EndlessReader.init(&buffer);
    // Without a limit this would allocate until the process dies.
    try testing.expectError(error.ReadFailed, serde.xml.fromReader(Point, testing.allocator, &reader.interface));
}

// Cross-format: instantiate every `fromReader` so a broken body is a build
// failure. Each format is fed the bytes its own serializer produced.

fn expectReaderMatchesSlice(
    comptime format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    value: T,
) !void {
    const bytes = try format.toSlice(allocator, value);
    defer allocator.free(bytes);

    var buffer: [16]u8 = undefined;
    var reader = ChunkedReader.init(bytes, &buffer, 3);
    const decoded = try format.fromReader(T, allocator, &reader.interface);
    try testing.expectEqualDeep(value, decoded);
}

test "every format decodes a struct from a chunked reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Point{ .x = 42, .y = -1 };

    try expectReaderMatchesSlice(serde.json, Point, a, v);
    try expectReaderMatchesSlice(serde.msgpack, Point, a, v);
    try expectReaderMatchesSlice(serde.toml, Point, a, v);
    try expectReaderMatchesSlice(serde.yaml, Point, a, v);
    try expectReaderMatchesSlice(serde.xml, Point, a, v);
    try expectReaderMatchesSlice(serde.zon, Point, a, v);
    try expectReaderMatchesSlice(serde.toon, Point, a, v);
    try expectReaderMatchesSlice(serde.etf, Point, a, v);
}

test "csv decodes rows from a chunked reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows: []const Point = &.{ .{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 } };

    const bytes = try serde.csv.toSlice(a, rows);
    var buffer: [16]u8 = undefined;
    var reader = ChunkedReader.init(bytes, &buffer, 3);
    const decoded = try serde.csv.fromReader([]const Point, a, &reader.interface);
    try testing.expectEqualDeep(rows, decoded);
}

test "every format reports ReadFailed when the transport fails" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Point{ .x = 42, .y = -1 };

    inline for (.{ serde.json, serde.msgpack, serde.toml, serde.yaml, serde.xml, serde.zon, serde.toon, serde.etf }) |format| {
        const bytes = try format.toSlice(a, v);
        var buffer: [16]u8 = undefined;
        var reader = FailingReader.init(bytes, &buffer, @min(2, bytes.len));
        try testing.expectError(error.ReadFailed, format.fromReader(Point, a, &reader.interface));
    }
}

test "every format caps an endless stream instead of exhausting memory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{ serde.json, serde.msgpack, serde.toml, serde.yaml, serde.xml, serde.zon, serde.toon }) |format| {
        var buffer: [64]u8 = undefined;
        var reader = EndlessReader.init(&buffer);
        try testing.expectError(error.ReadFailed, format.fromReader(Point, a, &reader.interface));
    }
}

// The remaining reader variants. Same generic-instantiation hazard: each is a
// distinct instantiation, so each needs its own call site to be compiled at all.

test "option and adapter reader variants decode from a chunked reader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = Point{ .x = 42, .y = -1 };
    const empty_map = .{};

    {
        const bytes = try serde.json.toSlice(a, v);
        var buffer: [16]u8 = undefined;
        var reader = ChunkedReader.init(bytes, &buffer, 3);
        try testing.expectEqualDeep(v, try serde.json.fromReaderWithMap(Point, a, &reader.interface, empty_map));
    }
    {
        const bytes = try serde.toon.toSlice(a, v);
        var buffer: [16]u8 = undefined;
        var reader = ChunkedReader.init(bytes, &buffer, 3);
        try testing.expectEqualDeep(v, try serde.toon.fromReaderWith(Point, a, &reader.interface, .{}));
    }
    {
        const bytes = try serde.toon.toSlice(a, v);
        var buffer: [16]u8 = undefined;
        var reader = ChunkedReader.init(bytes, &buffer, 3);
        try testing.expectEqualDeep(v, try serde.toon.fromReaderWithMap(Point, a, &reader.interface, empty_map));
    }
    {
        const bytes = try serde.etf.toSlice(a, v);
        var buffer: [16]u8 = undefined;
        var reader = ChunkedReader.init(bytes, &buffer, 3);
        try testing.expectEqualDeep(v, try serde.etf.fromReaderWith(Point, a, &reader.interface, .{}));
    }
    {
        const bytes = try serde.etf.toSlice(a, v);
        var buffer: [16]u8 = undefined;
        var reader = ChunkedReader.init(bytes, &buffer, 3);
        try testing.expectEqualDeep(v, try serde.etf.fromReaderWithSchema(Point, a, &reader.interface, .{}, .{}));
    }
    {
        const bytes = try serde.etf.toSlice(a, v);
        var buffer: [16]u8 = undefined;
        var reader = ChunkedReader.init(bytes, &buffer, 3);
        try testing.expectEqualDeep(v, try serde.etf.fromReaderWithMap(Point, a, &reader.interface, empty_map));
    }
}

test "every fromFilePath instantiates and reports a missing file" {
    const a = testing.allocator;
    const missing = "serde-zig-no-such-file.tmp";

    inline for (.{ serde.json, serde.msgpack, serde.toml, serde.yaml, serde.xml, serde.zon }) |format| {
        try testing.expectError(error.FileNotFound, format.fromFilePath(Point, a, missing));
    }
    try testing.expectError(error.FileNotFound, serde.csv.fromFilePath([]const Point, a, missing));
}
