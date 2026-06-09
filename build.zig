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
    const run_io_test = b.addRunArtifact(io_test_exe);
    io_test.dependOn(&run_io_test.step);

    const tui = b.step("tui", "more usable");
    const tui_exe = b.addExecutable(.{
        .name = "tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui.zig"),
            .optimize = opt,
            .target = t,
        }),
    });
    b.installArtifact(tui_exe);
    const run_tui = b.addRunArtifact(tui_exe);
    tui.dependOn(&run_tui.step);
    if (@hasField(std.Build, "args")) {
        if (b.args) |args| {
            run_tui.addArgs(args);
        }
    } else {
        run_tui.addPassthruArgs();
    }
}
