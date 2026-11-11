#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
bad() { printf '%s\n' 'invalid manifest invocation or record' >&2; exit 2; }
[[ $# == 3 ]] || bad
mode=$1; root=$2; manifest=$3
[[ $mode == create || $mode == verify ]] || bad
[[ -d $root ]] || bad
[[ $root == /* ]] || root=./$root
[[ $manifest == /* ]] || manifest=./$manifest
root=${root%/}
[[ -n $root ]] || root=/
mapfile -d '' -t paths < <(find "$root" -type f -printf '%P\0' | sort -z)
if [[ $mode == create ]]; then
    tmp=$(mktemp -- "$manifest.tmp.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    for rel in "${paths[@]}"; do
        sum=$(sha256sum < "$root/$rel")
        printf '%s\t%s\n' "${sum%% *}" "$rel"
    done > "$tmp"
    mv -- "$tmp" "$manifest"
    exit 0
fi
[[ -f $manifest && ! -L $manifest ]] || bad
declare -A expected=()
while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *$'\t'* ]] || bad
    sum=${line%%$'\t'*}; rel=${line#*$'\t'}
    [[ $sum =~ ^[0-9a-f]{64}$ && -n $rel && $rel != /* && $rel != *$'\t'* ]] || bad
    [[ /$rel/ != *'//'* && /$rel/ != *'/./'* && /$rel/ != *'/../'* ]] || bad
    [[ ! -v expected["$rel"] ]] || bad
    expected["$rel"]=$sum
done < "$manifest"
mismatch=0
[[ ${#paths[@]} == ${#expected[@]} ]] || mismatch=1
for rel in "${paths[@]}"; do
    sum=$(sha256sum < "$root/$rel")
    [[ ${expected["$rel"]-} == "${sum%% *}" ]] || mismatch=1
done
if ((mismatch)); then printf 'MISMATCH\n'; exit 1; fi
printf 'OK %d\n' "${#paths[@]}"
