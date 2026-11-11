#!/usr/bin/env bash
set -euo pipefail
cd /work
mkdir -p /work/tests
cp /verify/*.rs /work/tests/
cargo test --offline
