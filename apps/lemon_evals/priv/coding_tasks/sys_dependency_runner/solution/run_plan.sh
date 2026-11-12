#!/usr/bin/env bash
set -euo pipefail
bad() { printf 'invalid plan, jobs or results\n' >&2; exit 2; }
[[ $# == 3 ]] || bad
plan=$1; jobs=$2; results=$3
[[ -f $plan && -d $jobs ]] || bad
[[ $plan == /* ]] || plan=./$plan
[[ $jobs == /* ]] || jobs=./$jobs
[[ $results == /* ]] || results=./$results
if [[ -e $results || -L $results ]]; then
    [[ -d $results && ! -L $results ]] || bad
    contents=$(find "$results" -mindepth 1 -maxdepth 1 -printf x) || bad
    [[ -z $contents ]] || bad
fi
source "$(dirname "${BASH_SOURCE[0]}")/plan.sh"
load_plan "$plan" || bad
jobs=$(cd -- "$jobs" && pwd -P)
mkdir -p -- "$results"
results=$(cd -- "$results" && pwd -P)
declare -A states=() codes=()
failed=0
for i in "${order[@]}"; do
    id=${ids[i]}; blocked=0
    if [[ ${deps[i]} != - ]]; then
        IFS=, read -r -a parts <<< "${deps[i]}"
        for part in "${parts[@]}"; do [[ ${states[$part]} == succeeded ]] || blocked=1; done
    fi
    if ((blocked)); then states[$id]=blocked; codes[$id]=-; failed=1; continue; fi
    if (cd -- "$jobs" && bash -- "${scripts[i]}" < /dev/null) > "$results/$id.out" 2> "$results/$id.err"; then
        states[$id]=succeeded; codes[$id]=0
    else
        codes[$id]=$?; states[$id]=failed; failed=1
    fi
done
: > "$results/status.tsv"
for id in "${ids[@]}"; do printf '%s\t%s\t%s\n' "$id" "${states[$id]}" "${codes[$id]}"; done > "$results/status.tsv"
exit "$failed"
