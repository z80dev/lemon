#!/usr/bin/env bash
set -euo pipefail
HARBOR_DELIVERY_CHANNEL=sms node scripts/export-config.ts
node scripts/dispatch.ts --delivery-channel sms --message hello
