#!/usr/bin/env bash
set -euo pipefail
mkdir -p /work/tests
cp /verify/contract.rs /work/tests/contract.rs
cargo test --offline
