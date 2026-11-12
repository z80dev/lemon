#!/usr/bin/env bash
set -euo pipefail
mkdir -p /work/test
cp /verify/overlay.hidden.test.ts /work/test/overlay.hidden.test.ts
cd /work
node --test test/*.test.ts
