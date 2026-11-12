#!/usr/bin/env bash
set -euo pipefail
WORK_DIR=${WORK_DIR:-/work}
VERIFY_DIR=${VERIFY_DIR:-/verify}
export GOMAXPROCS=2
export GOTOOLCHAIN=local
export GOPROXY=off
cp "$VERIFY_DIR/arena_hidden_ledger_recovery_test.go" "$WORK_DIR/arena_hidden_ledger_recovery_test.go"
cd "$WORK_DIR"
go test ./...
