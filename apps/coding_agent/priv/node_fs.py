"""Worker-owned serialized filesystem service. No RPC input supplies policy.

Paths are walked through pinned directory descriptors. Every open is NOFOLLOW;
symlinks are resolved explicitly and re-admitted beneath a configured root.
This prevents substituted symlinks from redirecting an operation outside roots;
it does not sandbox other processes or prevent them moving an already-open inode.
"""
import base64
import ctypes
import errno
import hashlib
import heapq
import json
import os
import secrets
import stat
import struct
import sys
import time

MAX_CHUNK = 1048576
MAX_CANDIDATES = 10000
MAX_POLICIES = 128
MAX_ROOT_DESCRIPTORS = 128
MAX_PREVIEWS = 128
MAX_TOTAL_CANDIDATES = 20000
MAX_RECORD_BYTES = 8 * 1024 * 1024
MAX_TOTAL_RECORD_BYTES = 16 * 1024 * 1024
MAX_DEPTH = 64
TTL_MS = 300000
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
policies = {}
previews = {}


class Failure(Exception):
    pass


def fail(name):
    raise Failure(name)


def bounded_int(args, key, default, low=0, high=9007199254740991):
    value = args.get(key, default)
    if type(value) is not int or not low <= value <= high:
        fail("invalid_request")
    return value


def boolean(args, key, default=False):
    value = args.get(key, default)
    if type(value) is not bool:
        fail("invalid_request")
    return value


def valid_path(path):
    if not isinstance(path, str) or not 1 <= len(path.encode("utf-8")) <= 4096 or "\0" in path:
        fail("invalid_path")
    if ".." in path.split("/"):
        fail("path_not_allowed")
    return path


def inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def open_absolute(path):
    fd = os.open("/", DIR_FLAGS)
    try:
        for part in path.split("/"):
            if not part:
                continue
            nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


class Policy:
    def __init__(self, config):
        self.cwd = os.path.abspath(valid_path(config["cwd"]))
        roots = config["roots"]
        if not isinstance(roots, list) or not 1 <= len(roots) <= 64:
            fail("invalid_allowed_roots")
        self.roots = []
        try:
            for lexical in roots:
                lexical = os.path.abspath(valid_path(lexical))
                canonical = os.path.realpath(lexical)
                fd = open_absolute(canonical)
                self.roots.append((lexical, canonical, fd))
        except BaseException:
            for _, _, fd in self.roots:
                os.close(fd)
            fail("invalid_allowed_roots")

    def choose(self, path, canonical_only=False):
        candidates = [(lexical, root, fd) for lexical, root, fd in self.roots
                      if inside(path, root) or (not canonical_only and inside(path, lexical))]
        if not candidates:
            fail("path_not_allowed")
        lexical, root, fd = max(candidates, key=lambda item: len(item[1]))
        base = root if inside(path, root) else lexical
        relative = os.path.relpath(path, base)
        return root, fd, [] if relative == "." else relative.split("/")

    def parent(self, caller, mkdirs=False):
        path = os.path.abspath(os.path.join(self.cwd, valid_path(caller)))
        root, anchor, parts = self.choose(path)
        fd = os.dup(anchor)
        current = root
        hops = 40
        try:
            while parts:
                part, rest = parts[0], parts[1:]
                # One readlinkat classifies the entry and reads any link target
                # atomically. Separate stat/readlink calls let a link replaced by
                # a directory in between surface as an unclassified EINVAL.
                missing = False
                try:
                    target = os.readlink(part, dir_fd=fd)
                except FileNotFoundError:
                    target, missing = None, True
                except OSError as exc:
                    if exc.errno != errno.EINVAL:
                        raise
                    target = None
                if target is not None:
                    if hops == 0:
                        fail("symlink_loop")
                    hops -= 1
                    resolved = os.path.normpath(os.path.join(current, target))
                    root, anchor, target_parts = self.choose(resolved, canonical_only=True)
                    os.close(fd)
                    fd = os.dup(anchor)
                    current = root
                    parts = target_parts + rest
                    continue
                if not rest:
                    return fd, part, os.path.join(current, part)
                if missing and mkdirs:
                    try:
                        os.mkdir(part, dir_fd=fd)
                    except FileExistsError:
                        pass
                nxt = os.open(part, DIR_FLAGS, dir_fd=fd)
                os.close(fd)
                fd = nxt
                current = os.path.join(current, part)
                parts = rest
            return fd, ".", current
        except BaseException:
            os.close(fd)
            raise

    def not_root(self, path):
        if any(path == root for _, root, _ in self.roots):
            fail("path_not_allowed")


def revision(s):
    return [s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def view(path, s, parent, name):
    kind = "regular" if stat.S_ISREG(s.st_mode) else "directory" if stat.S_ISDIR(s.st_mode) else "symlink" if stat.S_ISLNK(s.st_mode) else "other"
    effective = os.access in os.supports_effective_ids
    if not effective and (os.getuid() != os.geteuid() or os.getgid() != os.getegid()):
        fail("filesystem_failed")
    access_opts = {"dir_fd": parent, "follow_symlinks": False}
    if effective:
        access_opts["effective_ids"] = True
    return {"path": path, "type": kind, "size": s.st_size, "mtimeMs": s.st_mtime_ns // 1000000, "mode": s.st_mode,
            "readable": os.access(name, os.R_OK, **access_opts), "writable": os.access(name, os.W_OK, **access_opts)}


def regular(fd):
    s = os.fstat(fd)
    if not stat.S_ISREG(s.st_mode):
        fail("not_regular_file")
    return s


def expected(args, s):
    value = args.get("expectedModifiedAtMs")
    if value is not None:
        value = bounded_int(args, "expectedModifiedAtMs", None)
    if s is None:
        if value not in (None, 0):
            fail("revision_conflict")
    elif value is None or value == 0 or value != s.st_mtime_ns // 1000000:
        fail("revision_conflict")


libc = ctypes.CDLL(None, use_errno=True)


def rename_no_replace(src_fd, src, dst_fd, dst):
    if sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        result = libc.renameatx_np(src_fd, os.fsencode(src), dst_fd, os.fsencode(dst), 4)
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        result = libc.renameat2(src_fd, os.fsencode(src), dst_fd, os.fsencode(dst), 1)
    else:
        fail("atomic_move_unavailable")
    if result != 0:
        code = ctypes.get_errno()
        if code in (errno.ENOSYS, errno.EINVAL, errno.ENOTSUP):
            fail("atomic_move_unavailable")
        raise OSError(code, os.strerror(code))


def bounded_names(fd, maximum, error="preview_too_large"):
    names = []
    with os.scandir(fd) as entries:
        for entry in entries:
            if len(names) >= maximum:
                fail(error)
            names.append(entry.name)
    return sorted(names)


def snapshot(parent, name, recursive):
    records = {}
    direct_count = 0
    record_bytes = 0

    def record(relative, s):
        nonlocal record_bytes
        if len(records) >= MAX_CANDIDATES or relative.count("/") >= MAX_DEPTH:
            fail("preview_too_large")
        record_bytes += len(relative.encode("utf-8")) + 512
        if record_bytes > MAX_RECORD_BYTES:
            fail("preview_too_large")
        records[relative] = revision(s)

    def visit(fd, leaf, relative):
        nonlocal direct_count
        s = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
        record(relative, s)
        if stat.S_ISDIR(s.st_mode):
            child_fd = os.open(leaf, DIR_FLAGS, dir_fd=fd)
            try:
                if revision(os.fstat(child_fd)) != revision(s):
                    fail("stale_preview")
                with os.scandir(child_fd) as children:
                    for child in children:
                        if relative == "":
                            direct_count += 1
                        key = child.name if not relative else relative + "/" + child.name
                        if recursive:
                            visit(child_fd, child.name, key)
                        else:
                            record(key, os.stat(child.name, dir_fd=child_fd, follow_symlinks=False))
                if revision(os.fstat(child_fd)) != revision(s):
                    fail("stale_preview")
            finally:
                os.close(child_fd)
    visit(parent, name, "")
    digest = hashlib.sha256(json.dumps(sorted(records.items()), separators=(",", ":")).encode()).hexdigest()
    return records, direct_count, digest


def remove_bound(parent, name, relative, records):
    # Atomically capture each entry before checking its identity. Replacements
    # cannot be deleted merely because a pre-stat once matched the preview.
    temporary = ".lemon-delete-" + secrets.token_hex(16)
    rename_no_replace(parent, name, parent, temporary)
    try:
        s = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
        # Renaming can change ctime, but not content mtime, size or identity.
        if revision(s)[:5] != records[relative][:5]:
            fail("stale_preview")
        if stat.S_ISDIR(s.st_mode):
            fd = os.open(temporary, DIR_FLAGS, dir_fd=parent)
            try:
                bound_names = sorted(key[len(relative) + 1:] if relative else key
                                     for key in records if key != relative and
                                     (key.startswith(relative + "/") if relative else True) and
                                     "/" not in (key[len(relative) + 1:] if relative else key))
                names = bounded_names(fd, len(bound_names), "stale_preview")
                if names != bound_names:
                    fail("stale_preview")
                for child in names:
                    key = child if not relative else relative + "/" + child
                    remove_bound(fd, child, key, records)
            finally:
                os.close(fd)
            os.rmdir(temporary, dir_fd=parent)
        else:
            os.unlink(temporary, dir_fd=parent)
    except BaseException:
        # Never overwrite a concurrently created original name during rollback.
        # A conflict leaves the captured entry under its private staging name.
        try:
            rename_no_replace(parent, temporary, parent, name)
        except OSError:
            pass
        raise


def operation(method, args, policy, policy_key):
    if method == "node.fs.delete" and (not isinstance(args.get("path"), str) or args.get("confirm") != args.get("path")):
        fail("confirmation_required")
    if method == "node.fs.write":
        data = args.get("dataBase64")
        if not isinstance(data, str):
            fail("invalid_base64")
        if len(data) > 1398104:
            fail("content_too_large")
        try:
            data = base64.b64decode(data, validate=True)
        except (ValueError, TypeError):
            fail("invalid_base64")
        if len(data) > MAX_CHUNK:
            fail("content_too_large")
        offset = bounded_int(args, "offset", 0)
        truncate = boolean(args, "truncate", True)
        mkdirs = boolean(args, "mkdirs")
        if "expectedModifiedAtMs" in args:
            bounded_int(args, "expectedModifiedAtMs", None)
    else:
        mkdirs = method == "node.fs.mkdir"
    if method == "node.fs.read":
        offset = bounded_int(args, "offset", 0)
        length = bounded_int(args, "length", MAX_CHUNK, 1, MAX_CHUNK)
    if method == "node.fs.list":
        hidden = boolean(args, "showHidden")
    if method == "node.fs.delete.preview":
        recursive = boolean(args, "recursive")
    if method == "node.fs.move":
        overwrite = boolean(args, "overwrite")
        bounded_int(args, "expectedModifiedAtMs", None)
    parent, name, path = policy.parent(args.get("path"), mkdirs)
    try:
        if method in ("node.fs.read", "node.fs.write"):
            try:
                admission = os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                if method == "node.fs.read":
                    raise
            else:
                if stat.S_ISLNK(admission.st_mode):
                    fail("path_not_allowed")
                if not stat.S_ISREG(admission.st_mode):
                    fail("not_regular_file")
            # Admission only classifies nonregular targets. The actual open
            # remains NOFOLLOW, and regular-file/CAS checks use the opened fd.
        if method == "node.fs.stat":
            return view(path, os.stat(name, dir_fd=parent, follow_symlinks=False), parent, name)
        if method == "node.fs.list":
            fd = os.open(name, DIR_FLAGS, dir_fd=parent)
            try:
                with os.scandir(fd) as directory:
                    names = heapq.nsmallest(501, (entry.name for entry in directory if hidden or not entry.name.startswith(".")))
                entries = []
                for child in names[:500]:
                    try:
                        entry = view(os.path.join(path, child), os.stat(child, dir_fd=fd, follow_symlinks=False), fd, child)
                        entry["name"] = child
                    except OSError as exc:
                        entry = {"name": child, "error": error_name(exc)}
                    entries.append(entry)
                return {"path": path, "entries": entries, "limit": 500, "truncated": len(names) > 500}
            finally:
                os.close(fd)
        if method == "node.fs.read":
            fd = os.open(name, os.O_RDONLY | FILE_FLAGS, dir_fd=parent)
            try:
                s = regular(fd)
                data = os.pread(fd, length, offset)
                return {"path": path, "offset": offset, "length": len(data), "size": s.st_size,
                        "dataBase64": base64.b64encode(data).decode(), "eof": offset + len(data) >= s.st_size}
            finally:
                os.close(fd)
        if method == "node.fs.write":
            try:
                fd = os.open(name, os.O_RDWR | FILE_FLAGS, dir_fd=parent)
            except FileNotFoundError:
                expected(args, None)
                fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | FILE_FLAGS, 0o666, dir_fd=parent)
                previous = None
            else:
                previous = os.fstat(fd)
            try:
                regular(fd)
                if previous is not None:
                    expected(args, previous)
                written = 0
                while written < len(data):
                    count = os.pwrite(fd, data[written:], offset + written)
                    if count <= 0:
                        fail("filesystem_failed")
                    written += count
                if truncate:
                    os.ftruncate(fd, offset + written)
                s = os.fstat(fd)
                # Ensure two worker CAS writes cannot win with the same ms value.
                minimum = (previous.st_mtime_ns // 1000000 + 1) * 1000000 if previous else 0
                if s.st_mtime_ns < minimum:
                    os.utime(fd, ns=(s.st_atime_ns, minimum))
                    if os.fstat(fd).st_mtime_ns // 1000000 <= previous.st_mtime_ns // 1000000:
                        next_second = (previous.st_mtime_ns // 1000000000 + 1) * 1000000000
                        os.utime(fd, ns=(s.st_atime_ns, next_second))
                final_stat = os.fstat(fd)
                return {"path": path, "offset": offset, "bytesWritten": written, "size": final_stat.st_size,
                        "mtimeMs": final_stat.st_mtime_ns // 1000000}
            finally:
                os.close(fd)
        if method == "node.fs.mkdir":
            try:
                os.mkdir(name, dir_fd=parent)
            except FileExistsError:
                fd = os.open(name, DIR_FLAGS, dir_fd=parent)
                os.close(fd)
            return {"path": path, "created": True}
        if method == "node.fs.move":
            policy.not_root(path)
            destination_parent, destination_name, destination = policy.parent(args.get("destination"))
            try:
                policy.not_root(destination)
                temporary = ".lemon-move-" + secrets.token_hex(16)
                rename_no_replace(parent, name, parent, temporary)
                try:
                    s = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
                    if stat.S_ISLNK(s.st_mode):
                        fail("path_not_allowed")
                    expected(args, s)
                    if overwrite:
                        os.rename(temporary, destination_name, src_dir_fd=parent, dst_dir_fd=destination_parent)
                    else:
                        rename_no_replace(parent, temporary, destination_parent, destination_name)
                except BaseException:
                    try:
                        rename_no_replace(parent, temporary, parent, name)
                    except OSError:
                        pass
                    raise
                return {"path": path, "destination": destination, "moved": True}
            finally:
                os.close(destination_parent)
        if method == "node.fs.delete.preview":
            policy.not_root(path)
            records, child_count, digest = snapshot(parent, name, recursive)
            if recursive:
                for relative in records:
                    policy.not_root(os.path.join(path, relative) if relative else path)
            s = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if revision(s) != records[""]:
                fail("stale_preview")
            if not stat.S_ISREG(s.st_mode) and not stat.S_ISDIR(s.st_mode):
                fail("not_regular_file")
            stat_view = view(path, s, parent, name)
            token = secrets.token_urlsafe(32)
            now = time.time_ns() // 1000000
            for key in list(previews):
                if previews[key]["expires"] < now:
                    del previews[key]
            record_bytes = sum(len(relative.encode("utf-8")) + 512 for relative in records)
            if (len(previews) >= MAX_PREVIEWS or
                    sum(len(preview["records"]) for preview in previews.values()) + len(records) > MAX_TOTAL_CANDIDATES or
                    sum(preview["recordBytes"] for preview in previews.values()) + record_bytes > MAX_TOTAL_RECORD_BYTES):
                fail("preview_too_large")
            expires = now + TTL_MS
            previews[token] = {"policy": policy_key, "caller": args["path"], "path": path,
                               "records": records, "recursive": recursive, "expires": expires, "recordBytes": record_bytes}
            return {"path": path, "stat": stat_view, "childCount": child_count,
                    "childrenDigest": digest, "candidateCount": len(records) if recursive else 1,
                    "confirmationToken": token, "expiresAtMs": expires}
        if method == "node.fs.delete":
            policy.not_root(path)
            token = args.get("confirmationToken")
            if not isinstance(token, str) or not token:
                fail("invalid_confirmation_token")
            preview = previews.pop(token, None)
            if preview is None or preview["policy"] != policy_key or preview["caller"] != args["path"]:
                fail("invalid_confirmation_token")
            if preview["expires"] < time.time_ns() // 1000000:
                fail("confirmation_expired")
            if preview["path"] != path:
                fail("stale_preview")
            try:
                records, child_count, _ = snapshot(parent, name, preview["recursive"])
            except (OSError, Failure):
                fail("stale_preview")
            if records != preview["records"]:
                fail("stale_preview")
            if child_count and not preview["recursive"]:
                fail("directory_not_empty")
            remove_bound(parent, name, "", records)
            return {"path": path, "deleted": True}
        fail("invalid_request")
    finally:
        os.close(parent)


def error_name(exc):
    return {errno.ENOENT: "not_found", errno.EACCES: "permission_denied", errno.EPERM: "permission_denied",
            errno.ENOTDIR: "not_directory", errno.EISDIR: "not_regular_file", errno.ENOTEMPTY: "directory_not_empty",
            errno.EEXIST: "already_exists", errno.ELOOP: "path_not_allowed"}.get(exc.errno, "filesystem_failed")


def read_exact(count):
    chunks = bytearray()
    while len(chunks) < count:
        data = sys.stdin.buffer.read(count - len(chunks))
        if not data:
            return None
        chunks.extend(data)
    return chunks


def respond(body):
    """Return the reply object for one request body. Errors are fixed classifications."""
    try:
        request = json.loads(body)
        config = request["policy"]
        key = json.dumps(config, sort_keys=True)
        if key not in policies:
            roots = config.get("roots")
            if not isinstance(roots, list) or not 1 <= len(roots) <= 64:
                fail("invalid_allowed_roots")
            if len(policies) >= MAX_POLICIES or sum(len(policy.roots) for policy in policies.values()) + len(roots) > MAX_ROOT_DESCRIPTORS:
                fail("filesystem_busy")
            policies[key] = Policy(config)
        return {"ok": operation(request["method"], request["args"], policies[key], key)}
    except Failure as exc:
        return {"error": str(exc)}
    except OSError as exc:
        return {"error": error_name(exc)}
    except Exception:
        return {"error": "filesystem_failed"}


def main():
    # PTY imports Policy for descriptor-rooted cwd admission. Importing this
    # module must never read that caller's protocol or emit filesystem frames.
    while True:
        header = read_exact(4)
        if header is None:
            break
        size = struct.unpack(">I", header)[0]
        if size > 2000000:
            break
        body = read_exact(size)
        if body is None:
            break
        payload = json.dumps(respond(body), separators=(",", ":")).encode()
        sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
