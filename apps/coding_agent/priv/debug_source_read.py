"""Read one debugger source file beneath a workspace root without following symlinks.

Usage: debug_source_read.py ROOT RELATIVE_PATH LIMIT [SYNC_DIR]

ROOT is opened as a directory; every RELATIVE_PATH component is then opened
relative to its parent's descriptor with O_NOFOLLOW, so a symlink substituted
anywhere below ROOT, at any time, fails the open instead of redirecting it.
The leaf must be a regular file with one link and at most LIMIT bytes; it is
read from that same descriptor. Exit 0 writes the bytes to stdout; any other
exit means no excerpt.

SYNC_DIR is a test seam: after opening directory component N the helper
creates SYNC_DIR/step-N and waits for SYNC_DIR/go-N.
"""
import os
import stat
import sys
import time

DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


def sync_step(sync_dir, index):
    if sync_dir is None:
        return
    open(os.path.join(sync_dir, "step-%d" % index), "w").close()
    deadline = time.monotonic() + 10
    while not os.path.exists(os.path.join(sync_dir, "go-%d" % index)):
        if time.monotonic() > deadline:
            sys.exit(4)
        time.sleep(0.01)


def main():
    if len(sys.argv) not in (4, 5):
        return 2
    root, relative, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
    sync_dir = sys.argv[4] if len(sys.argv) == 5 else None
    parts = relative.split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        return 2

    fd = os.open(root, DIR_FLAGS)
    try:
        for index, part in enumerate(parts[:-1]):
            child = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = child
            sync_step(sync_dir, index)

        leaf = os.open(parts[-1], FILE_FLAGS, dir_fd=fd)
    finally:
        os.close(fd)

    try:
        info = os.fstat(leaf)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
            return 3
        chunks, size = [], 0
        while size <= limit:
            chunk = os.read(leaf, limit + 1 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        if size > limit:
            return 3
    finally:
        os.close(leaf)

    sys.stdout.buffer.write(b"".join(chunks))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError:
        sys.exit(1)
