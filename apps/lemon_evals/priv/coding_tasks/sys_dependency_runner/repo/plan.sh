#!/usr/bin/env bash
load_plan() {
    ids=(); deps=(); scripts=()
    while IFS=$'\t' read -r id dep script; do
        ids+=("$id"); deps+=("$dep"); scripts+=("$script")
    done < "$1"
}
