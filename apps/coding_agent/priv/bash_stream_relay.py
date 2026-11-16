"""Private local shell transport. All children retain the owner's process group."""
import codecs
import json
import os
import selectors
import subprocess
import sys


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=True) + "\n")
    sys.stdout.flush()


process = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
selector = selectors.DefaultSelector()
for name, stream in (("stdout", process.stdout), ("stderr", process.stderr)):
    selector.register(stream, selectors.EVENT_READ, (name, codecs.getincrementaldecoder("utf-8")("replace")))
while selector.get_map():
    for key, _ in selector.select():
        name, decoder = key.data
        chunk = os.read(key.fd, 4096)
        text = decoder.decode(chunk, final=not chunk)
        if text:
            emit({"stream": name, "data": text})
        if not chunk:
            selector.unregister(key.fileobj)
            key.fileobj.close()
status = process.wait()
emit({"exit_code": status if status >= 0 else 128 - status})
