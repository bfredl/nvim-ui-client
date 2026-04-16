const std = @import("std");

pub fn build(b: *std.Build) !void {
    const t = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const io_test = b.step("io_test", "very basic");
    const io_test_exe = b.addExecutable(.{
        .name = "io_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/io_test.zig"),
            .optimize = opt,
            .target = t,
        }),
    });
    b.installArtifact(io_test_exe);
    const run_cmd = b.addRunArtifact(io_test_exe);
    io_test.dependOn(&run_cmd.step);
}
