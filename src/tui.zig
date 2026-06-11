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

const TUI = @This();

io: std.Io,
gpa: std.mem.Allocator,
parser: Parser,
child: std.process.Child = undefined,
winsize: std.posix.winsize,
tty_fd: std.posix.fd_t,

// TODO: reconsider this:
enc_buf: std.Io.Writer.Allocating,

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

    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
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
    pending_winch = true;
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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var mega_buffer: [512]u8 = undefined;

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

    try setWinchHandler();

    // try vx.enterAltScreen(ttyw);
    // defer vx.deinit(gpa, ttyw);

    // XX: encoder will be set with data when it is available
    self.decoder = mpack.SkipDecoder{ .data = undefined };

    var nvim: ?[]const u8 = null;
    var argv_rest = init.minimal.args.vector[1..];
    if (argv_rest.len >= 1 and std.mem.eql(u8, std.mem.span(argv_rest[0]), "--tui_noisy")) {
        is_noisy = true;
        argv_rest = argv_rest[1..];
    }
    if (argv_rest.len >= 2 and std.mem.eql(u8, std.mem.span(argv_rest[0]), "--nvim")) {
        nvim = std.mem.span(argv_rest[1]);
        argv_rest = argv_rest[2..];
    }
    try self.attach(nvim, argv_rest, self.winsize.col, self.winsize.row);
    const nvim_read: std.Io.File = self.child.stdout.?;

    // WOW they actually implemted something very useful: essentially
    // a mini-event loop which "just" tracks N fd:s and a resizing
    // buffer for each, GOOD JOB ZIG CORE DEVS:)
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, init.io, multi_reader_buffer.toStreams(), &.{ nvim_read, tty_read });
    defer multi_reader.deinit();

    const nvim_reader = multi_reader.reader(0);
    const tty_reader = multi_reader.reader(1);
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

        // too late but whatever
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
}

fn ttyReadCb(
    self: *TUI,
    buf: []const u8,
) !usize {
    // dbg("Nommm {}\r\n", .{n});
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

        switch (event) {
            .key_press => |k| {
                self.handleKeyPress(k);
                self.flush_input() catch @panic("RETURN TO SENDER");
            },
            .mouse => |m| {
                self.handleMouse(m);
                self.flush_input() catch @panic("YOU ARE NOW A NORMAL RAT");
            },
            else => dbg("event {}\r\n", .{event}),
        }
    }

    if (false and buf.size > 0 and buf[0] == 3) {
        self.loop.stop();
        return .disarm;
    }

    return seq_start;
}

fn handleKeyPress(self: *TUI, k: Parser.Key) void {
    const Key = Parser.Key;
    if (k.text) |text| {
        self.enqueueInput(text);
    } else if (k.codepoint < 32) {
        self.enqueueInput(&.{@intCast(k.codepoint)});
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
            self.enqueueInput(key);
        } else dbg("keypress {}", .{k});
    } else if (k.mods.ctrl == true and k.mods.alt == false and k.codepoint >= 'a' and k.codepoint <= 'z') {
        self.enqueueInput(&.{@intCast(k.codepoint - 'a' + 1)});
    } else {
        dbg("keypress {}", .{k});
    }
}

fn handleMouse(self: *TUI, m: Parser.Mouse) void {
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
                RPC.nvim_input_mouse(encoder, @tagName(m.button), @tagName(m.type), mod, 1, m.row, m.col) catch @panic("not cool");
            }
        },
        .wheel_up, .wheel_down, .wheel_right, .wheel_left => {
            if (m.type == .press) {
                const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
                RPC.nvim_input_mouse(encoder, "wheel", @tagName(m.button)[6..], mod, 1, m.row, m.col) catch @panic("not cool");
            }
        },
        else => {},
    }
}

fn attach(self: *TUI, nvim_exe: ?[]const u8, args: []const ?[*:0]const u8, width: u32, height: u32) !void {
    var the_fd: ?i32 = null;
    if (false) {
        the_fd = try std.posix.dup(0);
    }

    self.child = try server.spawn(self.gpa, self.io, nvim_exe, args, the_fd);

    const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
    try RPC.attach(encoder, width, height, if (the_fd) |_| @as(i32, 3) else null, false);
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

fn enqueueInput(self: *TUI, str: []const u8) void {
    // dbg("aha: {s}\n", .{str});
    const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
    RPC.nvim_input(encoder, str) catch @panic("memory error");
}

fn checkResize(self: *TUI) !void {
    const new_size = try getWinsize(self.tty_fd);
    if (new_size.row != self.winsize.row or new_size.col != self.winsize.col) {
        self.winsize = new_size;

        const encoder: mpack.Encoder = .init(&self.enc_buf.writer);
        RPC.nvim_ui_try_resize_grid(encoder, 1, self.winsize.col, self.winsize.row) catch @panic("memory error");
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

pub fn cb_grid_clear(self: *TUI, grid_id: u32) !void {
    _ = self.render.buf.writer.consumeAll();
    if (grid_id != 1) return;
    try self.render.put(ctlseqs.home ++ ctlseqs.erase_below_cursor);
    self.render.pos_r = 0;
    self.render.pos_c = 0;
}

const csr = "\x1b[{};{}r";
// TODO: safe to just ENTER 69 on startup (restore on exit);
const enter_lrmm = "\x1b[?69h";
const exit_lrmm = "\x1b[?69l";
const smglr = "\x1b[{};{}s";

fn grid(self: *TUI) ?*UIState.Grid {
    return self.rpc.ui.grid(1);
}

pub fn cb_grid_scroll(self: *TUI, grid_id: u32, top: u32, bot: u32, left: u32, right: u32, rows: i32) !void {
    dbg("scrollen {}: {}-{} X {}-{} delta {}\n", .{ grid_id, top, bot, left, right, rows });
    const g = self.grid() orelse return;
    const render = &self.render;
    const top_bot = true;
    const left_right = left > 0 or right < g.cols;

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
pub fn cb_grid_line(self: *TUI, grid_id: u32, row: u32, start_col: u32, end_col: u32) !void {
    // dbg("boll: {} {}, {}-{}\n", .{ grid_id, row, start_col, end_col });
    _ = grid_id;
    const render = &self.render;
    const ui = &self.rpc.ui;
    const g = ui.grid(1) orelse return;
    const basepos = row * g.cols;

    if (render.buf.writer.end == 0 or render.pos_r != row or render.pos_c != start_col) {
        try render.cup(row, start_col);
        render.pos_r = row;
    }

    var c = start_col;
    var attr_id = render.attr_id;
    while (c < end_col) : (c += 1) {
        const cell = &g.cell.items[basepos + c];
        if (cell.attr_id != attr_id) {
            attr_id = cell.attr_id;
            try render.put(self.attr_slice(cell.attr_id));
        }
        try render.put(ui.text(cell));
    }
    render.pos_c = c;
    render.attr_id = attr_id;

    // TODO: flow control. like check if cell buffer is almost full at the end of nvimReadCb ?
}

pub fn cb_flush(self: *TUI) !void {
    const ui = &self.rpc.ui;
    const tty = self.tty_writer;
    try tty.writeAll(ctlseqs.sgr_reset);
    // dbg("flish: {}\n", .{self.render.buf.writer.end});
    // TODO: want to use the writev trick just like in the C TUI
    try tty.writeAll(self.render.buf.writer.buffered());
    _ = self.render.buf.writer.consumeAll();

    // TODO: only if needed
    try tty.print(ctlseqs.cup, .{ ui.cursor.row + 1, ui.cursor.col + 1 });

    const wanted_shape = ui.mode().cursor_shape;
    if (wanted_shape != self.tty_state.cursor_shape) {
        try tty.print(ctlseqs.set_cursor_style, .{@intFromEnum(wanted_shape) + 1});
        self.tty_state.cursor_shape = wanted_shape;
    }
    if (ui.mouse != self.tty_state.mouse_reporting) {
        dbg("CRISIS THEORY: {}", .{ui.mouse});
        try self.set_dec_mode(.mouse_button_event, ui.mouse);
        try self.set_dec_mode(.mouse_sgr_ext, ui.mouse);
        self.tty_state.mouse_reporting = ui.mouse;
    }
    try tty.flush(); // dOn'T fORgEt To fLuSH
}

const DecMode = enum(u32) {
    mouse_button_event = 1002,
    mouse_sgr_ext = 1006,
    _,
};

fn set_dec_mode(self: *TUI, mode: DecMode, enabled: bool) !void {
    try self.tty_writer.print("\x1b[?{}{c}", .{ @intFromEnum(mode), @as(u8, if (enabled) 'h' else 'l') });
}
