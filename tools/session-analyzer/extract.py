"""Phase 1: Parse all JSONL → normalized parquet files.

Produces prompts.parquet, tool_calls.parquet, sessions.parquet.
"""

from __future__ import annotations

import os
import re
from datetime import datetime, timezone
from multiprocessing import Pool
from pathlib import Path
from typing import Any

import orjson
import polars as pl
from rich.progress import Progress, SpinnerColumn, BarColumn, TextColumn, TimeElapsedColumn


# ── Source directories ──────────────────────────────────────────────

CLAUDE_ROOT = Path.home() / ".claude" / "projects"
CODEX_ROOT = Path.home() / ".codex" / "sessions"
CODEX_HISTORY = Path.home() / ".codex" / "history.jsonl"
LEMON_ROOT = Path.home() / ".lemon" / "agent" / "sessions"


# ── Helpers ─────────────────────────────────────────────────────────

def _ts_to_dt(val: Any) -> str | None:
    """Convert various timestamp formats to ISO string."""
    if val is None:
        return None
    if isinstance(val, str):
        return val
    if isinstance(val, (int, float)):
        # epoch millis or seconds
        if val > 1e12:
            val = val / 1000.0
        return datetime.fromtimestamp(val, tz=timezone.utc).isoformat()
    return None


def _strip_xml_tags(text: str) -> str:
    """Strip XML/HTML-like tags and system messages from prompt text."""
    text = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", "", text)
    return text.strip()


def _truncate(s: str, max_len: int = 1024) -> str:
    if len(s) <= max_len:
        return s
    return s[:max_len] + "…"


# ── Claude Code Parser ──────────────────────────────────────────────

def _parse_claude_file(path: str) -> dict:
    """Parse a single Claude Code JSONL file."""
    prompts = []
    tool_calls = []
    session_id = None
    project = None
    prompt_idx = -1
    call_idx = 0

    try:
        with open(path, "rb") as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    line = orjson.loads(raw_line)
                except Exception:
                    continue

                line_type = line.get("type")
                if line_type in ("queue-operation", "file-history-snapshot", "progress"):
                    continue

                if session_id is None:
                    session_id = line.get("sessionId")
                if project is None:
                    project = line.get("cwd")

                msg = line.get("message", {})
                role = msg.get("role")
                content = msg.get("content")
                ts = line.get("timestamp")

                if line_type == "user" and role == "user":
                    if isinstance(content, str) and content.strip():
                        prompt_idx += 1
                        call_idx = 0
                        cleaned = _strip_xml_tags(content)
                        if cleaned:
                            prompts.append({
                                "source": "claude",
                                "session_id": session_id or Path(path).stem,
                                "prompt_idx": prompt_idx,
                                "timestamp": _ts_to_dt(ts),
                                "text": cleaned,
                                "project": project or "",
                                "char_count": len(cleaned),
                            })
                    # Skip tool_result messages (content is a list)

                elif line_type == "assistant" and role == "assistant":
                    if isinstance(content, list):
                        for item in content:
                            if isinstance(item, dict) and item.get("type") == "tool_use":
                                tool_calls.append({
                                    "source": "claude",
                                    "session_id": session_id or Path(path).stem,
                                    "prompt_idx": max(prompt_idx, 0),
                                    "call_idx": call_idx,
                                    "timestamp": _ts_to_dt(ts),
                                    "tool_name": item.get("name", "unknown"),
                                    "arguments_json": _truncate(
                                        orjson.dumps(item.get("input", {})).decode()
                                    ),
                                    "is_error": False,
                                })
                                call_idx += 1
    except Exception:
        pass

    return {"prompts": prompts, "tool_calls": tool_calls}


# ── Codex Parser ────────────────────────────────────────────────────

def _load_codex_history() -> dict[str, list[dict]]:
    """Load codex history.jsonl into a dict keyed by session_id."""
    result: dict[str, list[dict]] = {}
    if not CODEX_HISTORY.exists():
        return result
    try:
        with open(CODEX_HISTORY, "rb") as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    line = orjson.loads(raw_line)
                except Exception:
                    continue
                sid = line.get("session_id")
                if sid:
                    result.setdefault(sid, []).append(line)
    except Exception:
        pass
    return result


def _parse_codex_file(args: tuple[str, dict]) -> dict:
    """Parse a single Codex JSONL session file."""
    path, history_map = args
    prompts = []
    tool_calls = []
    session_id = None
    project = None
    prompt_idx = -1
    call_idx = 0

    try:
        with open(path, "rb") as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    line = orjson.loads(raw_line)
                except Exception:
                    continue

                line_type = line.get("type")
                ts = line.get("timestamp")
                payload = line.get("payload", {})

                if line_type == "session_meta":
                    session_id = payload.get("id")
                    project = payload.get("cwd")

                elif line_type == "response_item":
                    payload_type = payload.get("type")

                    if payload_type == "message" and payload.get("role") == "user":
                        # User prompt within the session file
                        content = payload.get("content", [])
                        if isinstance(content, list):
                            for item in content:
                                if isinstance(item, dict) and item.get("type") == "input_text":
                                    text = item.get("text", "")
                                    # Skip system/developer messages
                                    if text.startswith("<permissions") or text.startswith("<environment_context"):
                                        continue
                                    if text.startswith("# AGENTS.md"):
                                        continue
                                    cleaned = _strip_xml_tags(text)
                                    if cleaned and len(cleaned) > 5:
                                        prompt_idx += 1
                                        call_idx = 0
                                        prompts.append({
                                            "source": "codex",
                                            "session_id": session_id or Path(path).stem,
                                            "prompt_idx": prompt_idx,
                                            "timestamp": _ts_to_dt(ts),
                                            "text": cleaned,
                                            "project": project or "",
                                            "char_count": len(cleaned),
                                        })

                    elif payload_type == "function_call":
                        tool_calls.append({
                            "source": "codex",
                            "session_id": session_id or Path(path).stem,
                            "prompt_idx": max(prompt_idx, 0),
                            "call_idx": call_idx,
                            "timestamp": _ts_to_dt(ts),
                            "tool_name": payload.get("name", "unknown"),
                            "arguments_json": _truncate(payload.get("arguments", "{}")),
                            "is_error": False,
                        })
                        call_idx += 1

                elif line_type == "event_msg":
                    payload_type = payload.get("type")
                    if payload_type == "user_message":
                        text = payload.get("message", "")
                        cleaned = _strip_xml_tags(text)
                        if cleaned and len(cleaned) > 5:
                            prompt_idx += 1
                            call_idx = 0
                            prompts.append({
                                "source": "codex",
                                "session_id": session_id or Path(path).stem,
                                "prompt_idx": prompt_idx,
                                "timestamp": _ts_to_dt(ts),
                                "text": cleaned,
                                "project": project or "",
                                "char_count": len(cleaned),
                            })

    except Exception:
        pass

    # Also pull from history.jsonl if we have this session
    if session_id and session_id in history_map:
        for entry in history_map[session_id]:
            text = entry.get("text", "")
            cleaned = _strip_xml_tags(text)
            # Only add if we didn't already capture it (dedup by text prefix)
            existing_texts = {p["text"][:50] for p in prompts}
            if cleaned and cleaned[:50] not in existing_texts:
                prompt_idx += 1
                prompts.append({
                    "source": "codex",
                    "session_id": session_id,
                    "prompt_idx": prompt_idx,
                    "timestamp": _ts_to_dt(entry.get("ts")),
                    "text": cleaned,
                    "project": project or "",
                    "char_count": len(cleaned),
                })

    return {"prompts": prompts, "tool_calls": tool_calls}


# ── Lemon Parser ────────────────────────────────────────────────────

def _parse_lemon_file(path: str) -> dict:
    """Parse a single Lemon JSONL session file."""
    prompts = []
    tool_calls = []
    session_id = None
    project = None
    prompt_idx = -1
    call_idx = 0

    try:
        with open(path, "rb") as f:
            for raw_line in f:
                raw_line = raw_line.strip()
                if not raw_line:
                    continue
                try:
                    line = orjson.loads(raw_line)
                except Exception:
                    continue

                line_type = line.get("type")
                ts = line.get("timestamp")

                if line_type == "session":
                    session_id = line.get("id")
                    project = line.get("cwd")

                elif line_type == "message":
                    msg = line.get("message", {})
                    role = msg.get("role")
                    content = msg.get("content")
                    msg_ts = msg.get("timestamp") or ts

                    if role == "user":
                        if isinstance(content, str) and content.strip():
                            cleaned = _strip_xml_tags(content)
                            if cleaned:
                                prompt_idx += 1
                                call_idx = 0
                                prompts.append({
                                    "source": "lemon",
                                    "session_id": session_id or Path(path).stem,
                                    "prompt_idx": prompt_idx,
                                    "timestamp": _ts_to_dt(msg_ts),
                                    "text": cleaned,
                                    "project": project or "",
                                    "char_count": len(cleaned),
                                })

                    elif role == "assistant":
                        if isinstance(content, list):
                            for item in content:
                                if isinstance(item, dict) and item.get("type") in ("tool_call", "tool_use"):
                                    name = item.get("name", "unknown")
                                    # arguments can be dict or string
                                    args = item.get("arguments") or item.get("input") or {}
                                    if isinstance(args, dict):
                                        args_str = orjson.dumps(args).decode()
                                    else:
                                        args_str = str(args)
                                    tool_calls.append({
                                        "source": "lemon",
                                        "session_id": session_id or Path(path).stem,
                                        "prompt_idx": max(prompt_idx, 0),
                                        "call_idx": call_idx,
                                        "timestamp": _ts_to_dt(msg_ts),
                                        "tool_name": name,
                                        "arguments_json": _truncate(args_str),
                                        "is_error": False,
                                    })
                                    call_idx += 1
    except Exception:
        pass

    return {"prompts": prompts, "tool_calls": tool_calls}


# ── File Discovery ──────────────────────────────────────────────────

def discover_files(
    skip_lemon: bool = False,
    max_files: int | None = None,
) -> dict[str, list[str]]:
    """Find all JSONL files across sources."""
    files: dict[str, list[str]] = {"claude": [], "codex": [], "lemon": []}

    if CLAUDE_ROOT.exists():
        files["claude"] = sorted(str(p) for p in CLAUDE_ROOT.rglob("*.jsonl"))
    if CODEX_ROOT.exists():
        files["codex"] = sorted(str(p) for p in CODEX_ROOT.rglob("*.jsonl"))
    if not skip_lemon and LEMON_ROOT.exists():
        files["lemon"] = sorted(str(p) for p in LEMON_ROOT.rglob("*.jsonl"))

    if max_files is not None:
        for key in files:
            files[key] = files[key][:max_files]

    return files


# ── Main Extraction ─────────────────────────────────────────────────

def run_extraction(
    output_dir: Path,
    max_files: int | None = None,
    workers: int | None = None,
    skip_lemon: bool = False,
) -> dict[str, int]:
    """Run full extraction pipeline. Returns stats dict."""
    output_dir.mkdir(parents=True, exist_ok=True)
    n_workers = workers or os.cpu_count() or 4

    files = discover_files(skip_lemon=skip_lemon, max_files=max_files)
    total_files = sum(len(v) for v in files.values())

    all_prompts: list[dict] = []
    all_tool_calls: list[dict] = []

    with Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
        TextColumn("{task.completed}/{task.total} files"),
        TimeElapsedColumn(),
    ) as progress:
        task = progress.add_task("Extracting sessions", total=total_files)

        # Claude files
        if files["claude"]:
            with Pool(n_workers) as pool:
                for result in pool.imap_unordered(_parse_claude_file, files["claude"], chunksize=8):
                    all_prompts.extend(result["prompts"])
                    all_tool_calls.extend(result["tool_calls"])
                    progress.advance(task)

        # Codex files (need history map passed along)
        if files["codex"]:
            history_map = _load_codex_history()
            codex_args = [(path, history_map) for path in files["codex"]]
            with Pool(n_workers) as pool:
                for result in pool.imap_unordered(_parse_codex_file, codex_args, chunksize=8):
                    all_prompts.extend(result["prompts"])
                    all_tool_calls.extend(result["tool_calls"])
                    progress.advance(task)

        # Lemon files
        if files["lemon"]:
            with Pool(n_workers) as pool:
                for result in pool.imap_unordered(_parse_lemon_file, files["lemon"], chunksize=8):
                    all_prompts.extend(result["prompts"])
                    all_tool_calls.extend(result["tool_calls"])
                    progress.advance(task)

    # ── Build DataFrames ────────────────────────────────────────────

    prompts_df = pl.DataFrame(all_prompts, schema={
        "source": pl.Utf8,
        "session_id": pl.Utf8,
        "prompt_idx": pl.UInt32,
        "timestamp": pl.Utf8,
        "text": pl.Utf8,
        "project": pl.Utf8,
        "char_count": pl.UInt32,
    }) if all_prompts else pl.DataFrame(schema={
        "source": pl.Utf8,
        "session_id": pl.Utf8,
        "prompt_idx": pl.UInt32,
        "timestamp": pl.Utf8,
        "text": pl.Utf8,
        "project": pl.Utf8,
        "char_count": pl.UInt32,
    })

    tools_df = pl.DataFrame(all_tool_calls, schema={
        "source": pl.Utf8,
        "session_id": pl.Utf8,
        "prompt_idx": pl.UInt32,
        "call_idx": pl.UInt32,
        "timestamp": pl.Utf8,
        "tool_name": pl.Utf8,
        "arguments_json": pl.Utf8,
        "is_error": pl.Boolean,
    }) if all_tool_calls else pl.DataFrame(schema={
        "source": pl.Utf8,
        "session_id": pl.Utf8,
        "prompt_idx": pl.UInt32,
        "call_idx": pl.UInt32,
        "timestamp": pl.Utf8,
        "tool_name": pl.Utf8,
        "arguments_json": pl.Utf8,
        "is_error": pl.Boolean,
    })

    # ── Build Sessions DataFrame ────────────────────────────────────

    sessions_data: list[dict] = []
    if len(prompts_df) > 0 or len(tools_df) > 0:
        # Group prompts by (source, session_id)
        prompt_groups = {}
        if len(prompts_df) > 0:
            for row in prompts_df.iter_rows(named=True):
                key = (row["source"], row["session_id"])
                prompt_groups.setdefault(key, []).append(row)

        tool_groups = {}
        if len(tools_df) > 0:
            for row in tools_df.iter_rows(named=True):
                key = (row["source"], row["session_id"])
                tool_groups.setdefault(key, []).append(row)

        all_keys = set(prompt_groups.keys()) | set(tool_groups.keys())
        for key in all_keys:
            source, sid = key
            p_rows = prompt_groups.get(key, [])
            t_rows = tool_groups.get(key, [])

            timestamps = []
            for r in p_rows:
                if r["timestamp"]:
                    timestamps.append(r["timestamp"])
            for r in t_rows:
                if r["timestamp"]:
                    timestamps.append(r["timestamp"])
            timestamps.sort()

            unique_tools = sorted(set(r["tool_name"] for r in t_rows))
            tool_seq = "|".join(r["tool_name"] for r in sorted(t_rows, key=lambda x: (x["prompt_idx"], x["call_idx"])))

            sessions_data.append({
                "source": source,
                "session_id": sid,
                "project": p_rows[0]["project"] if p_rows else "",
                "start_time": timestamps[0] if timestamps else None,
                "end_time": timestamps[-1] if timestamps else None,
                "num_prompts": len(p_rows),
                "num_tool_calls": len(t_rows),
                "unique_tools": unique_tools,
                "tool_sequence": tool_seq,
                "first_prompt": p_rows[0]["text"][:500] if p_rows else "",
            })

    sessions_df = pl.DataFrame(sessions_data, schema={
        "source": pl.Utf8,
        "session_id": pl.Utf8,
        "project": pl.Utf8,
        "start_time": pl.Utf8,
        "end_time": pl.Utf8,
        "num_prompts": pl.UInt32,
        "num_tool_calls": pl.UInt32,
        "unique_tools": pl.List(pl.Utf8),
        "tool_sequence": pl.Utf8,
        "first_prompt": pl.Utf8,
    }) if sessions_data else pl.DataFrame(schema={
        "source": pl.Utf8,
        "session_id": pl.Utf8,
        "project": pl.Utf8,
        "start_time": pl.Utf8,
        "end_time": pl.Utf8,
        "num_prompts": pl.UInt32,
        "num_tool_calls": pl.UInt32,
        "unique_tools": pl.List(pl.Utf8),
        "tool_sequence": pl.Utf8,
        "first_prompt": pl.Utf8,
    })

    # ── Write Parquet ───────────────────────────────────────────────

    prompts_df.write_parquet(output_dir / "prompts.parquet")
    tools_df.write_parquet(output_dir / "tool_calls.parquet")
    sessions_df.write_parquet(output_dir / "sessions.parquet")

    stats = {
        "total_files": total_files,
        "claude_files": len(files["claude"]),
        "codex_files": len(files["codex"]),
        "lemon_files": len(files["lemon"]),
        "prompts": len(prompts_df),
        "tool_calls": len(tools_df),
        "sessions": len(sessions_df),
    }
    return stats
