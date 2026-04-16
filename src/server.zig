const std = @import("std");
const mem = std.mem;
const Child = std.process.Child;
const os = std.os;

pub fn spawn(gpa: mem.Allocator, io: std.Io, nvim_exe: ?[]const u8, args: []const ?[*:0]const u8, stdin_fd: ?i32) !std.process.Child {
    //const argv = &[_][]const u8{ "nvim", "--embed" };
    const base_argv = &[_][]const u8{ nvim_exe orelse "nvim", "--embed" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, base_argv);
    for (args) |arg| {
        try argv.append(gpa, mem.span(arg.?));
    }

    if (stdin_fd) |_| unreachable;
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stdin = .pipe,
        .stderr = .inherit,
        // .bonus_fd = stdin_fd;
    });

    return child;
}
