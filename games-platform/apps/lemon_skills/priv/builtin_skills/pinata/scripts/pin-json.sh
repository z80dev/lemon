#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  pin-json.sh <content.json> [--name <name>] [--cid-version <0|1>]
  pin-json.sh --raw-payload <payload.json>

Notes:
  - Default mode wraps <content.json> as {"pinataContent": <json>}.
  - --raw-payload sends your JSON as-is (advanced usage).

Env:
  PINATA_JWT (recommended) or PINATA_API_KEY + PINATA_API_SECRET
  PINATA_API_URL (default: https://api.pinata.cloud)
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

raw_payload="false"
file=""
name=""
cid_version="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw-payload)
      raw_payload="true"
      file="${2:-}"
      shift 2
      ;;
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
      if [[ -z "${file}" ]]; then
        file="$1"
        shift
      else
        echo "Unknown arg: $1" >&2
        usage
        exit 2
      fi
      ;;
  esac
done

[[ -n "${file}" ]] || pinata_die "missing JSON file path"
[[ -f "${file}" ]] || pinata_die "file not found: ${file}"

pinata_require_bin curl
pinata_build_auth_args

api_base="$(pinata_api_base)"
url="${api_base}/pinning/pinJSONToIPFS"

if [[ "${raw_payload}" == "true" ]]; then
  curl -sS --fail \
    -X POST "$url" \
    "${PINATA_CURL_AUTH_ARGS[@]}" \
    -H "Content-Type: application/json" \
    --data-binary "@${file}"
  exit 0
fi

pinata_require_bin python3

payload="$(
  python3 - "$file" "$name" "$cid_version" <<'PY'
import json
import sys

path = sys.argv[1]
name = sys.argv[2] or None
cid_version_raw = sys.argv[3]

with open(path, "rb") as f:
  content = json.load(f)

payload = {"pinataContent": content}

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

