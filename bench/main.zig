const std = @import("std");
const builtin = @import("builtin");
const serde = @import("serde");
const options = @import("bench_options");

const Allocator = std.mem.Allocator;
const compat = serde.compat;

const OutputFormat = enum { text, json };
const Mode = enum { cold, warm, cpu };
var msgpack_input: []const u8 = undefined;
var prepared_map: std.StringHashMap(u32) = undefined;
var cpu_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

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

const StringDocument = struct {
    text: []const u8,
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
const long_sparse_text = blk: {
    @setEvalBranchQuota(20_000);
    var text: [129 * 128]u8 = undefined;
    for (&text, 0..) |*byte, i| byte.* = if (i % 129 == 128) '\n' else 'a';
    break :blk text;
};
const long_plain_json = makePlainStringJson(16 * 1024);
const long_escaped_json = makeEscapedStringJson(8 * 1024);
const long_sparse_escaped_json = makeSparseEscapedStringJson(128, 128);

fn makePlainStringJson(comptime length: usize) [11 + length]u8 {
    var input: [11 + length]u8 = undefined;
    @memcpy(input[0..9], "{\"text\":\"");
    @memset(input[9 .. 9 + length], 'a');
    input[9 + length] = '"';
    input[10 + length] = '}';
    return input;
}

fn makeEscapedStringJson(comptime escapes: usize) [11 + escapes * 2]u8 {
    @setEvalBranchQuota(escapes * 2 + 1_000);
    var input: [11 + escapes * 2]u8 = undefined;
    @memcpy(input[0..9], "{\"text\":\"");
    for (0..escapes) |index| {
        input[9 + index * 2] = '\\';
        input[10 + index * 2] = 'n';
    }
    input[input.len - 2] = '"';
    input[input.len - 1] = '}';
    return input;
}

/// Prose-shaped input: long plain runs punctuated by the occasional escape,
/// which is what real documents look like. The all-plain and all-escape cases
/// above are the two extremes and behave differently from this one.
fn makeSparseEscapedStringJson(comptime runs: usize, comptime run_length: usize) [11 + runs * (run_length + 2)]u8 {
    @setEvalBranchQuota(runs * (run_length + 2) + 1_000);
    var input: [11 + runs * (run_length + 2)]u8 = undefined;
    @memcpy(input[0..9], "{\"text\":\"");
    var at: usize = 9;
    for (0..runs) |_| {
        @memset(input[at .. at + run_length], 'a');
        at += run_length;
        input[at] = '\\';
        input[at + 1] = 'n';
        at += 2;
    }
    input[input.len - 2] = '"';
    input[input.len - 1] = '}';
    return input;
}

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

const Wide = struct {
    f0: i32,
    f1: i32,
    f2: i32,
    f3: i32,
    f4: i32,
    f5: i32,
    f6: i32,
    f7: i32,
    f8: i32,
    f9: i32,
    f10: i32,
    f11: i32,
    f12: i32,
    f13: i32,
    f14: i32,
    f15: i32,
    f16: i32,
    f17: i32,
    f18: i32,
    f19: i32,
    f20: i32,
    f21: i32,
    f22: i32,
    f23: i32,
    pub const serde = .{ .alias = .{ .f0 = &.{"zero"} } };
};
const Wide64 = struct {
    field_000: i32,
    field_001: i32,
    field_002: i32,
    field_003: i32,
    field_004: i32,
    field_005: i32,
    field_006: i32,
    field_007: i32,
    field_008: i32,
    field_009: i32,
    field_010: i32,
    field_011: i32,
    field_012: i32,
    field_013: i32,
    field_014: i32,
    field_015: i32,
    field_016: i32,
    field_017: i32,
    field_018: i32,
    field_019: i32,
    field_020: i32,
    field_021: i32,
    field_022: i32,
    field_023: i32,
    field_024: i32,
    field_025: i32,
    field_026: i32,
    field_027: i32,
    field_028: i32,
    field_029: i32,
    field_030: i32,
    field_031: i32,
    field_032: i32,
    field_033: i32,
    field_034: i32,
    field_035: i32,
    field_036: i32,
    field_037: i32,
    field_038: i32,
    field_039: i32,
    field_040: i32,
    field_041: i32,
    field_042: i32,
    field_043: i32,
    field_044: i32,
    field_045: i32,
    field_046: i32,
    field_047: i32,
    field_048: i32,
    field_049: i32,
    field_050: i32,
    field_051: i32,
    field_052: i32,
    field_053: i32,
    field_054: i32,
    field_055: i32,
    field_056: i32,
    field_057: i32,
    field_058: i32,
    field_059: i32,
    field_060: i32,
    field_061: i32,
    field_062: i32,
    field_063: i32,
};
const wide64_json = "{\"field_000\":0,\"field_001\":1,\"field_002\":2,\"field_003\":3,\"field_004\":4,\"field_005\":5,\"field_006\":6,\"field_007\":7,\"field_008\":8,\"field_009\":9,\"field_010\":10,\"field_011\":11,\"field_012\":12,\"field_013\":13,\"field_014\":14,\"field_015\":15,\"field_016\":16,\"field_017\":17,\"field_018\":18,\"field_019\":19,\"field_020\":20,\"field_021\":21,\"field_022\":22,\"field_023\":23,\"field_024\":24,\"field_025\":25,\"field_026\":26,\"field_027\":27,\"field_028\":28,\"field_029\":29,\"field_030\":30,\"field_031\":31,\"field_032\":32,\"field_033\":33,\"field_034\":34,\"field_035\":35,\"field_036\":36,\"field_037\":37,\"field_038\":38,\"field_039\":39,\"field_040\":40,\"field_041\":41,\"field_042\":42,\"field_043\":43,\"field_044\":44,\"field_045\":45,\"field_046\":46,\"field_047\":47,\"field_048\":48,\"field_049\":49,\"field_050\":50,\"field_051\":51,\"field_052\":52,\"field_053\":53,\"field_054\":54,\"field_055\":55,\"field_056\":56,\"field_057\":57,\"field_058\":58,\"field_059\":59,\"field_060\":60,\"field_061\":61,\"field_062\":62,\"field_063\":63}";
const wide_json = "{\"f0\":0,\"f1\":1,\"f2\":2,\"f3\":3,\"f4\":4,\"f5\":5,\"f6\":6,\"f7\":7,\"f8\":8,\"f9\":9,\"f10\":10,\"f11\":11,\"f12\":12,\"f13\":13,\"f14\":14,\"f15\":15,\"f16\":16,\"f17\":17,\"f18\":18,\"f19\":19,\"f20\":20,\"f21\":21,\"f22\":22,\"f23\":23}";
const wide_shuffled_json = "{\"f23\":23,\"f22\":22,\"f21\":21,\"f20\":20,\"f19\":19,\"f18\":18,\"f17\":17,\"f16\":16,\"f15\":15,\"f14\":14,\"f13\":13,\"f12\":12,\"f11\":11,\"f10\":10,\"f9\":9,\"f8\":8,\"f7\":7,\"f6\":6,\"f5\":5,\"f4\":4,\"f3\":3,\"f2\":2,\"f1\":1,\"zero\":0}";
fn cpuParse(comptime T: type, comptime input: []const u8, comptime Format: type) BenchFn {
    return struct {
        fn run(_: Allocator) !usize {
            _ = cpu_arena.reset(.retain_capacity);
            const value = try Format.fromSlice(T, cpu_arena.allocator(), input);
            std.mem.doNotOptimizeAway(value);
            return input.len;
        }
    }.run;
}
fn cpuStringSerialize(comptime value: []const u8) BenchFn {
    return struct {
        fn run(_: Allocator) !usize {
            var buffer: [128 * 1024]u8 = undefined;
            var writer: compat.Io.Writer = .fixed(&buffer);
            try serde.json.toWriter(&writer, StringDocument{ .text = value });
            std.mem.doNotOptimizeAway(buffer[0..writer.end]);
            return writer.end;
        }
    }.run;
}
fn opNdjsonCpu(_: Allocator) !usize {
    _ = cpu_arena.reset(.retain_capacity);
    var reader: compat.Io.Reader = .fixed(large_ndjson);
    var stream = serde.helpers.StreamingDeserializer(Row).init(cpu_arena.allocator(), &reader);
    defer stream.deinit();
    while (try stream.next()) |row| std.mem.doNotOptimizeAway(row);
    return large_ndjson.len;
}
fn opMsgpackCpu(_: Allocator) !usize {
    _ = cpu_arena.reset(.retain_capacity);
    const value = try serde.msgpack.fromSlice(Nested, cpu_arena.allocator(), msgpack_input);
    std.mem.doNotOptimizeAway(value);
    return msgpack_input.len;
}
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
    min_ns_per_op: f64,
    max_ns_per_op: f64,
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
        std.debug.print("unsupported -Dbench-format='{s}', expected text or json\n", .{options.format});
        return error.InvalidArgument;
    };

    var results: std.ArrayList(BenchResult) = .empty;
    defer results.deinit(gpa);

    msgpack_input = try serde.msgpack.toSlice(gpa, nested_value);
    defer gpa.free(msgpack_input);
    prepared_map = std.StringHashMap(u32).init(gpa);
    defer prepared_map.deinit();
    try prepared_map.put("alpha", 1);
    try prepared_map.put("bravo", 2);
    try prepared_map.put("charlie", 3);
    try prepared_map.put("delta", 4);
    defer cpu_arena.deinit();
    try runAll(gpa, &results);
    if (options.baseline.len != 0) try applyBaseline(gpa, results.items, options.baseline, options.threshold_percent);

    const rendered = switch (format) {
        .text => try renderText(gpa, results.items),
        .json => try renderJson(gpa, results.items),
    };
    defer gpa.free(rendered);

    try compat.writeStdout(rendered);
    if (options.out.len != 0) {
        try compat.writeFile(options.out, rendered);
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
    const warmup_iters: usize = if (bench.mode != .cold) 20 else 1;
    for (0..warmup_iters) |_| {
        _ = try bench.run(std.heap.smp_allocator);
    }

    var probe_alloc = CountingAllocator{ .child = std.heap.smp_allocator };
    const probe_start = nowNs();
    const probe_size = try bench.run(probe_alloc.allocator());
    const probe_ns = @max(nowNs() - probe_start, 1);

    const target_ns: u64 = if (bench.mode != .cold) 150 * std.time.ns_per_ms else 50 * std.time.ns_per_ms;
    var iterations: usize = @intCast(@max(@as(u64, 1), target_ns / probe_ns));
    const max_iterations: usize = if (bench.mode == .cpu) 10_000_000 else if (bench.mode == .warm) 1_000_000 else 100_000;
    const min_iterations: usize = if (bench.mode != .cold) 20 else 5;
    iterations = @min(iterations, max_iterations);
    iterations = @max(iterations, min_iterations);

    // Count allocations separately: allocator instrumentation is not timed.
    var counting = CountingAllocator{ .child = std.heap.smp_allocator };
    const output_size = try bench.run(counting.allocator());
    var samples: [7]f64 = undefined;
    for (&samples) |*sample| {
        const start_ns = nowNs();
        for (0..iterations) |_| {
            const size = try bench.run(std.heap.smp_allocator);
            std.mem.doNotOptimizeAway(size);
        }
        sample.* = @as(f64, @floatFromInt(@max(nowNs() - start_ns, 1))) / @as(f64, @floatFromInt(iterations));
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    const ns_per_op = samples[3];
    const bytes_per_op: f64 = @floatFromInt(if (std.mem.eql(u8, bench.operation, "serialize")) output_size else if (std.mem.eql(u8, bench.format, "msgpack")) msgpack_input.len else bench.input_bytes);
    const throughput = bytes_per_op / ns_per_op * std.time.ns_per_s / (1024.0 * 1024.0);
    std.mem.doNotOptimizeAway(probe_size);

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
        .min_ns_per_op = samples[0],
        .max_ns_per_op = samples[6],
        .allocations_per_op = @floatFromInt(counting.allocations),
        .bytes_allocated_per_op = @floatFromInt(counting.bytes_allocated),
        .throughput_mb_s = throughput,
        .output_size_bytes = @floatFromInt(output_size),
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
    const out = try serde.json.toSlice(allocator, prepared_map);
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const typed = try serde.json.fromValue(Nested, arena.allocator(), value);
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

fn opJsonLongPlainDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(StringDocument, arena.allocator(), &long_plain_json);
    std.mem.doNotOptimizeAway(value.text.ptr);
    return long_plain_json.len;
}

fn opJsonLongPlainBorrowedDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSliceBorrowed(StringDocument, arena.allocator(), &long_plain_json);
    std.mem.doNotOptimizeAway(value.text.ptr);
    return long_plain_json.len;
}

fn opJsonLongEscapedDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(StringDocument, arena.allocator(), &long_escaped_json);
    std.mem.doNotOptimizeAway(value.text.ptr);
    return long_escaped_json.len;
}

fn opJsonLongSparseEscapedDeserialize(allocator: Allocator) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = try serde.json.fromSlice(StringDocument, arena.allocator(), &long_sparse_escaped_json);
    std.mem.doNotOptimizeAway(value.text.ptr);
    return long_sparse_escaped_json.len;
}

fn opMsgpackSerialize(allocator: Allocator) !usize {
    const out = try serde.msgpack.toSlice(allocator, nested_value);
    defer allocator.free(out);
    return out.len;
}

fn opMsgpackDeserialize(allocator: Allocator) !usize {
    const bytes = msgpack_input;
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
    var reader: compat.Io.Reader = .fixed(large_ndjson);
    var stream = serde.helpers.StreamingDeserializer(Row).init(arena.allocator(), &reader);
    defer stream.deinit();
    var count: usize = 0;
    while (try stream.next()) |row| {
        std.mem.doNotOptimizeAway(row);
        count += 1;
    }
    std.mem.doNotOptimizeAway(count);
    return large_ndjson.len;
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

fn opJsonFlatCpu(allocator: Allocator) !usize {
    _ = allocator;
    _ = cpu_arena.reset(.retain_capacity);
    const value = try serde.json.fromSlice(Flat, cpu_arena.allocator(), flat_json);
    std.mem.doNotOptimizeAway(value);
    return flat_json.len;
}

fn opJsonWriterCpu(_: Allocator) !usize {
    var buf: [1024]u8 = undefined;
    var writer: compat.Io.Writer = .fixed(&buf);
    try serde.json.toWriter(&writer, flat_value);
    std.mem.doNotOptimizeAway(buf);
    return writer.end;
}

const benchmarks = [_]Benchmark{
    .{ .id = "json.wide64.deserialize.serde.cpu", .format = "json", .case_name = "wide64", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = wide64_json.len, .key_case = true, .run = cpuParse(Wide64, wide64_json, serde.json) },
    .{ .id = "json.wide.deserialize.serde.cpu", .format = "json", .case_name = "wide", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = (wide_json).len, .key_case = true, .run = cpuParse(Wide, wide_json, serde.json) },
    .{ .id = "json.wide_shuffled_alias.deserialize.serde.cpu", .format = "json", .case_name = "wide_shuffled_alias", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = (wide_shuffled_json).len, .key_case = true, .run = cpuParse(Wide, wide_shuffled_json, serde.json) },
    .{ .id = "json.nested.deserialize.serde.cpu", .format = "json", .case_name = "nested", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = (nested_json).len, .key_case = true, .run = cpuParse(Nested, nested_json, serde.json) },
    .{ .id = "json.array_struct.deserialize.serde.cpu", .format = "json", .case_name = "array_struct", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = (rows_json).len, .key_case = true, .run = cpuParse([]const Row, rows_json, serde.json) },
    .{ .id = "json.long_plain.serialize.serde.cpu", .format = "json", .case_name = "long_plain", .operation = "serialize", .implementation = "serde", .mode = .cpu, .input_bytes = 16384, .key_case = true, .run = cpuStringSerialize((&long_plain_json)[9 .. long_plain_json.len - 2]) },
    .{ .id = "json.long_sparse_escaped.serialize.serde.cpu", .format = "json", .case_name = "long_sparse_escaped", .operation = "serialize", .implementation = "serde", .mode = .cpu, .input_bytes = 16512, .key_case = true, .run = cpuStringSerialize(&long_sparse_text) },
    .{ .id = "json.long_plain.deserialize.serde.cpu", .format = "json", .case_name = "long_plain", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = (&long_plain_json).len, .key_case = true, .run = cpuParse(StringDocument, &long_plain_json, serde.json) },
    .{ .id = "json.long_escaped.deserialize.serde.cpu", .format = "json", .case_name = "long_escaped", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = (&long_escaped_json).len, .key_case = true, .run = cpuParse(StringDocument, &long_escaped_json, serde.json) },
    .{ .id = "json.long_sparse_escaped.deserialize.serde.cpu", .format = "json", .case_name = "long_sparse_escaped", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = (&long_sparse_escaped_json).len, .key_case = true, .run = cpuParse(StringDocument, &long_sparse_escaped_json, serde.json) },
    .{ .id = "json.nested_collections.deserialize.serde.cpu", .format = "json", .case_name = "nested_collections", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = ("[[1,2,3],[4,5,6],[7,8,9]]").len, .key_case = true, .run = cpuParse([]const []const i32, "[[1,2,3],[4,5,6],[7,8,9]]", serde.json) },
    .{ .id = "ndjson.nested.deserialize.serde.cpu", .format = "ndjson", .case_name = "nested", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = large_ndjson.len, .key_case = true, .run = opNdjsonCpu },
    .{ .id = "msgpack.nested.deserialize.serde.cpu", .format = "msgpack", .case_name = "nested", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = 0, .key_case = true, .run = opMsgpackCpu },

    .{ .id = "json.flat.deserialize.serde.cpu", .format = "json", .case_name = "flat_struct", .operation = "deserialize", .implementation = "serde", .mode = .cpu, .input_bytes = flat_json.len, .key_case = true, .run = opJsonFlatCpu },
    .{ .id = "json.flat.serialize.serde.cpu", .format = "json", .case_name = "flat_struct", .operation = "serialize", .implementation = "serde", .mode = .cpu, .input_bytes = flat_json.len, .key_case = true, .run = opJsonWriterCpu },
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
    .{ .id = "json.long_plain.deserialize.serde.warm", .format = "json", .case_name = "long_plain", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = long_plain_json.len, .key_case = true, .run = opJsonLongPlainDeserialize },
    .{ .id = "json.long_plain_borrowed.deserialize.serde.warm", .format = "json", .case_name = "long_plain_borrowed", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = long_plain_json.len, .key_case = true, .run = opJsonLongPlainBorrowedDeserialize },
    .{ .id = "json.long_escaped.deserialize.serde.warm", .format = "json", .case_name = "long_escaped", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = long_escaped_json.len, .key_case = true, .run = opJsonLongEscapedDeserialize },
    .{ .id = "json.long_sparse_escaped.deserialize.serde.warm", .format = "json", .case_name = "long_sparse_escaped", .operation = "deserialize", .implementation = "serde", .mode = .warm, .input_bytes = long_sparse_escaped_json.len, .key_case = true, .run = opJsonLongSparseEscapedDeserialize },

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
    try aw.writer.writeAll("{\"schema_version\":3,\"allocator\":\"smp\",\"results\":[");
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
        try aw.writer.print(",\"samples\":7,\"min_ns_per_op\":{d:.3},\"max_ns_per_op\":{d:.3}", .{ result.min_ns_per_op, result.max_ns_per_op });
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

const Baseline = struct {
    schema_version: u32,
    allocator: []const u8,
    results: []const struct {
        id: []const u8,
        implementation: []const u8,
        zig_version: []const u8,
        target: []const u8,
        optimize: []const u8,
        ns_per_op: f64,
    },
};
fn parseBaseline(allocator: Allocator, bytes: []const u8) !std.json.Parsed(Baseline) {
    const parsed = std.json.parseFromSlice(Baseline, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.IncompatibleBaseline;
    errdefer parsed.deinit();
    if (parsed.value.schema_version != 3 or !std.mem.eql(u8, parsed.value.allocator, "smp")) return error.IncompatibleBaseline;
    for (parsed.value.results) |old| {
        if (!std.mem.eql(u8, old.zig_version, builtin.zig_version_string) or
            !std.mem.eql(u8, old.target, @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag)) or
            !std.mem.eql(u8, old.optimize, @tagName(builtin.mode)) or
            !std.math.isFinite(old.ns_per_op) or old.ns_per_op <= 0) return error.IncompatibleBaseline;
    }
    return parsed;
}
fn applyBaseline(allocator: Allocator, results: []BenchResult, baseline_path: []const u8, threshold_percent: f64) !void {
    const baseline = try compat.readFileAlloc(allocator, baseline_path, 10 * 1024 * 1024);
    defer allocator.free(baseline);
    const parsed = try parseBaseline(allocator, baseline);
    defer parsed.deinit();
    for (results) |*result| {
        for (parsed.value.results) |old| {
            if (!std.mem.eql(u8, old.id, result.id) or !std.mem.eql(u8, old.implementation, result.implementation)) continue;
            const pct = ((result.ns_per_op - old.ns_per_op) / old.ns_per_op) * 100.0;
            result.regression_percent = pct;
            result.regression_over_threshold = result.key_case and pct > threshold_percent;
            break;
        }
    }
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

test "baseline rejects missing and incompatible metadata" {
    try std.testing.expectError(error.IncompatibleBaseline, parseBaseline(std.testing.allocator, "{}"));
    try std.testing.expectError(error.IncompatibleBaseline, parseBaseline(std.testing.allocator, "{\"schema_version\":1,\"results\":[]}"));
    const empty = try parseBaseline(std.testing.allocator, "{ \"schema_version\": 3, \"allocator\": \"smp\", \"results\": [] }");
    defer empty.deinit();
}
