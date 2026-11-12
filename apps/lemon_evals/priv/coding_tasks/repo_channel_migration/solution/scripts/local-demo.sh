#!/usr/bin/env bash
set -euo pipefail
HARBOR_CHANNEL=sms node scripts/export-config.ts
node scripts/dispatch.ts --channel sms --message hello
