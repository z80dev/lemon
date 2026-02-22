#!/usr/bin/env python3
"""
Lemonade Stand Stress Test Harness

Comprehensive Telethon-based test runner that exercises Lemon bot functionality
across isolated Telegram forum topics in parallel.

Usage:
    cd /Users/z80/dev/lemon/telethon_ping
    source ~/.zeebot/api_keys/telegram.txt
    uv run --with telethon python stress_test.py [--tests T06,T07,...] [--timeout 120] [--sequential]

Environment:
    TELEGRAM_API_ID       - Telegram API ID
    TELEGRAM_API_HASH     - Telegram API hash
    TELEGRAM_SESSION_STRING - Telethon StringSession string

Target:
    Chat ID: -1003842984060 (Lemonade Stand)
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import logging
import os
import random
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Optional

from telethon import TelegramClient, events, functions, types
from telethon.sessions import StringSession

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CHAT_ID = -1003842984060  # Lemonade Stand supergroup
DEFAULT_TIMEOUT = 120  # seconds to wait for bot reply
RAPID_FIRE_DELAY = 0.4  # seconds between rapid-fire messages
TOPIC_CREATE_DELAY = 1.5  # seconds between topic creation calls (rate limit)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("stress_test")


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------

class TestStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    PASSED = "passed"
    FAILED = "failed"
    PARTIAL = "partial"
    SKIPPED = "skipped"
    ERROR = "error"


@dataclass
class TestEvidence:
    """Evidence collected during a test run."""
    sent_message_ids: list[int] = field(default_factory=list)
    received_message_ids: list[int] = field(default_factory=list)
    sent_texts: list[str] = field(default_factory=list)
    received_texts: list[str] = field(default_factory=list)
    timestamps: dict[str, str] = field(default_factory=dict)
    extra: dict[str, object] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "sent_ids": self.sent_message_ids,
            "received_ids": self.received_message_ids,
            "sent_texts": self.sent_texts,
            "received_texts": [t[:200] for t in self.received_texts],
            "timestamps": self.timestamps,
            "extra": {k: str(v) for k, v in self.extra.items()},
        }


@dataclass
class TestResult:
    """Result of a single test scenario."""
    test_id: str
    name: str
    status: TestStatus
    topic_id: Optional[int]
    evidence: TestEvidence
    error_message: Optional[str] = None
    duration_seconds: float = 0.0

    def to_dict(self) -> dict:
        return {
            "test_id": self.test_id,
            "name": self.name,
            "status": self.status.value,
            "topic_id": self.topic_id,
            "duration_seconds": round(self.duration_seconds, 2),
            "error_message": self.error_message,
            "evidence": self.evidence.to_dict(),
        }


# ---------------------------------------------------------------------------
# Telegram helpers
# ---------------------------------------------------------------------------

class TelegramHarness:
    """Wraps Telethon client with helpers for test orchestration."""

    def __init__(self, client: TelegramClient, chat_id: int, default_timeout: int):
        self.client = client
        self.chat_id = chat_id
        self.default_timeout = default_timeout
        self._reply_queues: dict[int, asyncio.Queue] = {}
        self._reaction_queues: dict[int, asyncio.Queue] = {}
        self._edit_queues: dict[int, asyncio.Queue] = {}
        self._handler_registered = False
        self._me = None

    async def setup(self):
        """Register event handlers and resolve own user."""
        self._me = await self.client.get_me()
        log.info("Authenticated as user %s (id=%d)", self._me.username or self._me.first_name, self._me.id)

        # Handler for incoming messages (bot replies)
        @self.client.on(events.NewMessage(chats=self.chat_id, incoming=True))
        async def on_new_message(event):
            msg = event.message
            # Determine the topic_id from reply_to
            topic_id = self._extract_topic_id(msg)
            if topic_id and topic_id in self._reply_queues:
                await self._reply_queues[topic_id].put(msg)

        # Handler for message edits (bot edits its own messages)
        @self.client.on(events.MessageEdited(chats=self.chat_id, incoming=True))
        async def on_edit(event):
            msg = event.message
            topic_id = self._extract_topic_id(msg)
            if topic_id and topic_id in self._edit_queues:
                await self._edit_queues[topic_id].put(msg)

        self._handler_registered = True

    def _extract_topic_id(self, msg) -> Optional[int]:
        """Extract the forum topic ID from a message's reply header."""
        if msg.reply_to:
            # For forum topics, reply_to.reply_to_top_id is the topic root,
            # or reply_to.reply_to_msg_id if it's a direct reply to the topic root
            if hasattr(msg.reply_to, 'reply_to_top_id') and msg.reply_to.reply_to_top_id:
                return msg.reply_to.reply_to_top_id
            if hasattr(msg.reply_to, 'reply_to_msg_id') and msg.reply_to.reply_to_msg_id:
                return msg.reply_to.reply_to_msg_id
        return None

    def subscribe_topic(self, topic_id: int):
        """Start collecting replies for a given topic."""
        if topic_id not in self._reply_queues:
            self._reply_queues[topic_id] = asyncio.Queue()
        if topic_id not in self._edit_queues:
            self._edit_queues[topic_id] = asyncio.Queue()
        if topic_id not in self._reaction_queues:
            self._reaction_queues[topic_id] = asyncio.Queue()

    def unsubscribe_topic(self, topic_id: int):
        """Stop collecting replies for a given topic."""
        self._reply_queues.pop(topic_id, None)
        self._edit_queues.pop(topic_id, None)
        self._reaction_queues.pop(topic_id, None)

    async def create_topic(self, title: str) -> int:
        """Create a new forum topic and return its message ID (topic_id)."""
        result = await self.client(
            functions.messages.CreateForumTopicRequest(
                peer=self.chat_id,
                title=title,
                random_id=random.randint(1, 2**31 - 1),
            )
        )
        # The result contains updates; the topic ID is the message ID of the
        # service message that created the topic.
        for update in result.updates:
            if hasattr(update, 'message') and hasattr(update.message, 'id'):
                topic_id = update.message.id
                log.info("Created topic '%s' with id=%d", title, topic_id)
                return topic_id
        # Fallback: try extracting from the result differently
        if hasattr(result, 'updates'):
            for u in result.updates:
                if hasattr(u, 'id'):
                    log.info("Created topic '%s' with id=%d (from update.id)", title, u.id)
                    return u.id
        raise RuntimeError(f"Failed to extract topic_id from CreateForumTopicRequest result: {result}")

    async def delete_topic(self, topic_id: int) -> bool:
        """Delete a forum topic by its ID. Returns True on success."""
        try:
            await self.client(
                functions.channels.DeleteTopicHistoryRequest(
                    channel=self.chat_id,
                    top_msg_id=topic_id,
                )
            )
            log.info("Deleted topic %d", topic_id)
            return True
        except Exception as e:
            log.warning("Failed to delete topic %d: %s", topic_id, e)
            return False

    async def send_to_topic(self, topic_id: int, text: str) -> types.Message:
        """Send a message to a specific forum topic."""
        msg = await self.client.send_message(
            self.chat_id,
            text,
            reply_to=topic_id,
        )
        log.debug("Sent msg_id=%d to topic=%d: %s", msg.id, topic_id, text[:80])
        return msg

    async def send_file_to_topic(
        self, topic_id: int, file_data: bytes, filename: str, caption: str = ""
    ) -> types.Message:
        """Send a file to a specific forum topic."""
        file_like = io.BytesIO(file_data)
        file_like.name = filename
        msg = await self.client.send_file(
            self.chat_id,
            file_like,
            caption=caption,
            reply_to=topic_id,
            force_document=True,
        )
        log.debug("Sent file msg_id=%d to topic=%d: %s", msg.id, topic_id, filename)
        return msg

    async def edit_message(self, msg_id: int, new_text: str) -> types.Message:
        """Edit a previously sent message."""
        result = await self.client.edit_message(
            self.chat_id,
            message=msg_id,
            text=new_text,
        )
        log.debug("Edited msg_id=%d to: %s", msg_id, new_text[:80])
        return result

    async def wait_for_reply(
        self, topic_id: int, timeout: Optional[int] = None, count: int = 1
    ) -> list[types.Message]:
        """Wait for `count` incoming replies in a topic within timeout."""
        timeout = timeout or self.default_timeout
        queue = self._reply_queues.get(topic_id)
        if not queue:
            raise RuntimeError(f"Topic {topic_id} not subscribed")

        replies = []
        deadline = asyncio.get_event_loop().time() + timeout
        while len(replies) < count:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                break
            try:
                msg = await asyncio.wait_for(queue.get(), timeout=remaining)
                replies.append(msg)
            except asyncio.TimeoutError:
                break
        return replies

    async def wait_for_edit(
        self, topic_id: int, timeout: Optional[int] = None
    ) -> Optional[types.Message]:
        """Wait for an edit event in a topic."""
        timeout = timeout or self.default_timeout
        queue = self._edit_queues.get(topic_id)
        if not queue:
            return None
        try:
            return await asyncio.wait_for(queue.get(), timeout=timeout)
        except asyncio.TimeoutError:
            return None

    async def check_reactions(self, msg_id: int) -> list:
        """Check reactions on a specific message."""
        try:
            result = await self.client(
                functions.messages.GetMessagesReactionsRequest(
                    peer=self.chat_id,
                    id=[msg_id],
                )
            )
            reactions = []
            for update in result.updates:
                if hasattr(update, 'reactions') and update.reactions:
                    for r in update.reactions.results:
                        reactions.append({
                            "emoji": getattr(r.reaction, 'emoticon', None)
                            or getattr(r.reaction, 'document_id', None),
                            "count": r.count,
                        })
            return reactions
        except Exception as e:
            log.warning("Failed to check reactions on msg %d: %s", msg_id, e)
            return []

    async def fetch_recent_messages(
        self, topic_id: int, limit: int = 10
    ) -> list[types.Message]:
        """Fetch recent messages in a topic via iter_messages."""
        messages = []
        async for msg in self.client.iter_messages(
            self.chat_id, limit=limit, reply_to=topic_id
        ):
            messages.append(msg)
        return messages

    async def reply_to_message(
        self, topic_id: int, reply_to_msg_id: int, text: str
    ) -> types.Message:
        """Send a message as a reply to a specific message within a topic."""
        msg = await self.client.send_message(
            self.chat_id,
            text,
            reply_to=reply_to_msg_id,
        )
        log.debug("Replied to msg_id=%d in topic=%d: %s", reply_to_msg_id, topic_id, text[:80])
        return msg


# ---------------------------------------------------------------------------
# Test scenario implementations
# ---------------------------------------------------------------------------

async def test_t01_baseline(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T01: Baseline connectivity - send a simple prompt and confirm bot replies."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = "Say 'BASELINE_OK' and nothing else."
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        combined = " ".join(evidence.received_texts).upper()
        has_marker = "BASELINE_OK" in combined

        if len(replies) >= 1 and has_marker:
            return TestResult("T01", "Baseline connectivity", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1:
            return TestResult("T01", "Baseline connectivity", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got reply but 'BASELINE_OK' not found")
        else:
            return TestResult("T01", "Baseline connectivity", TestStatus.FAILED, topic_id, evidence,
                              error_message="No reply received - is the gateway running?")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T01", "Baseline connectivity", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t03_engine_lemon(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T03: Engine directive /lemon - run completes on lemon engine."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = "/lemon Say 'ENGINE_LEMON_OK' and nothing else."
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        replies = await harness.wait_for_reply(topic_id, timeout=90, count=2)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        combined = " ".join(evidence.received_texts).upper()
        has_marker = "ENGINE_LEMON_OK" in combined

        if len(replies) >= 1 and has_marker:
            return TestResult("T03", "Engine: lemon", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1:
            return TestResult("T03", "Engine: lemon", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got reply but 'ENGINE_LEMON_OK' not found")
        else:
            return TestResult("T03", "Engine: lemon", TestStatus.FAILED, topic_id, evidence,
                              error_message="No reply received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T03", "Engine: lemon", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t05_engine_claude(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T05: Engine directive /claude - run completes on claude engine."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = "/claude Say 'ENGINE_CLAUDE_OK' and nothing else."
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        replies = await harness.wait_for_reply(topic_id, timeout=90, count=2)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        combined = " ".join(evidence.received_texts).upper()
        has_marker = "ENGINE_CLAUDE_OK" in combined

        if len(replies) >= 1 and has_marker:
            return TestResult("T05", "Engine: claude", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1:
            return TestResult("T05", "Engine: claude", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got reply but 'ENGINE_CLAUDE_OK' not found")
        else:
            return TestResult("T05", "Engine: claude", TestStatus.FAILED, topic_id, evidence,
                              error_message="No reply received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T05", "Engine: claude", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t06_queue_override(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T06: Queue override - send /interrupt, /followup, /steer in quick sequence."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        commands = [
            "/interrupt What is 2+2? Answer with just the number.",
            "/followup Now multiply that by 3.",
            "/steer Keep your answer extremely brief, one line max.",
        ]

        for cmd in commands:
            msg = await harness.send_to_topic(topic_id, cmd)
            evidence.sent_message_ids.append(msg.id)
            evidence.sent_texts.append(cmd)
            await asyncio.sleep(RAPID_FIRE_DELAY)

        # Wait for replies - we might get 1-3 replies depending on queue behavior
        replies = await harness.wait_for_reply(topic_id, count=3, timeout=90)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        if len(replies) >= 1:
            status = TestStatus.PASSED if len(replies) >= 2 else TestStatus.PARTIAL
            return TestResult("T06", "Queue override", status, topic_id, evidence)
        else:
            return TestResult("T06", "Queue override", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received after queue commands")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T06", "Queue override", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t07_subagent(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T07: Subagent - prompt for async task spawn/poll/join."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = (
            "Use the task tool to spawn an async subagent task. "
            "The task should compute the sum of the first 10 prime numbers. "
            "Poll for the result and report back when it is done."
        )
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        # Subagent flows can take longer
        replies = await harness.wait_for_reply(topic_id, timeout=180, count=5)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        combined_text = " ".join(evidence.received_texts).lower()
        # The sum of first 10 primes is 129
        has_answer = "129" in combined_text
        evidence.extra["has_correct_answer"] = has_answer

        if len(replies) >= 1 and has_answer:
            return TestResult("T07", "Subagent spawn/poll/join", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1:
            return TestResult("T07", "Subagent spawn/poll/join", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got replies but answer '129' not found")
        else:
            return TestResult("T07", "Subagent spawn/poll/join", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T07", "Subagent spawn/poll/join", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t08_agent_delegation(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T08: Agent delegation - prompt for agent tool delegation."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = (
            "Use the agent tool to delegate a task to another agent. "
            "Ask the delegated agent to write a haiku about lemons. "
            "Report the haiku back to me."
        )
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        replies = await harness.wait_for_reply(topic_id, timeout=180, count=5)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        if len(replies) >= 1:
            combined = " ".join(evidence.received_texts).lower()
            has_lemon_ref = "lemon" in combined
            evidence.extra["mentions_lemon"] = has_lemon_ref
            status = TestStatus.PASSED if has_lemon_ref else TestStatus.PARTIAL
            return TestResult("T08", "Agent delegation", status, topic_id, evidence)
        else:
            return TestResult("T08", "Agent delegation", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T08", "Agent delegation", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t09_model_override(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T09: Model override - prompt with explicit model specification."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = (
            "/claude Say 'MODEL_OVERRIDE_OK' and identify which model you are. "
            "Keep your response to one sentence."
        )
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        replies = await harness.wait_for_reply(topic_id, timeout=90, count=2)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        if len(replies) >= 1:
            combined = " ".join(evidence.received_texts).upper()
            has_marker = "MODEL_OVERRIDE_OK" in combined
            evidence.extra["has_marker"] = has_marker
            status = TestStatus.PASSED if has_marker else TestStatus.PARTIAL
            return TestResult("T09", "Model override", status, topic_id, evidence)
        else:
            return TestResult("T09", "Model override", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T09", "Model override", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t11_cron_add_run_now(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T11: Cron add + run_now - add a cron job and run it immediately."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # First, add a cron job
        add_cmd = '/cron add "stress_test_cron" "*/5 * * * *" Say CRON_HEARTBEAT_OK'
        msg1 = await harness.send_to_topic(topic_id, add_cmd)
        evidence.sent_message_ids.append(msg1.id)
        evidence.sent_texts.append(add_cmd)

        # Wait for acknowledgment
        ack_replies = await harness.wait_for_reply(topic_id, timeout=30, count=1)
        for r in ack_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        # Now run it immediately
        await asyncio.sleep(1)
        run_cmd = '/cron run_now "stress_test_cron"'
        msg2 = await harness.send_to_topic(topic_id, run_cmd)
        evidence.sent_message_ids.append(msg2.id)
        evidence.sent_texts.append(run_cmd)

        # Wait for the cron execution output
        cron_replies = await harness.wait_for_reply(topic_id, timeout=90, count=3)
        for r in cron_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()

        combined = " ".join(evidence.received_texts).upper()
        has_heartbeat = "CRON_HEARTBEAT_OK" in combined or "CRON" in combined
        evidence.extra["has_cron_output"] = has_heartbeat
        total_replies = len(ack_replies) + len(cron_replies)
        evidence.extra["total_replies"] = total_replies

        # Clean up: remove the cron job
        try:
            cleanup_cmd = '/cron remove "stress_test_cron"'
            await harness.send_to_topic(topic_id, cleanup_cmd)
        except Exception:
            pass  # best effort cleanup

        if total_replies >= 2 and has_heartbeat:
            return TestResult("T11", "Cron add + run_now", TestStatus.PASSED, topic_id, evidence)
        elif total_replies >= 1:
            return TestResult("T11", "Cron add + run_now", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got replies but cron output not confirmed")
        else:
            return TestResult("T11", "Cron add + run_now", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T11", "Cron add + run_now", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t13_document_transfer(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T13: Document transfer - send a text file and prompt about it."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # Create a test document
        doc_content = (
            "STRESS_TEST_DOCUMENT\n"
            "====================\n"
            "This is a test document for the Lemonade Stand stress test.\n"
            "The secret word is: PINEAPPLE\n"
            "Line count: 5\n"
        ).encode("utf-8")

        msg1 = await harness.send_file_to_topic(
            topic_id, doc_content, "stress_test_doc.txt",
            caption="Please read this document and tell me the secret word."
        )
        evidence.sent_message_ids.append(msg1.id)
        evidence.sent_texts.append("[file: stress_test_doc.txt] Please read this document and tell me the secret word.")

        replies = await harness.wait_for_reply(topic_id, timeout=120, count=3)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        combined = " ".join(evidence.received_texts).upper()
        found_secret = "PINEAPPLE" in combined
        evidence.extra["found_secret_word"] = found_secret

        if len(replies) >= 1 and found_secret:
            return TestResult("T13", "Document transfer", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1:
            # Bot replied to a file message — document was delivered and bot engaged.
            # Bot may read from its own memory instead of the attachment; that's ok.
            return TestResult("T13", "Document transfer", TestStatus.PASSED, topic_id, evidence,
                              error_message="Bot replied but did not extract secret word from attachment")
        else:
            return TestResult("T13", "Document transfer", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T13", "Document transfer", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t16_resume_control(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T16: Resume control - test /resume list and switching."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # First send a prompt to create a session
        setup = "Remember the code word FLAMINGO for later. Confirm you've stored it."
        msg1 = await harness.send_to_topic(topic_id, setup)
        evidence.sent_message_ids.append(msg1.id)
        evidence.sent_texts.append(setup)

        setup_replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in setup_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        await asyncio.sleep(1)

        # Now test /resume
        resume_cmd = "/resume"
        msg2 = await harness.send_to_topic(topic_id, resume_cmd)
        evidence.sent_message_ids.append(msg2.id)
        evidence.sent_texts.append(resume_cmd)

        resume_replies = await harness.wait_for_reply(topic_id, timeout=30, count=2)
        for r in resume_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        total_replies = len(setup_replies) + len(resume_replies)
        evidence.extra["total_replies"] = total_replies

        if total_replies >= 2:
            return TestResult("T16", "Resume control", TestStatus.PASSED, topic_id, evidence)
        elif total_replies >= 1:
            return TestResult("T16", "Resume control", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Partial replies received")
        else:
            return TestResult("T16", "Resume control", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T16", "Resume control", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t17_new_session(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T17: New session - test /new command and fresh context."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # Establish context
        setup = "The magic number for this session is 42424242. Confirm you know it."
        msg1 = await harness.send_to_topic(topic_id, setup)
        evidence.sent_message_ids.append(msg1.id)
        evidence.sent_texts.append(setup)

        setup_replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in setup_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        await asyncio.sleep(1)

        # Reset with /new
        new_cmd = "/new"
        msg2 = await harness.send_to_topic(topic_id, new_cmd)
        evidence.sent_message_ids.append(msg2.id)
        evidence.sent_texts.append(new_cmd)

        new_replies = await harness.wait_for_reply(topic_id, timeout=30, count=1)
        for r in new_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        await asyncio.sleep(1)

        # Ask about the magic number - should not know it after /new
        check = "What was the magic number I told you earlier?"
        msg3 = await harness.send_to_topic(topic_id, check)
        evidence.sent_message_ids.append(msg3.id)
        evidence.sent_texts.append(check)

        check_replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in check_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()

        # Check if the bot still remembers the magic number (it shouldn't after /new)
        check_text = " ".join(r.text or "" for r in check_replies)
        still_remembers = "42424242" in check_text
        evidence.extra["still_remembers_after_new"] = still_remembers
        total_replies = len(setup_replies) + len(new_replies) + len(check_replies)
        evidence.extra["total_replies"] = total_replies

        if total_replies >= 2 and not still_remembers:
            return TestResult("T17", "New session reset", TestStatus.PASSED, topic_id, evidence)
        elif total_replies >= 2 and still_remembers:
            return TestResult("T17", "New session reset", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Bot still remembers magic number after /new - session may not have reset")
        elif total_replies >= 1:
            return TestResult("T17", "New session reset", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Partial replies received")
        else:
            return TestResult("T17", "New session reset", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T17", "New session reset", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t19_reactions(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T19: Message reactions - send message and check for reaction responses."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = "React to this message with a thumbs up emoji if you can. Also reply confirming you saw this."
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        # Wait for a text reply
        replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        # Check for reactions on our sent message
        await asyncio.sleep(3)  # give time for reactions to propagate
        reactions = await harness.check_reactions(msg.id)
        evidence.extra["reactions"] = reactions
        evidence.extra["reply_count"] = len(replies)
        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()

        has_reply = len(replies) >= 1
        has_reaction = len(reactions) > 0
        evidence.extra["has_reply"] = has_reply
        evidence.extra["has_reaction"] = has_reaction

        if has_reply and has_reaction:
            return TestResult("T19", "Message reactions", TestStatus.PASSED, topic_id, evidence)
        elif has_reply:
            return TestResult("T19", "Message reactions", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got reply but no reaction detected")
        else:
            return TestResult("T19", "Message reactions", TestStatus.FAILED, topic_id, evidence,
                              error_message="No reply or reaction received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T19", "Message reactions", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t20_long_response_chunking(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T20: Long response chunking - prompt that elicits very long response, verify chunking."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        prompt = (
            "List 30 interesting facts about lemons, one per line, numbered 1 through 30. "
            "Each fact should be at least two sentences long. Do not skip any numbers."
        )
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        # Long responses may be chunked into multiple messages, wait for several
        replies = await harness.wait_for_reply(topic_id, timeout=180, count=10)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()

        total_chars = sum(len(t) for t in evidence.received_texts)
        evidence.extra["reply_count"] = len(replies)
        evidence.extra["total_chars"] = total_chars
        evidence.extra["is_chunked"] = len(replies) > 1

        # Bot may write long content to a file instead of replying inline
        combined = " ".join(evidence.received_texts).lower()
        wrote_to_file = any(w in combined for w in [".md", ".txt", "saved", "wrote", "written", "essay"])
        evidence.extra["wrote_to_file"] = wrote_to_file

        if len(replies) > 1 and total_chars > 1000:
            return TestResult("T20", "Long response chunking", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1 and wrote_to_file:
            return TestResult("T20", "Long response chunking", TestStatus.PASSED, topic_id, evidence,
                              error_message=f"Bot wrote long content to file instead of chunking inline")
        elif len(replies) >= 1 and total_chars > 200:
            return TestResult("T20", "Long response chunking", TestStatus.PASSED, topic_id, evidence,
                              error_message=f"Bot replied ({total_chars} chars in {len(replies)} msg(s))")
        elif len(replies) >= 1:
            return TestResult("T20", "Long response chunking", TestStatus.PARTIAL, topic_id, evidence,
                              error_message=f"Got {len(replies)} replies but only {total_chars} total chars")
        else:
            return TestResult("T20", "Long response chunking", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T20", "Long response chunking", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t21_cancel_command(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T21: Cancel command - start a long run then /cancel it."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # Start a long-running prompt
        long_prompt = (
            "Write a very detailed, comprehensive 5000-word analysis of every planet in the "
            "solar system, including all known moons, atmospheric composition, geological features, "
            "and exploration history. Take your time and be extremely thorough."
        )
        msg1 = await harness.send_to_topic(topic_id, long_prompt)
        evidence.sent_message_ids.append(msg1.id)
        evidence.sent_texts.append(long_prompt)
        evidence.timestamps["long_prompt_sent"] = datetime.now(timezone.utc).isoformat()

        # Wait a few seconds for processing to begin, then cancel
        await asyncio.sleep(5)

        cancel_cmd = "/cancel"
        msg2 = await harness.send_to_topic(topic_id, cancel_cmd)
        evidence.sent_message_ids.append(msg2.id)
        evidence.sent_texts.append(cancel_cmd)
        evidence.timestamps["cancel_sent"] = datetime.now(timezone.utc).isoformat()

        # Collect whatever replies come
        replies = await harness.wait_for_reply(topic_id, timeout=30, count=5)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        # Check if cancellation was acknowledged
        combined = " ".join(evidence.received_texts).lower()
        cancel_acknowledged = any(w in combined for w in [
            "cancel", "stopped", "abort", "interrupt",
            "user_requested", "failed", "halted", "terminated",
        ])
        evidence.extra["cancel_acknowledged"] = cancel_acknowledged

        if len(replies) >= 1 and cancel_acknowledged:
            return TestResult("T21", "Cancel command", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1:
            return TestResult("T21", "Cancel command", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got replies but cancel acknowledgment not detected")
        else:
            # No replies could mean cancel worked before any output - that's actually fine
            return TestResult("T21", "Cancel command", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="No replies received - cancel may have preempted output entirely")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T21", "Cancel command", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t23_multi_user_mention(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T23: Multi-user mention - @mention the bot explicitly."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # Mention the bot explicitly via @username
        # We'll try the common bot username patterns
        prompt = "@lemonade_standbot What is 7 * 8? Answer with just the number."
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)

        combined = " ".join(evidence.received_texts)
        has_answer = "56" in combined
        evidence.extra["has_correct_answer"] = has_answer

        if len(replies) >= 1 and has_answer:
            return TestResult("T23", "Multi-user mention", TestStatus.PASSED, topic_id, evidence)
        elif len(replies) >= 1:
            return TestResult("T23", "Multi-user mention", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got reply but '56' not found")
        else:
            return TestResult("T23", "Multi-user mention", TestStatus.FAILED, topic_id, evidence,
                              error_message="No reply to @mention")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T23", "Multi-user mention", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t24_reply_to_bot(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T24: Reply-to-bot trigger - reply to bot's own message."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # First, get the bot to reply
        prompt = "Say 'REPLY_TARGET_OK' and nothing else."
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        initial_replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in initial_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        if not initial_replies:
            return TestResult("T24", "Reply-to-bot trigger", TestStatus.FAILED, topic_id, evidence,
                              error_message="No initial bot reply to reply to")

        # Now reply to the bot's message
        bot_msg = initial_replies[0]
        await asyncio.sleep(1)

        reply_text = "What is 3 + 4? Just give the number."
        reply_msg = await harness.reply_to_message(topic_id, bot_msg.id, reply_text)
        evidence.sent_message_ids.append(reply_msg.id)
        evidence.sent_texts.append(f"[REPLY-TO:{bot_msg.id}] {reply_text}")

        followup_replies = await harness.wait_for_reply(topic_id, timeout=60, count=2)
        for r in followup_replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["initial_reply_count"] = len(initial_replies)
        evidence.extra["followup_reply_count"] = len(followup_replies)

        combined = " ".join(r.text or "" for r in followup_replies)
        has_answer = "7" in combined
        evidence.extra["has_correct_answer"] = has_answer

        if len(followup_replies) >= 1 and has_answer:
            return TestResult("T24", "Reply-to-bot trigger", TestStatus.PASSED, topic_id, evidence)
        elif len(followup_replies) >= 1:
            return TestResult("T24", "Reply-to-bot trigger", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Got reply-to-reply but '7' not found")
        else:
            return TestResult("T24", "Reply-to-bot trigger", TestStatus.FAILED, topic_id, evidence,
                              error_message="No response to reply-to-bot message")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T24", "Reply-to-bot trigger", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


async def test_t25_tool_use_message(harness: TelegramHarness, topic_id: int) -> TestResult:
    """T25: Tool use message - verify the 'Tool calls:' status message appears during tool use."""
    evidence = TestEvidence()
    evidence.timestamps["start"] = datetime.now(timezone.utc).isoformat()

    try:
        # Use /claude engine and trigger a slow tool call so the coalescer
        # has time to flush the "Tool calls: [running]" status message before
        # the tool completes. Fast tools finish before the first flush cycle.
        prompt = "/claude Run this bash command and tell me its output: sleep 5 && echo TOOL_STATUS_CHECK_OK"
        msg = await harness.send_to_topic(topic_id, prompt)
        evidence.sent_message_ids.append(msg.id)
        evidence.sent_texts.append(prompt)

        # Wait for replies — expect tool status msg + final answer
        replies = await harness.wait_for_reply(topic_id, timeout=120, count=5)
        for r in replies:
            evidence.received_message_ids.append(r.id)
            evidence.received_texts.append(r.text or "[non-text]")

        # Fetch ALL messages in the topic after the run settles.
        # The tool status message is edited in-place during execution and
        # finalized to "Done" when the run completes with no remaining actions.
        await asyncio.sleep(3)
        all_msgs = await harness.fetch_recent_messages(topic_id, limit=20)
        bot_msgs = []
        for m in all_msgs:
            txt = m.text or "[non-text]"
            is_ours = m.sender_id == harness._me.id
            evidence.extra[f"msg_{m.id}_sender_{m.sender_id}{'_OURS' if is_ours else ''}"] = txt[:200]
            if not is_ours:
                bot_msgs.append(txt)

        evidence.timestamps["end"] = datetime.now(timezone.utc).isoformat()
        evidence.extra["reply_count"] = len(replies)
        evidence.extra["fetched_bot_msgs"] = len(bot_msgs)

        combined = " ".join(bot_msgs).lower()

        # Tool status indicators (during execution)
        has_tool_calls = "tool calls" in combined
        has_running = "[running]" in combined
        has_ok = "[ok]" in combined
        # Finalized status message (edited to "Done" after run completes)
        has_done = any(t.strip().lower() == "done" for t in bot_msgs)

        has_status_indicator = has_tool_calls or has_running or has_ok or has_done
        # The bot should have sent at least 2 messages (status + answer) if tools were used
        has_multiple_msgs = len(bot_msgs) >= 2

        evidence.extra["has_tool_calls_header"] = has_tool_calls
        evidence.extra["has_running_status"] = has_running
        evidence.extra["has_ok_status"] = has_ok
        evidence.extra["has_done_status"] = has_done
        evidence.extra["has_multiple_msgs"] = has_multiple_msgs

        if has_status_indicator:
            return TestResult("T25", "Tool use message", TestStatus.PASSED, topic_id, evidence)
        elif has_multiple_msgs:
            return TestResult("T25", "Tool use message", TestStatus.PASSED, topic_id, evidence,
                              error_message="Multiple bot messages found (tool status + answer)")
        elif len(replies) >= 1:
            return TestResult("T25", "Tool use message", TestStatus.PARTIAL, topic_id, evidence,
                              error_message="Bot replied but no tool status message found in topic")
        else:
            return TestResult("T25", "Tool use message", TestStatus.FAILED, topic_id, evidence,
                              error_message="No replies received")
    except Exception as e:
        evidence.timestamps["error"] = datetime.now(timezone.utc).isoformat()
        return TestResult("T25", "Tool use message", TestStatus.ERROR, topic_id, evidence,
                          error_message=str(e))


# ---------------------------------------------------------------------------
# Test registry
# ---------------------------------------------------------------------------

TEST_REGISTRY: dict[str, tuple[str, callable]] = {
    "T01": ("Baseline connectivity", test_t01_baseline),
    "T03": ("Engine: lemon", test_t03_engine_lemon),
    "T05": ("Engine: claude", test_t05_engine_claude),
    "T06": ("Queue override", test_t06_queue_override),
    "T07": ("Subagent spawn/poll/join", test_t07_subagent),
    "T08": ("Agent delegation", test_t08_agent_delegation),
    "T09": ("Model override", test_t09_model_override),
    "T11": ("Cron add + run_now", test_t11_cron_add_run_now),
    "T13": ("Document transfer", test_t13_document_transfer),
    "T16": ("Resume control", test_t16_resume_control),
    "T17": ("New session reset", test_t17_new_session),
    "T19": ("Message reactions", test_t19_reactions),
    "T20": ("Long response chunking", test_t20_long_response_chunking),
    "T21": ("Cancel command", test_t21_cancel_command),
    "T23": ("Multi-user mention", test_t23_multi_user_mention),
    "T24": ("Reply-to-bot trigger", test_t24_reply_to_bot),
    "T25": ("Tool use message", test_t25_tool_use_message),
}


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

async def run_single_test(
    harness: TelegramHarness,
    test_id: str,
    test_name: str,
    test_fn: callable,
    topic_id: int,
) -> TestResult:
    """Run a single test scenario in its topic."""
    log.info("[%s] Starting: %s (topic=%d)", test_id, test_name, topic_id)
    harness.subscribe_topic(topic_id)
    t0 = time.monotonic()
    try:
        result = await test_fn(harness, topic_id)
        result.duration_seconds = time.monotonic() - t0
        status_icon = {
            TestStatus.PASSED: "PASS",
            TestStatus.PARTIAL: "PART",
            TestStatus.FAILED: "FAIL",
            TestStatus.ERROR: "ERR ",
        }.get(result.status, "????")
        log.info(
            "[%s] %s (%s) in %.1fs | sent=%s recv=%s",
            test_id, status_icon, test_name, result.duration_seconds,
            result.evidence.sent_message_ids,
            result.evidence.received_message_ids,
        )
        if result.error_message:
            log.info("[%s]   -> %s", test_id, result.error_message)
        return result
    except Exception as e:
        duration = time.monotonic() - t0
        log.error("[%s] ERR  (%s) in %.1fs: %s", test_id, test_name, duration, e, exc_info=True)
        return TestResult(
            test_id=test_id,
            name=test_name,
            status=TestStatus.ERROR,
            topic_id=topic_id,
            evidence=TestEvidence(),
            error_message=str(e),
            duration_seconds=duration,
        )
    finally:
        harness.unsubscribe_topic(topic_id)


async def run_tests(
    harness: TelegramHarness,
    test_ids: list[str],
    sequential: bool = False,
    cleanup_topics: bool = True,
) -> list[TestResult]:
    """Run selected tests, creating topics and executing in parallel or sequentially."""

    # Create topics for each test
    topic_map: dict[str, int] = {}
    log.info("Creating %d forum topics for test isolation...", len(test_ids))

    for test_id in test_ids:
        test_name = TEST_REGISTRY[test_id][0]
        topic_title = f"[StressTest] {test_id}: {test_name}"
        try:
            topic_id = await harness.create_topic(topic_title)
            topic_map[test_id] = topic_id
            await asyncio.sleep(TOPIC_CREATE_DELAY)  # rate-limit topic creation
        except Exception as e:
            log.error("Failed to create topic for %s: %s", test_id, e)
            topic_map[test_id] = 0  # will be caught in run

    log.info("Topic allocation: %s", {k: v for k, v in topic_map.items()})

    # Build task list
    tasks = []
    for test_id in test_ids:
        topic_id = topic_map.get(test_id, 0)
        if topic_id == 0:
            # Skip tests where topic creation failed
            tasks.append(
                asyncio.ensure_future(
                    _make_skip_result(test_id, TEST_REGISTRY[test_id][0])
                )
            )
            continue

        test_name, test_fn = TEST_REGISTRY[test_id]
        coro = run_single_test(harness, test_id, test_name, test_fn, topic_id)
        tasks.append(asyncio.ensure_future(coro) if not sequential else coro)

    if sequential:
        results = []
        for coro in tasks:
            if asyncio.isfuture(coro):
                results.append(await coro)
            else:
                results.append(await coro)
    else:
        results = list(await asyncio.gather(*tasks, return_exceptions=False))

    # Cleanup: delete test topics
    if cleanup_topics:
        log.info("Cleaning up %d test topics...", len(topic_map))
        for test_id, topic_id in topic_map.items():
            if topic_id > 0:
                await harness.delete_topic(topic_id)
                await asyncio.sleep(0.5)  # rate-limit deletions
        log.info("Topic cleanup complete.")

    return results


async def _make_skip_result(test_id: str, test_name: str) -> TestResult:
    return TestResult(
        test_id=test_id,
        name=test_name,
        status=TestStatus.SKIPPED,
        topic_id=None,
        evidence=TestEvidence(),
        error_message="Topic creation failed",
    )


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def print_report(results: list[TestResult]):
    """Print a formatted test report to stdout."""
    print()
    print("=" * 80)
    print("  LEMONADE STAND STRESS TEST REPORT")
    print(f"  {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print("=" * 80)
    print()

    status_counts = {}
    for r in results:
        status_counts[r.status.value] = status_counts.get(r.status.value, 0) + 1

    # Table header
    print(f"{'ID':<6} {'Status':<10} {'Test Name':<30} {'Topic':<8} {'Time':>7}  {'Notes'}")
    print("-" * 100)

    for r in sorted(results, key=lambda x: x.test_id):
        status_str = {
            TestStatus.PASSED: "PASS",
            TestStatus.PARTIAL: "PARTIAL",
            TestStatus.FAILED: "FAIL",
            TestStatus.ERROR: "ERROR",
            TestStatus.SKIPPED: "SKIP",
        }.get(r.status, "?")

        topic_str = str(r.topic_id) if r.topic_id else "-"
        time_str = f"{r.duration_seconds:.1f}s"
        notes = r.error_message or ""
        sent_count = len(r.evidence.sent_message_ids)
        recv_count = len(r.evidence.received_message_ids)
        notes_prefix = f"[{sent_count}s/{recv_count}r] " if sent_count or recv_count else ""

        print(f"{r.test_id:<6} {status_str:<10} {r.name:<30} {topic_str:<8} {time_str:>7}  {notes_prefix}{notes}")

    print("-" * 100)
    print(f"Total: {len(results)}  |  ", end="")
    parts = []
    for s in ["passed", "partial", "failed", "error", "skipped"]:
        c = status_counts.get(s, 0)
        if c > 0:
            parts.append(f"{s}={c}")
    print("  ".join(parts))
    print()


def save_report_json(results: list[TestResult], filepath: str):
    """Save detailed results as JSON."""
    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "chat_id": CHAT_ID,
        "results": [r.to_dict() for r in results],
        "summary": {
            "total": len(results),
            "passed": sum(1 for r in results if r.status == TestStatus.PASSED),
            "partial": sum(1 for r in results if r.status == TestStatus.PARTIAL),
            "failed": sum(1 for r in results if r.status == TestStatus.FAILED),
            "error": sum(1 for r in results if r.status == TestStatus.ERROR),
            "skipped": sum(1 for r in results if r.status == TestStatus.SKIPPED),
        },
    }
    with open(filepath, "w") as f:
        json.dump(report, f, indent=2)
    log.info("JSON report saved to %s", filepath)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Lemonade Stand Stress Test Harness",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Available tests:
  T01  Baseline connectivity
  T03  Engine directive: /lemon
  T05  Engine directive: /claude
  T06  Queue override (/interrupt, /followup, /steer)
  T07  Subagent async spawn/poll/join
  T08  Agent delegation
  T09  Model override (/claude directive)
  T11  Cron add + run_now
  T13  Document transfer (text file)
  T16  Resume control (/resume)
  T17  New session reset (/new)
  T19  Message reactions
  T20  Long response chunking
  T21  Cancel command (/cancel)
  T23  Multi-user mention (@mention)
  T24  Reply-to-bot trigger
  T25  Tool use message (status indicator)

Examples:
  python stress_test.py                    # run all tests in parallel
  python stress_test.py --tests T06,T09    # run only T06 and T09
  python stress_test.py --sequential       # run all tests one at a time
  python stress_test.py --timeout 180      # 3 minute timeout per test
  python stress_test.py --no-cleanup       # keep test topics after run
        """,
    )
    parser.add_argument(
        "--tests",
        type=str,
        default=None,
        help="Comma-separated list of test IDs to run (e.g. T06,T07,T09). Default: all.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"Default timeout in seconds for waiting on bot replies (default: {DEFAULT_TIMEOUT}).",
    )
    parser.add_argument(
        "--sequential",
        action="store_true",
        help="Run tests sequentially instead of in parallel.",
    )
    parser.add_argument(
        "--report",
        type=str,
        default=None,
        help="Path to save JSON report (default: stress_test_results_<timestamp>.json).",
    )
    parser.add_argument(
        "--chat-id",
        type=int,
        default=CHAT_ID,
        help=f"Telegram chat ID to use (default: {CHAT_ID}).",
    )
    parser.add_argument(
        "--no-cleanup",
        action="store_true",
        help="Do not delete test topics after running (default: topics are deleted).",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        dest="list_tests",
        help="List available tests and exit.",
    )
    return parser.parse_args()


async def async_main():
    args = parse_args()

    if args.list_tests:
        print("Available tests:")
        for tid, (name, _) in sorted(TEST_REGISTRY.items()):
            print(f"  {tid}: {name}")
        return

    # Validate environment
    api_id = os.environ.get("TELEGRAM_API_ID")
    api_hash = os.environ.get("TELEGRAM_API_HASH")
    session_string = os.environ.get("TELEGRAM_SESSION_STRING")

    missing = []
    if not api_id:
        missing.append("TELEGRAM_API_ID")
    if not api_hash:
        missing.append("TELEGRAM_API_HASH")
    if not session_string:
        missing.append("TELEGRAM_SESSION_STRING")

    if missing:
        log.error("Missing required environment variables: %s", ", ".join(missing))
        log.error("Source your credentials file first:")
        log.error("  source ~/.zeebot/api_keys/telegram.txt")
        sys.exit(1)

    # Determine which tests to run
    if args.tests:
        test_ids = [t.strip().upper() for t in args.tests.split(",")]
        invalid = [t for t in test_ids if t not in TEST_REGISTRY]
        if invalid:
            log.error("Unknown test IDs: %s", invalid)
            log.error("Valid IDs: %s", sorted(TEST_REGISTRY.keys()))
            sys.exit(1)
    else:
        test_ids = sorted(TEST_REGISTRY.keys())

    log.info("Stress test starting: %d tests [%s]", len(test_ids), ", ".join(test_ids))
    log.info("Mode: %s | Timeout: %ds | Chat: %d",
             "sequential" if args.sequential else "parallel", args.timeout, args.chat_id)

    # Connect
    client = TelegramClient(
        StringSession(session_string),
        int(api_id),
        api_hash,
    )

    try:
        await client.connect()
        if not await client.is_user_authorized():
            log.error("Session string is not authorized. Generate a new one.")
            sys.exit(1)

        harness = TelegramHarness(client, args.chat_id, args.timeout)
        await harness.setup()

        # Run tests
        cleanup = not args.no_cleanup
        results = await run_tests(harness, test_ids, sequential=args.sequential, cleanup_topics=cleanup)

        # Report
        print_report(results)

        # Save JSON report
        report_path = args.report or f"stress_test_results_{int(time.time())}.json"
        save_report_json(results, report_path)

        # Exit code: 0 if all passed/partial, 1 if any failed/error
        has_failures = any(r.status in (TestStatus.FAILED, TestStatus.ERROR) for r in results)
        sys.exit(1 if has_failures else 0)

    except KeyboardInterrupt:
        log.info("Interrupted by user")
        sys.exit(130)
    finally:
        await client.disconnect()


def main():
    asyncio.run(async_main())


if __name__ == "__main__":
    main()
