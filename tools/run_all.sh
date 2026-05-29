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
    case "$(uname -s)" in
      Linux) zig_os="linux" ;;
      Darwin) zig_os="macos" ;;
      *)
        echo "No Zig fallback download configured for OS: $(uname -s). Install zig or set ZIG=/path/to/zig." >&2
        exit 1
        ;;
    esac
    case "$(uname -m)" in
      x86_64|amd64) zig_arch="x86_64" ;;
      arm64|aarch64) zig_arch="aarch64" ;;
      *)
        echo "No Zig fallback download configured for architecture: $(uname -m). Install zig or set ZIG=/path/to/zig." >&2
        exit 1
        ;;
    esac
    zig_key="${zig_arch}-${zig_os}"
    zig_dir="$ROOT/.zig/$zig_key"
    mkdir -p "$ROOT/.zig"
    if [[ ! -x "$zig_dir/zig" ]]; then
      url="$(curl -LfsS https://ziglang.org/download/index.json | python3 -c 'import json,sys; key=sys.argv[1]; j=json.load(sys.stdin); print(j["0.16.0"][key]["tarball"])' "$zig_key")"
      tmp="$ROOT/.zig/zig-$zig_key.tar.xz"
      curl -LfsS "$url" -o "$tmp"
      rm -rf "$zig_dir"
      mkdir -p "$zig_dir"
      tar -C "$zig_dir" --strip-components=1 -xf "$tmp"
      rm -f "$tmp"
    fi
    ZIG_BIN="$zig_dir/zig"
  fi
fi
"$ZIG_BIN" test "$ROOT/zig/src/main.zig" -O ReleaseFast
"$ZIG_BIN" run "$ROOT/zig/src/main.zig" -O ReleaseFast
