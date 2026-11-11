#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] || exit 2
dir=$1
keep=$2
for file in $dir/*.log; do
    rm -f $file.$keep
    for ((i=1; i<keep; i++)); do
        [ ! -f $file.$i ] || mv $file.$i $file.$((i+1))
    done
    mv $file $file.1
    touch $file
done
