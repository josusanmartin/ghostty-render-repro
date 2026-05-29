const std = @import("std");

const Allocator = std.mem.Allocator;
const default_cluster_len = 2;
const max_cluster_len = 8;

const Cell = struct {
    codepoint: u32,
    comb_len: u16,
    combining: [max_cluster_len]u32,
    fg: u32,
    bg: u32,
    attr: u16,
};

const Row = struct {
    version: u64,
    cells: []Cell,
};

const Screen = struct {
    allocator: Allocator,
    rows: []Row,
    cols: usize,
    cursor_x: usize,
    cursor_y: usize,
    frame: u64,

    fn init(allocator: Allocator, rows_len: usize, cols: usize) !Screen {
        return initWithCluster(allocator, rows_len, cols, default_cluster_len);
    }

    fn initWithCluster(allocator: Allocator, rows_len: usize, cols: usize, cluster_len: usize) !Screen {
        std.debug.assert(cluster_len <= max_cluster_len);
        const rows = try allocator.alloc(Row, rows_len);
        errdefer allocator.free(rows);
        for (rows, 0..) |*row, y| {
            row.version = 1;
            row.cells = try allocator.alloc(Cell, cols);
            errdefer allocator.free(row.cells);
            for (row.cells, 0..) |*cell, x| {
                cell.* = makeCell(x, y, 1, cluster_len);
            }
        }
        return .{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
            .cursor_x = 0,
            .cursor_y = 0,
            .frame = 0,
        };
    }

    fn deinit(self: *Screen) void {
        for (self.rows) |row| {
            self.allocator.free(row.cells);
        }
        self.allocator.free(self.rows);
    }
};

fn makeCell(x: usize, y: usize, frame: u64, cluster_len: usize) Cell {
    const f: usize = @intCast(frame);
    var cell: Cell = .{
        .codepoint = @as(u32, 'a') + @as(u32, @intCast((x + y + f) % 26)),
        .comb_len = @intCast(cluster_len),
        .combining = [_]u32{0} ** max_cluster_len,
        .fg = 0x00d0d0d0 ^ @as(u32, @intCast((x * 17 + y * 11) & 0xff)),
        .bg = 0x00101010 ^ @as(u32, @intCast((x * 7 + y * 13) & 0xff)),
        .attr = @as(u16, @intCast((x + y) & 7)),
    };
    for (0..cluster_len) |i| {
        cell.combining[i] = 0x300 + @as(u32, @intCast((x * 3 + y * 5 + i * 7 + f) % 512));
    }
    return cell;
}

fn advanceFrame(screen: *Screen, dirty_rows: usize) void {
    if (dirty_rows == 0 or screen.rows.len == 0) return;
    screen.frame += 1;
    screen.cursor_x = @as(usize, @intCast(screen.frame * 7)) % screen.cols;
    screen.cursor_y = @as(usize, @intCast(screen.frame * 11)) % screen.rows.len;
    for (0..dirty_rows) |i| {
        const y = @as(usize, @intCast(screen.frame * 17 + @as(u64, @intCast(i)) * 131)) % screen.rows.len;
        var row = &screen.rows[y];
        row.version += 1;
        for (row.cells, 0..) |*cell, x| {
            const f: usize = @intCast(screen.frame);
            cell.codepoint = @as(u32, 'A') + @as(u32, @intCast((x + y + f) % 26));
            for (0..@as(usize, cell.comb_len)) |j| {
                cell.combining[j] = 0x300 + @as(u32, @intCast((x * 3 + y * 5 + j * 7 + f) % 512));
            }
            cell.fg ^= @as(u32, @intCast((x + y + f) & 0x0f));
            cell.attr = @as(u16, @intCast((@as(usize, cell.attr) + x + 1) & 15));
        }
    }
}

const NaiveCell = struct {
    codepoint: u32,
    combining: []u32,
    comb_len: usize,
    fg: u32,
    bg: u32,
    attr: u16,
};

const NaiveRow = struct {
    version: u64,
    cells: []NaiveCell,
};

const NaiveFrame = struct {
    allocator: Allocator,
    rows: []NaiveRow,
    cursor_x: usize,
    cursor_y: usize,

    fn deinit(self: *NaiveFrame) void {
        for (self.rows) |row| {
            for (row.cells) |cell| {
                self.allocator.free(cell.combining);
            }
            self.allocator.free(row.cells);
        }
        self.allocator.free(self.rows);
    }

    fn hash(self: *const NaiveFrame) u64 {
        var h: u64 = 1469598103934665603;
        h = mix(h, self.cursor_x);
        h = mix(h, self.cursor_y);
        for (self.rows) |row| {
            h = mix(h, row.version);
            for (row.cells) |cell| {
                h = mix(h, cell.codepoint);
                h = mix(h, cell.fg);
                h = mix(h, cell.bg);
                h = mix(h, cell.attr);
                h = mix(h, cell.comb_len);
                for (cell.combining[0..cell.comb_len]) |cp| h = mix(h, cp);
            }
        }
        return h;
    }
};

fn naiveUpdate(allocator: Allocator, screen: *const Screen, alloc_count: *usize) !NaiveFrame {
    return naiveUpdateWithScratch(allocator, screen, alloc_count, 0);
}

fn naiveUpdateWithScratch(allocator: Allocator, screen: *const Screen, alloc_count: *usize, scratch_cap: usize) !NaiveFrame {
    const rows = try allocator.alloc(NaiveRow, screen.rows.len);
    alloc_count.* += 1;
    errdefer allocator.free(rows);
    for (screen.rows, rows) |src, *dst| {
        const cells = try allocator.alloc(NaiveCell, src.cells.len);
        alloc_count.* += 1;
        errdefer allocator.free(cells);
        for (src.cells, cells) |cell, *out| {
            const n: usize = cell.comb_len;
            const capacity = @max(n, scratch_cap);
            const allocation = try allocator.alloc(u32, capacity);
            alloc_count.* += 1;
            @memcpy(allocation[0..n], cell.combining[0..n]);
            out.* = .{
                .codepoint = cell.codepoint,
                .combining = allocation,
                .comb_len = n,
                .fg = cell.fg,
                .bg = cell.bg,
                .attr = cell.attr,
            };
        }
        dst.* = .{
            .version = src.version,
            .cells = cells,
        };
    }
    return .{
        .allocator = allocator,
        .rows = rows,
        .cursor_x = screen.cursor_x,
        .cursor_y = screen.cursor_y,
    };
}

const DirtyKind = enum {
    false_dirty,
    partial,
    full,
};

const StateCell = struct {
    codepoint: u32,
    combine_from: u32,
    combine_len: u16,
    fg: u32,
    bg: u32,
    attr: u16,
};

const StateRow = struct {
    version: u64 = 0,
    cells: []StateCell = &.{},
    pool: []u32 = &.{},
    pool_len: usize = 0,
    dirty: bool = false,
};

const RenderState = struct {
    allocator: Allocator,
    rows: []StateRow = &.{},
    row_versions: []u64 = &.{},
    rows_len: usize = 0,
    cols: usize = 0,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    dirty: DirtyKind = .false_dirty,
    allocation_count: usize = 0,

    fn init(allocator: Allocator) RenderState {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RenderState) void {
        for (self.rows) |row| {
            if (row.cells.len != 0) self.allocator.free(row.cells);
            if (row.pool.len != 0) self.allocator.free(row.pool);
        }
        if (self.rows.len != 0) self.allocator.free(self.rows);
        if (self.row_versions.len != 0) self.allocator.free(self.row_versions);
    }

    fn update(self: *RenderState, screen: *const Screen) !void {
        const rows_len = screen.rows.len;
        const cols = screen.cols;
        const full = self.rows_len != rows_len or self.cols != cols or self.rows.len != rows_len;
        if (full) {
            self.deinit();
            self.rows = try self.allocator.alloc(StateRow, rows_len);
            self.allocation_count += 1;
            self.row_versions = try self.allocator.alloc(u64, rows_len);
            self.allocation_count += 1;
            for (self.rows) |*row| row.* = .{};
            @memset(self.row_versions, 0);
            self.rows_len = rows_len;
            self.cols = cols;
        }

        self.cursor_x = screen.cursor_x;
        self.cursor_y = screen.cursor_y;
        var any_dirty = false;
        for (screen.rows, 0..) |src, y| {
            if (!full and self.row_versions[y] == src.version) {
                self.rows[y].dirty = false;
                continue;
            }
            any_dirty = true;
            self.row_versions[y] = src.version;

            var dst = &self.rows[y];
            dst.version = src.version;
            dst.dirty = true;
            const row_cols = src.cells.len;
            if (dst.cells.len != row_cols) {
                if (dst.cells.len != 0) self.allocator.free(dst.cells);
                dst.cells = if (row_cols == 0) &.{} else try self.allocator.alloc(StateCell, row_cols);
                if (row_cols != 0) self.allocation_count += 1;
            }
            const need_pool = row_cols * max_cluster_len;
            if (dst.pool.len != need_pool) {
                if (dst.pool.len != 0) self.allocator.free(dst.pool);
                dst.pool = if (need_pool == 0) &.{} else try self.allocator.alloc(u32, need_pool);
                if (need_pool != 0) self.allocation_count += 1;
            }
            dst.pool_len = 0;

            for (src.cells, 0..) |cell, x| {
                const start = dst.pool_len;
                const n: usize = cell.comb_len;
                if (n != 0) {
                    @memcpy(dst.pool[start .. start + n], cell.combining[0..n]);
                    dst.pool_len += n;
                }
                dst.cells[x] = .{
                    .codepoint = cell.codepoint,
                    .combine_from = @intCast(start),
                    .combine_len = cell.comb_len,
                    .fg = cell.fg,
                    .bg = cell.bg,
                    .attr = cell.attr,
                };
            }
        }

        self.dirty = if (full) .full else if (any_dirty) .partial else .false_dirty;
    }

    fn hash(self: *const RenderState) u64 {
        var h: u64 = 1469598103934665603;
        h = mix(h, self.cursor_x);
        h = mix(h, self.cursor_y);
        for (self.rows) |row| {
            h = mix(h, row.version);
            for (row.cells) |cell| {
                h = mix(h, cell.codepoint);
                h = mix(h, cell.fg);
                h = mix(h, cell.bg);
                h = mix(h, cell.attr);
                h = mix(h, cell.combine_len);
                const start: usize = cell.combine_from;
                const end = start + @as(usize, cell.combine_len);
                for (row.pool[start..end]) |cp| h = mix(h, cp);
            }
        }
        return h;
    }
};

fn mix(h0: u64, value: anytype) u64 {
    var h = h0;
    const v: u64 = @intCast(value);
    h ^= v +% 0x9e3779b97f4a7c15 +% (h << 6) +% (h >> 2);
    return h;
}

fn nowNs() i128 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts))) {
        .SUCCESS => {},
        else => unreachable,
    }
    return @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
}

test "optimized matches naive after updates" {
    const allocator = std.testing.allocator;
    var screen = try Screen.initWithCluster(allocator, 80, 120, 7);
    defer screen.deinit();
    var state = RenderState.init(allocator);
    defer state.deinit();

    for (0..40) |_| {
        advanceFrame(&screen, 5);
        var allocs: usize = 0;
        var naive = try naiveUpdate(allocator, &screen, &allocs);
        defer naive.deinit();
        try state.update(&screen);
        try std.testing.expectEqual(naive.hash(), state.hash());
    }
}

test "optimized steady state allocs zero" {
    const allocator = std.testing.allocator;
    var screen = try Screen.initWithCluster(allocator, 1000, 160, default_cluster_len);
    defer screen.deinit();
    var state = RenderState.init(allocator);
    defer state.deinit();
    try state.update(&screen);
    const before = state.allocation_count;
    for (0..100) |_| {
        advanceFrame(&screen, 4);
        try state.update(&screen);
    }
    try std.testing.expectEqual(before, state.allocation_count);
}

test "optimized handles column shrink and grow" {
    const allocator = std.testing.allocator;
    var state = RenderState.init(allocator);
    defer state.deinit();

    var wide = try Screen.initWithCluster(allocator, 6, 12, default_cluster_len);
    defer wide.deinit();
    try state.update(&wide);

    var narrow = try Screen.initWithCluster(allocator, 6, 5, default_cluster_len);
    defer narrow.deinit();
    advanceFrame(&narrow, 3);
    var narrow_allocs: usize = 0;
    var narrow_naive = try naiveUpdate(allocator, &narrow, &narrow_allocs);
    defer narrow_naive.deinit();
    try state.update(&narrow);
    try std.testing.expectEqual(narrow_naive.hash(), state.hash());
    for (state.rows) |row| {
        try std.testing.expectEqual(@as(usize, 5), row.cells.len);
    }

    var wider = try Screen.initWithCluster(allocator, 6, 9, default_cluster_len);
    defer wider.deinit();
    advanceFrame(&wider, 4);
    var wider_allocs: usize = 0;
    var wider_naive = try naiveUpdate(allocator, &wider, &wider_allocs);
    defer wider_naive.deinit();
    try state.update(&wider);
    try std.testing.expectEqual(wider_naive.hash(), state.hash());
    for (state.rows) |row| {
        try std.testing.expectEqual(@as(usize, 9), row.cells.len);
    }
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    const rows = 1000;
    const cols = 160;
    const dirty = 4;
    const cluster = default_cluster_len;
    const scratch = 512;

    var naive_screen = try Screen.initWithCluster(allocator, rows, cols, cluster);
    var naive_allocs: usize = 0;
    var naive_sink: usize = 0;
    const naive_iters = 10;
    const naive_start = nowNs();
    for (0..naive_iters) |_| {
        advanceFrame(&naive_screen, dirty);
        var frame = try naiveUpdateWithScratch(allocator, &naive_screen, &naive_allocs, scratch);
        naive_sink ^= frame.rows.len;
        frame.deinit();
    }
    const naive_elapsed = nowNs() - naive_start;
    naive_screen.deinit();

    var naive_render_screen = try Screen.initWithCluster(allocator, rows, cols, cluster);
    var naive_render_allocs: usize = 0;
    var naive_render_sink: usize = 0;
    var naive_render_elapsed: i128 = 0;
    for (0..naive_iters) |_| {
        advanceFrame(&naive_render_screen, dirty);
        const start = nowNs();
        var frame = try naiveUpdateWithScratch(allocator, &naive_render_screen, &naive_render_allocs, scratch);
        naive_render_elapsed += nowNs() - start;
        naive_render_sink ^= frame.rows.len;
        frame.deinit();
    }
    naive_render_screen.deinit();

    var opt_screen = try Screen.initWithCluster(allocator, rows, cols, cluster);
    var state = RenderState.init(allocator);
    try state.update(&opt_screen);
    const opt_allocs_before = state.allocation_count;
    var opt_sink: usize = 0;
    const opt_iters = 10000;
    const opt_start = nowNs();
    for (0..opt_iters) |_| {
        advanceFrame(&opt_screen, dirty);
        try state.update(&opt_screen);
        opt_sink ^= state.cursor_x;
        if (state.dirty == .partial) opt_sink ^= 1;
    }
    const opt_elapsed = nowNs() - opt_start;
    const opt_allocs = state.allocation_count - opt_allocs_before;
    state.deinit();
    opt_screen.deinit();

    var opt_render_screen = try Screen.initWithCluster(allocator, rows, cols, cluster);
    var opt_render_state = RenderState.init(allocator);
    try opt_render_state.update(&opt_render_screen);
    const opt_render_allocs_before = opt_render_state.allocation_count;
    var opt_render_sink: usize = 0;
    var opt_render_elapsed: i128 = 0;
    for (0..opt_iters) |_| {
        advanceFrame(&opt_render_screen, dirty);
        const start = nowNs();
        try opt_render_state.update(&opt_render_screen);
        opt_render_elapsed += nowNs() - start;
        opt_render_sink ^= opt_render_state.cursor_x;
    }
    const opt_render_allocs = opt_render_state.allocation_count - opt_render_allocs_before;
    opt_render_state.deinit();
    opt_render_screen.deinit();

    var full_screen = try Screen.initWithCluster(allocator, rows, cols, cluster);
    var full_state = RenderState.init(allocator);
    try full_state.update(&full_screen);
    const full_allocs_before = full_state.allocation_count;
    var full_sink: usize = 0;
    const full_iters = 20;
    const full_start = nowNs();
    for (0..full_iters) |_| {
        advanceFrame(&full_screen, rows);
        try full_state.update(&full_screen);
        full_sink ^= full_state.cursor_x;
    }
    const full_elapsed = nowNs() - full_start;
    const full_allocs = full_state.allocation_count - full_allocs_before;
    full_state.deinit();
    full_screen.deinit();

    std.debug.print("case=naive_clone rows={} cols={} dirty={} cluster={} scratch={} ns_per_frame={} logical_allocs_per_frame={d:.1} sink={}\n", .{
        rows,
        cols,
        dirty,
        cluster,
        scratch,
        @divTrunc(naive_elapsed, naive_iters),
        @as(f64, @floatFromInt(naive_allocs)) / @as(f64, @floatFromInt(naive_iters)),
        naive_sink,
    });
    std.debug.print("case=naive_clone_render_only rows={} cols={} dirty={} cluster={} scratch={} ns_per_frame={} logical_allocs_per_frame={d:.1} sink={}\n", .{
        rows,
        cols,
        dirty,
        cluster,
        scratch,
        @divTrunc(naive_render_elapsed, naive_iters),
        @as(f64, @floatFromInt(naive_render_allocs)) / @as(f64, @floatFromInt(naive_iters)),
        naive_render_sink,
    });
    std.debug.print("case=optimized_steady rows={} cols={} dirty={} cluster={} ns_per_frame={} logical_allocs_per_frame={d:.1} sink={}\n", .{
        rows,
        cols,
        dirty,
        cluster,
        @divTrunc(opt_elapsed, opt_iters),
        @as(f64, @floatFromInt(opt_allocs)) / @as(f64, @floatFromInt(opt_iters)),
        opt_sink,
    });
    std.debug.print("case=optimized_steady_render_only rows={} cols={} dirty={} cluster={} ns_per_frame={} logical_allocs_per_frame={d:.1} sink={}\n", .{
        rows,
        cols,
        dirty,
        cluster,
        @divTrunc(opt_render_elapsed, opt_iters),
        @as(f64, @floatFromInt(opt_render_allocs)) / @as(f64, @floatFromInt(opt_iters)),
        opt_render_sink,
    });
    std.debug.print("case=optimized_full_redraw_warm rows={} cols={} dirty={} cluster={} ns_per_frame={} logical_allocs_per_frame={d:.1} sink={}\n", .{
        rows,
        cols,
        rows,
        cluster,
        @divTrunc(full_elapsed, full_iters),
        @as(f64, @floatFromInt(full_allocs)) / @as(f64, @floatFromInt(full_iters)),
        full_sink,
    });
}
