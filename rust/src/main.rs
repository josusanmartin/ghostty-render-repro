use ghostty_render_repro_rust::{
    advance_frame, alloc_count, naive_update_with_scratch, new_screen_with_cluster,
    reset_alloc_count, DirtyKind, RenderState, DEFAULT_CLUSTER_LEN,
};
use std::hint::black_box;
use std::time::{Duration, Instant};

fn main() {
    const ROWS: usize = 1000;
    const COLS: usize = 160;
    const DIRTY: usize = 4;
    const CLUSTER: usize = DEFAULT_CLUSTER_LEN;
    const SCRATCH: usize = 512;

    let mut naive_screen = new_screen_with_cluster(ROWS, COLS, CLUSTER);
    reset_alloc_count();
    let naive_start = Instant::now();
    let mut naive_sink = 0usize;
    let naive_iters = 10;
    for _ in 0..naive_iters {
        advance_frame(&mut naive_screen, DIRTY);
        let frame = naive_update_with_scratch(&naive_screen, SCRATCH);
        naive_sink ^= frame.rows_len();
        black_box(&frame);
    }
    let naive_elapsed = naive_start.elapsed();
    let naive_allocs = alloc_count();
    drop(naive_screen);

    let mut naive_render_screen = new_screen_with_cluster(ROWS, COLS, CLUSTER);
    reset_alloc_count();
    let mut naive_render_elapsed = Duration::ZERO;
    let mut naive_render_sink = 0usize;
    for _ in 0..naive_iters {
        advance_frame(&mut naive_render_screen, DIRTY);
        let start = Instant::now();
        let frame = naive_update_with_scratch(&naive_render_screen, SCRATCH);
        naive_render_elapsed += start.elapsed();
        naive_render_sink ^= frame.rows_len();
        black_box(&frame);
    }
    let naive_render_allocs = alloc_count();
    drop(naive_render_screen);

    let mut opt_screen = new_screen_with_cluster(ROWS, COLS, CLUSTER);
    let mut state = RenderState::default();
    state.update(&opt_screen);
    reset_alloc_count();
    let opt_start = Instant::now();
    let opt_iters = 10_000;
    let mut opt_sink = 0usize;
    for _ in 0..opt_iters {
        advance_frame(&mut opt_screen, DIRTY);
        state.update(&opt_screen);
        opt_sink ^= state.cursor_x();
        if state.dirty() == DirtyKind::Partial {
            opt_sink ^= 1;
        }
        black_box(&state);
    }
    let opt_elapsed = opt_start.elapsed();
    let opt_allocs = alloc_count();
    drop(state);
    drop(opt_screen);

    let mut opt_render_screen = new_screen_with_cluster(ROWS, COLS, CLUSTER);
    let mut opt_render_state = RenderState::default();
    opt_render_state.update(&opt_render_screen);
    reset_alloc_count();
    let mut opt_render_elapsed = Duration::ZERO;
    let mut opt_render_sink = 0usize;
    for _ in 0..opt_iters {
        advance_frame(&mut opt_render_screen, DIRTY);
        let start = Instant::now();
        opt_render_state.update(&opt_render_screen);
        opt_render_elapsed += start.elapsed();
        opt_render_sink ^= opt_render_state.cursor_x();
        black_box(&opt_render_state);
    }
    let opt_render_allocs = alloc_count();
    drop(opt_render_state);
    drop(opt_render_screen);

    let mut full_screen = new_screen_with_cluster(ROWS, COLS, CLUSTER);
    let mut full_state = RenderState::default();
    full_state.update(&full_screen);
    reset_alloc_count();
    let full_start = Instant::now();
    let full_iters = 20;
    let mut full_sink = 0usize;
    for _ in 0..full_iters {
        advance_frame(&mut full_screen, ROWS);
        full_state.update(&full_screen);
        full_sink ^= full_state.cursor_x();
        black_box(&full_state);
    }
    let full_elapsed = full_start.elapsed();
    let full_allocs = alloc_count();

    println!(
        "case=naive_clone rows={} cols={} dirty={} cluster={} scratch={} ns_per_frame={} allocs_per_frame={:.1} sink={}",
        ROWS,
        COLS,
        DIRTY,
        CLUSTER,
        SCRATCH,
        naive_elapsed.as_nanos() / naive_iters as u128,
        naive_allocs as f64 / naive_iters as f64,
        naive_sink
    );
    println!(
        "case=naive_clone_render_only rows={} cols={} dirty={} cluster={} scratch={} ns_per_frame={} allocs_per_frame={:.1} sink={}",
        ROWS,
        COLS,
        DIRTY,
        CLUSTER,
        SCRATCH,
        naive_render_elapsed.as_nanos() / naive_iters as u128,
        naive_render_allocs as f64 / naive_iters as f64,
        naive_render_sink
    );
    println!(
        "case=optimized_steady rows={} cols={} dirty={} cluster={} ns_per_frame={} allocs_per_frame={:.1} sink={}",
        ROWS,
        COLS,
        DIRTY,
        CLUSTER,
        opt_elapsed.as_nanos() / opt_iters as u128,
        opt_allocs as f64 / opt_iters as f64,
        opt_sink
    );
    println!(
        "case=optimized_steady_render_only rows={} cols={} dirty={} cluster={} ns_per_frame={} allocs_per_frame={:.1} sink={}",
        ROWS,
        COLS,
        DIRTY,
        CLUSTER,
        opt_render_elapsed.as_nanos() / opt_iters as u128,
        opt_render_allocs as f64 / opt_iters as f64,
        opt_render_sink
    );
    println!(
        "case=optimized_full_redraw_warm rows={} cols={} dirty={} cluster={} ns_per_frame={} allocs_per_frame={:.1} sink={}",
        ROWS,
        COLS,
        ROWS,
        CLUSTER,
        full_elapsed.as_nanos() / full_iters as u128,
        full_allocs as f64 / full_iters as f64,
        full_sink
    );
}
