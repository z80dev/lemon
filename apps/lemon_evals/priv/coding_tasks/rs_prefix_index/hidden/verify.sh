#!/usr/bin/env bash
set -euo pipefail
mkdir -p /work/tests
cp /verify/*.rs /work/tests/
cd /work
cargo test --offline
