const std = @import("std");

pub fn build(b: *std.Build) !void {
    const t = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const tui = b.step("tui", "run the tui");
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
    run_tui.addPassthruArgs();
}
