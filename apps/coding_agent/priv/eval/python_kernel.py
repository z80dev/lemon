"""Lemon `eval` tool kernel: one persistent Python namespace driven over stdio.

Protocol (owned by CodingAgent.Eval.Kernel):

* Commands arrive on the original stdin, one JSON object per line:
  {"op": "execute", "id": <int>, "code": <str>}.
* User code keeps the real stdout/stderr (fd 1/2, merged by the host), so
  prints, C extensions and subprocesses all stream as raw output.
* Protocol frames are written to stdout as single lines prefixed with
  "\\x1eLEMONEVAL:<token>:", where the token comes from LEMON_EVAL_TOKEN and is
  removed from the environment before user code runs. Anything that is not a
  framed line is user output, so user code cannot corrupt the protocol.
* Rich display records go to a bounded private JSONL side channel, never stdout.

Stdin for user code is /dev/null. When the host closes the command pipe, the
kernel kills its own process group (it is the group leader) and exits.
"""

import ast
import base64
import asyncio
import builtins
import inspect
import json
import linecache
import os
import platform
import queue
import shlex
import signal
import subprocess
import sys
import threading
import traceback
import types

DRIVER_FILE = os.path.abspath(__file__)
MAX_DISPLAY_CHARS = 1_000_000


def main():
    token = os.environ.pop("LEMON_EVAL_TOKEN", "")
    marker = ("\x1eLEMONEVAL:" + token + ":").encode("ascii")

    group_leader = False
    if hasattr(os, "setpgrp"):
        try:
            os.setpgrp()
        except OSError:
            pass
        group_leader = os.getpgrp() == os.getpid()
        if not group_leader:
            raise RuntimeError("could not isolate the Python kernel process group")

    command_fd = os.dup(0)
    devnull = os.open(os.devnull, os.O_RDONLY)
    os.dup2(devnull, 0)
    os.close(devnull)

    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(line_buffering=True, write_through=True)
        except (AttributeError, ValueError):
            pass

    # Imports resolve against the kernel cwd (the session cwd), not this file.
    sys.path[0] = ""

    write_lock = threading.Lock()

    def send(message):
        for stream in (sys.stdout, sys.stderr, sys.__stdout__, sys.__stderr__):
            try:
                stream.flush()
            except Exception:
                pass
        data = marker + json.dumps(message, ensure_ascii=True).encode("ascii") + b"\n"
        with write_lock:
            view = memoryview(data)
            while view:
                written = os.write(1, view)
                view = view[written:]

    commands = queue.Queue()

    def read_commands():
        with os.fdopen(command_fd, "rb") as source:
            for line in source:
                commands.put(line)
        # The host closed the pipe: nothing can read results any more.
        if group_leader:
            os.killpg(os.getpgrp(), signal.SIGKILL)
        elif os.name == "nt":
            subprocess.run(
                ["taskkill", "/F", "/T", "/PID", str(os.getpid())],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            )
        os._exit(0)

    threading.Thread(target=read_commands, name="lemon-eval-commands", daemon=True).start()

    module = types.ModuleType("__main__")
    module.__dict__["__builtins__"] = builtins
    sys.modules["__main__"] = module
    namespace = module.__dict__

    display_path = os.environ.pop("LEMON_EVAL_DISPLAY_PATH")
    pip_command = json.loads(os.environ.pop("LEMON_EVAL_PIP_COMMAND", "null"))
    display_bytes = 0
    display_count = 0

    def display(value, mime=None):
        nonlocal display_bytes, display_count
        if mime is None and isinstance(value, dict) and len(value) == 1:
            kind, content = next(iter(value.items()))
            if kind in ("image/png", "image/jpeg", "text/markdown", "application/json"):
                mime, value = kind, content
        if mime is None:
            for method, kind in (("_repr_png_", "image/png"), ("_repr_jpeg_", "image/jpeg"),
                                 ("_repr_markdown_", "text/markdown"), ("_repr_json_", "application/json")):
                formatter = getattr(value, method, None)
                if callable(formatter):
                    rendered = formatter()
                    if rendered is not None:
                        mime, value = kind, rendered
                        break
        if mime is None and isinstance(value, (bytes, bytearray, memoryview)):
            value = bytes(value)
            if value.startswith(b"\x89PNG\r\n\x1a\n"):
                mime = "image/png"
            elif value.startswith(b"\xff\xd8\xff"):
                mime = "image/jpeg"
            else:
                raise ValueError("display bytes must be PNG or JPEG")
        mime = mime or ("text/markdown" if isinstance(value, str) else "application/json")
        if mime in ("image/png", "image/jpeg"):
            if not isinstance(value, (bytes, bytearray, memoryview)):
                raise TypeError("image display requires bytes")
            payload = {"mime": mime, "data": base64.b64encode(value).decode("ascii")}
        elif mime in ("text/markdown", "application/json"):
            payload = {"mime": mime, "data": value}
        else:
            raise ValueError("unsupported display MIME type: " + mime)
        encoded = (json.dumps(payload, ensure_ascii=True) + "\n").encode("ascii")
        if len(encoded) > 1024 * 1024 or display_bytes + len(encoded) > 4 * 1024 * 1024 or display_count >= 32:
            raise ValueError("display limit exceeded (1 MiB per output, 4 MiB / 32 outputs per cell)")
        with open(display_path, "ab") as sink:
            sink.write(encoded)
        display_bytes += len(encoded)
        display_count += 1

    namespace["display"] = display

    def run_magic(code):
        words = shlex.split(code.strip())
        if words[0] == "%pip":
            if len(words) < 2 or words[1] != "install":
                raise ValueError("supported pip magic: %pip install <arguments>")
            subprocess.run((pip_command or [sys.executable, "-m", "pip"]) + words[1:], check=True)
        elif words[0] == "%load" and len(words) == 2:
            with open(words[1], encoding="utf-8") as source:
                exec(compile(source.read(), words[1], "exec"), namespace)
        else:
            raise ValueError("supported magics: %pip install <arguments>, %load <path>")

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    executing = False

    def interrupt_cell(_signal, _frame):
        if executing:
            raise KeyboardInterrupt

    signal.signal(signal.SIGINT, interrupt_cell)

    send({"type": "ready", "runtime": "python", "version": platform.python_version()})

    cell = 0
    while True:
        line = commands.get()
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if not isinstance(message, dict) or message.get("op") != "execute":
            continue

        cell += 1
        display_bytes = 0
        display_count = 0
        code = str(message.get("code", ""))
        try:
            executing = True
            if code.lstrip().startswith("%"):
                run_magic(code)
                result = {"status": "ok", "display": None}
            else:
                result = run_cell(namespace, loop, code, "<cell %d>" % cell)
        except BaseException as exc:
            result = {"status": "error", "error": format_user_exception(exc)}
        finally:
            executing = False
        result["type"] = "result"
        result["id"] = message.get("id")
        send(result)


def run_cell(namespace, loop, code, filename):
    linecache.cache[filename] = (len(code), None, code.splitlines(True), filename)

    try:
        tree = ast.parse(code, filename=filename, mode="exec")
        tail = None
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            tail = ast.Expression(body=tree.body.pop().value)

        flags = ast.PyCF_ALLOW_TOP_LEVEL_AWAIT
        body_code = compile(tree, filename, "exec", flags=flags, dont_inherit=True)
        tail_code = compile(tail, filename, "eval", flags=flags, dont_inherit=True) if tail else None
    except SyntaxError as exc:
        return {"status": "error", "error": "".join(traceback.format_exception_only(type(exc), exc))}

    try:
        run_code(body_code, namespace, loop)
        value = run_code(tail_code, namespace, loop) if tail_code is not None else None
    except BaseException as exc:  # noqa: B036 - SystemExit/KeyboardInterrupt are cell errors too
        return {"status": "error", "error": format_user_exception(exc)}

    if value is None:
        return {"status": "ok", "display": None}

    namespace["_"] = value
    try:
        display = repr(value)
    except BaseException as exc:  # noqa: B036
        display = "<repr() failed: %s>" % format_user_exception(exc).strip()
    if len(display) > MAX_DISPLAY_CHARS:
        display = display[:MAX_DISPLAY_CHARS] + "\n[display truncated at %d characters]" % MAX_DISPLAY_CHARS
    return {"status": "ok", "display": display}


def run_code(code, namespace, loop):
    asyncio.set_event_loop(loop)
    result = eval(code, namespace)  # noqa: S307 - executing the cell is the purpose
    if code.co_flags & inspect.CO_COROUTINE:
        result = loop.run_until_complete(result)
    return result


def format_user_exception(exc):
    tb = exc.__traceback__
    frames = []
    cursor = tb
    while cursor is not None:
        frames.append(cursor)
        cursor = cursor.tb_next

    # Start at the first user-cell frame; drop driver and asyncio plumbing.
    start = next((f for f in frames if f.tb_frame.f_code.co_filename.startswith("<cell ")), None)
    if start is None:
        start = next((f for f in frames if f.tb_frame.f_code.co_filename != DRIVER_FILE), None)

    return "".join(traceback.format_exception(type(exc), exc, start))


if __name__ == "__main__":
    main()
