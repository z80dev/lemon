#!/usr/bin/env bash
load_plan() {
    ids=(); deps=(); scripts=(); order=()
    declare -gA positions=()
    local line id rest dep script part i ready progress
    local -a parts=()
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *$'\t'* ]] || return 1
        id=${line%%$'\t'*}; rest=${line#*$'\t'}
        [[ $rest == *$'\t'* ]] || return 1
        dep=${rest%%$'\t'*}; script=${rest#*$'\t'}
        [[ $id =~ ^[a-z][a-z0-9_]{0,31}$ && -n $dep && -n $script && $script != *$'\t'* ]] || return 1
        [[ ! -v positions[$id] ]] || return 1
        [[ $script != /* && /$script/ != *'//'* && /$script/ != *'/./'* && /$script/ != *'/../'* ]] || return 1
        [[ -f $jobs/$script && ! -L $jobs/$script ]] || return 1
        positions[$id]=${#ids[@]}
        ids+=("$id"); deps+=("$dep"); scripts+=("$script")
    done < "$1"
    local -A unique=() seen=()
    for dep in "${deps[@]}"; do
        [[ $dep != - ]] || continue
        [[ $dep != ,* && $dep != *, && $dep != *,,* ]] || return 1
        IFS=, read -r -a parts <<< "$dep"
        unique=()
        for part in "${parts[@]}"; do
            [[ $part =~ ^[a-z][a-z0-9_]{0,31}$ ]] || return 1
            [[ -v positions[$part] && ! -v unique[$part] ]] || return 1
            unique[$part]=1
        done
    done
    while ((${#order[@]} < ${#ids[@]})); do
        progress=0
        for ((i=0; i<${#ids[@]}; i++)); do
            [[ ! -v seen[${ids[i]}] ]] || continue
            ready=1
            if [[ ${deps[i]} != - ]]; then
                IFS=, read -r -a parts <<< "${deps[i]}"
                for part in "${parts[@]}"; do [[ -v seen[$part] ]] || ready=0; done
            fi
            if ((ready)); then
                order+=("$i"); seen[${ids[i]}]=1; progress=1; break
            fi
        done
        ((progress)) || return 1
    done
}
