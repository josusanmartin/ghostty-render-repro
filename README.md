# Ghostty-style render state reproduction

This is a compact reproduction of the renderer optimization point from
Ghostty's `src/terminal/render.zig`: keep render state resident, compare row
versions/dirty state, bulk-copy raw cells, and retain per-row memory for managed
cell contents so steady-state frames do not allocate.

It is intentionally not a Ghostty clone. The public input shape is the same in
all three languages:

- `Screen` owns fixed-layout rows and cells.
- Each `Row` has a monotonically increasing `version`.
- Each `Cell` has a primary codepoint plus a bounded combining-codepoint payload,
  so a naive deep clone performs one allocation per cell.
- `advanceFrame` mutates real input rows and increments their versions.

The naive renderer deep-clones every row and every cell's combining data every
frame. The optimized renderer keeps `RenderState` memory between calls and only
rewrites rows whose versions changed. Validation hashes compare the full logical
render output, not only dirty rows.

This mirrors the important design in Ghostty's renderer:

- stateful render output instead of cloning the whole screen every frame
- retained row/cell allocations
- per-row arenas or pools for managed cell data
- dirty/partial/full update decisions

## Run

```sh
cd /home/josu/dev/ghostty-render-repro
./tools/run_all.sh
```

If `zig` is not on `PATH`, `tools/run_all.sh` downloads the Zig 0.16.0 Linux
x86_64 tarball from `ziglang.org` into `.zig/`.

Individual runs:

```sh
cd go && go test ./... -run '^$' -bench='OptimizedSteadyAudit88ms' -benchmem -benchtime=1000x -count=3
cd rust && cargo test --release && cargo run --release
.zig/zig test zig/src/main.zig -O ReleaseFast
.zig/zig run zig/src/main.zig -O ReleaseFast
```

## Audited Workload

The default audited workload uses:

- 1000 rows x 160 columns = 160,000 cells
- 4 dirty rows per steady-state frame
- 2 logical combining codepoints per cell
- a naive-renderer scratch capacity of 512 codepoints per cell

That scratch capacity is intentionally synthetic. It calibrates the naive Go and
Rust renderers toward the quoted bad baseline on this host while keeping the
logical cell payload small and the allocation shape unchanged at about 161k
allocations per frame. It is not evidence that Ghostty cells normally contain
512 combining codepoints. Zig reports much lower naive time here because its
allocator path does not zero unused scratch capacity in the same way.

The Go benchmark also reports renderer-only cases. The plain audited cases
include `advanceFrame`, which mutates test input and is not renderer work.

## Results

Implemented and verified the sub-20us optimized renderer path.

Important audit correction: the previous 321 logical combining-codepoint
workload made optimized rendering copy a huge payload, which is not the same
problem as "150k bad allocations." The audited model is now:

- 160,000 cells
- 2 logical combining codepoints per cell
- naive renderer allocates oversized 512-codepoint scratch buffers per cell
- optimized renderer keeps retained compact row state and copies only dirty rows

Results from `./tools/run_all.sh`:

```text
Go naive render-only:        68-85 ms, 161002 allocs/op
Go optimized render-only:    14.5-15.0 us, 0 allocs/op
Go optimized incl mutation:  20.5-20.7 us, 0 allocs/op

Rust naive render-only:      96.5 ms, 161001 allocs/frame
Rust optimized render-only:  4.9 us, 0 allocs/frame
Rust optimized incl mutation: 7.4 us, 0 allocs/frame

Zig optimized render-only:   6.5 us, 0 logical allocs/frame
Zig optimized incl mutation: 9.5 us, 0 logical allocs/frame
```

Zig's naive baseline is much faster because its allocator path does not zero
unused scratch capacity like Go/Rust here, but its optimized path is still
sub-20us.

Key files:

- `go/renderbench/renderer.go`
- `go/renderbench/renderer_test.go`
- `rust/src/lib.rs`
- `zig/src/main.zig`
- `README.md`

## What to look for

The steady-state optimized update should report zero allocations after warmup.
The naive path should report roughly `rows * cols` allocations per frame because
it deep-clones every grapheme every time.

Absolute time depends on CPU, compiler, and thermal state. The useful comparison
is the same-language ratio between:

- naive full clone
- optimized steady dirty-row update
- optimized full redraw after warmup
