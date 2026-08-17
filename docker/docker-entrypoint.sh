#!/bin/sh
# Entrypoint for docker/Dockerfile.runtime.
#
# Two jobs, in order:
#   1. As root: make the /data volume usable by the unprivileged `lemon` user,
#      then drop privileges and re-run this script as that user.
#   2. As lemon: supply the secrets config/runtime.exs demands of the
#      lemon_runtime_full release, persisting generated ones on the volume so a
#      restart does not invalidate every signed cookie.
set -eu

DATA_DIR="${LEMON_DATA_DIR:-/data}"
STORE_DIR="${LEMON_STORE_PATH:-$DATA_DIR/store}"
STATE_DIR="$DATA_DIR/.lemon"
ENV_FILE="$STATE_DIR/env"
COOKIE_FILE="$STATE_DIR/cookie"
TMP_DIR="${RELEASE_TMP:-/tmp/lemon-release}"

if [ "$(id -u)" = "0" ]; then
  install -d -m 0755 "$DATA_DIR"
  install -d -m 0700 "$STATE_DIR"
  install -d -m 0755 "$STORE_DIR"
  install -d -m 0755 "$TMP_DIR"
  # $DATA_DIR itself is not chowned recursively: it may be a bind mount holding
  # unrelated data, and the runtime only needs to own its own subtrees.
  chown lemon:lemon "$DATA_DIR" "$TMP_DIR"
  chown -R lemon:lemon "$STATE_DIR" "$STORE_DIR"
  exec gosu lemon "$0" "$@"
fi

mkdir -p "$STORE_DIR" "$STATE_DIR" "$TMP_DIR"

if [ ! -w "$STORE_DIR" ]; then
  echo "lemon: store directory is not writable by uid $(id -u): $STORE_DIR" >&2
  echo "lemon: mount /data writable, or run the container as root so the" >&2
  echo "lemon: entrypoint can fix ownership before dropping privileges." >&2
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  # Generated secrets from a previous start of this container.
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

persist_secret() {
  if [ -w "$STATE_DIR" ]; then
    (umask 077; printf 'export %s=%s\n' "$1" "$2" >> "$ENV_FILE")
  fi
}

require_or_generate() {
  name="$1"
  bytes="$2"
  explanation="$3"

  if [ "${LEMON_REQUIRE_SECRETS:-0}" = "1" ] || [ "${LEMON_REQUIRE_SECRETS:-0}" = "true" ]; then
    echo "lemon: $name is required (LEMON_REQUIRE_SECRETS is set) — $explanation" >&2
    exit 1
  fi

  value="$(openssl rand -hex "$bytes")"
  export "$name=$value"
  persist_secret "$name" "$value"

  echo "lemon: WARNING: $name was not set; generated a random value." >&2
  echo "lemon: WARNING: $explanation" >&2
  echo "lemon: WARNING: it is stored in $ENV_FILE and only survives as long as" >&2
  echo "lemon: WARNING: the /data volume does. Set it explicitly in production." >&2
}

# config/runtime.exs calls System.fetch_env! for this one when RELEASE_NAME is
# lemon_runtime_full, so an unset value is a hard boot failure, not a warning.
if [ -z "${LEMON_WEB_SECRET_KEY_BASE:-}" ]; then
  require_or_generate LEMON_WEB_SECRET_KEY_BASE 32 \
    "it signs LemonWeb session cookies; rotating it logs every session out."
fi

if [ -z "${LEMON_GATEWAY_NODE_COOKIE:-}" ] && [ -z "${LEMON_GATEWAY_COOKIE:-}" ]; then
  require_or_generate LEMON_GATEWAY_NODE_COOKIE 16 \
    "it is the Erlang distribution cookie; nodes must share it to cluster."
fi

# Without this the node would use releases/COOKIE, which is baked into the image
# and therefore identical in every container started from it. Reading the same
# file `bin/lemon` reads also means `docker exec ... /app/bin/lemon rpc` reaches
# the node started by CMD instead of failing on a cookie mismatch.
if [ -z "${RELEASE_COOKIE:-}" ]; then
  if [ ! -s "$COOKIE_FILE" ]; then
    (umask 077; openssl rand -hex 32 > "$COOKIE_FILE")
  fi
  RELEASE_COOKIE="$(cat "$COOKIE_FILE")"
  export RELEASE_COOKIE
fi

exec "$@"
