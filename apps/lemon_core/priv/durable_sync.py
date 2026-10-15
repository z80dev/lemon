"""Private Darwin stable-storage barrier. Literal mode/path argv; no output.

Both directory metadata and regular-file contents require fsync followed by
Darwin F_FULLFSYNC (51), which asks the device to flush its buffered writes.
An unsupported filesystem/syscall fails; there is no weaker flush fallback.
"""
import fcntl
import os
import stat
import sys


def main():
    if sys.platform != "darwin" or len(sys.argv) != 3 or sys.argv[1] not in ("file", "directory"):
        return 64
    kind, path = sys.argv[1:]
    descriptor = None
    try:
        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
        if kind == "directory":
            flags |= os.O_DIRECTORY
        descriptor = os.open(path, flags)
        mode = os.fstat(descriptor).st_mode
        if not (stat.S_ISDIR(mode) if kind == "directory" else stat.S_ISREG(mode)):
            return 65
        os.fsync(descriptor)
        # Darwin's documented F_FULLFSYNC command; never ordinary sync(8).
        fcntl.fcntl(descriptor, 51)
        return 0
    except (OSError, ValueError):
        return 1
    finally:
        if descriptor is not None:
            os.close(descriptor)


if __name__ == "__main__":
    try:
        status = main()
    except Exception:
        # Fail closed without paths, exception text or a diagnostic traceback.
        status = 1
    sys.exit(status)
