const std = @import("std");
const mpack = @import("./mpack.zig");
const UIState = @import("./UIState.zig");
const mem = std.mem;
const stringToEnum = std.meta.stringToEnum;
const RPC = @This();
const log = std.log.scoped(.RPC);
const dbg = log.debug;

const State = enum {
    next_msg,
    redraw_event,
    redraw_call,
    next_cell,
    next_mode,
};

state: State = .next_msg,
event: RedrawEvents = undefined,

redraw_events: u64 = 0,
event_calls: u64 = 0,
event_state: union { cell: CellState, mode: ModeState } = undefined,

ui: UIState,

fn doColors(w: anytype, fg: bool, rgb: UIState.RGB) !void {
    const kod = if (fg) "3" else "4";
    try w.print("\x1b[{s}8;2;{};{};{}m", .{ kod, rgb.r, rgb.g, rgb.b });
}

fn putAt(allocator: mem.Allocator, array_list: anytype, index: usize, item: anytype) !void {
    if (array_list.items.len < index + 1) {
        // TODO: safe fill with attr[0] values!
        try array_list.resize(allocator, index + 1);
    }
    array_list.items[index] = item;
}

pub fn init(gpa: mem.Allocator) !RPC {
    return .{ .ui = try .init(gpa) };
}

pub fn deinit(self: *RPC) void {
    self.ui.deinit();
}

fn process_inner(self: *RPC, decoder: *mpack.SkipDecoder) !void {
    // dbg("haii {}\n", .{decoder.data.len});

    while (true) {
        try decoder.skipData();

        // not strictly needed but lets return void on a clean break..
        if (decoder.data.len == 0) break;

        try switch (self.state) {
            inline else => |tag| @field(RPC, @tagName(tag))(self, decoder),
        };
    }
}

pub fn process(self: *RPC, decoder: *mpack.SkipDecoder) !void {
    return self.process_inner(decoder) catch |e| switch (e) {
        error.EOFError => {}, // recoverable when more data is available
        else => return e,
    };
}

fn next_msg(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const tok = try decoder.expectArray();
    if (tok < 3) return error.MalformatedRPCMessage;
    const num = try decoder.expectUInt();
    if (num != 2) @panic("handle replies and requests");
    if (tok != 3) return error.MalformatedRPCMessage;

    const name = try decoder.expectString();

    if (!std.mem.eql(u8, name, "redraw")) @panic("handle notifications other than 'redraw'");

    self.redraw_events = try decoder.expectArray();
    dbg("begen REDRAW {}", .{self.redraw_events});
    base_decoder.consumed(decoder);

    return self.redraw_event(base_decoder);
}

fn redraw_event(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    if (self.redraw_events == 0) {
        // todo: with guaranteed tail calls, we could "return next_msg()" without problems
        self.state = .next_msg;
        return;
    }
    self.state = .redraw_event;

    var decoder = try base_decoder.inner();
    const nitems = try decoder.expectArray();
    if (nitems < 1) return error.MalformatedRPCMessage;
    const n_calls = nitems - 1;
    const name = try decoder.expectString();

    if (n_calls != 1) {
        dbg("EVENT: '{s}' with {}", .{ name, n_calls });
    } else {
        dbg("EVENT: '{s}'{s}", .{ name, if (mem.eql(u8, name, "flush")) "\n" else "" });
    }

    base_decoder.consumed(decoder);
    self.redraw_events -= 1;

    const event = stringToEnum(RedrawEvents, name) orelse {
        base_decoder.toSkip(n_calls);
        return;
    };

    self.event_calls = n_calls;
    self.event = event;
    return redraw_call(self, base_decoder);
}

const RedrawEvents = enum {
    hl_attr_define,
    mode_info_set,
    mode_change,
    grid_resize,
    grid_clear,
    grid_line,
    grid_scroll,
    grid_cursor_goto,
    default_colors_set,
    win_pos,
    win_float_pos,
    win_hide,
    win_close,
    msg_set_pos,
    mouse_on,
    mouse_off,
    set_title,
    flush,
};

fn redraw_call(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    if (self.event_calls == 0) {
        // todo: with guaranteed tail calls, we could "return redraw_event()" without problems
        self.state = .redraw_event;
        return;
    }
    self.state = .redraw_call;
    try switch (self.event) {
        inline else => |tag| @field(RPC, @tagName(tag))(self, base_decoder),
    };
}

fn hl_attr_define(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    const debug = false;
    var decoder = try base_decoder.decodeArrayPrefix(2);

    const id = try decoder.expectUInt();
    const rgb_attrs = try decoder.expectMap();
    if (debug) dbg("ATTEN: {} {}", .{ id, rgb_attrs });
    var attr: UIState.Attr = .{};
    var j: u32 = 0;
    while (j < rgb_attrs) : (j += 1) {
        const name = try decoder.expectString();
        const Keys = enum { foreground, background, special, bold, italic, reverse, underline, underdouble, undercurl, altfont, Unknown };
        const key = stringToEnum(Keys, name) orelse .Unknown;
        switch (key) {
            .foreground => {
                const num = try decoder.expectUInt();
                if (debug) dbg(" fg={}", .{num});
                attr.fg = @bitCast(@as(u24, @intCast(num)));
            },
            .background => {
                const num = try decoder.expectUInt();
                if (debug) dbg(" bg={}", .{num});
                attr.bg = @bitCast(@as(u24, @intCast(num)));
            },
            .special => {
                const num = try decoder.expectUInt();
                if (debug) dbg(" sp={}", .{num});
                attr.sp = @bitCast(@as(u24, @intCast(num)));
            },
            inline else => |k| {
                @field(attr, @tagName(k)) = try decoder.expectBool();
                if (debug) dbg(" {s}", .{@tagName(k)});
            },
            .Unknown => {
                if (debug) dbg(" {s}", .{name});
                // if this is the only skipAny, maybe this loop should be a state lol
                try decoder.skipAny(1);
            },
        }
    }
    attr.start = @intCast(self.ui.attr_arena.items.len);
    // soo. Writer.Allocating is the new ArrayListManaged. GOOD JOB ZIG CORE DEVS
    var aw: std.Io.Writer.Allocating = .fromArrayList(self.ui.gpa, &self.ui.attr_arena);
    const w = &aw.writer;
    try w.writeAll("\x1b[0m");
    if (attr.fg) |rgb| {
        try doColors(w, true, rgb);
    }
    if (attr.bg) |rgb| {
        try doColors(w, false, rgb);
    }
    if (attr.bold) {
        try w.writeAll("\x1b[1m");
    }
    self.ui.attr_arena = aw.toArrayList();
    attr.end = @intCast(self.ui.attr_arena.items.len);
    try putAt(self.ui.gpa, &self.ui.attrs, id, attr);
    if (debug) dbg("\n", .{});

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

const ModeState = struct {
    event_extra_args: usize,
    n_modes: u32,
};

fn mode_info_set(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.inner();
    const iarg = try decoder.expectArray();
    const cursor_style = try decoder.expectBool();
    _ = cursor_style;
    const n_modes = try decoder.expectArray();

    self.event_state = .{ .mode = .{
        .event_extra_args = iarg - 2,
        .n_modes = n_modes,
    } };
    base_decoder.consumed(decoder);
    self.event_calls -= 1;

    try self.ui.mode_info.ensureTotalCapacity(self.ui.gpa, n_modes);
    self.ui.mode_info.items.len = 0;

    try self.next_mode(base_decoder);
}

fn next_mode(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    const s = &self.event_state.mode;
    self.state = .next_mode;
    const debug = false;

    while (s.n_modes > 0) {
        var decoder = try base_decoder.inner();
        const nsize = try decoder.expectMap();
        var mode: UIState.ModeInfo = .{};
        for (0..nsize) |_| {
            const key = try decoder.expectString();
            const Keys = enum { name, cursor_shape, cell_percentage, attr_id, Unknown };
            switch (stringToEnum(Keys, key) orelse .Unknown) {
                .name => {
                    const name = try decoder.expectString();
                    if (debug) dbg("FOR mODE {s}: ", .{name});
                },
                .cursor_shape => {
                    const kinda = try decoder.expectString();
                    if (debug) dbg(" shape={s}", .{kinda});
                    mode.cursor_shape = stringToEnum(UIState.CursorShape, kinda) orelse .block;
                },
                .cell_percentage => {
                    const ival = try decoder.expectUInt();
                    if (debug) dbg(" CELL={}", .{ival});
                    mode.cell_percentage = @truncate(ival);
                },
                .attr_id => {
                    mode.attr_id = @intCast(try decoder.expectUInt());
                    if (debug) dbg(" attr_id={}", .{mode.attr_id});
                },
                .Unknown => {
                    if (debug) dbg(" {s}", .{key});
                    // skipAny is bull, this should also be a state :p
                    try decoder.skipAny(1);
                },
            }
        }

        base_decoder.consumed(decoder);
        if (debug) dbg("\n", .{});
        self.ui.mode_info.appendAssumeCapacity(mode);
        s.n_modes -= 1;
    }

    base_decoder.toSkip(s.event_extra_args);
    self.state = .redraw_call;
    try base_decoder.skipData();
}

fn mode_change(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(2);
    const mode = try decoder.expectString();
    const mode_idx = try decoder.expectUInt();

    // dbg("MODE {s} with {}\n", .{ mode, self.ui.mode_info.items[mode_idx] });
    _ = mode;
    self.ui.mode_idx = @intCast(mode_idx);

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

fn grid_resize(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(3);
    const grid_id = try decoder.expectUInt();

    const grid = try self.ui.put_grid(@intCast(grid_id));
    grid.cols = @intCast(try decoder.expectUInt());
    grid.rows = @intCast(try decoder.expectUInt());

    base_decoder.consumed(decoder);
    self.event_calls -= 1;

    try grid.cell.resize(self.ui.gpa, @as(usize, grid.rows) * grid.cols);

    // TODO: not correct for windows, which retain the upper-left
    var char: [UIState.charsize]u8 = undefined;
    char[0] = ' ';
    char[1] = 0;
    @memset(grid.cell.items, .{ .text = .{ .plain = char }, .attr_id = 0 });
}

fn grid_clear(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(1);
    const grid_id = try decoder.expectUInt();

    base_decoder.consumed(decoder);
    self.event_calls -= 1;

    const grid = self.ui.grid(@intCast(grid_id)) orelse return error.InvalidUIState;
    var char: [UIState.charsize]u8 = undefined;
    //char[0..2] = .{ ' ', 0 };
    char[0] = ' ';
    char[1] = 0;

    @memset(grid.cell.items, .{ .text = .{ .plain = char }, .attr_id = 0 });

    dbg("clear only {}!", .{grid_id});

    try owner(self).cb_grid_clear(@intCast(grid_id));
}

fn grid_scroll(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(7);
    const grid_id: u32 = @intCast(try decoder.expectUInt());
    const top: i32 = @intCast(try decoder.expectUInt());
    const bot: i32 = @intCast(try decoder.expectUInt());
    const left: u32 = @intCast(try decoder.expectUInt());
    const right: u32 = @intCast(try decoder.expectUInt());
    const rows: i32 = @intCast(try decoder.expectInt());
    const cols: i32 = @intCast(try decoder.expectInt());

    base_decoder.consumed(decoder);
    self.event_calls -= 1;

    if (cols != 0) {
        dbg("ACHTUNG: column scrolling not implemented\n", .{});
        return error.MalformatedRPCMessage;
    }

    const grid = self.ui.grid(grid_id) orelse return error.InvalidUIState;
    const cells = grid.cell.items;

    const start, const stop, const step: i32 = if (rows > 0)
        .{ top, bot - rows, 1 }
    else
        .{ bot - 1, top - rows - 1, -1 };

    var i: i32 = start;
    while (i != stop) : (i += step) {
        const target, const src = .{ @as(usize, @intCast(i)) * grid.cols, @as(usize, @intCast(i + rows)) * grid.cols };
        @memcpy(cells[target + left .. target + right], cells[src + left .. src + right]);
    }

    try owner(self).cb_grid_scroll(grid_id, @intCast(top), @intCast(bot), left, right, rows);
}

fn grid_cursor_goto(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(3);
    const grid_id: u32 = @intCast(try decoder.expectUInt());
    const row: u16 = @intCast(try decoder.expectUInt());
    const col: u16 = @intCast(try decoder.expectUInt());

    self.ui.cursor = .{ .grid = grid_id, .row = row, .col = col };

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

fn default_colors_set(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(3);
    const fg: u24 = @intCast(try decoder.expectUInt());
    const bg: u24 = @intCast(try decoder.expectUInt());
    const sp: u24 = @intCast(try decoder.expectUInt());

    self.ui.default_colors = .{ .fg = @bitCast(fg), .bg = @bitCast(bg), .sp = @bitCast(sp) };

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

fn skip_args(self: *RPC, base_decoder: *mpack.SkipDecoder) void {
    // skip entire event_call arg array
    base_decoder.toSkip(1);
    self.event_calls -= 1;
}

fn flush(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    self.skip_args(base_decoder);
    try owner(self).cb_flush();
}

fn owner(self: *RPC) *@import("root") {
    return @fieldParentPtr("rpc", self);
}

const CellState = struct {
    event_extra_args: usize,
    grid_id: u32,
    grid: *UIState.Grid,
    row: u32,
    start_col: u32,
    col: u32,
    ncells: u32,
    attr_id: u32,
};

fn grid_line(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    while (self.event_calls > 0) {
        var decoder = try base_decoder.inner();
        const iarg = try decoder.expectArray();
        if (iarg < 4) return error.MalformatedRPCMessage;
        const grid_id = try decoder.expectUInt();

        const row = try decoder.expectUInt();
        const col = try decoder.expectUInt();
        const ncells = try decoder.expectArray();

        const grid = self.ui.grid(@intCast(grid_id)) orelse return error.InvalidUIState;

        dbg("grid {} with line: {} {} has cellpacks {}", .{ grid_id, row, col, ncells });

        self.event_state = .{ .cell = .{
            .event_extra_args = iarg - 4,
            .grid_id = @intCast(grid_id),
            .grid = grid,
            .row = @intCast(row),
            .start_col = @intCast(col),
            .col = @intCast(col),
            .ncells = ncells,
            .attr_id = 0,
        } };
        base_decoder.consumed(decoder);
        self.event_calls -= 1;

        try self.next_cell(base_decoder);
    }
}

fn next_cell(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    const s = &self.event_state.cell;
    self.state = .next_cell;

    while (s.ncells > 0) {
        var decoder = try base_decoder.inner();
        const nsize = try decoder.expectArray();
        const str = try decoder.expectString();
        var used: u8 = 1;
        var repeat: u64 = 1;
        if (nsize >= 2) {
            s.attr_id = @intCast(try decoder.expectUInt());
            used = 2;
            if (nsize >= 3) {
                repeat = try decoder.expectUInt();
                used = 3;
            }
        }
        base_decoder.consumed(decoder);

        const cell_text = try self.ui.intern_glyph(str);
        const basepos = s.row * s.grid.cols;
        while (repeat > 0) : (repeat -= 1) {
            s.grid.cell.items[basepos + s.col] = .{ .text = cell_text, .attr_id = s.attr_id };
            s.col += 1;
            //dbg("{s}", .{str});
            // self.writer.writeAll(str) catch return RPCError.IOError;
        }
        // dbg("used {} out of {} to get str {s} attr={} x {}\n", .{ used, nsize, str, s.attr_id, repeat });

        s.ncells -= 1;
    }

    try owner(self).cb_grid_line(s.grid_id, s.row, s.start_col, s.col);

    base_decoder.toSkip(s.event_extra_args);
    self.state = .redraw_call;
    try base_decoder.skipData();
}

fn win_pos(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(6);
    const grid: u32 = @intCast(try decoder.expectUInt());
    const win = try decoder.expectExt();
    _ = win; // who cares
    const row: u16 = @intCast(try decoder.expectUInt());
    const col: u16 = @intCast(try decoder.expectUInt());
    const width: u32 = @intCast(try decoder.expectUInt());
    const height: u32 = @intCast(try decoder.expectUInt());

    // dbg("window: grid={} at ({},{}) size={},{}\n", .{ grid, row, col, width, height });

    const g = try self.ui.put_grid(grid);

    const old_info = g.info;
    const old_off_r = g.off_r;
    const old_off_c = g.off_c;

    try owner(self).cb_grid_info(g, old_info, old_off_r, old_off_c);
    g.info = .{ .window = .{ .width = width, .height = height } };
    g.off_c = col;
    g.off_r = row;
    try owner(self).cb_grid_info(g, old_info, old_off_r, old_off_c);

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

fn win_float_pos(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(11);

    const grid: u32 = @intCast(try decoder.expectUInt());
    const win = try decoder.expectExt();
    _ = win; // who cares
    const anchor: []const u8 = try decoder.expectString();
    const anchor_grid: u16 = @intCast(try decoder.expectUInt());
    const anchor_row = try decoder.expectFloat();
    const anchor_col = try decoder.expectFloat();
    const mouse = try decoder.expectBool();
    const zindex = try decoder.expectUInt();
    const compindex: u32 = @intCast(try decoder.expectUInt());
    const off_r: u16 = @intCast(try decoder.expectUInt());
    const off_c: u16 = @intCast(try decoder.expectUInt());

    _ = anchor;
    _ = anchor_grid;
    _ = anchor_row;
    _ = anchor_col;
    _ = zindex;
    // todo: reconcillate this:
    const g = try self.ui.put_grid(grid);
    const old_info = g.info;
    const old_off_r = g.off_r;
    const old_off_c = g.off_c;

    g.info = .{ .float = .{ .mouse = mouse, .compindex = compindex } };
    g.off_r = off_r;
    g.off_c = off_c;
    try owner(self).cb_grid_info(g, old_info, old_off_r, old_off_c);

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

fn win_hide(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(1);
    const grid_id: u32 = @intCast(try decoder.expectUInt());

    // dbg("IT's HIDDEN: {}\n", .{grid_id});
    if (self.ui.grid(grid_id)) |grid| {
        const old_info = grid.info;
        grid.info = .none;
        try owner(self).cb_grid_info(grid, old_info, grid.off_r, grid.off_c);
    }

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

fn win_close(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    // dbg("closed and ", .{});
    return win_hide(self, base_decoder);
}

fn msg_set_pos(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(4);
    const grid: u32 = @intCast(try decoder.expectUInt());
    const row: u32 = @intCast(try decoder.expectUInt());
    const scrolled = try decoder.expectBool();
    const char = try decoder.expectString();

    base_decoder.consumed(decoder);
    self.event_calls -= 1;

    // dbg("messages: grid={} at {} scrolled={} char='{s}'\n", .{ grid, row, scrolled, char });
    self.ui.msg = .{ .grid = grid, .row = row, .scrolled = scrolled, .char = try self.ui.intern_glyph(char) };
}

fn mouse_on(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    self.skip_args(base_decoder);
    self.ui.mouse = true;
}

fn mouse_off(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    self.skip_args(base_decoder);
    self.ui.mouse = false;
}

fn set_title(self: *RPC, base_decoder: *mpack.SkipDecoder) !void {
    var decoder = try base_decoder.decodeArrayPrefix(1);
    // TODO: too loooong for oneshot?
    const str = try decoder.expectString();

    try owner(self).cb_set_title(str);

    base_decoder.consumed(decoder);
    self.event_calls -= 1;
}

pub fn attach(encoder: mpack.Encoder, width: u32, height: u32, stdin_fd: ?i32, multigrid: bool) !void {
    if (false) {
        try encoder.putArrayHead(4);
        try encoder.putInt(0); // request
        try encoder.putInt(0); // msgid
        try encoder.putStr("nvim_get_api_info");
        try encoder.putArrayHead(0);
    } else {
        if (false) {
            // we prefer this once we have implemented replies..
            try encoder.putArrayHead(4);
            try encoder.putInt(0); // request
            try encoder.putInt(0); // msgid
        } else {
            try encoder.putArrayHead(3);
            try encoder.putInt(2); // notify
        }

        try encoder.putStr("nvim_ui_attach");
        try encoder.putArrayHead(3);
        try encoder.putInt(width);
        try encoder.putInt(height);
        const EINS: u32 = 1;
        const items: u32 = 1 + (if (stdin_fd != null) EINS else 0);
        try encoder.putMapHead(items);
        // multigrid implies "linegrid"
        try encoder.putStr(if (multigrid) "ext_multigrid" else "ext_linegrid");
        try encoder.putBool(true);
        if (stdin_fd) |fd| {
            try encoder.putStr("stdin_fd");
            try encoder.putInt(fd);
        }
    }
}

pub fn nvim_input(encoder: mpack.Encoder, input: []const u8) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // notify
    try encoder.putStr("nvim_input");
    try encoder.putArrayHead(1);
    try encoder.putStr(input);
}

pub fn nvim_ui_try_resize_grid(encoder: mpack.Encoder, grid: u32, width: u32, height: u32) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // notify
    try encoder.putStr("nvim_ui_try_resize_grid");
    try encoder.putArrayHead(3);
    try encoder.putInt(grid);
    try encoder.putInt(width);
    try encoder.putInt(height);
}

pub fn nvim_input_mouse(encoder: mpack.Encoder, button: []const u8, action: []const u8, modifier: []const u8, grid: u32, row: i32, col: i32) !void {
    try encoder.putArrayHead(3);
    try encoder.putInt(2); // notify
    try encoder.putStr("nvim_input_mouse");
    try encoder.putArrayHead(6);
    try encoder.putStr(button);
    try encoder.putStr(action);
    try encoder.putStr(modifier);
    try encoder.putInt(grid);
    try encoder.putInt(row);
    try encoder.putInt(col);
}
