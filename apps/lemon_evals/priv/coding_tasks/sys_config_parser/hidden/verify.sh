#!/usr/bin/env bash
set -euo pipefail
cd /work
make test
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
gcc -std=c99 -Wall -Wextra -Werror -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -I/work /verify/test_config.c config.c -o "$build/test_config"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$build/test_config"
make all
python3 - <<'PY'
import subprocess
p=subprocess.run(['./config_dump'],input=b'b=one\\#two\na="line\\nnext"\nb=last\n',capture_output=True)
assert p.returncode==0 and p.stdout==b'b="last"\na="line\\nnext"\n'
p=subprocess.run(['./config_dump'],input=b'#comment\nx="bad"junk\n',capture_output=True)
assert p.returncode==1 and p.stdout==b'' and p.stderr==b'line 2: invalid configuration\n'
p=subprocess.run(['./config_dump'],input=b'',capture_output=True)
assert p.returncode==0 and not p.stdout
PY
