#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  unpin.sh <cid>

Env:
  PINATA_JWT (recommended) or PINATA_API_KEY + PINATA_API_SECRET
  PINATA_API_URL (default: https://api.pinata.cloud)
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

cid="$1"

pinata_require_bin curl
pinata_build_auth_args

api_base="$(pinata_api_base)"

curl -sS --fail \
  -X DELETE "${api_base}/pinning/unpin/${cid}" \
  "${PINATA_CURL_AUTH_ARGS[@]}"

