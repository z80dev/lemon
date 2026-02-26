#!/usr/bin/env python3
"""
Comprehensive Lemon Bot Test Suite — extensive parallel testing of async/sync
tasks, agent delegation, and general bot capabilities.

Tests:
1. Sync task — immediate result (no async)
2. Async task with auto-followup — background task completes and notifies
3. Async agent delegation — coder agent does work and notifies
4. Parallel async tasks — multiple background tasks at once
5. Knowledge question — direct answer, no tools
6. Multi-turn conversation — follow-up questions in same topic
7. Sync agent (async=false) — wait for agent result inline

Usage:
    source ~/.zeebot/api_keys/telegram.txt
    uv run --with telethon python comprehensive_test.py
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field

from telethon import TelegramClient, events
from telethon.sessions import StringSession
from telethon.tl.functions.messages import CreateForumTopicRequest

CHAT_ID = -1003842984060
BOT_ID = 8594539953

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("lemon_test")


@dataclass
class TestResult:
    test_name: str
    status: str = "PENDING"
    latency: float = 0.0
    notes: str = ""
    timeline: list = field(default_factory=list)


async def collect_bot_messages(client, topic_id, timeout=120, min_messages=1,
                                stop_check=None):
    """Collect bot messages in a topic until timeout or stop condition."""
    msg_queue = asyncio.Queue()
    messages = []

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

    t0 = time.time()
    deadline = t0 + timeout
    while time.time() < deadline:
        if len(messages) >= min_messages and stop_check and stop_check(messages):
            break
        try:
            msg = await asyncio.wait_for(msg_queue.get(), timeout=10)
            text = msg.message or ""
            elapsed = time.time() - t0
            messages.append({"text": text, "time": elapsed, "msg_id": msg.id})
            log.info(f"Bot msg at t={elapsed:.1f}s ({len(text)} chars): {text[:80]}")
        except asyncio.TimeoutError:
            if len(messages) >= min_messages:
                break

    client.remove_event_handler(on_msg)
    return messages


async def create_topic(client, title):
    result = await client(CreateForumTopicRequest(
        peer=CHAT_ID,
        title=title[:128],
        random_id=int(time.time() * 1000) % (2**31),
    ))
    topic_id = result.updates[1].message.id
    log.info(f"Created topic '{title}' → {topic_id}")
    return topic_id


# =========================================================================
# Test 1: Direct Knowledge Question (no tools)
# =========================================================================
async def test_knowledge_question(client):
    """Bot answers a simple factual question directly."""
    result = TestResult("knowledge_question")
    topic_id = await create_topic(client, "[Test] Knowledge Q&A")
    await asyncio.sleep(1)

    t0 = time.time()
    await client.send_message(CHAT_ID, "What is the speed of light in meters per second?", reply_to=topic_id)

    msgs = await collect_bot_messages(client, topic_id, timeout=60,
        stop_check=lambda ms: any("299" in m["text"] for m in ms))

    if any("299" in m["text"] for m in msgs):
        latency = msgs[0]["time"]
        result.status = "PASS"
        result.latency = latency
        result.notes = f"Answered in {latency:.1f}s"
    else:
        result.status = "FAIL"
        result.notes = "Did not mention 299,792,458 m/s"

    result.timeline = [{"t": m["time"], "preview": m["text"][:60]} for m in msgs]
    return result


# =========================================================================
# Test 2: Sync Task (async=false, inline result)
# =========================================================================
async def test_sync_task(client):
    """Task tool with async=false — result returned inline."""
    result = TestResult("sync_task")
    topic_id = await create_topic(client, "[Test] Sync Task")
    await asyncio.sleep(1)

    prompt = (
        'Use the `task` tool with async=false to answer this question: '
        '"What are the first 5 Fibonacci numbers?" '
        'Return the answer directly.'
    )
    t0 = time.time()
    await client.send_message(CHAT_ID, prompt, reply_to=topic_id)

    msgs = await collect_bot_messages(client, topic_id, timeout=120,
        stop_check=lambda ms: any("1, 1, 2, 3, 5" in m["text"] or
                                   "0, 1, 1, 2, 3" in m["text"] or
                                   "fibonacci" in m["text"].lower()
                                   for m in ms))

    fib_check = lambda t: any(x in t for x in ["1, 1, 2, 3, 5", "0, 1, 1, 2, 3", "1, 2, 3, 5, 8"])
    if any(fib_check(m["text"]) for m in msgs):
        latency = next(m["time"] for m in msgs if fib_check(m["text"]))
        result.status = "PASS"
        result.latency = latency
        result.notes = f"Fibonacci answered in {latency:.1f}s (sync)"
    elif msgs:
        result.status = "PARTIAL"
        result.notes = f"Got response but no Fibonacci sequence found"
    else:
        result.status = "FAIL"
        result.notes = "No response received"

    result.timeline = [{"t": m["time"], "preview": m["text"][:60]} for m in msgs]
    return result


# =========================================================================
# Test 3: Async Task with Auto-Followup
# =========================================================================
async def test_async_task(client):
    """Async task runs in background, auto-followup delivers result."""
    result = TestResult("async_task_followup")
    topic_id = await create_topic(client, "[Test] Async Task")
    await asyncio.sleep(1)

    prompt = (
        'Use the `task` tool with async=true to: '
        '"Write a haiku about Elixir programming." '
        'After spawning the task, tell me you did so.'
    )
    t0 = time.time()
    await client.send_message(CHAT_ID, prompt, reply_to=topic_id)

    # Collect: expect spawn ack + followup result
    msgs = await collect_bot_messages(client, topic_id, timeout=180, min_messages=2,
        stop_check=lambda ms: (
            any("task" in m["text"].lower() and ("spawn" in m["text"].lower() or "id" in m["text"].lower()) for m in ms) and
            any(len(m["text"]) > 30 and any(kw in m["text"].lower() for kw in ["haiku", "elixir", "beam", "pattern", "pipe"]) for m in ms)
        ))

    has_ack = any("task" in m["text"].lower() for m in msgs)
    has_result = any(
        len(m["text"]) > 30 and any(kw in m["text"].lower() for kw in ["haiku", "elixir", "beam", "pattern", "pipe", "completed", "result"])
        for m in msgs
    )

    if has_ack and has_result:
        result.status = "PASS"
        result.notes = f"Ack + result received ({len(msgs)} messages)"
    elif has_ack:
        result.status = "PARTIAL"
        result.notes = "Task acknowledged but result never received"
    else:
        result.status = "FAIL"
        result.notes = "No acknowledgment received"

    result.timeline = [{"t": m["time"], "preview": m["text"][:60]} for m in msgs]
    return result


# =========================================================================
# Test 4: Async Agent Delegation with Auto-Followup
# =========================================================================
async def test_async_agent(client):
    """Agent delegation (async=true) — coder agent does work, notifies back."""
    result = TestResult("async_agent_delegation")
    topic_id = await create_topic(client, "[Test] Agent Delegation")
    await asyncio.sleep(1)

    prompt = (
        'Use the `agent` tool to delegate to the coder agent asynchronously: '
        '"Write a Python function called `is_palindrome(s: str) -> bool` that checks if a string '
        'is a palindrome (ignoring case and spaces). Save it to ~/dev/lemon/content/palindrome.py" '
        'Use async=true. Tell me you delegated it.'
    )
    t0 = time.time()
    await client.send_message(CHAT_ID, prompt, reply_to=topic_id)

    msgs = await collect_bot_messages(client, topic_id, timeout=180, min_messages=2,
        stop_check=lambda ms: (
            any("delegat" in m["text"].lower() or "agent" in m["text"].lower() for m in ms) and
            any("completed" in m["text"].lower() or "finished" in m["text"].lower() or "palindrome" in m["text"].lower() for m in ms)
        ))

    has_ack = any("delegat" in m["text"].lower() or "agent" in m["text"].lower() or "task" in m["text"].lower() for m in msgs)
    has_result = any(
        "completed" in m["text"].lower() or "finished" in m["text"].lower() or "saved" in m["text"].lower()
        for m in msgs
    )

    if has_ack and has_result:
        result.status = "PASS"
        result.notes = f"Delegation + completion received ({len(msgs)} messages)"
    elif has_ack:
        result.status = "PARTIAL"
        result.notes = "Delegated but completion never received"
    else:
        result.status = "FAIL"
        result.notes = "No delegation acknowledgment"

    result.timeline = [{"t": m["time"], "preview": m["text"][:60]} for m in msgs]
    return result


# =========================================================================
# Test 5: Non-Blocking Check (async task + immediate follow-up)
# =========================================================================
async def test_nonblocking(client):
    """Spawn async task, immediately ask a question — must answer quickly."""
    result = TestResult("nonblocking_check")
    topic_id = await create_topic(client, "[Test] Non-Blocking")
    await asyncio.sleep(1)

    # Phase 1: spawn async task
    spawn_prompt = (
        'Use the `task` tool with async=true to: '
        '"Research the history of the Erlang programming language in detail, '
        'covering its development at Ericsson, key design decisions, and its impact '
        'on telecommunications. Write a 400-word essay." '
        'After spawning, confirm you are still available.'
    )
    await client.send_message(CHAT_ID, spawn_prompt, reply_to=topic_id)

    # Wait for spawn ack
    msgs_phase1 = await collect_bot_messages(client, topic_id, timeout=60,
        stop_check=lambda ms: any("task" in m["text"].lower() or "spawn" in m["text"].lower() for m in ms))

    if not msgs_phase1:
        result.status = "FAIL"
        result.notes = "No spawn acknowledgment"
        return result

    # Phase 2: immediately ask a follow-up
    await asyncio.sleep(2)
    t_followup = time.time()
    await client.send_message(CHAT_ID, "Quick question: what is 12 * 12?", reply_to=topic_id)

    msgs_phase2 = await collect_bot_messages(client, topic_id, timeout=300, min_messages=1,
        stop_check=lambda ms: (
            any("144" in m["text"] for m in ms) and
            any("completed" in m["text"].lower() or "result" in m["text"].lower() or "erlang" in m["text"].lower()
                for m in ms if len(m["text"]) > 100)
        ))

    followup_answered = any("144" in m["text"] for m in msgs_phase2)
    async_result = any(
        len(m["text"]) > 100 and any(kw in m["text"].lower() for kw in ["erlang", "completed", "result", "ericsson"])
        for m in msgs_phase2
    )

    if followup_answered:
        followup_time = next(m["time"] for m in msgs_phase2 if "144" in m["text"])
        if async_result:
            async_time = next(
                m["time"] for m in msgs_phase2
                if len(m["text"]) > 100 and any(kw in m["text"].lower() for kw in ["erlang", "completed", "result", "ericsson"])
            )
            if followup_time < async_time:
                result.status = "PASS"
                result.notes = f"Follow-up at {followup_time:.1f}s, async at {async_time:.1f}s — non-blocking!"
            else:
                result.status = "PARTIAL"
                result.notes = f"Both received but follow-up ({followup_time:.1f}s) after async ({async_time:.1f}s)"
        else:
            result.status = "PARTIAL"
            result.notes = f"Follow-up answered at {followup_time:.1f}s but async result missing"
    else:
        result.status = "FAIL"
        result.notes = "Follow-up question never answered"

    result.timeline = (
        [{"t": m["time"], "phase": 1, "preview": m["text"][:60]} for m in msgs_phase1] +
        [{"t": m["time"], "phase": 2, "preview": m["text"][:60]} for m in msgs_phase2]
    )
    return result


# =========================================================================
# Test 6: Multi-Turn Conversation
# =========================================================================
async def test_multi_turn(client):
    """Multiple messages in same topic — bot maintains context."""
    result = TestResult("multi_turn_conversation")
    topic_id = await create_topic(client, "[Test] Multi-Turn")
    await asyncio.sleep(1)

    # Turn 1
    await client.send_message(CHAT_ID, "My favorite animal is a penguin. Remember that.", reply_to=topic_id)
    msgs1 = await collect_bot_messages(client, topic_id, timeout=60,
        stop_check=lambda ms: len(ms) >= 1)
    if not msgs1:
        result.status = "FAIL"
        result.notes = "No response to turn 1"
        return result

    await asyncio.sleep(3)

    # Turn 2 — test recall
    await client.send_message(CHAT_ID, "What is my favorite animal?", reply_to=topic_id)
    msgs2 = await collect_bot_messages(client, topic_id, timeout=60,
        stop_check=lambda ms: any("penguin" in m["text"].lower() for m in ms))

    if any("penguin" in m["text"].lower() for m in msgs2):
        result.status = "PASS"
        result.latency = msgs2[0]["time"]
        result.notes = f"Recalled 'penguin' correctly"
    else:
        result.status = "FAIL"
        result.notes = "Did not recall the favorite animal"

    result.timeline = (
        [{"t": m["time"], "turn": 1, "preview": m["text"][:60]} for m in msgs1] +
        [{"t": m["time"], "turn": 2, "preview": m["text"][:60]} for m in msgs2]
    )
    return result


# =========================================================================
# Test 7: Parallel Async Tasks
# =========================================================================
async def test_parallel_tasks(client):
    """Spawn multiple async tasks at once — all should complete."""
    result = TestResult("parallel_async_tasks")
    topic_id = await create_topic(client, "[Test] Parallel Tasks")
    await asyncio.sleep(1)

    prompt = (
        'Spawn THREE async tasks using the `task` tool:\n'
        '1. "What is the population of Tokyo?"\n'
        '2. "What is the tallest mountain in Africa?"\n'
        '3. "What year was the Eiffel Tower built?"\n'
        'Use async=true for all three. After spawning, confirm all three are running.'
    )
    await client.send_message(CHAT_ID, prompt, reply_to=topic_id)

    msgs = await collect_bot_messages(client, topic_id, timeout=300, min_messages=2,
        stop_check=lambda ms: (
            sum(1 for m in ms if any(kw in m["text"].lower() for kw in
                ["tokyo", "kilimanjaro", "eiffel", "1889", "million"]))
            >= 2
        ))

    has_ack = any("task" in m["text"].lower() or "running" in m["text"].lower() or "spawned" in m["text"].lower() for m in msgs)
    result_count = sum(1 for m in msgs if any(kw in m["text"].lower() for kw in
        ["tokyo", "kilimanjaro", "eiffel", "1889", "million", "population"]))

    if has_ack and result_count >= 2:
        result.status = "PASS"
        result.notes = f"Spawned + {result_count} results received"
    elif has_ack:
        result.status = "PARTIAL"
        result.notes = f"Spawned but only {result_count} results"
    else:
        result.status = "FAIL"
        result.notes = "No spawn acknowledgment"

    result.timeline = [{"t": m["time"], "preview": m["text"][:60]} for m in msgs]
    return result


# =========================================================================
# Main
# =========================================================================
async def main():
    api_id = int(os.environ["TELEGRAM_API_ID"])
    api_hash = os.environ["TELEGRAM_API_HASH"]
    session_str = os.environ["TELEGRAM_SESSION_STRING"]

    client = TelegramClient(StringSession(session_str), api_id, api_hash)
    await client.start()
    me = await client.get_me()
    log.info(f"Authenticated as {me.username} (id={me.id})")

    # Run tests in two waves: fast tests in parallel, then sequential slow tests

    # Wave 1: Fast independent tests (parallel)
    log.info("\n" + "=" * 70)
    log.info("WAVE 1: Fast tests (parallel)")
    log.info("=" * 70)

    fast_tests = await asyncio.gather(
        test_knowledge_question(client),
        test_multi_turn(client),
        test_sync_task(client),
        return_exceptions=True,
    )

    # Wave 2: Async/agent tests (sequential to avoid interference)
    log.info("\n" + "=" * 70)
    log.info("WAVE 2: Async & agent tests (sequential)")
    log.info("=" * 70)

    slow_results = []
    for test_fn in [test_async_task, test_async_agent, test_nonblocking, test_parallel_tasks]:
        log.info(f"\n--- Running {test_fn.__name__} ---")
        try:
            r = await test_fn(client)
        except Exception as e:
            r = TestResult(test_fn.__name__, status="ERROR", notes=str(e))
        slow_results.append(r)
        log.info(f"  Result: {r.status} — {r.notes}")
        await asyncio.sleep(5)

    # Combine results
    all_results = []
    for r in fast_tests:
        if isinstance(r, Exception):
            all_results.append(TestResult("unknown", status="ERROR", notes=str(r)))
        else:
            all_results.append(r)
    all_results.extend(slow_results)

    # Summary
    print("\n" + "=" * 70)
    print("COMPREHENSIVE LEMON BOT TEST RESULTS")
    print("=" * 70)

    for r in all_results:
        icon = {"PASS": "✅", "PARTIAL": "⚠️", "FAIL": "❌", "ERROR": "💥"}.get(r.status, "?")
        print(f"\n{icon} {r.test_name}: {r.status}")
        print(f"   {r.notes}")
        if r.latency:
            print(f"   Latency: {r.latency:.1f}s")
        if r.timeline:
            for evt in r.timeline[:5]:
                preview = evt.get("preview", "")
                print(f"   t={evt['t']:.1f}s: {preview[:55]}")
            if len(r.timeline) > 5:
                print(f"   ... +{len(r.timeline) - 5} more events")

    passed = sum(1 for r in all_results if r.status == "PASS")
    partial = sum(1 for r in all_results if r.status == "PARTIAL")
    failed = sum(1 for r in all_results if r.status in ("FAIL", "ERROR"))
    total = len(all_results)

    print(f"\n{'=' * 70}")
    print(f"OVERALL: {passed}/{total} PASS, {partial} PARTIAL, {failed} FAIL")
    print(f"{'=' * 70}")

    # Save results
    ts = int(time.time())
    outfile = f"comprehensive_results_{ts}.json"
    with open(outfile, "w") as f:
        json.dump(
            [
                {
                    "test_name": r.test_name,
                    "status": r.status,
                    "latency": r.latency,
                    "notes": r.notes,
                    "timeline": r.timeline,
                }
                for r in all_results
            ],
            f,
            indent=2,
        )
    log.info(f"Results saved to {outfile}")

    await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
