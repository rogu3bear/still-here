#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/build-support.sh"
EXPECTED_CARGO_LEPTOS_VERSION="0.3.5"
CARGO_LEPTOS_ROOT="$ROOT_DIR/var/cargo-tools/cargo-leptos-$EXPECTED_CARGO_LEPTOS_VERSION"
if [ -x "$CARGO_LEPTOS_ROOT/bin/cargo-leptos" ]; then
  export PATH="$CARGO_LEPTOS_ROOT/bin:$PATH"
fi
EXPECTED_WORKER_BUILD_VERSION="0.7.5"
EXPECTED_WRANGLER_VERSION="4.120.1"

log() {
  printf '[bootstrap] %s\n' "$1"
}

require_command() {
  local cmd="$1"
  local hint="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '[bootstrap] %s\n' "$hint" >&2
    exit 1
  fi
}

require_command rustup "Rustup is required. Install it from https://rustup.rs/."
require_command cargo "Cargo is required. Install Rust from https://rustup.rs/."
require_command bun "Bun is required. Install it from https://bun.sh/."

wrangler_cmd() {
  bunx "wrangler@${EXPECTED_WRANGLER_VERSION}" "$@"
}

if rustup toolchain list | grep -q '^stable'; then
  log "Stable Rust toolchain already installed."
else
  log "Installing the stable Rust toolchain."
  rustup toolchain install stable
fi

if rustup target list --installed | grep -qx 'wasm32-unknown-unknown'; then
  log "wasm32-unknown-unknown target already installed."
else
  log "Installing the wasm32-unknown-unknown target."
  rustup target add wasm32-unknown-unknown
fi

if cargo leptos --version >/dev/null 2>&1; then
  current_cargo_leptos_version="$(cargo leptos --version | awk '{print $2}')"
else
  current_cargo_leptos_version=""
fi

if [ "$current_cargo_leptos_version" = "$EXPECTED_CARGO_LEPTOS_VERSION" ]; then
  log "cargo-leptos $EXPECTED_CARGO_LEPTOS_VERSION already installed."
else
  log "Installing cargo-leptos $EXPECTED_CARGO_LEPTOS_VERSION."
  cargo install cargo-leptos --locked --version "$EXPECTED_CARGO_LEPTOS_VERSION" --root "$CARGO_LEPTOS_ROOT" \
    --target-dir "$ROOT_DIR/var/cargo-tools/target"
  export PATH="$CARGO_LEPTOS_ROOT/bin:$PATH"
fi

repo_wasm_bindgen_version="$("$ROOT_DIR/scripts/with-wasm-bindgen-cli.sh" --version | awk '{print $2}')"
log "Ensured repo-local wasm-bindgen-cli $repo_wasm_bindgen_version from Cargo.lock."

if command -v worker-build >/dev/null 2>&1; then
  current_worker_build_version="$(worker-build --version | awk '{print $1}')"
else
  current_worker_build_version=""
fi

if [ "$current_worker_build_version" = "$EXPECTED_WORKER_BUILD_VERSION" ]; then
  log "worker-build $EXPECTED_WORKER_BUILD_VERSION already installed."
else
  log "Installing worker-build $EXPECTED_WORKER_BUILD_VERSION."
  cargo install worker-build --locked --version "$EXPECTED_WORKER_BUILD_VERSION" \
    --target-dir "$ROOT_DIR/var/cargo-tools/target"
fi

if ! command -v cargo-audit >/dev/null 2>&1; then
  log "cargo-audit is required for release verification. Install it with cargo install cargo-audit --locked, then rerun bootstrap."
  exit 1
fi

log "Checking Wrangler $EXPECTED_WRANGLER_VERSION through bunx."
wrangler_cmd --version >/dev/null

log "Running dependency checks."
"$ROOT_DIR/scripts/check-deps.sh"

cat <<'EOF'

Bootstrap complete.

Local next steps:
1. bash ./scripts/build-edge.sh
2. bunx wrangler@4.120.1 dev --local --ip 127.0.0.1 --port 57583

Provider publication is a separate governed transaction through cfctl and the
registered Cloudflare Authority. Read RELEASE.md. This product site does not
query D1; do not provision a database for inherited sample workflows.
EOF
