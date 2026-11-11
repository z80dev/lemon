#!/usr/bin/env bash
set -euo pipefail
src=$1; store=$2; label=$3
mkdir -p "$store/$label/data"
cp -a "$src/." "$store/$label/data/"
bash "$(dirname "${BASH_SOURCE[0]}")/build_manifest.sh" "$store/$label/data" > "$store/$label/manifest"
ln -sfn "$label" "$store/current"
printf '%s\n' "$label"
