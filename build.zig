const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const serde_mod = b.addModule("serde", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");

    // Main library tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
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

    // Fuzz targets — build-only, no assertions. Compiled as static libraries
    // with the libFuzzer entry point for use with external fuzzers.
    const fuzz_step = b.step("fuzz", "Build fuzz targets");

    const fuzz_sources = [_][]const u8{
        "test/fuzz_json.zig",
        "test/fuzz_msgpack.zig",
        "test/fuzz_toml.zig",
        "test/fuzz_zon.zig",
        "test/fuzz_csv.zig",
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
}
