#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== Go =="
(cd "$ROOT/go" && go test ./...)
(cd "$ROOT/go" && go test ./... -run '^$' -bench='NaiveCloneAudit88ms' -benchmem -benchtime=10x -count=3)
(cd "$ROOT/go" && go test ./... -run '^$' -bench='OptimizedSteadyAudit88ms|AdvanceFrameAudit88ms' -benchmem -benchtime=1000x -count=3)
(cd "$ROOT/go" && go test ./... -run '^$' -bench='OptimizedFullRedrawWarmAudit88ms' -benchmem -benchtime=10x -count=3)

echo "== Rust =="
(cd "$ROOT/rust" && cargo test --release && cargo run --release)

echo "== Zig =="
ZIG_BIN="${ZIG:-}"
if [[ -z "$ZIG_BIN" ]]; then
  if command -v zig >/dev/null 2>&1; then
    ZIG_BIN="$(command -v zig)"
  else
    mkdir -p "$ROOT/.zig"
    if [[ ! -x "$ROOT/.zig/zig" ]]; then
      url="$(curl -LfsS https://ziglang.org/download/index.json | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j["0.16.0"]["x86_64-linux"]["tarball"])')"
      tmp="$ROOT/.zig/zig.tar.xz"
      curl -LfsS "$url" -o "$tmp"
      tar -C "$ROOT/.zig" --strip-components=1 -xf "$tmp"
      rm -f "$tmp"
    fi
    ZIG_BIN="$ROOT/.zig/zig"
  fi
fi
"$ZIG_BIN" test "$ROOT/zig/src/main.zig" -O ReleaseFast
"$ZIG_BIN" run "$ROOT/zig/src/main.zig" -O ReleaseFast
