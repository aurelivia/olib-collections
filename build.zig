const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.addModule("root", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    const tests = b.addTest(.{ .root_module = root });
    const test_step = b.step("test", "test");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
