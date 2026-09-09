const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("serde", .{ .target = target, .optimize = optimize });
    const module = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    module.addImport("serde", dependency.module("serde"));
    const tests = b.addTest(.{ .root_module = module });
    const run = b.addRunArtifact(tests);
    b.step("test", "Test the public serde integration").dependOn(&run.step);
}
