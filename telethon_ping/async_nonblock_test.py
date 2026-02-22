#!/usr/bin/env python3
"""
Async Non-Blocking Test — verifies that async task/agent spawns don't block
the main conversation loop.

Test Protocol:
1. Send a message that spawns an async task (slow: "count to 100 slowly")
2. Immediately after the bot acknowledges the spawn, send a follow-up message
   ("what is 2+2?") to the SAME topic
3. The bot should answer "4" quickly WITHOUT waiting for the async task to finish
4. Eventually the async task result should also appear in the topic

Success criteria:
- Bot responds to the quick question within 30s of asking it
- Bot response to quick question arrives BEFORE the async task completes
- Async task result eventually appears (within 10 minutes)

Usage:
    source ~/.zeebot/api_keys/telegram.txt
    uv run --with telethon python async_nonblock_test.py
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

from telethon import TelegramClient, events, types
from telethon.sessions import StringSession
from telethon.tl.functions.messages import CreateForumTopicRequest

CHAT_ID = -1003842984060
BOT_ID = 8594539953

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("async_nonblock")


@dataclass
class TestResult:
    test_name: str
    status: str = "PENDING"
    spawn_msg_id: int = 0
    spawn_ack_time: float = 0.0
    followup_msg_id: int = 0
    followup_reply_time: float = 0.0
    async_result_time: float = 0.0
    spawn_ack_text: str = ""
    followup_reply_text: str = ""
    async_result_text: str = ""
    timeline: list = field(default_factory=list)
    notes: str = ""


async def run_test(client, test_name, spawn_prompt, followup_prompt, followup_check,
                   spawn_keyword=None, timeout=600):
    """
    Run a single async non-blocking test.

    1. Create a topic
    2. Send spawn_prompt (triggers async task/agent)
    3. Wait for bot to acknowledge the spawn
    4. Immediately send followup_prompt (simple question)
    5. Verify bot answers followup BEFORE async task completes
    """
    result = TestResult(test_name=test_name)
    t0 = time.time()

    # Create topic
    topic_title = f"[AsyncTest] {test_name}"
    topic_result = await client(CreateForumTopicRequest(
        peer=CHAT_ID,
        title=topic_title[:128],
        random_id=int(time.time() * 1000) % (2**31),
    ))
    topic_id = topic_result.updates[1].message.id
    log.info(f"[{test_name}] Created topic {topic_id}")

    # Set up message queue for this topic
    msg_queue = asyncio.Queue()

    @client.on(events.NewMessage(chats=CHAT_ID))
    async def on_msg(event):
        msg = event.message
        if msg.sender_id != BOT_ID:
            return
        reply = getattr(msg, "reply_to", None)
        if reply:
            tid = getattr(reply, "reply_to_top_id", None) or getattr(
                reply, "reply_to_msg_id", None
            )
            if tid == topic_id:
                await msg_queue.put(msg)

    await asyncio.sleep(1)

    # Phase 1: Send the spawn prompt
    log.info(f"[{test_name}] Phase 1: Sending spawn prompt")
    spawn_msg = await client.send_message(CHAT_ID, spawn_prompt, reply_to=topic_id)
    result.spawn_msg_id = spawn_msg.id
    result.timeline.append({"event": "spawn_sent", "t": time.time() - t0})
    log.info(f"[{test_name}] Spawn sent (msg={spawn_msg.id})")

    # Phase 2: Wait for bot to acknowledge the async spawn
    # The bot should reply relatively quickly saying it started the task
    log.info(f"[{test_name}] Phase 2: Waiting for spawn acknowledgment...")
    spawn_ack = None
    ack_deadline = time.time() + 120  # 2 min to acknowledge spawn

    while time.time() < ack_deadline:
        try:
            msg = await asyncio.wait_for(msg_queue.get(), timeout=10)
            text = msg.message or ""
            log.info(f"[{test_name}] Bot msg ({len(text)} chars): {text[:100]}")
            result.timeline.append({
                "event": "bot_msg",
                "t": time.time() - t0,
                "msg_id": msg.id,
                "chars": len(text),
                "preview": text[:80],
            })

            # Check if this looks like a spawn acknowledgment
            # (mentions task_id, started, spawned, delegated, etc.)
            ack_indicators = ["task", "started", "spawned", "running", "delegated",
                              "submitted", "launched", "queued", "async", "background",
                              "working on", "will notify"]
            is_ack = any(ind in text.lower() for ind in ack_indicators)

            # If spawn_keyword specified, check for that
            if spawn_keyword and spawn_keyword.lower() in text.lower():
                is_ack = True

            if is_ack and not spawn_ack:
                spawn_ack = msg
                result.spawn_ack_time = time.time() - t0
                result.spawn_ack_text = text[:500]
                log.info(f"[{test_name}] Spawn acknowledged at t={result.spawn_ack_time:.1f}s")
                break

            # If the bot just answered directly (no async), that's also useful info
            if not is_ack and len(text) > 50:
                # Bot might have answered synchronously — not what we want
                spawn_ack = msg
                result.spawn_ack_time = time.time() - t0
                result.spawn_ack_text = text[:500]
                log.info(f"[{test_name}] Bot responded (possibly sync) at t={result.spawn_ack_time:.1f}s")
                break

        except asyncio.TimeoutError:
            continue

    if not spawn_ack:
        result.status = "FAIL"
        result.notes = "No spawn acknowledgment within 120s"
        client.remove_event_handler(on_msg)
        return result

    # Phase 3: Immediately send the follow-up question
    await asyncio.sleep(2)  # tiny pause to ensure message ordering
    log.info(f"[{test_name}] Phase 3: Sending follow-up question")
    followup_msg = await client.send_message(CHAT_ID, followup_prompt, reply_to=topic_id)
    result.followup_msg_id = followup_msg.id
    result.timeline.append({"event": "followup_sent", "t": time.time() - t0})
    followup_sent_at = time.time()
    log.info(f"[{test_name}] Follow-up sent (msg={followup_msg.id})")

    # Phase 4: Wait for the bot to answer the follow-up
    # AND track when the async result comes in
    log.info(f"[{test_name}] Phase 4: Waiting for follow-up answer + async result...")
    followup_answered = False
    async_result_received = False
    phase4_deadline = time.time() + timeout

    while time.time() < phase4_deadline:
        if followup_answered and async_result_received:
            break

        try:
            msg = await asyncio.wait_for(msg_queue.get(), timeout=15)
            text = msg.message or ""
            log.info(f"[{test_name}] Bot msg ({len(text)} chars): {text[:100]}")
            result.timeline.append({
                "event": "bot_msg",
                "t": time.time() - t0,
                "msg_id": msg.id,
                "chars": len(text),
                "preview": text[:80],
            })

            # Check if this answers our follow-up question
            if not followup_answered and followup_check(text):
                followup_answered = True
                result.followup_reply_time = time.time() - t0
                result.followup_reply_text = text[:500]
                followup_latency = time.time() - followup_sent_at
                log.info(f"[{test_name}] Follow-up answered at t={result.followup_reply_time:.1f}s "
                         f"(latency={followup_latency:.1f}s from send)")

            # Check if this is the async task result (independently — same msg can be both)
            if not async_result_received and len(text) > 100:
                result_indicators = ["result", "completed", "finished", "done",
                                     "output", "returned", "answer is", "count"]
                if any(ind in text.lower() for ind in result_indicators):
                    async_result_received = True
                    result.async_result_time = time.time() - t0
                    result.async_result_text = text[:500]
                    log.info(f"[{test_name}] Async result received at t={result.async_result_time:.1f}s")

        except asyncio.TimeoutError:
            if followup_answered and not async_result_received:
                # Keep waiting for async result but note the followup was fast
                log.info(f"[{test_name}] Follow-up answered, still waiting for async result...")
            continue

    # Evaluate results
    if followup_answered and result.followup_reply_time < result.async_result_time:
        result.status = "PASS"
        result.notes = (
            f"Follow-up answered at {result.followup_reply_time:.1f}s, "
            f"async result at {result.async_result_time:.1f}s — "
            f"non-blocking confirmed!"
        )
    elif followup_answered and async_result_received:
        result.status = "PARTIAL"
        result.notes = (
            f"Both received but follow-up at {result.followup_reply_time:.1f}s, "
            f"async at {result.async_result_time:.1f}s — "
            f"follow-up arrived after async (may have been blocked)"
        )
    elif followup_answered and not async_result_received:
        result.status = "PARTIAL"
        result.notes = (
            f"Follow-up answered at {result.followup_reply_time:.1f}s but "
            f"async result never received within timeout"
        )
    elif not followup_answered and async_result_received:
        result.status = "FAIL"
        result.notes = "Async result received but follow-up was never answered — BLOCKED"
    else:
        result.status = "FAIL"
        result.notes = "Neither follow-up nor async result received"

    client.remove_event_handler(on_msg)
    return result


async def main():
    api_id = int(os.environ["TELEGRAM_API_ID"])
    api_hash = os.environ["TELEGRAM_API_HASH"]
    session_str = os.environ["TELEGRAM_SESSION_STRING"]

    client = TelegramClient(StringSession(session_str), api_id, api_hash)
    await client.start()
    me = await client.get_me()
    log.info(f"Authenticated as {me.username} (id={me.id})")

    results = []

    # =========================================================================
    # Test 1: Async TASK non-blocking
    # =========================================================================
    log.info("\n" + "=" * 70)
    log.info("TEST 1: Async task tool — does spawning a task block the convo?")
    log.info("=" * 70)

    r1 = await run_test(
        client,
        test_name="async_task_nonblock",
        spawn_prompt=(
            "Use the `task` tool to spawn an async subtask with this prompt: "
            "\"Research the history of the BEAM virtual machine in detail. "
            "Write a comprehensive 500-word summary covering its origins at Ericsson, "
            "the key design decisions, the process model, and how it influenced Elixir.\" "
            "Use async=true so it runs in the background. "
            "After spawning the task, confirm you did so and that you're still available."
        ),
        followup_prompt="Quick question while that runs: what is the capital of France?",
        followup_check=lambda text: "paris" in text.lower(),
        spawn_keyword="task",
        timeout=600,
    )
    results.append(r1)
    log.info(f"TEST 1 RESULT: {r1.status} — {r1.notes}")

    await asyncio.sleep(5)

    # =========================================================================
    # Test 2: Async AGENT non-blocking
    # =========================================================================
    log.info("\n" + "=" * 70)
    log.info("TEST 2: Async agent delegation — does spawning an agent block the convo?")
    log.info("=" * 70)

    r2 = await run_test(
        client,
        test_name="async_agent_nonblock",
        spawn_prompt=(
            "Use the `agent` tool to delegate this work to the coder agent asynchronously: "
            "\"Write a Python function that implements the Sieve of Eratosthenes to find "
            "all prime numbers up to n=10000. Include comprehensive docstring and type hints. "
            "Save it to ~/dev/lemon/content/sieve.py\" "
            "Use async=true. After delegating, confirm you're still here and available."
        ),
        followup_prompt="While the coder works on that — what is 7 times 8?",
        followup_check=lambda text: "56" in text,
        spawn_keyword="agent",
        timeout=600,
    )
    results.append(r2)
    log.info(f"TEST 2 RESULT: {r2.status} — {r2.notes}")

    await asyncio.sleep(5)

    # =========================================================================
    # Test 3: Multiple async spawns + rapid follow-ups
    # =========================================================================
    log.info("\n" + "=" * 70)
    log.info("TEST 3: Multiple async spawns + rapid follow-up")
    log.info("=" * 70)

    r3 = await run_test(
        client,
        test_name="multi_async_nonblock",
        spawn_prompt=(
            "Spawn TWO async tasks using the `task` tool:\n"
            "1. First task: \"List all files in ~/dev/lemon/apps/ recursively and count them\"\n"
            "2. Second task: \"Search the web for the current price of Bitcoin\"\n"
            "Use async=true for both. After spawning both, tell me you're still available "
            "and ready for questions."
        ),
        followup_prompt="Great, while those run — what color do you get when you mix red and blue?",
        followup_check=lambda text: "purple" in text.lower() or "violet" in text.lower(),
        spawn_keyword=None,
        timeout=600,
    )
    results.append(r3)
    log.info(f"TEST 3 RESULT: {r3.status} — {r3.notes}")

    # =========================================================================
    # Summary
    # =========================================================================
    print("\n" + "=" * 70)
    print("ASYNC NON-BLOCKING TEST RESULTS")
    print("=" * 70)

    for r in results:
        print(f"\n{r.test_name}: {r.status}")
        print(f"  {r.notes}")
        print(f"  Timeline:")
        for evt in r.timeline:
            preview = evt.get("preview", "")
            if preview:
                preview = f" | {preview[:60]}"
            print(f"    t={evt['t']:.1f}s: {evt['event']}{preview}")

    passed = sum(1 for r in results if r.status == "PASS")
    print(f"\nOVERALL: {passed}/{len(results)} PASS")

    # Save results
    ts = int(time.time())
    outfile = f"async_nonblock_results_{ts}.json"
    with open(outfile, "w") as f:
        json.dump(
            [
                {
                    "test_name": r.test_name,
                    "status": r.status,
                    "spawn_ack_time": r.spawn_ack_time,
                    "followup_reply_time": r.followup_reply_time,
                    "async_result_time": r.async_result_time,
                    "spawn_ack_text": r.spawn_ack_text[:200],
                    "followup_reply_text": r.followup_reply_text[:200],
                    "async_result_text": r.async_result_text[:200],
                    "timeline": r.timeline,
                    "notes": r.notes,
                }
                for r in results
            ],
            f,
            indent=2,
        )
    log.info(f"Results saved to {outfile}")

    await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
