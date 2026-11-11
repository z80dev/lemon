#!/usr/bin/env bash
set -euo pipefail
cd /work
make test
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
gcc -std=c99 -Wall -Wextra -Werror -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -I/work /verify/test_ring.c ring.c -o "$build/test_ring"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$build/test_ring"
make all
[[ "$(./ring_demo 4 -2 17)" == "4 -2 17" ]]
[[ -z "$(./ring_demo)" ]]
