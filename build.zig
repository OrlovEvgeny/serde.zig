const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_config = parseBenchOptions(b);

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
        "test/core_regressions_test.zig",
        "test/stress_test.zig",
        "test/edge_cases_test.zig",
        "test/adversarial_test.zig",
        "test/serde_options_test.zig",
        "test/toon_test.zig",
        "test/etf_test.zig",
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
        "test/fuzz_toon.zig",
        "test/fuzz_etf.zig",
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

    // OTP 29 interoperability. The escript generates an authoritative corpus
    // with term_to_binary, invokes the Zig helper, then verifies Zig output
    // with binary_to_term. Erlang is intentionally only a test-time tool.
    const interop_step = b.step("interop", "Run Erlang/OTP 29 ETF interoperability checks");
    const interop_helper_mod = b.createModule(.{
        .root_source_file = b.path("test/etf_interop_helper.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "serde", .module = serde_mod },
            .{ .name = "compat", .module = compat_mod },
        },
    });
    const interop_helper = b.addExecutable(.{
        .name = "etf-interop-helper",
        .root_module = interop_helper_mod,
    });
    const interop_run = b.addSystemCommand(&.{ "escript", "test/etf_interop.escript" });
    interop_run.addFileArg(interop_helper.getEmittedBin());
    interop_step.dependOn(&interop_run.step);

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
    ) orelse if (@hasField(std.builtin.OptimizeMode, "fast")) .fast else .ReleaseFast;
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

fn parseBenchOptions(b: *std.Build) BenchConfig {
    var config = BenchConfig{};
    if (b.option([]const u8, "bench-format", "Benchmark output format: text or json (default: text)")) |v|
        config.format = v;
    if (b.option([]const u8, "bench-filter", "Only run benchmarks whose id/format/case/operation/implementation contains this substring")) |v|
        config.filter = v;
    if (b.option(bool, "bench-compare-std-json", "Also run std.json comparison benchmarks (default: false)")) |v|
        config.compare_std_json = v;
    if (b.option([]const u8, "bench-baseline", "Path to a baseline JSON file to compare results against")) |v|
        config.baseline = v;
    if (b.option(f64, "bench-threshold", "Regression threshold percent (default: 10.0)")) |v|
        config.threshold_percent = v;
    if (b.option([]const u8, "bench-out", "Write benchmark results JSON to this path")) |v|
        config.out = v;
    return config;
}
