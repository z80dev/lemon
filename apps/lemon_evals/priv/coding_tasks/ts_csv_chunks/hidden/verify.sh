#!/usr/bin/env bash
set -euo pipefail
mkdir -p /work/test
cp /verify/csv.hidden.test.ts /work/test/csv.hidden.test.ts
cd /work
node --test test/*.test.ts
