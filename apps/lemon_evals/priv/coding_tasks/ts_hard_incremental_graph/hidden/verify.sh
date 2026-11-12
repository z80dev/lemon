#!/usr/bin/env bash
set -euo pipefail
cd "${WORK_DIR:-/work}"
node --experimental-strip-types --test test/*.test.ts
node --experimental-strip-types --test "${VERIFY_DIR:-/verify}/arena_hidden_contract.test.ts"
