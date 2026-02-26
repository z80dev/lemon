pinata_die() {
  echo "pinata: $*" >&2
  exit 1
}

pinata_require_bin() {
  command -v "$1" >/dev/null 2>&1 || pinata_die "missing required binary: $1"
}

pinata_api_base() {
  echo "${PINATA_API_URL:-https://api.pinata.cloud}"
}

pinata_upload_base() {
  echo "${PINATA_UPLOAD_URL:-https://uploads.pinata.cloud}"
}

pinata_secret_env() {
  # Support a few common names people use.
  echo "${PINATA_API_SECRET:-${PINATA_API_SECRET_KEY:-${PINATA_SECRET_API_KEY:-}}}"
}

pinata_build_auth_args() {
  local secret
  secret="$(pinata_secret_env)"

  PINATA_CURL_AUTH_ARGS=()

  if [[ -n "${PINATA_JWT:-}" ]]; then
    PINATA_CURL_AUTH_ARGS=(-H "Authorization: Bearer ${PINATA_JWT}")
    return 0
  fi

  if [[ -n "${PINATA_API_KEY:-}" && -n "${secret:-}" ]]; then
    PINATA_CURL_AUTH_ARGS=(
      -H "pinata_api_key: ${PINATA_API_KEY}"
      -H "pinata_secret_api_key: ${secret}"
    )
    return 0
  fi

  pinata_die "missing auth. Set PINATA_JWT (recommended) or PINATA_API_KEY + PINATA_API_SECRET."
}

pinata_build_jwt_auth_args() {
  PINATA_CURL_AUTH_ARGS=()

  if [[ -n "${PINATA_JWT:-}" ]]; then
    PINATA_CURL_AUTH_ARGS=(-H "Authorization: Bearer ${PINATA_JWT}")
    return 0
  fi

  pinata_die "missing auth. This command requires PINATA_JWT."
}

