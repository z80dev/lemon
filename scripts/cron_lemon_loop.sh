#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

TS="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
RUN_DIR="docs/agent-loop/runs"
mkdir -p "$RUN_DIR"

OUT="$RUN_DIR/${TS}-native-loop.md"

cat >"$OUT" <<EOF
# Native Lemon loop run

This cron entry no longer invokes vendor coding CLIs (Codex/Claude). The product
execution stack is native-only; use Cloud Agents or a local Lemon runtime for
autonomous planning and implementation work.

## Timestamp

$TS

## Repository health check

EOF

{
  echo "Running scripts/test fast ..."
  scripts/test fast
} >>"$OUT" 2>&1 || true

{
  echo "## $TS"
  echo "- Output: $OUT"
  echo
} >>docs/agent-loop/RUN_LOG.md

echo "Lemon native loop run $TS"
echo "Output: $OUT"
