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

Stdin for user code is /dev/null. When the host closes the command pipe, the
kernel kills its own process group (it is the group leader) and exits.
"""

import ast
import asyncio
import builtins
import inspect
import json
import linecache
import os
import platform
import queue
import signal
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
    try:
        os.setpgrp()
        group_leader = os.getpgrp() == os.getpid()
    except OSError:
        pass

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
        os._exit(0)

    threading.Thread(target=read_commands, name="lemon-eval-commands", daemon=True).start()

    module = types.ModuleType("__main__")
    module.__dict__["__builtins__"] = builtins
    sys.modules["__main__"] = module
    namespace = module.__dict__

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

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
        result = run_cell(namespace, loop, str(message.get("code", "")), "<cell %d>" % cell)
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
