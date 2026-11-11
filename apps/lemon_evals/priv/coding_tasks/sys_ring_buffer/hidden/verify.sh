#!/usr/bin/env bash
set -euo pipefail
cd /work
make test
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
make -s print-lib > "$build/sources"
mapfile -t lib_sources < "$build/sources"
gcc -std=c99 -Wall -Wextra -Werror -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -I/work /verify/test_ring.c "${lib_sources[@]}" -o "$build/test_ring"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$build/test_ring"
make all
python3 - <<'PY'
import subprocess
for args, expected in [(['4', '-2', '17'], b'4 -2 17\n'), ([], b'\n')]:
    result = subprocess.run(['./ring_demo', *args], capture_output=True)
    assert result.returncode == 0, (args, result.returncode, result.stderr)
    assert result.stdout == expected, (args, result.stdout, expected)
PY
