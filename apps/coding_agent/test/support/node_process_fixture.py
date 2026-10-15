"""Literal-argv fixture for destination pipe/group ownership tests."""
import base64
import json
import os
import subprocess
import sys
import time

mode = sys.argv[1]
if mode == "report":
    raw = sys.stdin.buffer.read()
    sys.stdout.write(json.dumps({"argv": sys.argv[2:], "stdin": base64.b64encode(raw).decode(),
                                "isatty": [os.isatty(fd) for fd in (0, 1, 2)], "cwd": os.getcwd()}, ensure_ascii=False))
    sys.stdout.flush()
    sys.stderr.buffer.write(b"independent-stderr\x00\xff")
    sys.stderr.buffer.flush()
    sys.exit(17)
elif mode == "hold":
    with open(sys.argv[2], "w") as ready:
        ready.write(str(os.getpid()))
    sys.stdin.buffer.read()
    time.sleep(60)
elif mode == "tree":
    child = subprocess.Popen([sys.executable, __file__, "delayed", sys.argv[3]])
    with open(sys.argv[2], "w") as ready:
        ready.write(str(child.pid))
    time.sleep(60)
elif mode == "delayed":
    time.sleep(2)
    with open(sys.argv[2], "w") as marker:
        marker.write("descendant-survived")
    time.sleep(60)
elif mode == "overflow":
    os.write(1, b"o" * 65536)
    os.write(2, b"e" * 65536)
    time.sleep(60)
elif mode == "touch":
    with open(sys.argv[2], "a") as marker:
        marker.write("executed\n")
else:
    sys.exit(2)
