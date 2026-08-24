const std = @import("std");
const mem = std.mem;
const UIState = @This();
const log = std.log.scoped(.UIState);
const dbg = log.debug;

gpa: mem.Allocator,
attr_arena: std.ArrayList(u8) = .empty,
glyph_arena: std.ArrayList(u8) = .empty,
glyph_cache: std.HashMapUnmanaged(u32, void, std.hash_map.StringIndexContext, std.hash_map.default_max_load_percentage) = .empty,
attrs: std.ArrayList(Attr) = .empty,
mode_info: std.ArrayList(ModeInfo) = .empty,
mode_idx: u32 = 0,
mouse: bool = false,

cursor: struct { grid: u32, row: u16, col: u16 } = undefined,
default_colors: struct { fg: RGB, bg: RGB, sp: RGB } = undefined,

grid_nr: ?u32 = null,
grid_cached: *Grid = undefined,
grids: std.AutoArrayHashMapUnmanaged(u32, Grid) = .empty,
msg: ?struct {
    grid: u32,
    row: u32,
    scrolled: bool,
    char: CellText,
} = null,

pub fn grid(self: *UIState, id: u32) ?*Grid {
    if (self.grid_nr == id) {
        return self.grid_cached;
    }
    return self.grids.getPtr(id);
}

pub fn put_grid(self: *UIState, id: u32) !*Grid {
    if (self.grid_nr == id) {
        return self.grid_cached;
    }
    const gop = try self.grids.getOrPut(self.gpa, id);
    if (!gop.found_existing) {
        gop.value_ptr.* = Grid{};
    }
    return gop.value_ptr;
}

pub const Attr = struct {
    start: u32 = 0,
    end: u32 = 0,
    fg: ?RGB = null,
    bg: ?RGB = null,
    sp: ?RGB = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    undercurl: bool = false,
    underdouble: bool = false,
    reverse: bool = false,
    altfont: bool = false,
};

pub const CursorShape = enum(u8) { block = 1, horizontal = 3, vertical = 5 };
pub const ModeInfo = struct {
    cursor_shape: CursorShape = .block,
    cell_percentage: u8 = 100,
    attr_id: u32 = 0,
    short_name: [2]u8 = .{ '?', '?' },
};
pub fn mode(self: *UIState) ModeInfo {
    return if (self.mode_info.items.len > self.mode_idx) self.mode_info.items[self.mode_idx] else .{};
}
pub fn attr(self: *UIState, attr_id: u32) Attr {
    return self.attrs.items[if (self.attrs.items.len > attr_id) attr_id else 0];
}

pub fn get_colors(self: *UIState, a: Attr) struct { RGB, RGB, RGB } {
    const bg = a.bg orelse self.default_colors.bg;
    const fg = a.fg orelse self.default_colors.fg;
    const sp = a.sp orelse self.default_colors.sp;
    return if (a.reverse) .{ fg, bg, sp } else .{ bg, fg, sp };
}

pub const Grid = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    cell: std.ArrayList(Cell) = .empty,
    info: GridInfo = .none,
    off_r: u16 = 0,
    off_c: u16 = 0,
};

pub const GridInfo = union(enum) {
    none: void,
    window: struct { width: u32, height: u32 },
    float: struct { mouse: bool, compindex: u32 },
};

// base charsize
pub const charsize = 4;

pub const CellText = union(enum) { plain: [charsize]u8, indexed: u32 };

pub const Cell = struct {
    // TODO: use compression trick like in nvim to avoid the tag byte
    text: CellText,
    attr_id: u32,

    pub fn is_ascii_space(self: Cell) bool {
        return switch (self.text) {
            .indexed => false,
            .plain => |txt| mem.eql(u8, txt[0..2], &.{ 32, 0 }),
        };
    }
};

pub const RGB = packed struct { b: u8, g: u8, r: u8 };

pub fn init(gpa: mem.Allocator) !UIState {
    var attrs: std.ArrayList(Attr) = .empty;
    try attrs.append(gpa, .{});
    return .{
        .gpa = gpa,
        .attrs = attrs,
    };
}

pub fn deinit(self: *UIState) void {
    self.attr_arena.deinit(self.gpa);
    self.glyph_arena.deinit(self.gpa);
    self.glyph_cache.deinit(self.gpa);
    self.attrs.deinit(self.gpa);
    self.mode_info.deinit(self.gpa);
    var it = self.grids.iterator();
    while (it.next()) |e| {
        e.value_ptr.cell.deinit(self.gpa);
    }
    self.grids.deinit(self.gpa);
}

pub fn text(self: *UIState, cell: *const Cell) []const u8 {
    return switch (cell.text) {
        // oo I eat plain toast
        .plain => |*str| str[0 .. std.mem.indexOfScalar(u8, str, 0) orelse charsize],
        .indexed => |idx| mem.span(@as([*:0]u8, @ptrCast(self.glyph_arena.items[idx..]))),
    };
}

pub fn intern_glyph(self: *UIState, str: []const u8) !CellText {
    if (str.len <= charsize) {
        var char: [charsize]u8 = undefined;
        for (0..str.len) |i| {
            char[i] = str[i];
        }
        if (str.len < charsize) {
            char[str.len] = 0;
        }
        return .{ .plain = char };
    }
    const gop = try self.glyph_cache.getOrPutContextAdapted(self.gpa, str, std.hash_map.StringIndexAdapter{
        .bytes = &self.glyph_arena,
    }, std.hash_map.StringIndexContext{
        .bytes = &self.glyph_arena,
    });
    if (gop.found_existing) {
        return .{ .indexed = gop.key_ptr.* };
    } else {
        const str_index: u32 = @intCast(self.glyph_arena.items.len);
        gop.key_ptr.* = str_index;
        try self.glyph_arena.appendSlice(self.gpa, str);
        try self.glyph_arena.append(self.gpa, 0);
        return .{ .indexed = str_index };
    }
}

pub fn dump_grid(self: *UIState, id: u32) void {
    var attr_id: u32 = 0;
    const print = std.debug.print;
    print("GRID {} begin ======\n", .{id});
    const g = self.grid(id) orelse &Grid{};
    for (0..g.rows) |row| {
        const basepos = row * g.cols;
        for (0..g.cols) |col| {
            const cell = g.cell.items[basepos + col];

            if (cell.attr_id != attr_id) {
                attr_id = cell.attr_id;
                const slice = if (attr_id > 0) theslice: {
                    const islice = self.attrs.items[attr_id];
                    break :theslice self.attr_arena.items[islice.start..islice.end];
                } else "\x1b[0m";
                print("{s}", .{slice});
            }
            print("{s}", .{self.text(&cell)});
        }
        print("\r\n", .{});
    }
    print("\x1b[0mGRID end ======\n", .{});
}
