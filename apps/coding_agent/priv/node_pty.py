"""Lemon node PTY transport: length-prefixed JSON, one unacknowledged output chunk."""
import base64
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

MAX_FRAME = 2 * 1024 * 1024
MAX_OUTPUT = 32 * 1024 * 1024


def emit(value):
    data = json.dumps(value, separators=(",", ":")).encode()
    sys.stdout.buffer.write(struct.pack("!I", len(data)) + data)
    sys.stdout.buffer.flush()


def size(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def read_exact(length):
    # Do not mix buffered stdin reads with the event loop's os.read: buffering
    # could consume the first input frame before the shell is marked ready.
    data = bytearray()
    while len(data) < length:
        chunk = os.read(0, length - len(data))
        if not chunk:
            raise ValueError("missing policy")
        data.extend(chunk)
    return data


def admitted_cwd(cwd):
    # Same owning policy/resolver as filesystem operations. Pin cwd before fork;
    # a substituted path/symlink cannot redirect chdir outside admitted roots.
    from node_fs import Policy, DIR_FLAGS
    header = read_exact(4)
    length = struct.unpack("!I", header)[0]
    if not 1 <= length <= MAX_FRAME:
        raise ValueError("policy limit")
    data = read_exact(length)
    policy = Policy(json.loads(data))
    parent = None
    try:
        parent, name, _ = policy.parent(cwd)
        return os.open(name, DIR_FLAGS, dir_fd=parent)
    finally:
        if parent is not None:
            os.close(parent)
        for _, _, root_fd in policy.roots:
            os.close(root_fd)



def main():
    cwd, shell, cols, rows = sys.argv[1:]
    cwd_fd = admitted_cwd(cwd)
    try:
        os.fchdir(cwd_fd)
    finally:
        os.close(cwd_fd)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(shell, [shell, "-i"])
    def stop(_signal, _frame):
        raise SystemExit()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    size(fd, int(cols), int(rows))
    os.set_blocking(fd, False)
    pending = False
    incoming = bytearray()
    input_bytes = bytearray()
    total = 0
    deadline = time.monotonic() + 3600
    code = 0
    try:
        emit({"type": "ready"})
        while time.monotonic() < deadline:
            read_fds = [0] + ([] if pending else [fd])
            readable, writable, _ = select.select(read_fds, [fd] if input_bytes else [], [], 1)
            if 0 in readable:
                data = os.read(0, 65536)
                if not data:
                    break
                incoming.extend(data)
                if len(incoming) > MAX_FRAME + 4:
                    raise ValueError("frame limit")
                while len(incoming) >= 4:
                    length = struct.unpack("!I", incoming[:4])[0]
                    if length > MAX_FRAME:
                        raise ValueError("frame limit")
                    if len(incoming) < length + 4:
                        break
                    frame = json.loads(incoming[4:4 + length])
                    del incoming[:4 + length]
                    kind = frame["type"]
                    if kind == "ack":
                        pending = False
                    elif kind == "input":
                        input_bytes.extend(base64.b64decode(frame["dataBase64"], validate=True))
                        if len(input_bytes) > 1024 * 1024:
                            raise ValueError("input limit")
                    elif kind == "resize":
                        size(fd, frame["cols"], frame["rows"])
                    elif kind == "close":
                        return
            if fd in writable and input_bytes:
                try:
                    count = os.write(fd, input_bytes[:16384])
                    del input_bytes[:count]
                except BlockingIOError:
                    pass
            if fd in readable:
                try:
                    data = os.read(fd, 16384)
                except OSError:
                    data = b""
                if not data:
                    code = 124
                    for _ in range(100):
                        ended, status = os.waitpid(pid, os.WNOHANG)
                        if ended:
                            code = os.waitstatus_to_exitcode(status)
                            break
                        time.sleep(0.01)
                    break
                total += len(data)
                if total > MAX_OUTPUT:
                    code = 124
                    break
                emit({"type": "output", "dataBase64": base64.b64encode(data).decode()})
                pending = True
        else:
            code = 124
    finally:
        os.close(fd)
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        emit({"type": "exit", "code": code})


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Never expose shell contents, environment, cwd or exception text.
        emit({"type": "exit", "code": 1})
