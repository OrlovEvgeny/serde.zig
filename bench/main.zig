const std = @import("std");
const builtin = @import("builtin");
const serde = @import("serde");
const options = @import("bench_options");

const Allocator = std.mem.Allocator;
const compat = serde.compat;

const OutputFormat = enum { text, json };
const Mode = enum { cold, warm };

const Flat = struct {
    id: u64,
    name: []const u8,
    active: bool,
    score: f64,
};

const Address = struct {
    street: []const u8,
    city: []const u8,
    zip: []const u8,
};

const Nested = struct {
    id: u64,
    user: []const u8,
    address: Address,
    tags: []const []const u8,
};

const Row = struct {
    id: u64,
    name: []const u8,
    active: bool,
    score: f64,
};

const Command = union(enum) {
    ping,
    write: struct { key: []const u8, value: []const u8 },
    delete: []const u8,
};

const Color = enum { red, green, blue, amber };

const CsvRow = struct {
    id: u32,
    name: []const u8,
    department: []const u8,
    salary: u32,
    active: bool,
};

const Borrowed = struct {
    id: u64,
    title: []const u8,
    body: []const u8,
};

const flat_value = Flat{ .id = 42, .name = "alice", .active = true, .score = 91.75 };
const flat_json = "{\"id\":42,\"name\":\"alice\",\"active\":true,\"score\":91.75}";

const nested_value = Nested{
    .id = 7,
    .user = "bob",
    .address = .{ .street = "123 Main St", .city = "Springfield", .zip = "62704" },
    .tags = &.{ "admin", "active", "trial" },
};
const nested_json = "{\"id\":7,\"user\":\"bob\",\"address\":{\"street\":\"123 Main St\",\"city\":\"Springfield\",\"zip\":\"62704\"},\"tags\":[\"admin\",\"active\",\"trial\"]}";

const rows_value = [_]Row{
    .{ .id = 1, .name = "alpha", .active = true, .score = 10.5 },
    .{ .id = 2, .name = "bravo", .active = false, .score = 20.25 },
    .{ .id = 3, .name = "charlie", .active = true, .score = 30.75 },
    .{ .id = 4, .name = "delta", .active = true, .score = 40.125 },
    .{ .id = 5, .name = "echo", .active = false, .score = 50.875 },
    .{ .id = 6, .name = "foxtrot", .active = true, .score = 60.0 },
    .{ .id = 7, .name = "golf", .active = true, .score = 70.5 },
    .{ .id = 8, .name = "hotel", .active = false, .score = 80.25 },
};
const rows_json = "[{\"id\":1,\"name\":\"alpha\",\"active\":true,\"score\":10.5},{\"id\":2,\"name\":\"bravo\",\"active\":false,\"score\":20.25},{\"id\":3,\"name\":\"charlie\",\"active\":true,\"score\":30.75},{\"id\":4,\"name\":\"delta\",\"active\":true,\"score\":40.125},{\"id\":5,\"name\":\"echo\",\"active\":false,\"score\":50.875},{\"id\":6,\"name\":\"foxtrot\",\"active\":true,\"score\":60},{\"id\":7,\"name\":\"golf\",\"active\":true,\"score\":70.5},{\"id\":8,\"name\":\"hotel\",\"active\":false,\"score\":80.25}]";

const command_value = Command{ .write = .{ .key = "feature", .value = "bench" } };
const command_json = "{\"write\":{\"key\":\"feature\",\"value\":\"bench\"}}";
const enum_json = "\"green\"";
const borrowed_json = "{\"id\":99,\"title\":\"zero copy\",\"body\":\"plain string without escapes\"}";

const large_csv =
    "id,name,department,salary,active\n" ++
    "1,Alice,Engineering,120000,true\n" ++
    "2,Bob,Support,74000,true\n" ++
    "3,Carol,Finance,98000,false\n" ++
    "4,Dan,Engineering,130000,true\n" ++
    "5,Eve,Product,118000,true\n" ++
    "6,Frank,Sales,86000,false\n" ++
    "7,Grace,Engineering,140000,true\n" ++
    "8,Heidi,Support,71000,true\n" ++
    "9,Ivan,Finance,99000,true\n" ++
    "10,Judy,Product,121000,false\n" ++
    "11,Kate,Sales,91000,true\n" ++
    "12,Leo,Engineering,125000,true\n";

const large_ndjson =
    "{\"id\":1,\"name\":\"alpha\",\"active\":true,\"score\":10.5}\n" ++
    "{\"id\":2,\"name\":\"bravo\",\"active\":false,\"score\":20.25}\n" ++
    "{\"id\":3,\"name\":\"charlie\",\"active\":true,\"score\":30.75}\n" ++
    "{\"id\":4,\"name\":\"delta\",\"active\":true,\"score\":40.125}\n" ++
    "{\"id\":5,\"name\":\"echo\",\"active\":false,\"score\":50.875}\n" ++
    "{\"id\":6,\"name\":\"foxtrot\",\"active\":true,\"score\":60}\n" ++
    "{\"id\":7,\"name\":\"golf\",\"active\":true,\"score\":70.5}\n" ++
    "{\"id\":8,\"name\":\"hotel\",\"active\":false,\"score\":80.25}\n";

const BenchFn = *const fn (Allocator) anyerror!usize;

const Benchmark = struct {
    id: []const u8,
    format: []const u8,
    case_name: []const u8,
    operation: []const u8,
    implementation: []const u8,
    mode: Mode,
    input_bytes: usize,
    key_case: bool = false,
    run: BenchFn,
};

const BenchResult = struct {
    id: []const u8,
    format: []const u8,
    case_name: []const u8,
    operation: []const u8,
    implementation: []const u8,
    mode: Mode,
    zig_version: std.SemanticVersion,
    target: []const u8,
    optimize: std.builtin.OptimizeMode,
    iterations: usize,
    ns_per_op: f64,
    allocations_per_op: f64,
    bytes_allocated_per_op: f64,
    throughput_mb_s: f64,
    output_size_bytes: f64,
    regression_percent: ?f64 = null,
    regression_over_threshold: bool = false,
    key_case: bool = false,
};

const CountingAllocator = struct {
    child: Allocator,
    allocations: usize = 0,
    bytes_allocated: usize = 0,

    pub fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.bytes_allocated += len;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
        if (ok and new_len > memory.len) self.bytes_allocated += new_len - memory.len;
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr) orelse return null;
        if (ptr != memory.ptr) self.allocations += 1;
        if (new_len > memory.len) self.bytes_allocated += new_len - memory.len;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    const format = parseOutputFormat(options.format) orelse {
        std.debug.print("unsupported --format '{s}', expected text or json\n", .{options.format});
        return error.InvalidArgument;
    };

    var results: std.ArrayList(BenchResult) = .empty;
    defer results.deinit(gpa);

    try runAll(gpa, &results);
    if (options.baseline.len != 0) try applyBaseline(gpa, results.items, options.baseline, options.threshold_percent);

    const rendered = switch (format) {
        .text => try renderText(gpa, results.items),
        .json => try renderJson(gpa, results.items),
    };
    defer gpa.free(rendered);

    try writeStdout(rendered);
    if (options.out.len != 0) {
        try compat.writeFile(options.out, rendered);
    }
}

fn writeStdout(bytes: []const u8) !void {
    if (comptime @hasDecl(std, "Io") and @hasDecl(std.Io, "File")) {
        try std.Io.File.stdout().writeStreamingAll(std.Options.debug_io, bytes);
    } else {
        try std.io.getStdOut().writer().writeAll(bytes);
    }
}

fn runAll(allocator: Allocator, results: *std.ArrayList(BenchResult)) !void {
    for (benchmarks) |bench| {
        if (!matchesFilter(bench)) continue;
        if (std.mem.eql(u8, bench.implementation, "std_json") and !options.compare_std_json) continue;
        const result = try runBenchmark(bench);
        try results.append(allocator, result);
    }
}

fn runBenchmark(bench: Benchmark) !BenchResult {
    const warmup_iters: usize = if (bench.mode == .warm) 20 else 1;
    for (0..warmup_iters) |_| {
        _ = try bench.run(std.heap.page_allocator);
    }

    var probe_alloc = CountingAllocator{ .child = std.heap.page_allocator };
    const probe_start = nowNs();
    const probe_size = try bench.run(probe_alloc.allocator());
    const probe_ns = @max(nowNs() - probe_start, 1);

    const target_ns: u64 = if (bench.mode == .warm) 150 * std.time.ns_per_ms else 50 * std.time.ns_per_ms;
    var iterations: usize = @intCast(@max(@as(u64, 1), target_ns / probe_ns));
    const max_iterations: usize = if (bench.mode == .warm) 10_000 else 1_000;
    const min_iterations: usize = if (bench.mode == .warm) 20 else 5;
    iterations = @min(iterations, max_iterations);
    iterations = @max(iterations, min_iterations);

    var counting = CountingAllocator{ .child = std.heap.page_allocator };
    const measured_allocator = counting.allocator();
    var total_output_size: usize = 0;
    const start_ns = nowNs();
    for (0..iterations) |_| {
        total_output_size += try bench.run(measured_allocator);
    }
    const elapsed_ns = @max(nowNs() - start_ns, 1);

    const iter_f: f64 = @floatFromInt(iterations);
    const elapsed_f: f64 = @floatFromInt(elapsed_ns);
    const ns_per_op = elapsed_f / iter_f;
    const bytes_per_op: f64 = @floatFromInt(bench.input_bytes);
    const throughput = if (bench.input_bytes == 0)
        0
    else
        (bytes_per_op * iter_f) / (elapsed_f / std.time.ns_per_s) / (1024.0 * 1024.0);

    std.mem.doNotOptimizeAway(probe_size);
    std.mem.doNotOptimizeAway(total_output_size);

    return .{
        .id = bench.id,
        .format = bench.format,
        .case_name = bench.case_name,
        .operation = bench.operation,
        .implementation = bench.implementation,
        .mode = bench.mode,
        .zig_version = builtin.zig_version,
        .target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag),
        .optimize = builtin.mode,
        .iterations = iterations,
        .ns_per_op = ns_per_op,
        .allocations_per_op = @as(f64, @floatFromInt(counting.allocations)) / iter_f,
        .bytes_allocated_per_op = @as(f64, @floatFromInt(counting.bytes_allocated)) / iter_f,
        .throughput_mb_s = throughput,
        .output_size_bytes = @as(f64, @floatFromInt(total_output_size)) / iter_f,
        .key_case = bench.key_case,
    };
}

fn matchesFilter(bench: Benchmark) bool {
    if (options.filter.len == 0) return true;
    return std.mem.indexOf(u8, bench.id, options.filter) != null or
        std.mem.indexOf(u8, bench.format, options.filter) != null or
        std.mem.indexOf(u8, bench.case_name, options.filter) != null or
        std.mem.indexOf(u8, bench.operation, options.filter) != null or
        std.mem.indexOf(u8, bench.implementation, options.filter) != null;
}

fn parseOutputFormat(value: []const u8) ?OutputFormat {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

fn nowNs() u64 {
    if (comptime @hasDecl(std.time, "nanoTimestamp")) {
        return @intCast(std.time.nanoTimestamp());
    }
    return @intCast(std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds);
}

fn opJsonFlatSerialize(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, flat_value);
    defer allocator.free(out);
    std.mem.doNotOptimizeAway(out.ptr);
    return out.len;
}

fn opJsonFlatDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(Flat, arena.allocator(), flat_json);
    std.mem.doNotOptimizeAway(value);
    return @sizeOf(Flat);
}

fn opJsonFlatRoundtrip(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, flat_value);
    defer allocator.free(out);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(Flat, arena.allocator(), out);
    std.mem.doNotOptimizeAway(value);
    return out.len;
}

fn opStdJsonFlatSerialize(allocator: Allocator) !usize {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try stdJsonStringify(flat_value, &aw.writer);
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);
    std.mem.doNotOptimizeAway(out.ptr);
    return out.len;
}

fn opStdJsonFlatDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(Flat, arena.allocator(), flat_json, .{});
    std.mem.doNotOptimizeAway(value);
    return @sizeOf(Flat);
}

fn opStdJsonFlatRoundtrip(allocator: Allocator) !usize {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try stdJsonStringify(flat_value, &aw.writer);
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(Flat, arena.allocator(), out, .{});
    std.mem.doNotOptimizeAway(value);
    return out.len;
}

fn stdJsonStringify(value: anytype, writer: *compat.Io.Writer) !void {
    if (comptime @hasDecl(std.json, "Stringify")) {
        return std.json.Stringify.value(value, .{}, writer);
    }
    return std.json.stringify(value, .{}, writer);
}

fn opJsonNestedSerialize(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, nested_value);
    defer allocator.free(out);
    std.mem.doNotOptimizeAway(out.ptr);
    return out.len;
}

fn opJsonNestedDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(Nested, arena.allocator(), nested_json);
    std.mem.doNotOptimizeAway(value);
    return nested_json.len;
}

fn opJsonNestedRoundtrip(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, nested_value);
    defer allocator.free(out);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(Nested, arena.allocator(), out);
    std.mem.doNotOptimizeAway(value);
    return out.len;
}

fn opJsonArraySerialize(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, rows_value[0..]);
    defer allocator.free(out);
    std.mem.doNotOptimizeAway(out.ptr);
    return out.len;
}

fn opJsonArrayDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice([]const Row, arena.allocator(), rows_json);
    std.mem.doNotOptimizeAway(value.ptr);
    return rows_json.len;
}

fn opJsonArrayRoundtrip(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, rows_value[0..]);
    defer allocator.free(out);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice([]const Row, arena.allocator(), out);
    std.mem.doNotOptimizeAway(value.ptr);
    return out.len;
}

fn opJsonUnionSerialize(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, command_value);
    defer allocator.free(out);
    return out.len;
}

fn opJsonUnionDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(Command, arena.allocator(), command_json);
    std.mem.doNotOptimizeAway(value);
    return command_json.len;
}

fn opJsonEnumSerialize(allocator: Allocator) !usize {
    const out = try serde.json.toSlice(allocator, Color.green);
    defer allocator.free(out);
    return out.len;
}

fn opJsonEnumDeserialize(allocator: Allocator) !usize {
    const value = try serde.json.fromSlice(Color, allocator, enum_json);
    std.mem.doNotOptimizeAway(value);
    return enum_json.len;
}

fn opJsonMapSerialize(allocator: Allocator) !usize {
    var map = std.StringHashMap(u32).init(allocator);
    defer map.deinit();
    try map.put("alpha", 1);
    try map.put("bravo", 2);
    try map.put("charlie", 3);
    try map.put("delta", 4);
    const out = try serde.json.toSlice(allocator, map);
    defer allocator.free(out);
    return out.len;
}

fn opJsonMapDeserialize(allocator: Allocator) !usize {
    const input = "{\"alpha\":1,\"bravo\":2,\"charlie\":3,\"delta\":4}";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var value = try serde.json.fromSlice(std.StringHashMap(u32), arena.allocator(), input);
    std.mem.doNotOptimizeAway(value.count());
    return input.len;
}

fn opJsonDynamicValue(allocator: Allocator) !usize {
    const value = try serde.json.toValue(allocator, nested_value);
    defer value.deinit(allocator);
    const typed = try serde.json.fromValue(Nested, allocator, value);
    std.mem.doNotOptimizeAway(typed);
    return nested_json.len;
}

fn opJsonBorrowedDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSliceBorrowed(Borrowed, arena.allocator(), borrowed_json);
    std.mem.doNotOptimizeAway(value.title.ptr);
    return borrowed_json.len;
}

fn opMsgpackSerialize(allocator: Allocator) !usize {
    const out = try serde.msgpack.toSlice(allocator, nested_value);
    defer allocator.free(out);
    return out.len;
}

fn opMsgpackDeserialize(allocator: Allocator) !usize {
    const bytes = try serde.msgpack.toSlice(allocator, nested_value);
    defer allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.msgpack.fromSlice(Nested, arena.allocator(), bytes);
    std.mem.doNotOptimizeAway(value);
    return bytes.len;
}

fn opMsgpackRoundtrip(allocator: Allocator) !usize {
    const bytes = try serde.msgpack.toSlice(allocator, nested_value);
    defer allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.msgpack.fromSlice(Nested, arena.allocator(), bytes);
    std.mem.doNotOptimizeAway(value);
    return bytes.len;
}

fn opCsvLargeDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rows = try serde.csv.fromSlice([]const CsvRow, arena.allocator(), large_csv);
    std.mem.doNotOptimizeAway(rows.ptr);
    return large_csv.len;
}

fn opCsvLargeRoundtrip(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rows = try serde.csv.fromSlice([]const CsvRow, arena.allocator(), large_csv);
    const out = try serde.csv.toSlice(allocator, rows);
    defer allocator.free(out);
    return out.len;
}

fn opNdjsonLargeDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var it = std.mem.tokenizeScalar(u8, large_ndjson, '\n');
    var count: usize = 0;
    while (it.next()) |line| {
        const row = try serde.json.fromSlice(Row, arena.allocator(), line);
        std.mem.doNotOptimizeAway(row);
        count += 1;
    }
    return large_ndjson.len + count;
}

fn opNdjsonLargeSerialize(allocator: Allocator) !usize {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    for (rows_value) |row| {
        const line = try serde.json.toSlice(allocator, row);
        defer allocator.free(line);
        try aw.writer.writeAll(line);
        try aw.writer.writeByte('\n');
    }
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);
    return out.len;
}

const benchmarks = [_]Benchmark{
    .{ .id = "json.flat.serialize.serde.warm", .format = "json", .case_name = "flat_struct", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = flat_json.len, .key_case = true, .run = opJsonFlatSerialize },
    .{ .id = "json.flat.deserialize.serde.warm", .format = "json", .case_name = "flat_struct", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = flat_json.len, .key_case = true, .run = opJsonFlatDeserialize },
    .{ .id = "json.flat.roundtrip.serde.warm", .format = "json", .case_name = "flat_struct", .operation = "roundtrip", .implementation = "serde", .mode = .warm, .input_bytes = flat_json.len, .key_case = true, .run = opJsonFlatRoundtrip },
    .{ .id = "json.flat.serialize.serde.cold", .format = "json", .case_name = "flat_struct", .operation = "serialize", .implementation = "serde", .mode = .cold, .input_bytes = flat_json.len, .key_case = true, .run = opJsonFlatSerialize },
    .{ .id = "json.flat.deserialize.serde.cold", .format = "json", .case_name = "flat_struct", .operation = "deserialize", .implementation = "serde", .mode = .cold, .input_bytes = flat_json.len, .key_case = true, .run = opJsonFlatDeserialize },
    .{ .id = "json.flat.roundtrip.serde.cold", .format = "json", .case_name = "flat_struct", .operation = "roundtrip", .implementation = "serde", .mode = .cold, .input_bytes = flat_json.len, .key_case = true, .run = opJsonFlatRoundtrip },
    .{ .id = "json.flat.serialize.std_json.warm", .format = "json", .case_name = "flat_struct", .operation = "serialize", .implementation = "std_json", .mode = .warm, .input_bytes = flat_json.len, .run = opStdJsonFlatSerialize },
    .{ .id = "json.flat.deserialize.std_json.warm", .format = "json", .case_name = "flat_struct", .operation = "deserialize", .implementation = "std_json", .mode = .warm, .input_bytes = flat_json.len, .run = opStdJsonFlatDeserialize },
    .{ .id = "json.flat.roundtrip.std_json.warm", .format = "json", .case_name = "flat_struct", .operation = "roundtrip", .implementation = "std_json", .mode = .warm, .input_bytes = flat_json.len, .run = opStdJsonFlatRoundtrip },

    .{ .id = "json.nested.serialize.serde.warm", .format = "json", .case_name = "nested_struct", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = nested_json.len, .key_case = true, .run = opJsonNestedSerialize },
    .{ .id = "json.nested.deserialize.serde.warm", .format = "json", .case_name = "nested_struct", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = nested_json.len, .key_case = true, .run = opJsonNestedDeserialize },
    .{ .id = "json.nested.roundtrip.serde.warm", .format = "json", .case_name = "nested_struct", .operation = "roundtrip", .implementation = "serde", .mode = .warm, .input_bytes = nested_json.len, .key_case = true, .run = opJsonNestedRoundtrip },
    .{ .id = "json.nested.serialize.serde.cold", .format = "json", .case_name = "nested_struct", .operation = "serialize", .implementation = "serde", .mode = .cold, .input_bytes = nested_json.len, .key_case = true, .run = opJsonNestedSerialize },
    .{ .id = "json.nested.deserialize.serde.cold", .format = "json", .case_name = "nested_struct", .operation = "deserialize", .implementation = "serde", .mode = .cold, .input_bytes = nested_json.len, .key_case = true, .run = opJsonNestedDeserialize },
    .{ .id = "json.nested.roundtrip.serde.cold", .format = "json", .case_name = "nested_struct", .operation = "roundtrip", .implementation = "serde", .mode = .cold, .input_bytes = nested_json.len, .key_case = true, .run = opJsonNestedRoundtrip },
    .{ .id = "json.array_struct.serialize.serde.warm", .format = "json", .case_name = "array_struct", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = rows_json.len, .key_case = true, .run = opJsonArraySerialize },
    .{ .id = "json.array_struct.deserialize.serde.warm", .format = "json", .case_name = "array_struct", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = rows_json.len, .key_case = true, .run = opJsonArrayDeserialize },
    .{ .id = "json.array_struct.roundtrip.serde.warm", .format = "json", .case_name = "array_struct", .operation = "roundtrip", .implementation = "serde", .mode = .warm, .input_bytes = rows_json.len, .key_case = true, .run = opJsonArrayRoundtrip },
    .{ .id = "json.array_struct.serialize.serde.cold", .format = "json", .case_name = "array_struct", .operation = "serialize", .implementation = "serde", .mode = .cold, .input_bytes = rows_json.len, .key_case = true, .run = opJsonArraySerialize },
    .{ .id = "json.array_struct.deserialize.serde.cold", .format = "json", .case_name = "array_struct", .operation = "deserialize", .implementation = "serde", .mode = .cold, .input_bytes = rows_json.len, .key_case = true, .run = opJsonArrayDeserialize },
    .{ .id = "json.array_struct.roundtrip.serde.cold", .format = "json", .case_name = "array_struct", .operation = "roundtrip", .implementation = "serde", .mode = .cold, .input_bytes = rows_json.len, .key_case = true, .run = opJsonArrayRoundtrip },
    .{ .id = "json.tagged_union.serialize.serde.warm", .format = "json", .case_name = "tagged_union", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = command_json.len, .run = opJsonUnionSerialize },
    .{ .id = "json.tagged_union.deserialize.serde.warm", .format = "json", .case_name = "tagged_union", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = command_json.len, .run = opJsonUnionDeserialize },
    .{ .id = "json.enum.serialize.serde.warm", .format = "json", .case_name = "enum", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = enum_json.len, .run = opJsonEnumSerialize },
    .{ .id = "json.enum.deserialize.serde.warm", .format = "json", .case_name = "enum", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = enum_json.len, .run = opJsonEnumDeserialize },
    .{ .id = "json.map.serialize.serde.warm", .format = "json", .case_name = "map", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = 46, .run = opJsonMapSerialize },
    .{ .id = "json.map.deserialize.serde.warm", .format = "json", .case_name = "map", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = 46, .run = opJsonMapDeserialize },
    .{ .id = "json.dynamic_value.roundtrip.serde.warm", .format = "json", .case_name = "dynamic_value", .operation = "roundtrip", .implementation = "serde", .mode = .warm, .input_bytes = nested_json.len, .run = opJsonDynamicValue },
    .{ .id = "json.borrowed_strings.deserialize.serde.warm", .format = "json", .case_name = "borrowed_strings", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = borrowed_json.len, .key_case = true, .run = opJsonBorrowedDeserialize },
    .{ .id = "json.borrowed_strings.deserialize.serde.cold", .format = "json", .case_name = "borrowed_strings", .operation = "deserialize", .implementation = "serde", .mode = .cold, .input_bytes = borrowed_json.len, .key_case = true, .run = opJsonBorrowedDeserialize },

    .{ .id = "msgpack.nested.serialize.serde.warm", .format = "msgpack", .case_name = "nested_struct", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = nested_json.len, .key_case = true, .run = opMsgpackSerialize },
    .{ .id = "msgpack.nested.serialize.serde.cold", .format = "msgpack", .case_name = "nested_struct", .operation = "serialize", .implementation = "serde", .mode = .cold, .input_bytes = nested_json.len, .key_case = true, .run = opMsgpackSerialize },
    .{ .id = "msgpack.nested.deserialize.serde.warm", .format = "msgpack", .case_name = "nested_struct", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = nested_json.len, .run = opMsgpackDeserialize },
    .{ .id = "msgpack.nested.roundtrip.serde.warm", .format = "msgpack", .case_name = "nested_struct", .operation = "roundtrip", .implementation = "serde", .mode = .warm, .input_bytes = nested_json.len, .run = opMsgpackRoundtrip },
    .{ .id = "csv.large.deserialize.serde.warm", .format = "csv", .case_name = "large_csv", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = large_csv.len, .key_case = true, .run = opCsvLargeDeserialize },
    .{ .id = "csv.large.deserialize.serde.cold", .format = "csv", .case_name = "large_csv", .operation = "deserialize", .implementation = "serde", .mode = .cold, .input_bytes = large_csv.len, .key_case = true, .run = opCsvLargeDeserialize },
    .{ .id = "csv.large.roundtrip.serde.warm", .format = "csv", .case_name = "large_csv", .operation = "roundtrip", .implementation = "serde", .mode = .warm, .input_bytes = large_csv.len, .run = opCsvLargeRoundtrip },
    .{ .id = "ndjson.large.serialize.serde.warm", .format = "ndjson", .case_name = "large_ndjson", .operation = "serialize", .implementation = "serde", .mode = .warm, .input_bytes = large_ndjson.len, .run = opNdjsonLargeSerialize },
    .{ .id = "ndjson.large.deserialize.serde.warm", .format = "ndjson", .case_name = "large_ndjson", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = large_ndjson.len, .key_case = true, .run = opNdjsonLargeDeserialize },
    .{ .id = "ndjson.large.deserialize.serde.cold", .format = "ndjson", .case_name = "large_ndjson", .operation = "deserialize", .implementation = "serde", .mode = .cold, .input_bytes = large_ndjson.len, .key_case = true, .run = opNdjsonLargeDeserialize },
};

fn renderText(allocator: Allocator, results: []const BenchResult) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try aw.writer.print("serde.zig benchmarks ({s}, {s})\n", .{ @tagName(builtin.mode), @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) });
    try aw.writer.writeAll("id, ns/op, allocs/op, bytes/op, MB/s, output bytes\n");
    for (results) |result| {
        try aw.writer.print("{s}, {d:.2}, {d:.2}, {d:.2}, {d:.2}, {d:.2}", .{
            result.id,
            result.ns_per_op,
            result.allocations_per_op,
            result.bytes_allocated_per_op,
            result.throughput_mb_s,
            result.output_size_bytes,
        });
        if (result.regression_percent) |pct| {
            try aw.writer.print(", regression={d:.2}%{s}", .{ pct, if (result.regression_over_threshold) " OVER_THRESHOLD" else "" });
        }
        try aw.writer.writeByte('\n');
    }
    return aw.toOwnedSlice();
}

fn renderJson(allocator: Allocator, results: []const BenchResult) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try aw.writer.writeAll("{\"schema_version\":1,\"results\":[");
    for (results, 0..) |result, i| {
        if (i != 0) try aw.writer.writeByte(',');
        try aw.writer.writeByte('{');
        try writeJsonStringField(&aw.writer, "id", result.id, true);
        try writeJsonStringField(&aw.writer, "format", result.format, false);
        try writeJsonStringField(&aw.writer, "case", result.case_name, false);
        try writeJsonStringField(&aw.writer, "operation", result.operation, false);
        try writeJsonStringField(&aw.writer, "implementation", result.implementation, false);
        try writeJsonStringField(&aw.writer, "mode", @tagName(result.mode), false);
        try writeJsonStringField(&aw.writer, "zig_version", builtin.zig_version_string, false);
        try writeJsonStringField(&aw.writer, "target", result.target, false);
        try writeJsonStringField(&aw.writer, "optimize", @tagName(result.optimize), false);
        try aw.writer.print(",\"iterations\":{},\"ns_per_op\":{d:.3},\"allocations_per_op\":{d:.3},\"bytes_allocated_per_op\":{d:.3},\"throughput_mb_s\":{d:.3},\"output_size_bytes\":{d:.3},\"key_case\":{}", .{
            result.iterations,
            result.ns_per_op,
            result.allocations_per_op,
            result.bytes_allocated_per_op,
            result.throughput_mb_s,
            result.output_size_bytes,
            result.key_case,
        });
        if (result.regression_percent) |pct| {
            try aw.writer.print(",\"regression_percent\":{d:.3},\"regression_over_threshold\":{}", .{ pct, result.regression_over_threshold });
        }
        try aw.writer.writeByte('}');
    }
    try aw.writer.writeAll("]}\n");
    return aw.toOwnedSlice();
}

fn writeJsonStringField(writer: *compat.Io.Writer, name: []const u8, value: []const u8, first: bool) !void {
    if (!first) try writer.writeByte(',');
    try writer.writeByte('"');
    try writer.writeAll(name);
    try writer.writeAll("\":\"");
    try writeEscapedJsonString(writer, value);
    try writer.writeByte('"');
}

fn writeEscapedJsonString(writer: *compat.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(c),
    };
}

fn applyBaseline(allocator: Allocator, results: []BenchResult, baseline_path: []const u8, threshold_percent: f64) !void {
    const baseline = try compat.readFileAlloc(allocator, baseline_path, 10 * 1024 * 1024);
    defer allocator.free(baseline);
    for (results) |*result| {
        const old_ns = findBaselineNs(baseline, result.id, result.implementation) orelse continue;
        if (old_ns <= 0) continue;
        const pct = ((result.ns_per_op - old_ns) / old_ns) * 100.0;
        result.regression_percent = pct;
        result.regression_over_threshold = result.key_case and pct > threshold_percent;
    }
}

fn findBaselineNs(json: []const u8, id: []const u8, implementation: []const u8) ?f64 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_from, "\"id\":\"")) |id_key| {
        const value_start = id_key + "\"id\":\"".len;
        const value_end = std.mem.indexOfScalarPos(u8, json, value_start, '"') orelse return null;
        if (std.mem.eql(u8, json[value_start..value_end], id)) {
            const object_end = std.mem.indexOfScalarPos(u8, json, value_end, '}') orelse return null;
            const object = json[id_key..object_end];
            const impl_pos = std.mem.indexOf(u8, object, "\"implementation\":\"") orelse {
                search_from = object_end + 1;
                continue;
            };
            const impl_start = impl_pos + "\"implementation\":\"".len;
            const impl_end = std.mem.indexOfScalarPos(u8, object, impl_start, '"') orelse return null;
            if (!std.mem.eql(u8, object[impl_start..impl_end], implementation)) {
                search_from = object_end + 1;
                continue;
            }
            const ns_pos = std.mem.indexOf(u8, object, "\"ns_per_op\":") orelse return null;
            const ns_start = ns_pos + "\"ns_per_op\":".len;
            var ns_end = ns_start;
            while (ns_end < object.len and (std.ascii.isDigit(object[ns_end]) or object[ns_end] == '.' or object[ns_end] == '-')) ns_end += 1;
            return std.fmt.parseFloat(f64, object[ns_start..ns_end]) catch null;
        }
        search_from = value_end + 1;
    }
    return null;
}

test "parse output format" {
    try std.testing.expectEqual(OutputFormat.text, parseOutputFormat("text").?);
    try std.testing.expectEqual(OutputFormat.json, parseOutputFormat("json").?);
    try std.testing.expect(parseOutputFormat("xml") == null);
}

test "counting allocator records allocations" {
    var counter = CountingAllocator{ .child = std.testing.allocator };
    const allocator = counter.allocator();
    const bytes = try allocator.alloc(u8, 16);
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 1), counter.allocations);
    try std.testing.expect(counter.bytes_allocated >= 16);
}

test "baseline lookup parses ns_per_op" {
    const json = "{\"schema_version\":1,\"results\":[{\"id\":\"json.flat.serialize.serde.warm\",\"implementation\":\"serde\",\"ns_per_op\":123.5}]}";
    const ns = findBaselineNs(json, "json.flat.serialize.serde.warm", "serde").?;
    try std.testing.expectEqual(@as(f64, 123.5), ns);
}
