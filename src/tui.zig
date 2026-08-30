const std = @import("std");
const RPC = @import("RPC.zig");
const UIState = @import("UIState.zig");
const mpack = @import("mpack.zig");
const server = @import("server.zig");
const Parser = @import("vaxis/Parser.zig");
const ctlseqs = struct {
    pub const home = "\x1b[H";
    pub const cup = "\x1b[{d};{d}H";
    pub const sgr_reset = "\x1b[m";
    pub const erase_below_cursor = "\x1b[J";
    pub const set_cursor_style = "\x1b[{d} q";
    pub const to_status_line = "\x1b]0;";
    pub const from_status_line = "\x07";
};
const log = std.log.scoped(.tui);
const dbg = log.debug;

var is_noisy = false;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!is_noisy) return;
    std.log.defaultLog(level, scope, format, args);
}
pub const std_options: std.Options = .{ .logFn = logFn };

const RowDamage = struct {
    start: u32,
    end: u32,
};

const TUI = @This();

io: std.Io,
gpa: std.mem.Allocator,
parser: Parser,
child: std.process.Child = undefined,
winsize: std.posix.winsize,
tty_fd: std.posix.fd_t,

screen_damage: []RowDamage = undefined, // always winsize.row

// TODO: reconsider this:
enc_buf: std.Io.Writer.Allocating,
tick: usize = 0,

// buf only for cell rendering. high prio messages might be sent directly
// or use another buf
render: struct {
    buf: std.Io.Writer.Allocating,
    // this is the position emitting buf would take you to. might
    // want another for "assumed start position"
    pos_r: u32 = 0,
    pos_c: u32 = 0,
    attr_id: ?u32 = null,
    const Render = @This();

    pub fn print(self: *Render, comptime fmt: []const u8, vals: anytype) !void {
        try self.buf.writer.print(fmt, vals);
    }
    pub fn put(self: *Render, str: []const u8) !void {
        try self.buf.writer.writeAll(str);
    }

    pub fn cup(self: *Render, row: u32, col: u32) !void {
        try self.print(ctlseqs.cup, .{ row + 1, col + 1 });
    }
},

tty_state: struct {
    cursor_shape: ?UIState.CursorShape = .block,
    mouse_reporting: bool = false,
} = .{},

decoder: mpack.SkipDecoder = undefined,
rpc: RPC,
tty_writer: *std.Io.Writer,

var pending_winch: bool = false;
var winch_pipe: std.posix.fd_t = undefined;

fn makeRawTTY(fd: std.posix.fd_t) !std.posix.termios {
    const state = try std.posix.tcgetattr(fd);
    var raw = state;
    // see termios(3)
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;

    raw.oflag.OPOST = false;

    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;

    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;

    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .FLUSH, raw);
    return state;
}

/// Get the window size from the kernel
pub fn getWinsize(fd: std.posix.fd_t) !std.posix.winsize {
    var winsize = std.posix.winsize{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };

    const err = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) == .SUCCESS) return winsize;
    return error.IoctlError;
}

fn handleWinch(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*const anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx_ptr;
    if (pending_winch == false) {
        pending_winch = true;
        _ = std.posix.system.write(winch_pipe, " ", 1);
    }
}

pub fn setWinchHandler() !void {
    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = handleWinch },
        .mask = switch (@import("builtin").os.tag) {
            .macos => 0,
            else => std.posix.sigemptyset(),
        },
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
}

fn clear_damage(self: *TUI) void {
    @memset(self.screen_damage, .{ .start = 0x8FFFFFFF, .end = 0 });
}

fn mark_damaged(self: *TUI, top: u32, bot: u32, left: u32, right: u32) void {
    for (top..bot) |row| {
        if (row < self.screen_damage.len) {
            const wi = &self.screen_damage[row];
            wi.start = @min(wi.start, left);
            wi.end = @max(wi.end, right);
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var mega_buffer: [512]u8 = undefined;

    var nvim: ?[]const u8 = null;
    var argv_rest = init.minimal.args.vector[1..];

    var multigrid = false;

    while (argv_rest.len > 0) {
        const try_arg = std.mem.span(argv_rest[0]);
        if (!(try_arg.len >= 6 and std.mem.eql(u8, try_arg[0..6], "--tui-"))) {
            break;
        }
        argv_rest = argv_rest[1..];
        const rest = try_arg[6..];
        if (std.mem.eql(u8, rest, "noisy")) {
            is_noisy = true;
        } else if (std.mem.eql(u8, rest, "multigrid")) {
            multigrid = true;
        } else {
            std.debug.print("unknown arg: {s}\n", .{try_arg});
            return 1;
        }
    }

    const tty_fd = 0; // fubbit, do the full fd and /dev/tty dance

    const termios = try makeRawTTY(tty_fd);
    defer std.posix.tcsetattr(tty_fd, .FLUSH, termios) catch |err| dbg("couldn't restore terminal: {}", .{err});

    const tty_read: std.Io.File = .{ .handle = tty_fd, .flags = .{ .nonblocking = false } };
    const tty_write: std.Io.File = .{ .handle = tty_fd, .flags = .{ .nonblocking = false } };
    var writer = tty_write.writerStreaming(init.io, &mega_buffer);

    const winsize = (getWinsize(tty_fd)) catch std.posix.winsize{ .row = 25, .col = 80, .xpixel = 0, .ypixel = 0 };

    var self: TUI = .{
        .parser = .{},
        .rpc = try .init(gpa),
        .tty_writer = &writer.interface,
        .gpa = gpa,
        .io = init.io,
        .enc_buf = .init(gpa),
        .render = .{ .buf = .init(gpa) },
        .winsize = winsize,
        .tty_fd = tty_fd,
    };
    defer self.rpc.deinit();
    defer self.render.buf.deinit();
    defer self.enc_buf.deinit();

    self.screen_damage = try self.gpa.alloc(RowDamage, winsize.row);
    self.clear_damage();

    const pipa = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    winch_pipe = pipa[1]; // write end

    try setWinchHandler();

    try self.set_dec_mode(.alt_screen, true);
    defer {
        self.set_dec_mode(.alt_screen, false) catch {};
        self.tty_writer.flush() catch {};
    }

    // XX: decoder will be set with data when it is available
    self.decoder = mpack.SkipDecoder{ .data = undefined };

    if (argv_rest.len >= 2 and std.mem.eql(u8, std.mem.span(argv_rest[0]), "--nvim")) {
        nvim = std.mem.span(argv_rest[1]);
        argv_rest = argv_rest[2..];
    }
    try self.attach(nvim, argv_rest, self.winsize.col, self.winsize.row, multigrid);
    const nvim_read: std.Io.File = self.child.stdout.?;

    const pipa_read: std.Io.File = .{ .handle = pipa[0], .flags = .{ .nonblocking = false } };

    // WOW they actually implemted something very useful: essentially
    // a mini-event loop which "just" tracks N fd:s and a resizing
    // buffer for each, GOOD JOB ZIG CORE DEVS:)
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(3) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, init.io, multi_reader_buffer.toStreams(), &.{ nvim_read, tty_read, pipa_read });
    defer multi_reader.deinit();

    const nvim_reader = multi_reader.reader(0);
    const tty_reader = multi_reader.reader(1);
    const pipa_reader = multi_reader.reader(2);
    const nvim_context = &multi_reader.streams.contexts()[0];

    var tty_available_last: usize = 0;
    var nvim_available_last: usize = 0;
    while (multi_reader.fill(256, .none)) |_| {
        const nvim_buffered = nvim_reader.buffered();
        if (nvim_buffered.len > nvim_available_last) {
            const read = self.nvimReadCb(nvim_buffered);
            nvim_reader.toss(read);
            nvim_available_last = nvim_reader.bufferedLen();
        }
        if (if (nvim_context.err) |e| e == error.EndOfStream else false) {
            // NVIM EOF
            break;
        }

        const tty_buffered = tty_reader.buffered();
        if (tty_buffered.len > tty_available_last) {
            const read = try self.ttyReadCb(tty_buffered);
            tty_reader.toss(read);
            tty_available_last = tty_reader.bufferedLen();
        }

        // TODO: do something smart, like allow multi_reader.fill() to be interuppted by
        // a signal (it is possible but then it fails on the next fill() )
        const pipa_buffered = pipa_reader.buffered();
        if (pipa_buffered.len > 0) {
            pipa_reader.toss(pipa_buffered.len);
        }

        if (pending_winch) {
            // XXX: this is a bit of a hack. preferably the event loop should natively
            // handle signals as events
            pending_winch = false;
            try self.checkResize();
        }
    } else |err| {
        // TODO;
        return err;
    }
    if (self.tty_state.mouse_reporting) {
        try self.set_mouse(false);
    }

    return 0;
}

fn ttyReadCb(
    self: *TUI,
    buf: []const u8,
) !usize {
    var seq_start: usize = 0;
    while (seq_start < buf.len) {
        const result = self.parser.parse(buf[seq_start..buf.len], undefined) catch {
            log.err("??parser panik\r\n", .{});
            return error.PANIK;
        };
        if (result.n == 0) {
            // cannot parse more, return how much we consumed
            return seq_start;
        }
        seq_start += result.n;

        const event = result.event orelse continue;

        // TODO: handle errors on input flooding?
        try self.handleEvent(event);
    }

    if (false and buf.size > 0 and buf[0] == 3) {
        self.loop.stop();
        return .disarm;
    }

    return seq_start;
}

fn handleEvent(self: *TUI, event: Parser.Event) !void {
    switch (event) {
        .key_press => |k| {
            try self.handleKeyPress(k);
            try self.flush_input();
        },
        .mouse => |m| {
            try self.handleMouse(m);
            try self.flush_input();
        },
        else => dbg("event {}\r\n", .{event}),
    }
}

fn handleKeyPress(self: *TUI, k: Parser.Key) !void {
    const Key = Parser.Key;
    if (k.text) |text| {
        try self.enqueueInput(text);
    } else if (k.codepoint < 32) {
        try self.enqueueInput(&.{@intCast(k.codepoint)});
    } else if (k.codepoint >= 127) {
        const string = switch (k.codepoint) {
            127 => "bs",
            Key.left => "Left",
            Key.right => "Right",
            Key.up => "Up",
            Key.down => "Down",
            Key.page_up => "PageUp",
            Key.page_down => "PageDown",
            Key.home => "Home",
            Key.end => "End",
            Key.f1 => "F1",
            Key.f2 => "F2",
            Key.f3 => "F3",
            Key.f4 => "F4",
            Key.f5 => "F5",
            Key.f6 => "F6",
            Key.f7 => "F7",
            Key.f8 => "F8",
            Key.f9 => "F9",
            Key.f10 => "F10",
            else => null,
        };
        if (string) |s| {
            const ctrl = if (k.mods.ctrl) "C-" else "";
            const shift = if (k.mods.shift) "S-" else "";
            const alt = if (k.mods.alt) "A-" else "";
            var buf: [128]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "<{s}{s}{s}{s}>", .{ ctrl, shift, alt, s }) catch unreachable;
            try self.enqueueInput(key);
        } else dbg("keypress {}", .{k});
    } else if (k.mods.ctrl == true and k.mods.alt == false and k.codepoint >= 'a' and k.codepoint <= 'z') {
        try self.enqueueInput(&.{@intCast(k.codepoint - 'a' + 1)});
    } else {
        dbg("keypress {}", .{k});
    }
}

fn handleMouse(self: *TUI, m: Parser.Mouse) !void {
    var buf: [3]u8 = .{ 0, 0, 0 };
    var nmod: usize = 0;
    if (m.mods.ctrl) {
        buf[nmod] = 'c';
        nmod += 1;
    }
    if (m.mods.alt) {
        buf[nmod] = 'a';
        nmod += 1;
    }
    if (m.mods.shift) {
        buf[nmod] = 's';
        nmod += 1;
    }
    const mod = buf[0..nmod];
    dbg("moous {} blev '{s}'", .{ m, mod });
    switch (m.button) {
        .left, .middle, .right => {
            if (m.type != .motion) {
                const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
                try RPC.nvim_input_mouse(encoder, @tagName(m.button), @tagName(m.type), mod, 1, m.row, m.col);
            }
        },
        .wheel_up, .wheel_down, .wheel_right, .wheel_left => {
            if (m.type == .press) {
                const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
                try RPC.nvim_input_mouse(encoder, "wheel", @tagName(m.button)[6..], mod, 1, m.row, m.col);
            }
        },
        else => {},
    }
}

fn attach(self: *TUI, nvim_exe: ?[]const u8, args: []const ?[*:0]const u8, width: u32, height: u32, multigrid: bool) !void {
    var the_fd: ?i32 = null;
    if (false) {
        the_fd = try std.posix.dup(0);
    }

    self.child = try server.spawn(self.gpa, self.io, nvim_exe, args, the_fd);

    const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
    try RPC.attach(encoder, width, height, if (the_fd) |_| @as(i32, 3) else null, multigrid);
    try self.flush_input();
}

fn flush_input(self: *TUI) !void {
    self.child.stdin.?.writeStreamingAll(self.io, self.enc_buf.writer.buffered()) catch |err| switch (err) {
        error.BrokenPipe => {
            // Nvim exited. we will handle this later
            @panic("handle nvim exit somehowe reasonable");
        },
        else => |e| return e,
    };
    _ = self.enc_buf.writer.consumeAll();
}

fn enqueueInput(self: *TUI, str: []const u8) !void {
    // dbg("aha: {s}\n", .{str});
    const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
    try RPC.nvim_input(encoder, str);
}

fn checkResize(self: *TUI) !void {
    const new_size = try getWinsize(self.tty_fd);
    if (new_size.row != self.winsize.row or new_size.col != self.winsize.col) {
        const new_row = new_size.row != self.winsize.row;
        self.winsize = new_size;

        if (new_row) {
            self.gpa.free(self.screen_damage);
            self.screen_damage = try self.gpa.alloc(RowDamage, new_size.row);
            self.clear_damage();
        }
        const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
        try RPC.nvim_ui_try_resize_grid(encoder, 1, self.winsize.col, self.winsize.row);
        try self.flush_input();
    }
}

fn nvimReadCb(self: *TUI, buf: []const u8) usize {
    self.decoder.data = buf;
    self.rpc.process(&self.decoder) catch @panic("go crazy yea");
    // TODO: this is a little messy. rework mpack.SkipDecoder to work nicely with
    // std.Io.Reader style buffering
    const consumed = buf.len - self.decoder.data.len;
    self.decoder.data = undefined;

    return consumed;
}

pub fn attr_slice(self: *TUI, id: u32) []const u8 {
    if (id > 0 and id < self.rpc.ui.attrs.items.len) {
        // TODO: cached slices are still cool, but we should build them using vaxis
        const islice = self.rpc.ui.attrs.items[id];
        return self.rpc.ui.attr_arena.items[islice.start..islice.end];
    }
    return ctlseqs.sgr_reset;
}

pub fn cb_grid_info(self: *TUI, grid_id: u32, grid: *UIState.Grid, old_info: UIState.GridInfo, old_off_r: u32, old_off_c: u32) !void {
    dbg("HOW DARE YOU: {} changed from {s} to {s}", .{ grid_id, @tagName(old_info), @tagName(grid.info) });
    switch (grid.info) {
        .float => |fi| dbg("{} at (r={} c={})", .{ fi, grid.off_r, grid.off_c }),
        else => {},
    }
    const moved = grid.off_r != old_off_r or grid.off_c != old_off_c;

    switch (old_info) {
        .float => if (grid.info != .float or moved) {
            // TODO: rethink this, if we throttle updates to cb_flush we know the new grid size for floats.
            self.mark_damaged(old_off_r, old_off_r + grid.rows, old_off_c, old_off_c + grid.cols);
        },
        .window => |wi| {
            if (moved) {
                self.mark_damaged(old_off_r, old_off_r + wi.height, old_off_c, old_off_c + wi.width);
            } else if (grid.info == .window) {
                // see TODO above, this is the common case for demo purposes
                const new_info = grid.info.window;
                if (wi.height > new_info.height) {
                    self.mark_damaged(old_off_r + new_info.height, old_off_r + wi.height, old_off_c, old_off_c + wi.width);
                }
                if (wi.width > new_info.width) {
                    self.mark_damaged(old_off_r, old_off_r + wi.height, old_off_c + new_info.width, old_off_c + wi.width);
                }
            }
        },
        .none => {},
    }

    if (old_info != .none and moved) {
        dbg("did a move so: [{} {}] with cols [{} {}]", .{ grid.off_r, grid.off_r + grid.rows, grid.off_c, grid.off_c + grid.cols });
        self.mark_damaged(grid.off_r, grid.off_r + grid.rows, grid.off_c, grid.off_c + grid.cols);
    }
}

pub fn cb_grid_clear(self: *TUI, grid_id: u32) !void {
    _ = self.render.buf.writer.consumeAll();
    // NB: clear in multigrid mode is HIDEOUS. it will be fixed
    // by fixing the statusline issue
    if (grid_id != 1) return;

    try self.render.put(ctlseqs.home ++ ctlseqs.erase_below_cursor);
    self.render.pos_r = 0;
    self.render.pos_c = 0;

    @memset(self.screen_damage, .{ .start = 0, .end = self.winsize.col });
}

const csr = "\x1b[{};{}r";
// TODO: safe to just ENTER 69 on startup (restore on exit);
const enter_lrmm = "\x1b[?69h";
const exit_lrmm = "\x1b[?69l";
const smglr = "\x1b[{};{}s";

fn covered(self: *TUI, g: *UIState.Grid) bool {
    var it = self.rpc.ui.grids.iterator();
    while (it.next()) |e| {
        const gi = e.value_ptr;
        switch (gi.info) {
            .float => |fi| {
                if (g.info != .float or g.info.float.compindex < fi.compindex) {
                    if (g.off_r + g.rows > gi.off_r and gi.off_r + gi.rows > g.off_r and
                        g.off_c + g.cols > gi.off_c and gi.off_c + gi.cols > g.off_c)
                    {
                        // TODO: check intersection with scroll region like ui_compositor.c does
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

pub fn cb_grid_scroll(self: *TUI, grid_id: u32, top_i: u32, bot_i: u32, left_i: u32, right_i: u32, rows: i32) !void {
    dbg("scrollen {}: {}-{} X {}-{} delta {}", .{ grid_id, top_i, bot_i, left_i, right_i, rows });
    const g = self.rpc.ui.grid(grid_id) orelse return;
    const render = &self.render;
    const top_bot = true;

    const top, const bot = .{ g.off_r + top_i, g.off_r + bot_i };
    const left, const right = .{ g.off_c + left_i, g.off_c + right_i };

    const left_right = left > 0 or right < self.winsize.col;

    const cover = self.covered(g);
    dbg("was COVERD: {}", .{cover});

    if (cover) {
        self.mark_damaged(top, bot, left, right);
        return;
    }

    if (top_bot) {
        try render.print(csr, .{ top + 1, bot });
    }
    if (left_right) {
        try render.print(enter_lrmm ++ smglr, .{ left + 1, right });
    }
    try render.cup(top, left);
    try render.put(ctlseqs.sgr_reset);
    if (rows > 0) {
        try render.print("\x1b[{}M", .{rows});
    } else if (rows < 0) {
        try render.print("\x1b[{}L", .{-rows});
    }
    if (top_bot) {
        try render.put("\x1b[r");
    }
    if (left_right) {
        try render.put("\x1b[s" ++ exit_lrmm);
    }
    render.pos_r = invalid_fixme;
    render.pos_c = invalid_fixme;
}

const invalid_fixme = 0xFFFFFFFF;

// note: RPC callbacks happen in the nvim read callback. heavy work need to be scheduled..
pub fn cb_grid_line(self: *TUI, grid_id: u32, row_i: u32, start_col_i: u32, end_col_i: u32) !void {
    // dbg("boll: {} {}, {}-{}\n", .{ grid_id, row_i, start_col_i, end_col_i });
    // if (grid_id > 1) return;
    const ui = &self.rpc.ui;
    const g = ui.grid(grid_id) orelse return;

    const start_col = g.off_c + start_col_i;
    const end_col = g.off_c + end_col_i;
    const row = g.off_r + row_i;

    // TODO: we still might a directed rendering path for uncovered grids, so that the terminal
    // can start eat sequences is in parallell.
    if (row < self.screen_damage.len) {
        const wi = &self.screen_damage[row];
        wi.start = @min(wi.start, start_col);
        wi.end = @max(wi.end, end_col);
    }
}

pub fn cb_set_title(self: *TUI, title: []const u8) !void {
    const noise = if (is_noisy) "LOOK AT IT: " else "";
    try self.tty_writer.print("{s}{s}{s}{s}", .{ ctlseqs.to_status_line, noise, title, ctlseqs.from_status_line });
}

pub fn cb_flush(self: *TUI) !void {
    const ui = &self.rpc.ui;
    const tty = self.tty_writer;
    self.tick += 1;
    try tty.writeAll(ctlseqs.sgr_reset);

    for (0.., self.screen_damage) |i, d| {
        const safe_col = @min(d.end, self.winsize.col);
        if (safe_col > d.start) {
            try self.render_segment(@intCast(i), d.start, safe_col);
        }
    }
    self.clear_damage();
    // dbg("flish: {}\n", .{self.render.buf.writer.end});
    // TODO: want to use the writev trick just like in the C TUI
    try tty.writeAll(self.render.buf.writer.buffered());
    _ = self.render.buf.writer.consumeAll();

    // TODO: only if needed
    const c = ui.cursor;
    if (ui.grid(c.grid)) |g| {
        const c_row = g.off_r + c.row;
        const c_col = g.off_c + c.col;
        if (c_row != self.render.pos_r or c_col != self.render.pos_c) {
            try tty.print(ctlseqs.cup, .{ c_row + 1, c_col + 1 });
            self.render.pos_r = c_row;
            self.render.pos_c = c_col;
        }
    }

    const wanted_shape = ui.mode().cursor_shape;
    if (wanted_shape != self.tty_state.cursor_shape) {
        try tty.print(ctlseqs.set_cursor_style, .{@backingInt(wanted_shape) + 1});
        self.tty_state.cursor_shape = wanted_shape;
    }
    if (ui.mouse != self.tty_state.mouse_reporting) {
        try self.set_mouse(ui.mouse);
        self.tty_state.mouse_reporting = ui.mouse;
    }
    try tty.flush(); // dOn'T fORgEt To fLuSH
}

fn render_segment(self: *TUI, row: u32, start_col: u32, end_col: u32) !void {
    const render = &self.render;
    if (render.buf.writer.end == 0 or render.pos_r != row or render.pos_c != start_col) {
        try render.cup(row, start_col);
        render.pos_r = row;
    }
    var attr_id = render.attr_id;

    // dbg("segment {}: {} to {}", .{ row, start_col, end_col });

    var c = start_col;
    while (c < end_col) {
        var cur_base: ?*UIState.Grid = null;
        var cur_float: ?*UIState.Grid = null;
        var float_next = false;
        {
            var it = self.rpc.ui.grids.iterator();
            while (it.next()) |e| {
                const g = e.value_ptr;
                if (!(g.off_r <= row and row < g.off_r + g.rows)) {
                    continue;
                }
                const g_endc = g.off_c + g.cols;
                if (g.off_c <= c and c < g_endc) {
                    switch (g.info) {
                        .window => cur_base = g,
                        .float => |f| if (if (cur_float) |cf| f.compindex > cf.info.float.compindex else true) {
                            cur_float = g;
                        },
                        .none => {},
                    }
                } else if (g.off_c > c and g.info == .float) {
                    float_next = true;
                }
            }
        }

        const g = cur_float orelse cur_base orelse self.rpc.ui.grid(1).?;
        var end = @min(end_col, g.off_c + g.cols);
        if (float_next or cur_base == null) {
            var it = self.rpc.ui.grids.iterator();
            while (it.next()) |e| {
                const gi = e.value_ptr;
                if (!(gi.off_r <= row and row < gi.off_r + gi.rows)) {
                    continue;
                }
                if (gi.off_c > c) {
                    const splitting = switch (gi.info) {
                        .window => cur_base == null,
                        .float => |f| if (cur_float) |cf| f.compindex > cf.info.float.compindex else true,
                        .none => false,
                    };
                    if (splitting) end = @min(end, gi.off_c);
                }
            }
        }

        const basepos = (row - g.off_r) * g.cols;

        // dbg("subsegment {} to {}", .{ c, end });

        while (c < end) : (c += 1) {
            const cell = &g.cell.items[basepos + (c - g.off_c)];
            if (cell.attr_id != attr_id) {
                attr_id = cell.attr_id;
                try render.put(self.attr_slice(cell.attr_id));
            }
            try render.put(self.rpc.ui.text(cell));
        }
    }

    self.render.attr_id = attr_id;
    self.render.pos_r = end_col;
}

const DecMode = enum(u32) {
    mouse_button_event = 1002,
    mouse_sgr_ext = 1006,
    alt_screen = 1049,
    _,
};

fn set_dec_mode(self: *TUI, mode: DecMode, enabled: bool) !void {
    try self.tty_writer.print("\x1b[?{}{c}", .{ @backingInt(mode), @as(u8, if (enabled) 'h' else 'l') });
}

fn set_mouse(self: *TUI, enabled: bool) !void {
    try self.set_dec_mode(.mouse_button_event, enabled);
    try self.set_dec_mode(.mouse_sgr_ext, enabled);
}
