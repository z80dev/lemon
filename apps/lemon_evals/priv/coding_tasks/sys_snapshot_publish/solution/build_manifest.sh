#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
[[ $# == 1 && -d $1 ]] || exit 1
root=$1
[[ $root == /* ]] || root=./$root
list=$(mktemp)
trap 'rm -f -- "$list"' EXIT
find "$root" -type f -printf '%P\0' | sort -z > "$list"
while IFS= read -r -d '' rel; do
    sum=$(sha256sum < "$root/$rel")
    printf '%s\t%s\0' "${sum%% *}" "$rel"
done < "$list"
