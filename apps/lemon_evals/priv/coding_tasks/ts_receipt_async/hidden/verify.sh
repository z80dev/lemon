#!/usr/bin/env bash
set -euo pipefail
cp /verify/contract.test.js /work/test/contract.test.js
node --test test/*.test.js
