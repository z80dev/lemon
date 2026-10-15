#!/usr/bin/env python3
"""Scriptable fake Debug Adapter Protocol adapter for coding_agent tests.

Speaks DAP over stdio. Every request (and every response to a reverse request)
is appended as a JSON line to the log file given as argv[1], so tests can
assert handshake ordering and payloads.

Behaviour is selected by the launch argument "fakeMode":
  normal          initialized after launch; launch answered after configurationDone
  hang            continue never stops
  reverse         sends runInTerminal + startDebugging reverse requests on launch
  fail_launch     launch fails with "cannot launch: boom"
  crash           writes to stderr and exits(3) when launch arrives
  no_initialized  never sends the initialized event

The launch spawns `sleep 300` as a stand-in debuggee and reports its pid in a
`process` event, so tests can verify the debuggee is killed with the adapter.
"""

import json
import subprocess
import sys
import socket

LOG_PATH = sys.argv[1]
stdin = sys.stdin.buffer
stdout = sys.stdout.buffer
if "--listen" in sys.argv:
    listener = socket.socket()
    listener.bind(("127.0.0.1", int(sys.argv[sys.argv.index("--listen") + 1])))
    listener.listen()
    while True:
        connection, _ = listener.accept()
        subprocess.Popen(
            [sys.executable, __file__, LOG_PATH, "--connection-fd", str(connection.fileno())],
            pass_fds=(connection.fileno(),))
        connection.close()
elif "--connection-fd" in sys.argv:
    connection = socket.socket(fileno=int(sys.argv[sys.argv.index("--connection-fd") + 1]))
    stdin = connection.makefile("rb")
    stdout = connection.makefile("wb")

seq = 0
state = {
    "mode": "normal",
    "breakpoints": {},
    "functions": [],
    "file": None,
    "line": 1,
    "launch_seq": None,
    "stop_on_entry": False,
    "debuggee": None,
    "next_bp_id": 1,
}


def log(entry):
    with open(LOG_PATH, "a") as handle:
        handle.write(json.dumps(entry) + "\n")


def send(message):
    global seq
    seq += 1
    message["seq"] = seq
    body = json.dumps(message).encode()
    stdout.write(b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
    stdout.flush()


def respond(request, body=None, success=True, message=None):
    response = {
        "type": "response",
        "request_seq": request["seq"],
        "command": request["command"],
        "success": success,
    }
    if body is not None:
        response["body"] = body
    if message is not None:
        response["message"] = message
    send(response)


def event(name, body=None):
    message = {"type": "event", "event": name}
    if body is not None:
        message["body"] = body
    send(message)


def read_message():
    headers = {}
    while True:
        line = stdin.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            break
        name, _, value = line.decode().partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers["content-length"])
    return json.loads(stdin.read(length))


def stopped(reason, hit=None):
    body = {"reason": reason, "threadId": 1, "allThreadsStopped": True}
    if hit:
        body["hitBreakpointIds"] = hit
    event("stopped", body)


def first_breakpoint():
    for path, entries in sorted(state["breakpoints"].items()):
        if entries:
            return path, entries[0]
    return None, None


def kill_debuggee():
    if state["debuggee"] is not None:
        state["debuggee"].kill()
        state["debuggee"].wait()
        state["debuggee"] = None


def start_program():
    path, bp = first_breakpoint()
    if bp is not None:
        state["file"], state["line"] = path, bp["line"]
        event("output", {"category": "stdout", "output": "hello from debuggee\n"})
        stopped("breakpoint", [bp["id"]])
    elif state["functions"]:
        state["line"] = 1
        stopped("function breakpoint", [state["functions"][0]["id"]])
    elif state["stop_on_entry"]:
        stopped("entry")
    else:
        finish(0)


def finish(code):
    event("output", {"category": "stdout", "output": "bye\n"})
    event("exited", {"exitCode": code})
    event("terminated")


def handle(request):
    command = request["command"]
    args = request.get("arguments") or {}
    log({"request": command, "arguments": args})

    if command == "initialize":
        respond(request, {
            "supportsConfigurationDoneRequest": True,
            "supportsFunctionBreakpoints": True,
            "supportsTerminateRequest": True,
            "supportsConditionalBreakpoints": True,
            "supportsLogPoints": "--no-capabilities" not in sys.argv,
            "supportsDataBreakpoints": "--no-capabilities" not in sys.argv,
            "supportsInstructionBreakpoints": "--no-capabilities" not in sys.argv,
            "supportsReadMemoryRequest": "--no-capabilities" not in sys.argv,
            "supportsDisassembleRequest": "--no-capabilities" not in sys.argv,
        })
    elif command in ("launch", "attach"):
        state["mode"] = args.get("fakeMode", "normal")
        state["stop_on_entry"] = args.get("stopOnEntry", False)
        state["launch_seq"] = request
        if state["mode"] == "crash":
            sys.stderr.write("fatal adapter error\n")
            sys.stderr.flush()
            sys.exit(3)
        if state["mode"] == "fail_launch":
            respond(request, {"error": {"id": 1, "format": "cannot launch: boom"}}, False, "launch failed")
            return
        state["debuggee"] = subprocess.Popen(
            ["sleep", "300"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        event("process", {"name": args.get("program"), "systemProcessId": state["debuggee"].pid})
        if state["mode"] == "reverse":
            send({"type": "request", "command": "runInTerminal",
                  "arguments": {"kind": "integrated", "args": ["/bin/echo", "hi"], "cwd": "/"}})
            send({"type": "request", "command": "startDebugging",
                  "arguments": {"request": args.get("childRequest", "launch"),
                                "configuration": args.get("childConfiguration", {
                                    "program": "child", "stopOnEntry": True,
                                    "__pendingTargetId": "target-42"})}})
        if state["mode"] != "no_initialized":
            event("initialized")
    elif command == "setBreakpoints":
        path = args["source"]["path"]
        entries = []
        for bp in args.get("breakpoints", []):
            entry = {"id": state["next_bp_id"], "line": bp["line"], "verified": bp["line"] != 999}
            state["next_bp_id"] += 1
            if bp["line"] == 999:
                entry["message"] = "no code at line"
            entries.append(entry)
        state["breakpoints"][path] = entries
        respond(request, {"breakpoints": entries})
    elif command == "setFunctionBreakpoints":
        entries = []
        for bp in args.get("breakpoints", []):
            entries.append({"id": state["next_bp_id"], "verified": True})
            state["next_bp_id"] += 1
        state["functions"] = entries
        respond(request, {"breakpoints": entries})
    elif command == "configurationDone":
        respond(request, {})
        respond(state["launch_seq"], {})
        start_program()
    elif command == "threads":
        respond(request, {"threads": [{"id": 1, "name": "main"}, {"id": 2, "name": "worker"}]})
    elif command == "stackTrace":
        frames = [
            {"id": 100, "name": "main", "line": state["line"], "column": 1,
             "source": {"path": state["file"], "name": "main.c"} if state["file"] else None},
            {"id": 101, "name": "start", "line": 0, "column": 0},
        ]
        frames = [{k: v for k, v in frame.items() if v is not None} for frame in frames]
        levels = args.get("levels") or len(frames)
        respond(request, {"stackFrames": frames[:levels], "totalFrames": len(frames)})
    elif command == "scopes":
        respond(request, {"scopes": [{"name": "Locals", "variablesReference": 10, "expensive": False}]})
    elif command == "variables":
        if args.get("variablesReference") == 10:
            variables = [
                {"name": "x", "value": "40", "type": "int", "variablesReference": 0},
                {"name": "p", "value": "{a=1}", "type": "struct point", "variablesReference": 11},
            ]
        else:
            variables = [{"name": "a", "value": "1", "type": "int", "variablesReference": 0}]
        respond(request, {"variables": variables})
    elif command == "evaluate":
        if args.get("expression") == "fail":
            respond(request, None, False, "cannot evaluate")
        else:
            respond(request, {
                "result": "eval:%s frame=%s ctx=%s" % (args.get("expression"), args.get("frameId"), args.get("context")),
                "type": "string",
                "variablesReference": 0,
            })
    elif command in ("next", "stepIn", "stepOut"):
        respond(request, {})
        state["line"] += 1
        stopped("step")
    elif command == "continue":
        respond(request, {"allThreadsContinued": True})
        if state["mode"] != "hang":
            finish(7)
    elif command == "pause":
        respond(request, {})
        stopped("pause")
    elif command == "terminate":
        respond(request, {})
        kill_debuggee()
        event("terminated")
    elif command == "disconnect":
        respond(request, {})
        kill_debuggee()
        sys.exit(0)
    elif command == "dataBreakpointInfo":
        respond(request, {"dataId": "data-1", "description": args.get("name"), "accessTypes": ["read", "write"]})
    elif command in ("setDataBreakpoints", "setInstructionBreakpoints"):
        respond(request, {"breakpoints": [{"verified": True} for _ in args.get("breakpoints", [])]})
    elif command == "readMemory":
        respond(request, {"address": args.get("memoryReference"), "data": "AQID", "requestedCount": args.get("count")})
    elif command == "disassemble":
        if args.get("memoryReference") == "oversized":
            respond(request, {"instructions": [{"instruction": "X" * (128 * 1024)}]})
        else:
            respond(request, {"instructions": [{"address": "0x10", "instruction": "nop"}], "requestedCount": args.get("instructionCount")})
    elif command == "crash":
        sys.exit(3)
    elif command == "echo":
        respond(request, {"echo": args})
    else:
        respond(request, None, False, "unsupported request %s" % command)


def main():
    while True:
        message = read_message()
        if message is None:
            kill_debuggee()
            return
        if message.get("type") == "request":
            handle(message)
        elif message.get("type") == "response":
            log({"reverse_response": message.get("command"), "success": message.get("success"),
                 "message": message.get("message")})


main()
