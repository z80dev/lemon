#!/usr/bin/env bash
set -euo pipefail
cd /work
make test
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
gcc -std=c99 -Wall -Wextra -Werror -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -I/work /verify/test_packet.c packet.c stream.c -o "$build/test_packet"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$build/test_packet"
make all
python3 - <<'PY'
import subprocess
p=subprocess.run(['./event_dump'],input=bytes([0xd3,1,0,2,104,105,0xd3,2,0,2,0,255,0xd3,3,0,0]),capture_output=True)
assert p.returncode==0 and p.stdout==b'1:2:6869\n2:2:00ff\n3:0:\n'
for payload in (b'\xd3',b'\xd3\x01\x00\x01',b'\xd3\x07\x00\x00'):
    assert subprocess.run(['./event_dump'],input=payload,capture_output=True).returncode==1
p=subprocess.run(['./event_dump'],input=b'',capture_output=True)
assert p.returncode==0 and p.stdout==b''
PY
