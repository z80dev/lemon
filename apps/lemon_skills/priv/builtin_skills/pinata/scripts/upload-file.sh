#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  upload-file.sh <path> [--network <private|public>] [--name <name>] [--group-id <id>] [--keyvalues <json>] [--car]

Notes:
  - Uses Pinata v3 uploads API: POST https://uploads.pinata.cloud/v3/files
  - Requires PINATA_JWT (API key/secret are not supported for v3 uploads)

Env:
  PINATA_JWT
  PINATA_UPLOAD_URL (default: https://uploads.pinata.cloud)
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

file_path="$1"
shift

network="private"
name=""
group_id=""
keyvalues=""
car="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      network="${2:-}"
      shift 2
      ;;
    --name)
      name="${2:-}"
      shift 2
      ;;
    --group-id)
      group_id="${2:-}"
      shift 2
      ;;
    --keyvalues)
      keyvalues="${2:-}"
      shift 2
      ;;
    --car)
      car="true"
      shift
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

[[ -f "${file_path}" ]] || pinata_die "file not found: ${file_path}"
[[ "${network}" == "private" || "${network}" == "public" ]] || pinata_die "invalid --network: ${network}"

pinata_require_bin curl
pinata_build_jwt_auth_args

upload_base="$(pinata_upload_base)"
url="${upload_base}/v3/files"

args=(
  -sS
  --fail
  -X POST "$url"
  "${PINATA_CURL_AUTH_ARGS[@]}"
  -F "network=${network}"
  -F "file=@${file_path}"
)

if [[ -n "${name}" ]]; then
  args+=(-F "name=${name}")
fi

if [[ -n "${group_id}" ]]; then
  args+=(-F "group_id=${group_id}")
fi

if [[ -n "${keyvalues}" ]]; then
  args+=(-F "keyvalues=${keyvalues}")
fi

if [[ "${car}" == "true" ]]; then
  args+=(-F "car=true")
fi

curl "${args[@]}"

