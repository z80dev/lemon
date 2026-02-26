#!/usr/bin/env python3
"""
Engine Matrix Test — targeted tests for agent/task delegation across engines.

Tests:
  T40: task engine=claude async=true
  T41: task engine=codex async=true
  T42: task engine=claude async=false (sync)
  T43: task engine=codex async=false (sync)
  T44: agent agent_id=coder async=true
  T45: agent agent_id=coder async=false (sync)
  T46: agent engine_id=claude async=true
  T47: cron add + run_now + verify output
  T48: cron scheduled (near-future, 1-min window)

Usage:
    source ~/.zeebot/api_keys/telegram.txt
    uv run --with telethon python engine_matrix_test.py [--tests T40,T41,...] [--timeout 300]
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

from telethon import TelegramClient, events, types
from telethon.sessions import StringSession

CHAT_ID = -1003842984060
DEFAULT_TIMEOUT = 300

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("engine_matrix")


@dataclass
class TestResult:
    test_id: str
    name: str
    status: str = "PENDING"
    topic_id: int = 0
    sent_ids: list = field(default_factory=list)
    recv_ids: list = field(default_factory=list)
    recv_texts: list = field(default_factory=list)
    duration: float = 0.0
    notes: str = ""


class Harness:
    def __init__(self, client, chat_id, timeout):
        self.client = client
        self.chat_id = chat_id
        self.timeout = timeout
        self.queues: dict[int, asyncio.Queue] = {}

    async def setup_handlers(self):
        @self.client.on(events.NewMessage(chats=self.chat_id))
        async def on_msg(event):
            msg = event.message
            reply = getattr(msg, "reply_to", None)
            if reply:
                tid = getattr(reply, "reply_to_top_id", None) or getattr(
                    reply, "reply_to_msg_id", None
                )
                if tid and tid in self.queues:
                    await self.queues[tid].put(msg)

    def subscribe(self, topic_id):
        self.queues[topic_id] = asyncio.Queue()

    def unsubscribe(self, topic_id):
        self.queues.pop(topic_id, None)

    async def create_topic(self, title):
        import random as _rnd
        from telethon.tl import functions
        result = await self.client(
            functions.messages.CreateForumTopicRequest(
                peer=self.chat_id,
                title=title,
                random_id=_rnd.randint(1, 2**31 - 1),
            )
        )
        # Extract topic_id from updates
        if hasattr(result, 'updates'):
            for u in result.updates:
                if hasattr(u, 'message') and hasattr(u.message, 'id'):
                    topic_id = u.message.id
                    log.info(f"Created topic '{title}' id={topic_id}")
                    await asyncio.sleep(1.5)
                    return topic_id
                if hasattr(u, 'id'):
                    topic_id = u.id
                    log.info(f"Created topic '{title}' id={topic_id}")
                    await asyncio.sleep(1.5)
                    return topic_id
        raise RuntimeError(f"Failed to extract topic_id: {result}")

    async def send(self, topic_id, text):
        msg = await self.client.send_message(
            self.chat_id, text, reply_to=topic_id
        )
        return msg

    async def wait_replies(self, topic_id, count=1, timeout=None):
        timeout = timeout or self.timeout
        replies = []
        deadline = time.monotonic() + timeout
        while len(replies) < count and time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                msg = await asyncio.wait_for(
                    self.queues[topic_id].get(), timeout=min(remaining, 5)
                )
                replies.append(msg)
            except asyncio.TimeoutError:
                continue
        return replies


# ---------------------------------------------------------------------------
# Test implementations
# ---------------------------------------------------------------------------


async def test_task_claude_async(h: Harness, topic_id: int) -> TestResult:
    """T40: task engine=claude async=true"""
    r = TestResult("T40", "task engine=claude async", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        prompt = (
            "Use the task tool to spawn a subtask with engine='claude' and async=true. "
            "The subtask prompt should be: 'What is the capital of France? Reply with just the city name.' "
            "Description should be 'capital lookup'. Wait for the result and tell me what it returned."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T40] Sent msg {msg.id}")

        replies = await h.wait_replies(topic_id, count=2, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).lower()
        if "paris" in combined:
            r.status = "PASS"
            r.notes = "Claude task returned 'Paris'"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got {len(replies)} replies but 'Paris' not found"
        else:
            r.status = "FAIL"
            r.notes = "No replies"
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_task_codex_async(h: Harness, topic_id: int) -> TestResult:
    """T41: task engine=codex async=true"""
    r = TestResult("T41", "task engine=codex async", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        prompt = (
            "Use the task tool to spawn a subtask with engine='codex' and async=true. "
            "The subtask prompt should be: 'What is 7 * 8? Reply with just the number.' "
            "Description should be 'math check'. Wait for the result and tell me what it returned."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T41] Sent msg {msg.id}")

        replies = await h.wait_replies(topic_id, count=2, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).lower()
        if "56" in combined:
            r.status = "PASS"
            r.notes = "Codex task returned '56'"
        elif "codex exec finished" in combined or "no session_id" in combined:
            r.status = "FAIL"
            r.notes = "D01 reproduced — codex session_id not captured"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got {len(replies)} replies but '56' not found"
        else:
            r.status = "FAIL"
            r.notes = "No replies"
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_task_claude_sync(h: Harness, topic_id: int) -> TestResult:
    """T42: task engine=claude async=false (synchronous)"""
    r = TestResult("T42", "task engine=claude sync", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        prompt = (
            "Use the task tool to spawn a subtask with engine='claude' and async=false (synchronous). "
            "The subtask prompt should be: 'What is the largest planet in our solar system? Reply with just the name.' "
            "Description should be 'planet lookup'. Tell me the result."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T42] Sent msg {msg.id}")

        replies = await h.wait_replies(topic_id, count=1, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).lower()
        if "jupiter" in combined:
            r.status = "PASS"
            r.notes = "Sync claude task returned 'Jupiter'"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got reply but 'Jupiter' not found"
        else:
            r.status = "FAIL"
            r.notes = "No replies"
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_task_codex_sync(h: Harness, topic_id: int) -> TestResult:
    """T43: task engine=codex async=false (synchronous)"""
    r = TestResult("T43", "task engine=codex sync", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        prompt = (
            "Use the task tool to spawn a subtask with engine='codex' and async=false (synchronous). "
            "The subtask prompt should be: 'What is 12 * 12? Reply with just the number.' "
            "Description should be 'math verify'. Tell me the result."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T43] Sent msg {msg.id}")

        replies = await h.wait_replies(topic_id, count=1, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).lower()
        if "144" in combined:
            r.status = "PASS"
            r.notes = "Sync codex task returned '144'"
        elif "codex exec finished" in combined or "no session_id" in combined:
            r.status = "FAIL"
            r.notes = "D01 reproduced — codex session_id not captured"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got reply but '144' not found"
        else:
            r.status = "FAIL"
            r.notes = "No replies"
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_agent_coder_async(h: Harness, topic_id: int) -> TestResult:
    """T44: agent agent_id=coder async=true"""
    r = TestResult("T44", "agent coder async", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        prompt = (
            "Use the agent tool to delegate to agent_id='coder' with async=true. "
            "The prompt should be: 'Write a Python one-liner that prints hello world.' "
            "Wait for the result and tell me what the coder agent produced."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T44] Sent msg {msg.id}")

        replies = await h.wait_replies(topic_id, count=2, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).lower()
        if "hello" in combined and ("print" in combined or "world" in combined):
            r.status = "PASS"
            r.notes = "Coder agent produced hello world code"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got {len(replies)} replies"
        else:
            r.status = "FAIL"
            r.notes = "No replies"
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_agent_coder_sync(h: Harness, topic_id: int) -> TestResult:
    """T45: agent agent_id=coder async=false (sync)"""
    r = TestResult("T45", "agent coder sync", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        prompt = (
            "Use the agent tool to delegate to agent_id='coder' with async=false (synchronous). "
            "The prompt should be: 'Write a bash one-liner that prints the current date.' "
            "Tell me the result."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T45] Sent msg {msg.id}")

        replies = await h.wait_replies(topic_id, count=1, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).lower()
        if "date" in combined:
            r.status = "PASS"
            r.notes = "Sync coder agent returned date command"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got reply but 'date' not found"
        else:
            r.status = "FAIL"
            r.notes = "No replies"
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_agent_claude_engine(h: Harness, topic_id: int) -> TestResult:
    """T46: agent with engine_id=claude async=true"""
    r = TestResult("T46", "agent engine=claude async", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        prompt = (
            "Use the agent tool with engine_id='claude' and async=true. "
            "Set agent_id to 'default'. "
            "The prompt should be: 'What color is the sky on a clear day? Reply with one word.' "
            "Wait for the result and tell me."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T46] Sent msg {msg.id}")

        replies = await h.wait_replies(topic_id, count=2, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).lower()
        if "blue" in combined:
            r.status = "PASS"
            r.notes = "Claude engine agent returned 'blue'"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got {len(replies)} replies but 'blue' not found"
        else:
            r.status = "FAIL"
            r.notes = "No replies"
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_cron_add_run(h: Harness, topic_id: int) -> TestResult:
    """T47: cron add + run_now + verify output"""
    r = TestResult("T47", "cron add + run_now", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        # Step 1: Ask bot to add a cron job and then run it
        prompt = (
            "Do two things in sequence:\n"
            "1. Use the cron tool to add a new cron job with action='add', "
            "name='engine_matrix_cron_test', schedule='0 0 1 1 *', "
            "prompt='Say CRON_ENGINE_MATRIX_OK and nothing else.', enabled=true\n"
            "2. Then immediately use the cron tool with action='run' on the job you just created.\n"
            "Tell me when both are done."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T47] Sent msg {msg.id}")

        # Wait for replies — cron add confirmation + run output
        replies = await h.wait_replies(topic_id, count=3, timeout=h.timeout)
        r.recv_ids = [m.id for m in replies]
        r.recv_texts = [m.text or "" for m in replies]

        combined = " ".join(r.recv_texts).upper()
        if "CRON_ENGINE_MATRIX_OK" in combined:
            r.status = "PASS"
            r.notes = "Cron job created, run, and output received"
        elif "cron" in combined.lower() and replies:
            r.status = "PARTIAL"
            r.notes = f"Got {len(replies)} replies; cron mentioned but marker not found"
        elif replies:
            r.status = "PARTIAL"
            r.notes = f"Got {len(replies)} replies"
        else:
            r.status = "FAIL"
            r.notes = "No replies"

        # Cleanup: remove the cron job
        cleanup = await h.send(topic_id, "Use the cron tool with action='list' to find the engine_matrix_cron_test job, then use action='remove' to delete it.")
        r.sent_ids.append(cleanup.id)
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


async def test_cron_scheduled(h: Harness, topic_id: int) -> TestResult:
    """T48: cron scheduled execution (near-future)"""
    r = TestResult("T48", "cron scheduled tick", topic_id=topic_id)
    t0 = time.monotonic()
    h.subscribe(topic_id)
    try:
        # Schedule a cron job 2 minutes from now
        now = datetime.now(timezone.utc)
        target_min = (now.minute + 2) % 60
        target_hour = now.hour + ((now.minute + 2) // 60)
        schedule = f"{target_min} {target_hour % 24} * * *"

        prompt = (
            f"Use the cron tool to add a cron job with action='add', "
            f"name='scheduled_tick_test', schedule='{schedule}', "
            f"prompt='Say SCHEDULED_TICK_OK and nothing else.', "
            f"enabled=true, timezone='UTC'. "
            f"Tell me the job ID after adding."
        )
        msg = await h.send(topic_id, prompt)
        r.sent_ids.append(msg.id)
        log.info(f"[T48] Sent cron add (schedule={schedule}), waiting for scheduled tick...")

        # Wait for the cron add confirmation
        add_replies = await h.wait_replies(topic_id, count=1, timeout=60)
        r.recv_ids.extend([m.id for m in add_replies])
        r.recv_texts.extend([m.text or "" for m in add_replies])

        # Now wait up to 180s for the scheduled execution
        tick_replies = await h.wait_replies(topic_id, count=1, timeout=180)
        r.recv_ids.extend([m.id for m in tick_replies])
        r.recv_texts.extend([m.text or "" for m in tick_replies])

        combined = " ".join(r.recv_texts).upper()
        if "SCHEDULED_TICK_OK" in combined:
            r.status = "PASS"
            r.notes = "Scheduled cron tick fired and output received"
        elif tick_replies:
            r.status = "PARTIAL"
            r.notes = f"Got tick reply but marker not found"
        elif add_replies:
            r.status = "PARTIAL"
            r.notes = "Cron added but scheduled tick did not fire within 180s"
        else:
            r.status = "FAIL"
            r.notes = "No replies at all"

        # Cleanup
        cleanup = await h.send(topic_id, "Use the cron tool with action='list' to find scheduled_tick_test, then action='remove' to delete it.")
        r.sent_ids.append(cleanup.id)
    except Exception as e:
        r.status = "ERROR"
        r.notes = str(e)
    finally:
        r.duration = time.monotonic() - t0
        h.unsubscribe(topic_id)
    return r


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

TESTS = {
    "T40": ("task engine=claude async", test_task_claude_async),
    "T41": ("task engine=codex async", test_task_codex_async),
    "T42": ("task engine=claude sync", test_task_claude_sync),
    "T43": ("task engine=codex sync", test_task_codex_sync),
    "T44": ("agent coder async", test_agent_coder_async),
    "T45": ("agent coder sync", test_agent_coder_sync),
    "T46": ("agent engine=claude async", test_agent_claude_engine),
    "T47": ("cron add + run_now", test_cron_add_run),
    "T48": ("cron scheduled tick", test_cron_scheduled),
}


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tests", default=None, help="Comma-separated test IDs")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--sequential", action="store_true")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    if args.list:
        print("Available tests:")
        for tid, (name, _) in sorted(TESTS.items()):
            print(f"  {tid}: {name}")
        return

    api_id = os.environ.get("TELEGRAM_API_ID")
    api_hash = os.environ.get("TELEGRAM_API_HASH")
    session_str = os.environ.get("TELEGRAM_SESSION_STRING")

    if not all([api_id, api_hash, session_str]):
        log.error("Missing TELEGRAM_API_ID, TELEGRAM_API_HASH, or TELEGRAM_SESSION_STRING")
        sys.exit(1)

    selected = sorted(TESTS.keys())
    if args.tests:
        selected = [t.strip().upper() for t in args.tests.split(",")]

    client = TelegramClient(StringSession(session_str), int(api_id), api_hash)
    await client.start()
    me = await client.get_me()
    log.info(f"Authenticated as {me.username} (id={me.id})")

    h = Harness(client, CHAT_ID, args.timeout)
    await h.setup_handlers()

    # Create topics
    log.info(f"Creating {len(selected)} topics...")
    topic_map = {}
    for tid in selected:
        name = TESTS[tid][0]
        topic_id = await h.create_topic(f"[EngineMatrix] {tid}: {name}")
        topic_map[tid] = topic_id

    log.info(f"Topic allocation: {topic_map}")

    # Run tests
    results = []
    if args.sequential:
        for tid in selected:
            name, fn = TESTS[tid]
            log.info(f"[{tid}] Starting: {name} (topic={topic_map[tid]})")
            result = await fn(h, topic_map[tid])
            results.append(result)
            log.info(
                f"[{tid}] {result.status} ({name}) in {result.duration:.1f}s "
                f"| sent={result.sent_ids} recv={result.recv_ids}"
            )
            if result.notes:
                log.info(f"[{tid}]   -> {result.notes}")
    else:
        async def run_one(tid):
            name, fn = TESTS[tid]
            log.info(f"[{tid}] Starting: {name} (topic={topic_map[tid]})")
            result = await fn(h, topic_map[tid])
            log.info(
                f"[{tid}] {result.status} ({name}) in {result.duration:.1f}s "
                f"| sent={result.sent_ids} recv={result.recv_ids}"
            )
            if result.notes:
                log.info(f"[{tid}]   -> {result.notes}")
            return result

        results = await asyncio.gather(*[run_one(tid) for tid in selected])

    # Report
    report_file = f"engine_matrix_results_{int(time.time())}.json"
    report_data = []
    for r in results:
        report_data.append({
            "test_id": r.test_id,
            "name": r.name,
            "status": r.status,
            "topic_id": r.topic_id,
            "sent_ids": r.sent_ids,
            "recv_ids": r.recv_ids,
            "recv_texts": r.recv_texts,
            "duration": r.duration,
            "notes": r.notes,
        })
    with open(report_file, "w") as f:
        json.dump(report_data, f, indent=2, default=str)
    log.info(f"JSON report saved to {report_file}")

    await client.disconnect()

    # Summary
    print()
    print("=" * 80)
    print(f"  ENGINE MATRIX TEST REPORT")
    print(f"  {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print("=" * 80)
    print()
    print(f"{'ID':<8}{'Status':<10}{'Test Name':<35}{'Topic':<10}{'Time':>8}  Notes")
    print("-" * 100)
    counts = {}
    for r in results:
        status_label = r.status
        counts[status_label] = counts.get(status_label, 0) + 1
        notes = r.notes[:50] if r.notes else ""
        print(
            f"{r.test_id:<8}{status_label:<10}{r.name:<35}{r.topic_id:<10}"
            f"{r.duration:>7.1f}s  {notes}"
        )
    print("-" * 100)
    parts = [f"{k.lower()}={v}" for k, v in sorted(counts.items())]
    print(f"Total: {len(results)}  |  {'  '.join(parts)}")
    print()

    any_fail = any(r.status in ("FAIL", "ERROR") for r in results)
    sys.exit(1 if any_fail else 0)


if __name__ == "__main__":
    asyncio.run(main())
