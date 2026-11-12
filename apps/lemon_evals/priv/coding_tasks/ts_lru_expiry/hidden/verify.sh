#!/usr/bin/env bash
set -euo pipefail
cp /verify/contract.test.ts /work/test/contract.test.ts
node --test test/*.test.ts
