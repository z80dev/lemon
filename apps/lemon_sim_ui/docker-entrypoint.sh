#!/bin/sh
set -eu

if [ "$(id -u)" = "0" ]; then
  install -d -m 0755 /app/data /app/data/store /app/data/leagues
  chown root:root /app/data
  chown -R lemon:lemon /app/data/store /app/data/leagues
  exec gosu lemon "$@"
fi

mkdir -p /app/data/store /app/data/leagues
test -w /app/data/store
test -w /app/data/leagues
exec "$@"
