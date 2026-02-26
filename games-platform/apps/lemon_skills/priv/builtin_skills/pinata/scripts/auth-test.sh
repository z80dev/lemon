#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_common.sh"

pinata_require_bin curl
pinata_build_auth_args

api_base="$(pinata_api_base)"

curl -sS --fail \
  -X GET "${api_base}/data/testAuthentication" \
  "${PINATA_CURL_AUTH_ARGS[@]}"

