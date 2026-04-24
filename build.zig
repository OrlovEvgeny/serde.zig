const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_config = parseBenchArgs(b);
    const compat_source = switch (builtin.zig_version.minor) {
        15 => "src/compat.zig",
        16...std.math.maxInt(u32) => "src/compat_0_16.zig",
        else => @compileError("unsupported Zig minor version"),
    };
    const compat_mod = b.createModule(.{
        .root_source_file = b.path(compat_source),
        .target = target,
        .optimize = optimize,
    });

    const serde_mod = b.addModule("serde", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    serde_mod.addImport("compat", compat_mod);

    const test_step = b.step("test", "Run all tests");

    // Main library tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("compat", compat_mod);
    const t = b.addTest(.{
        .root_module = test_mod,
    });
    const run = b.addRunArtifact(t);
    test_step.dependOn(&run.step);

    // Cross-format roundtrip tests.
    const roundtrip_mod = b.createModule(.{
        .root_source_file = b.path("test/roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "serde", .module = serde_mod },
        },
    });
    const roundtrip_t = b.addTest(.{
        .root_module = roundtrip_mod,
    });
    const roundtrip_run = b.addRunArtifact(roundtrip_t);
    test_step.dependOn(&roundtrip_run.step);

    // Additional test suites.
    const extra_test_sources = [_][]const u8{
        "test/stress_test.zig",
        "test/edge_cases_test.zig",
        "test/adversarial_test.zig",
        "test/serde_options_test.zig",
    };

    for (extra_test_sources) |src| {
        const mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "serde", .module = serde_mod },
            },
        });
        const extra_t = b.addTest(.{
            .root_module = mod,
        });
        const extra_run = b.addRunArtifact(extra_t);
        test_step.dependOn(&extra_run.step);
    }

    // Fuzz targets — build-only, no assertions. Compiled as static libraries
    // with the libFuzzer entry point for use with external fuzzers.
    const fuzz_step = b.step("fuzz", "Build fuzz targets");

    const fuzz_sources = [_][]const u8{
        "test/fuzz_json.zig",
        "test/fuzz_msgpack.zig",
        "test/fuzz_toml.zig",
        "test/fuzz_zon.zig",
        "test/fuzz_csv.zig",
        "test/fuzz_xml.zig",
        "test/fuzz_yaml.zig",
    };

    for (fuzz_sources) |src| {
        const fuzz_lib = b.addLibrary(.{
            .name = std.fs.path.stem(src),
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "serde", .module = serde_mod },
                },
            }),
        });
        fuzz_step.dependOn(&fuzz_lib.step);
    }

    // Performance benchmarks.
    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "format", bench_config.format);
    bench_options.addOption([]const u8, "filter", bench_config.filter);
    bench_options.addOption(bool, "compare_std_json", bench_config.compare_std_json);
    bench_options.addOption([]const u8, "baseline", bench_config.baseline);
    bench_options.addOption(f64, "threshold_percent", bench_config.threshold_percent);
    bench_options.addOption([]const u8, "out", bench_config.out);

    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Benchmark optimization mode",
    ) orelse .ReleaseFast;
    const bench_compat_mod = b.createModule(.{
        .root_source_file = b.path(compat_source),
        .target = target,
        .optimize = bench_optimize,
    });
    const serde_bench_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    serde_bench_mod.addImport("compat", bench_compat_mod);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = bench_optimize,
        .imports = &.{
            .{ .name = "serde", .module = serde_bench_mod },
            .{ .name = "bench_options", .module = bench_options.createModule() },
        },
    });
    const bench_exe = b.addExecutable(.{
        .name = "serde-bench",
        .root_module = bench_mod,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_run.step);

    const bench_test_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "serde", .module = serde_mod },
            .{ .name = "bench_options", .module = bench_options.createModule() },
        },
    });
    const bench_t = b.addTest(.{
        .root_module = bench_test_mod,
    });
    const bench_test_run = b.addRunArtifact(bench_t);
    test_step.dependOn(&bench_test_run.step);

    // Example programs.
    const examples_step = b.step("examples", "Build all examples");

    const example_sources = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "example-basic-json", .src = "examples/basic_json/main.zig" },
        .{ .name = "example-config-toml", .src = "examples/config_toml/main.zig" },
        .{ .name = "example-custom-types", .src = "examples/custom_types/main.zig" },
        .{ .name = "example-http-api", .src = "examples/http_api/main.zig" },
        .{ .name = "example-config-yaml", .src = "examples/config_yaml/main.zig" },
        .{ .name = "example-csv-pipeline", .src = "examples/csv_pipeline/main.zig" },
        .{ .name = "example-config-xml", .src = "examples/config_xml/main.zig" },
        .{ .name = "example-binary-interchange", .src = "examples/binary_interchange/main.zig" },
        .{ .name = "example-multi-format", .src = "examples/multi_format/main.zig" },
        .{ .name = "example-schema-override", .src = "examples/schema_override/main.zig" },
        .{ .name = "example-dynamic-value", .src = "examples/dynamic_value/main.zig" },
        .{ .name = "example-streaming-ndjson", .src = "examples/streaming_ndjson/main.zig" },
    };

    inline for (example_sources) |ex| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(ex.src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "serde", .module = serde_mod },
            },
        });
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = exe_mod,
        });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);

        const step = b.step(ex.name, "Run " ++ ex.src);
        const example_run = b.addRunArtifact(exe);
        step.dependOn(&example_run.step);
    }

    // Documentation generation.
    const docs_step = b.step("docs", "Generate autodocs");
    const docs_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    docs_mod.addImport("compat", compat_mod);
    const docs_lib = b.addLibrary(.{
        .name = "serde",
        .linkage = .static,
        .root_module = docs_mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);
}

const BenchConfig = struct {
    format: []const u8 = "text",
    filter: []const u8 = "",
    compare_std_json: bool = false,
    baseline: []const u8 = "",
    threshold_percent: f64 = 10.0,
    out: []const u8 = "",
};

fn parseBenchArgs(b: *std.Build) BenchConfig {
    var config = BenchConfig{};
    const args = b.args orelse return config;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= args.len) @panic("--format requires a value");
            config.format = b.dupe(args[i]);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= args.len) @panic("--filter requires a value");
            config.filter = b.dupe(args[i]);
        } else if (std.mem.eql(u8, arg, "--compare")) {
            i += 1;
            if (i >= args.len) @panic("--compare requires a value");
            if (std.mem.eql(u8, args[i], "std_json")) {
                config.compare_std_json = true;
            } else {
                @panic("unsupported --compare value; expected std_json");
            }
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            i += 1;
            if (i >= args.len) @panic("--baseline requires a value");
            config.baseline = b.dupe(args[i]);
        } else if (std.mem.eql(u8, arg, "--threshold")) {
            i += 1;
            if (i >= args.len) @panic("--threshold requires a value");
            config.threshold_percent = std.fmt.parseFloat(f64, args[i]) catch @panic("invalid --threshold value");
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) @panic("--out requires a value");
            config.out = b.dupe(args[i]);
        } else {
            @panic("unknown benchmark argument");
        }
    }
    return config;
}
