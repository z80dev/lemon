#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/plan.sh"
load_plan "$1"
jobs=$2; results=$3
mkdir -p "$results"
: > "$results/status.tsv"
for ((i=0; i<${#ids[@]}; i++)); do
    bash "$jobs/${scripts[i]}" > "$results/${ids[i]}.out" 2> "$results/${ids[i]}.err"
    printf '%s\tsucceeded\t0\n' "${ids[i]}" >> "$results/status.tsv"
done
