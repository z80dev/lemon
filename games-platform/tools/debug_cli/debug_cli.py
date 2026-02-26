#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import threading
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def build_mix_cmd(
    elixir_script: Path,
    cwd: str,
    model: str | None,
    system_prompt: str | None,
    base_url: str | None,
) -> list[str]:
    cmd = ["mix", "run", str(elixir_script), "--", "--cwd", cwd]
    if model:
        cmd += ["--model", model]
    if system_prompt:
        cmd += ["--system-prompt", system_prompt]
    if base_url:
        cmd += ["--base-url", base_url]
    return cmd


def _extract_assistant_text(message: dict) -> str:
    content = message.get("content") or []
    parts = []
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text")
                if text:
                    parts.append(text)
    elif isinstance(content, str):
        parts.append(content)
    return "".join(parts)


def reader_thread(proc: subprocess.Popen, debug: bool):
    for line in proc.stdout:
        line = line.rstrip("\n")
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            print(line)
            continue

        kind = payload.get("type", "event")
        if kind == "ready":
            model = payload.get("model", {})
            debug_flag = payload.get("debug")
            debug_suffix = f" debug={debug_flag}" if debug_flag is not None else ""
            print(
                f"[ready] cwd={payload.get('cwd')} model={model.get('provider')}:{model.get('id')}{debug_suffix}"
            )
            continue

        if debug:
            if kind == "event":
                event = payload.get("event", {})
                print(json.dumps(event, indent=2, sort_keys=True))

                event_type = event.get("type")
                data = event.get("data") or []
                if event_type == "message_end" and data:
                    message = data[0]
                    if isinstance(message, dict) and message.get("role") == "assistant":
                        text = _extract_assistant_text(message)
                        if text.strip():
                            print(f"[assistant] {text}")
            elif kind == "stats":
                stats = payload.get("stats", {})
                print(json.dumps({"type": "stats", "stats": stats}, indent=2, sort_keys=True))
            elif kind == "pong":
                print("[pong]")
            elif kind == "debug":
                message = payload.get("message", "")
                stats = payload.get("stats")
                if stats is not None:
                    print(
                        json.dumps(
                            {"type": "debug", "message": message, "stats": stats}, indent=2, sort_keys=True
                        )
                    )
                else:
                    print(f"[debug] {message}")
            elif kind == "error":
                print(f"[error] {payload.get('message')}")
            else:
                print(json.dumps(payload, indent=2, sort_keys=True))
            continue

        # Non-debug: show only assistant responses and tool calls.
        if kind == "event":
            event = payload.get("event", {})
            event_type = event.get("type")
            data = event.get("data") or []

            if event_type == "message_end" and data:
                message = data[0]
                if isinstance(message, dict) and message.get("role") == "assistant":
                    text = _extract_assistant_text(message)
                    if text.strip():
                        print(text)
            elif event_type == "tool_execution_start" and len(data) >= 3:
                _, name, args = data[0], data[1], data[2]
                print(f"[tool] {name} {args}")
            elif event_type == "tool_execution_end" and len(data) >= 4:
                _, name, result, is_error = data[0], data[1], data[2], data[3]
                if isinstance(is_error, str):
                    is_error = is_error.lower() == "true"
                status = "error" if is_error else "ok"
                print(f"[tool] {name} -> {status}")
        elif kind == "pong":
            print("[pong]")
        elif kind == "error":
            print(f"[error] {payload.get('message')}")


def send_json(proc: subprocess.Popen, data: dict, debug: bool = False):
    if debug:
        print(f"[debug] -> {json.dumps(data)}")
    proc.stdin.write(json.dumps(data) + "\n")
    proc.stdin.flush()


def repl(proc: subprocess.Popen, debug: bool = False):
    while True:
        try:
            line = input("> ")
        except EOFError:
            send_json(proc, {"type": "quit"}, debug=debug)
            return

        text = line.strip()
        if not text:
            continue

        if text in {":q", "/q", ":quit", "/quit"}:
            send_json(proc, {"type": "quit"}, debug=debug)
            return
        if text in {":abort", "/abort"}:
            send_json(proc, {"type": "abort"}, debug=debug)
            continue
        if text in {":reset", "/reset"}:
            send_json(proc, {"type": "reset"}, debug=debug)
            continue
        if text in {":save", "/save"}:
            send_json(proc, {"type": "save"}, debug=debug)
            continue
        if text in {":stats", "/stats"}:
            send_json(proc, {"type": "stats"}, debug=debug)
            continue
        if text in {":ping", "/ping"}:
            send_json(proc, {"type": "ping"}, debug=debug)
            continue

        send_json(proc, {"type": "prompt", "text": text}, debug=debug)


def main() -> int:
    parser = argparse.ArgumentParser(description="Debug CLI for CodingAgent")
    parser.add_argument("--cwd", default=str(Path.cwd()), help="Working directory for the agent")
    parser.add_argument("--model", default=None, help="Model as provider:model_id")
    parser.add_argument("--system-prompt", default=None, help="Override system prompt")
    parser.add_argument("--base-url", default=None, help="Override model base URL")
    parser.add_argument("--debug", action="store_true", help="Enable debug logs from Elixir")
    args = parser.parse_args()

    root = repo_root()
    script = root / "scripts" / "debug_agent_rpc.exs"
    if not script.exists():
        print(f"Missing Elixir script: {script}")
        return 1

    cmd = build_mix_cmd(script, args.cwd, args.model, args.system_prompt, args.base_url)
    if args.debug:
        cmd += ["--debug"]

    env = dict(**{k: v for k, v in os.environ.items()})
    if args.debug:
        env["LEMON_DEBUG_RPC"] = "1"

    proc = subprocess.Popen(
        cmd,
        cwd=str(root),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env,
    )

    t = threading.Thread(target=reader_thread, args=(proc, args.debug), daemon=True)
    t.start()

    try:
        repl(proc, debug=args.debug)
    finally:
        try:
            proc.terminate()
        except Exception:
            pass

    return proc.wait()


if __name__ == "__main__":
    raise SystemExit(main())
