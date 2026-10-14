"""Private packet4 process owner: one run frame, optional cancel frame, one reply.

Input: {"op":"run","args":RPC arguments,"policy":node_fs policy}.
Control: {"op":"cancel"}; control EOF also cancels the entire process group.
Output: {"ok":final RPC receipt} or {"error":fixed safe classification}.
No command strings, PTYs, output events, environment overrides or diagnostics.
"""
import base64
import binascii
import errno
import json
import os
import re
import selectors
import signal
import struct
import subprocess
import sys
import time

from node_fs import Policy, Failure, DIR_FLAGS

MAX_FRAME = 4 * 1024 * 1024
MAX_BYTES = 1048576


def invalid():
    raise Failure("invalid_request")


def text(value, maximum, nonempty=False):
    if not isinstance(value, str) or "\0" in value:
        invalid()
    try:
        size = len(value.encode("utf-8", "strict"))
    except UnicodeError:
        invalid()
    if size > maximum or (nonempty and not size):
        invalid()
    return size


def validate(args):
    if not isinstance(args, dict) or set(args) != {
        "nodeId", "processId", "cwd", "argv", "stdinBase64", "timeoutMs", "maxOutputBytes"
    }:
        invalid()
    text(args["nodeId"], 256, True)
    if not isinstance(args["processId"], str) or not re.fullmatch(r"[A-Za-z0-9_:-]{1,128}", args["processId"]):
        invalid()
    text(args["cwd"], 4096, True)
    argv = args["argv"]
    if not isinstance(argv, list) or not 1 <= len(argv) <= 128:
        invalid()
    if sum(text(arg, 131072, index == 0) for index, arg in enumerate(argv)) > 131072:
        invalid()
    for key, low, high in (("timeoutMs", 1000, 1800000), ("maxOutputBytes", 1, MAX_BYTES)):
        if type(args[key]) is not int or not low <= args[key] <= high:
            invalid()
    encoded = args["stdinBase64"]
    if not isinstance(encoded, str) or len(encoded) > 1398104:
        invalid()
    try:
        data = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        invalid()
    if len(data) > MAX_BYTES or base64.b64encode(data).decode("ascii") != encoded:
        invalid()
    return data


def read_exact(size):
    data = bytearray()
    while len(data) < size:
        chunk = os.read(0, min(65536, size - len(data)))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return data


def packet():
    size = struct.unpack(">I", read_exact(4))[0]
    if size > MAX_FRAME:
        invalid()
    return json.loads(read_exact(size))


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def execute(request):
    if not isinstance(request, dict) or request.get("op") != "run":
        invalid()
    args = request["args"]
    stdin = validate(args)
    policy = Policy(request["policy"])
    parent = cwd_fd = None
    process = None
    selector = selectors.DefaultSelector()
    group_stop_requested = False

    def stop_group():
        nonlocal group_stop_requested
        if process is not None and not group_stop_requested:
            # A successful stop request belongs to this execution, not each
            # output chunk or cleanup phase. Never signal its numeric group
            # again while draining or after reaping the stopped leader.
            # Darwin can refuse repeated signals to an already-dead group.
            # A first permission failure remains a real execution error.
            kill_group(process)
            group_stop_requested = True

    try:
        parent, leaf, _ = policy.parent(args["cwd"])
        cwd_fd = os.open(leaf, DIR_FLAGS, dir_fd=parent)
        # The descriptor, not a second path lookup, determines the child cwd.
        process = subprocess.Popen(
            args["argv"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, shell=False, start_new_session=True,
            close_fds=True, pass_fds=(cwd_fd,), preexec_fn=lambda: os.fchdir(cwd_fd)
        )
        os.close(cwd_fd)
        cwd_fd = None
        os.close(parent)
        parent = None
        for _, _, fd in policy.roots:
            os.close(fd)
        policy.roots = []
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        os.set_blocking(0, False)
        selector.register(0, selectors.EVENT_READ, "control")
        if stdin:
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
        else:
            process.stdin.close()
        offset = 0
        outputs = {"stdout": bytearray(), "stderr": bytearray()}
        total = 0
        control = bytearray()
        deadline = time.monotonic() + args["timeoutMs"] / 1000
        cleanup_deadline = None
        cancelled = truncated = False
        exit_code = None

        def cancel():
            nonlocal cancelled, cleanup_deadline
            cancelled = True
            if cleanup_deadline is None:
                cleanup_deadline = time.monotonic() + 1
            stop_group()
            if not process.stdin.closed:
                try:
                    selector.unregister(process.stdin)
                except KeyError:
                    pass
                process.stdin.close()

        while True:
            now = time.monotonic()
            if now >= deadline and cleanup_deadline is None:
                cancel()
            observed = process.poll()
            if observed is not None and exit_code is None:
                exit_code = observed
                # A successful parent must not leave inherited pipes/descendants alive.
                stop_group()
                cleanup_deadline = cleanup_deadline or now + 1
            output_open = any(key.data in ("stdout", "stderr") for key in selector.get_map().values())
            if exit_code is not None and not output_open:
                break
            if cleanup_deadline is not None and now >= cleanup_deadline:
                truncated = truncated or output_open
                break
            until = cleanup_deadline if cleanup_deadline is not None else deadline
            for key, _ in selector.select(min(0.05, max(0, until - now))):
                stream, name = key.fileobj, key.data
                if name == "stdin":
                    # An earlier ready stdout/control event in this same batch
                    # may have cancelled and closed input ownership already.
                    if stream.closed:
                        continue
                    try:
                        written = os.write(stream.fileno(), memoryview(stdin)[offset:offset + 65536])
                        offset += written
                    except BrokenPipeError:
                        offset = len(stdin)
                    except BlockingIOError:
                        continue
                    if offset == len(stdin):
                        selector.unregister(stream)
                        stream.close()
                        stdin = b""
                elif name == "control":
                    try:
                        chunk = os.read(0, min(65536, MAX_FRAME + 4 - len(control)))
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(0)
                        cancel()
                        continue
                    control.extend(chunk)
                    if len(control) >= 4:
                        size = struct.unpack(">I", control[:4])[0]
                        if size > MAX_FRAME or len(control) >= size + 4:
                            # Only cancellation is a legal subsequent packet. Malformed
                            # control closes ownership as well; never execute more work.
                            selector.unregister(0)
                            cancel()
                            control.clear()
                else:
                    try:
                        chunk = os.read(stream.fileno(), 65536)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(stream)
                        stream.close()
                        continue
                    remaining = args["maxOutputBytes"] - total
                    captured = chunk[:remaining]
                    outputs[name].extend(captured)
                    total += len(captured)
                    if len(chunk) > remaining:
                        truncated = True
                        cancel()
        if process.poll() is None:
            stop_group()
            try:
                exit_code = process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
        else:
            exit_code = process.returncode
        return {"processId": args["processId"], "nodeId": args["nodeId"],
                "state": "cancelled" if cancelled else "completed", "exitCode": exit_code,
                "stdoutBase64": base64.b64encode(outputs["stdout"]).decode("ascii"),
                "stderrBase64": base64.b64encode(outputs["stderr"]).decode("ascii"),
                "outputTruncated": truncated}
    finally:
        try:
            stop_group()
        finally:
            # A refused first group stop must still release all owned pipes,
            # policy descriptors and the selector; it is never a success.
            if process is not None:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()
            selector.close()
            if cwd_fd is not None:
                os.close(cwd_fd)
            if parent is not None:
                os.close(parent)
            for _, _, fd in policy.roots:
                os.close(fd)


def main():
    try:
        result = {"ok": execute(packet())}
    except EOFError:
        return
    except Failure as exc:
        name = str(exc)
        result = {"error": name if name in {"invalid_request", "invalid_path", "path_not_allowed",
                  "invalid_allowed_roots", "symlink_loop"} else "process_failed"}
    except OSError as exc:
        result = {"error": {errno.ENOENT: "executable_not_found", errno.EACCES: "permission_denied",
                  errno.EPERM: "permission_denied", errno.ENOTDIR: "not_directory",
                  errno.E2BIG: "argv_too_large", errno.ELOOP: "path_not_allowed"}.get(exc.errno, "process_failed")}
    except Exception:
        result = {"error": "process_failed"}
    payload = json.dumps(result, separators=(",", ":")).encode("utf-8")
    try:
        sys.stdout.buffer.write(struct.pack(">I", len(payload)) + payload)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        pass


if __name__ == "__main__":
    main()
