#!/usr/bin/env bash
set -euo pipefail
hidden_dir="$(cd "$(dirname "$0")" && pwd)"
cd /work
node "$hidden_dir/check-mutants.mjs" /work
