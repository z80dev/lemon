#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  pin-by-hash.sh <cid> [--name <name>] [--cid-version <0|1>]

Env:
  PINATA_JWT (recommended) or PINATA_API_KEY + PINATA_API_SECRET
  PINATA_API_URL (default: https://api.pinata.cloud)
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

cid="$1"
shift

name=""
cid_version="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      name="${2:-}"
      shift 2
      ;;
    --cid-version)
      cid_version="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

pinata_require_bin curl
pinata_require_bin python3
pinata_build_auth_args

api_base="$(pinata_api_base)"
url="${api_base}/pinning/pinByHash"

payload="$(
  python3 - "$cid" "$name" "$cid_version" <<'PY'
import json
import sys

cid = sys.argv[1]
name = sys.argv[2] or None
cid_version_raw = sys.argv[3]

payload = {"hashToPin": cid}

if name:
  payload["pinataMetadata"] = {"name": name}

if cid_version_raw != "":
  payload["pinataOptions"] = {"cidVersion": int(cid_version_raw)}

print(json.dumps(payload, separators=(",", ":")))
PY
)"

curl -sS --fail \
  -X POST "$url" \
  "${PINATA_CURL_AUTH_ARGS[@]}" \
  -H "Content-Type: application/json" \
  --data "$payload"

