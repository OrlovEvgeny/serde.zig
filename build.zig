const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const compat_source = switch (builtin.zig_version.minor) {
        15 => "src/compat.zig",
        16 => "src/compat_0_16.zig",
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
