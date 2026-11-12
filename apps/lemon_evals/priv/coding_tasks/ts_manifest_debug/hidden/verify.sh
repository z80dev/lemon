#!/usr/bin/env bash
set -euo pipefail
hidden_dir="$(cd "$(dirname "$0")" && pwd)"
cd /work
mkdir -p test
cp "$hidden_dir/manifest.hidden.test.js" test/manifest.hidden.test.js
node --test test/*.test.js
