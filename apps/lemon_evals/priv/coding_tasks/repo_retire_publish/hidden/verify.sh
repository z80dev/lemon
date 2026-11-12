#!/usr/bin/env bash
set -euo pipefail
node --test /verify/contracts.test.ts
node --test tests/*.test.ts
