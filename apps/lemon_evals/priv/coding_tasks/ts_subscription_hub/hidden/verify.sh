#!/usr/bin/env bash
set -euo pipefail
mkdir -p /work/test
cp /verify/hub.hidden.test.ts /work/test/hub.hidden.test.ts
cd /work
node --test test/*.test.ts
