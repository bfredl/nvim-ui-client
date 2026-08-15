const std = @import("std");
const ArrayList = std.ArrayList;
const mpack = @import("./mpack.zig");
const RPC = @import("./RPC.zig");

const server = @import("./server.zig");

rpc: RPC,
const IOTest = @This();

pub fn cb_grid_clear(self: *IOTest, grid: u32) !void {
    _ = self;
    std.debug.print("kireee: {} \n", .{grid});
}

pub fn cb_grid_line(self: *IOTest, grid: u32, row: u32, start_col: u32, end_col: u32) !void {
    _ = self;
    std.debug.print("boll: {} {}, {}-{}\n", .{ grid, row, start_col, end_col });
}

pub fn cb_grid_scroll(self: *IOTest, grid: u32, top: u32, bot: u32, left: u32, right: u32, rows: i32) !void {
    _ = self;
    std.debug.print("scrollen {}: {}-{} X {}-{} delta {}\n", .{ grid, top, bot, left, right, rows });
}

pub fn cb_flush(self: *IOTest) !void {
    self.rpc.ui.dump_grid(1);
    var it = self.rpc.ui.grids.iterator();
    while (it.next()) |e| {
        const g = e.key_ptr.*;
        const v = e.value_ptr;
        if (v.info != .none) {
            if (g != 1) self.rpc.ui.dump_grid(g);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv_rest = init.minimal.args.vector[1..];
    var child = try server.spawn(gpa, init.io, null, argv_rest, null);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    const encoder: mpack.Encoder = .init(&aw.writer);
    const multigrid = true;
    try RPC.attach(encoder, 80, 25, null, multigrid);

    var x = aw.toArrayList();
    defer x.deinit(gpa);

    try child.stdin.?.writeStreamingAll(init.io, x.items);

    try dummy_loop(init.io, &child.stdout.?, gpa);
}

fn dummy_loop(io: std.Io, stdout: anytype, allocator: std.mem.Allocator) !void {
    var buf: [1024]u8 = undefined;
    var decoder = mpack.SkipDecoder{ .data = buf[0..0] };
    var self: IOTest = .{ .rpc = try RPC.init(allocator) };

    while (true) {
        const oldlen = decoder.data.len;
        if (oldlen > 0 and decoder.data.ptr != &buf) {
            // TODO: avoid move if remaining space is plenty (like > 900)
            std.mem.copyForwards(u8, &buf, decoder.data);
        }
        const lenny = try stdout.readStreaming(io, &.{buf[oldlen..]});
        decoder.data = buf[0 .. oldlen + lenny];
        try self.rpc.process(&decoder);
    }
}
