use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

pub const DEFAULT_CLUSTER_LEN: usize = 2;
pub const MAX_CLUSTER_LEN: usize = 8;

pub struct CountingAllocator;

static ALLOCS: AtomicUsize = AtomicUsize::new(0);

#[global_allocator]
static GLOBAL_ALLOCATOR: CountingAllocator = CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::Relaxed);
        System.alloc(layout)
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::Relaxed);
        System.alloc_zeroed(layout)
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::Relaxed);
        System.realloc(ptr, layout, new_size)
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout)
    }
}

pub fn reset_alloc_count() {
    ALLOCS.store(0, Ordering::Relaxed);
}

pub fn alloc_count() -> usize {
    ALLOCS.load(Ordering::Relaxed)
}

#[derive(Clone, Copy)]
pub struct Cell {
    pub codepoint: u32,
    pub comb_len: u16,
    pub combining: [u32; MAX_CLUSTER_LEN],
    pub fg: u32,
    pub bg: u32,
    pub attr: u16,
}

pub struct Row {
    pub version: u64,
    pub cells: Vec<Cell>,
}

pub struct Screen {
    pub rows: Vec<Row>,
    pub cols: usize,
    pub cursor_x: usize,
    pub cursor_y: usize,
    pub frame: u64,
}

pub fn new_screen(rows: usize, cols: usize) -> Screen {
    new_screen_with_cluster(rows, cols, DEFAULT_CLUSTER_LEN)
}

pub fn new_screen_with_cluster(rows: usize, cols: usize, cluster_len: usize) -> Screen {
    assert!(cluster_len <= MAX_CLUSTER_LEN);
    let mut out = Screen {
        rows: Vec::with_capacity(rows),
        cols,
        cursor_x: 0,
        cursor_y: 0,
        frame: 0,
    };
    for y in 0..rows {
        let mut cells = Vec::with_capacity(cols);
        for x in 0..cols {
            cells.push(make_cell(x, y, 1, cluster_len));
        }
        out.rows.push(Row { version: 1, cells });
    }
    out
}

fn make_cell(x: usize, y: usize, frame: u64, cluster_len: usize) -> Cell {
    let mut cell = Cell {
        codepoint: 'a' as u32 + ((x + y + frame as usize) % 26) as u32,
        comb_len: cluster_len as u16,
        combining: [0; MAX_CLUSTER_LEN],
        fg: 0x00d0d0d0 ^ ((x * 17 + y * 11) & 0xff) as u32,
        bg: 0x00101010 ^ ((x * 7 + y * 13) & 0xff) as u32,
        attr: ((x + y) & 7) as u16,
    };
    for i in 0..cluster_len {
        cell.combining[i] = 0x300 + ((x * 3 + y * 5 + i * 7 + frame as usize) % 512) as u32;
    }
    cell
}

pub fn advance_frame(s: &mut Screen, dirty_rows: usize) {
    if dirty_rows == 0 || s.rows.is_empty() {
        return;
    }
    s.frame += 1;
    s.cursor_x = ((s.frame * 7) as usize) % s.cols;
    s.cursor_y = ((s.frame * 11) as usize) % s.rows.len();
    for i in 0..dirty_rows {
        let y = ((s.frame * 17 + i as u64 * 131) as usize) % s.rows.len();
        let row = &mut s.rows[y];
        row.version += 1;
        for (x, c) in row.cells.iter_mut().enumerate() {
            c.codepoint = 'A' as u32 + ((x + y + s.frame as usize) % 26) as u32;
            for j in 0..c.comb_len as usize {
                c.combining[j] =
                    0x300 + ((x * 3 + y * 5 + j * 7 + s.frame as usize) % 512) as u32;
            }
            c.fg ^= ((x + y + s.frame as usize) & 0x0f) as u32;
            c.attr = ((c.attr as usize + x + 1) & 15) as u16;
        }
    }
}

pub struct NaiveFrame {
    rows: Vec<NaiveRow>,
    cursor_x: usize,
    cursor_y: usize,
}

pub struct NaiveRow {
    version: u64,
    cells: Vec<NaiveCell>,
}

pub struct NaiveCell {
    codepoint: u32,
    combining: Vec<u32>,
    fg: u32,
    bg: u32,
    attr: u16,
}

pub fn naive_update(s: &Screen) -> NaiveFrame {
    naive_update_with_scratch(s, 0)
}

pub fn naive_update_with_scratch(s: &Screen, scratch_cap: usize) -> NaiveFrame {
    let mut rows = Vec::with_capacity(s.rows.len());
    for src in &s.rows {
        let mut cells = Vec::with_capacity(src.cells.len());
        for c in &src.cells {
            let n = c.comb_len as usize;
            let mut combining = Vec::with_capacity(n.max(scratch_cap));
            combining.extend_from_slice(&c.combining[..n]);
            cells.push(NaiveCell {
                codepoint: c.codepoint,
                combining,
                fg: c.fg,
                bg: c.bg,
                attr: c.attr,
            });
        }
        rows.push(NaiveRow {
            version: src.version,
            cells,
        });
    }
    NaiveFrame {
        rows,
        cursor_x: s.cursor_x,
        cursor_y: s.cursor_y,
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum DirtyKind {
    False,
    Partial,
    Full,
}

pub struct RenderState {
    rows: Vec<StateRow>,
    row_versions: Vec<u64>,
    rows_len: usize,
    cols: usize,
    cursor_x: usize,
    cursor_y: usize,
    dirty: DirtyKind,
}

impl Default for RenderState {
    fn default() -> Self {
        Self {
            rows: Vec::new(),
            row_versions: Vec::new(),
            rows_len: 0,
            cols: 0,
            cursor_x: 0,
            cursor_y: 0,
            dirty: DirtyKind::False,
        }
    }
}

#[derive(Default)]
struct StateRow {
    version: u64,
    cells: Vec<StateCell>,
    grapheme_pool: Vec<u32>,
    dirty: bool,
}

#[derive(Clone, Copy, Default)]
struct StateCell {
    codepoint: u32,
    combine_from: u32,
    combine_len: u16,
    fg: u32,
    bg: u32,
    attr: u16,
}

impl RenderState {
    pub fn update(&mut self, s: &Screen) {
        let rows = s.rows.len();
        let cols = s.cols;
        let full = self.rows_len != rows || self.cols != cols || self.rows.len() != rows;
        if full {
            self.rows.resize_with(rows, StateRow::default);
            self.row_versions.resize(rows, 0);
            for version in &mut self.row_versions {
                *version = 0;
            }
            self.rows_len = rows;
            self.cols = cols;
        }

        self.cursor_x = s.cursor_x;
        self.cursor_y = s.cursor_y;
        let mut any_dirty = false;
        for (y, src) in s.rows.iter().enumerate() {
            if !full && self.row_versions[y] == src.version {
                self.rows[y].dirty = false;
                continue;
            }
            any_dirty = true;
            self.row_versions[y] = src.version;

            let dst = &mut self.rows[y];
            dst.version = src.version;
            dst.dirty = true;
            dst.cells.clear();
            if dst.cells.capacity() < cols {
                dst.cells.reserve_exact(cols - dst.cells.capacity());
            }
            let needed_pool = cols * MAX_CLUSTER_LEN;
            dst.grapheme_pool.clear();
            if dst.grapheme_pool.capacity() < needed_pool {
                dst.grapheme_pool
                    .reserve_exact(needed_pool - dst.grapheme_pool.capacity());
            }

            for c in &src.cells {
                let start = dst.grapheme_pool.len();
                let n = c.comb_len as usize;
                if n != 0 {
                    dst.grapheme_pool.extend_from_slice(&c.combining[..n]);
                }
                dst.cells.push(StateCell {
                    codepoint: c.codepoint,
                    combine_from: start as u32,
                    combine_len: c.comb_len,
                    fg: c.fg,
                    bg: c.bg,
                    attr: c.attr,
                });
            }
        }

        self.dirty = if full {
            DirtyKind::Full
        } else if any_dirty {
            DirtyKind::Partial
        } else {
            DirtyKind::False
        };
    }

    pub fn hash(&self) -> u64 {
        let mut h = 1469598103934665603u64;
        h = mix(h, self.cursor_x as u64);
        h = mix(h, self.cursor_y as u64);
        for row in &self.rows {
            h = mix(h, row.version);
            for cell in &row.cells {
                h = mix(h, cell.codepoint as u64);
                h = mix(h, cell.fg as u64);
                h = mix(h, cell.bg as u64);
                h = mix(h, cell.attr as u64);
                h = mix(h, cell.combine_len as u64);
                let start = cell.combine_from as usize;
                let end = start + cell.combine_len as usize;
                for cp in &row.grapheme_pool[start..end] {
                    h = mix(h, *cp as u64);
                }
            }
        }
        h
    }

    pub fn dirty(&self) -> DirtyKind {
        self.dirty
    }

    pub fn cursor_x(&self) -> usize {
        self.cursor_x
    }
}

impl NaiveFrame {
    pub fn hash(&self) -> u64 {
        let mut h = 1469598103934665603u64;
        h = mix(h, self.cursor_x as u64);
        h = mix(h, self.cursor_y as u64);
        for row in &self.rows {
            h = mix(h, row.version);
            for cell in &row.cells {
                h = mix(h, cell.codepoint as u64);
                h = mix(h, cell.fg as u64);
                h = mix(h, cell.bg as u64);
                h = mix(h, cell.attr as u64);
                h = mix(h, cell.combining.len() as u64);
                for cp in &cell.combining {
                    h = mix(h, *cp as u64);
                }
            }
        }
        h
    }

    pub fn rows_len(&self) -> usize {
        self.rows.len()
    }
}

fn mix(mut h: u64, v: u64) -> u64 {
    h ^= v
        .wrapping_add(0x9e3779b97f4a7c15)
        .wrapping_add(h << 6)
        .wrapping_add(h >> 2);
    h
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn optimized_matches_naive_after_updates() {
        let _guard = TEST_LOCK.lock().unwrap();
        let mut screen = new_screen_with_cluster(80, 120, 7);
        let mut state = RenderState::default();
        for _ in 0..40 {
            advance_frame(&mut screen, 5);
            let naive = naive_update(&screen);
            state.update(&screen);
            assert_eq!(state.hash(), naive.hash());
        }
    }

    #[test]
    fn optimized_steady_state_allocs_zero() {
        let _guard = TEST_LOCK.lock().unwrap();
        let mut screen = new_screen_with_cluster(1000, 160, DEFAULT_CLUSTER_LEN);
        let mut state = RenderState::default();
        state.update(&screen);
        reset_alloc_count();
        for _ in 0..100 {
            advance_frame(&mut screen, 4);
            state.update(&screen);
        }
        assert_eq!(alloc_count(), 0);
    }
}
