#!/usr/bin/env bash
set -euo pipefail
mode=$1
root=$2
manifest=$3
if [[ $mode == create ]]; then
    find "$root" -type f | while read -r path; do
        sha256sum "$path"
    done > "$manifest"
else
    sha256sum -c "$manifest"
fi
