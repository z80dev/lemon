#!/usr/bin/env bash
set -euo pipefail
fail() { printf '%s\n' 'usage: rotate.sh DIRECTORY KEEP (1..50)' >&2; exit 2; }
[[ $# == 2 ]] || fail
dir=$1
keep=$2
[[ $keep =~ ^[1-9][0-9]?$ ]] && ((keep <= 50)) || fail
[[ -d $dir ]] || fail
# Prefix relative paths so option-like directory names remain operands.
[[ $dir == /* ]] || dir=./$dir
shopt -s nullglob dotglob
files=("$dir"/*.log)
for file in "${files[@]}"; do
    [[ -f $file && ! -L $file ]] || continue
    rm -f -- "$file.$keep"
    for ((i=keep-1; i>=1; i--)); do
        [[ ! -f $file.$i ]] || mv -- "$file.$i" "$file.$((i+1))"
    done
    mv -- "$file" "$file.1"
    : > "$file"
    chmod --reference="$file.1" -- "$file"
done
