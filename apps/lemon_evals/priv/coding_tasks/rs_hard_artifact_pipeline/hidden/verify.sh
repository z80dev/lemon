#!/usr/bin/env bash
set -euo pipefail
WORK_DIR=${WORK_DIR:-/work}
VERIFY_DIR=${VERIFY_DIR:-/verify}
mkdir -p "$WORK_DIR/tests"
cp "$VERIFY_DIR"/arena_hidden_*.rs "$WORK_DIR/tests/"
cd "$WORK_DIR"
cargo test --offline
