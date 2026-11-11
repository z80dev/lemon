#!/usr/bin/env bash
set -euo pipefail
bad() { printf '%s\n' 'invalid snapshot arguments or source' >&2; exit 2; }
[[ $# == 3 ]] || bad
src=$1; store=$2; label=$3
[[ -d $src && -d $store && $label != current && $label =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || bad
[[ $src == /* ]] || src=./$src
[[ $store == /* ]] || store=./$store
[[ ! -e $store/$label && ! -L $store/$label ]] || bad
links=$(find "$src" -type l -printf x) || bad
[[ -z $links ]] || bad
if ! mkdir -- "$store/.lock" 2>/dev/null; then
    printf 'snapshot store is locked\n' >&2
    exit 3
fi
stage=''
cleanup() {
    local status=$?
    [[ -z $stage ]] || rm -rf -- "$stage"
    rmdir -- "$store/.lock"
    if ((status != 0)); then printf 'snapshot publication failed\n' >&2; fi
}
trap cleanup EXIT
stage=$(mktemp -d -- "$store/.stage.XXXXXXXX") || exit 1
mkdir -- "$stage/data" || exit 1
cp -a -- "$src/." "$stage/data/" || exit 1
bash "$(dirname "${BASH_SOURCE[0]}")/build_manifest.sh" "$stage/data" > "$stage/manifest" || exit 1
# Build the pointer before installing data, then move each prepared object.
ln -s -- "$label" "$stage/pointer" || exit 1
pointer=$stage/pointer
mkdir -- "$stage/snapshot"
mv -- "$stage/data" "$stage/manifest" "$stage/snapshot/"
mv -- "$stage/snapshot" "$store/$label"
mv -Tf -- "$pointer" "$store/current"
printf '%s\n' "$label"
