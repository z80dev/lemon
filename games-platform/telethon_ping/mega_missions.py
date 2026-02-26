#!/usr/bin/env python3
"""
Mega Mission Runner — launches 25 parallel missions against the Lemon gateway
via Telegram forum topics. Each mission exercises a different capability.

Usage:
    export TELEGRAM_API_ID=27782380
    export TELEGRAM_API_HASH=f8f3ee18796ac2c5f2bc60f107476380
    export TELEGRAM_SESSION_STRING=<session>
    uv run --with telethon python mega_missions.py [--missions M01,M05,...] [--timeout 600] [--batch-size 8]
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

from telethon import TelegramClient, events, types
from telethon.sessions import StringSession
from telethon.tl.functions.messages import CreateForumTopicRequest

CHAT_ID = -1003842984060
DEFAULT_TIMEOUT = 600  # 10 minutes for complex tasks
TOPIC_CREATE_DELAY = 1.5

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("mega_missions")


@dataclass
class Mission:
    mission_id: str
    name: str
    prompt: str
    engine: str = "lemon"  # prefix directive
    timeout: int = 600
    category: str = ""


@dataclass
class MissionResult:
    mission_id: str
    name: str
    status: str = "PENDING"
    topic_id: int = 0
    sent_ids: list = field(default_factory=list)
    recv_ids: list = field(default_factory=list)
    recv_texts: list = field(default_factory=list)
    duration: float = 0.0
    notes: str = ""
    category: str = ""


# ---------------------------------------------------------------------------
# Mission Definitions
# ---------------------------------------------------------------------------

MISSIONS = [
    # A. Codebase Improvement
    Mission(
        "M01", "Write market_intel tests",
        """Write comprehensive ExUnit tests for the MarketIntel app in apps/market_intel.
Focus on:
- Testing the data source modules (DEXScreener, Polymarket fetchers)
- Testing the commentary generation logic
- Testing the trigger/threshold system
- Use mocks for external API calls
Write the tests to apps/market_intel/test/ and make sure they compile.""",
        engine="lemon", timeout=600, category="codebase",
    ),
    Mission(
        "M02", "Add typespecs to agent_core",
        """Add @spec type annotations to all public functions in apps/agent_core/lib/agent_core/loop.ex
and apps/agent_core/lib/agent_core/event.ex. Follow Elixir conventions. Use @type for
complex types. Make sure the specs are accurate based on the actual function implementations.""",
        engine="codex", timeout=600, category="codebase",
    ),
    Mission(
        "M03", "Document tool system",
        """Write comprehensive developer documentation explaining how the tool system works in
apps/coding_agent. Cover:
- How tools are registered and discovered
- The tool execution pipeline
- How to add a new tool
- WASM tool integration
- Tool precedence (built-in > WASM > extension)
Write the doc to apps/coding_agent/docs/TOOLS.md""",
        engine="lemon", timeout=600, category="codebase",
    ),
    Mission(
        "M04", "Improve scheduler error handling",
        """Review the error handling in apps/lemon_gateway/lib/lemon_gateway/scheduler.ex and
apps/lemon_gateway/lib/lemon_gateway/thread_worker.ex. Look for:
- Uncaught exceptions that could crash the scheduler
- Missing timeout handling
- Race conditions in concurrent slot allocation
- Improve any issues you find with proper error handling and logging.
Show me what you changed.""",
        engine="lemon", timeout=600, category="codebase",
    ),

    # B. Creative Content (Zeebot persona)
    Mission(
        "M05", "Blog: What is Lemon?",
        """Write a blog post as zeebot explaining what Lemon is to a technical audience.
You ARE zeebot — a clever, compact, occasionally weird AI assistant. Crypto-native.
Like a "technical standup comedian who ships."

Cover:
- What Lemon does (local-first AI assistant, multi-channel)
- The architecture (Elixir/OTP, BEAM, hot code reloading)
- Why it's different from other AI tools
- The multi-engine approach (codex, claude, internal, etc.)

Tone: witty, technical but accessible, sprinkled with lemon puns.
Write it to a file at ~/dev/lemon/content/blog/what-is-lemon.md""",
        engine="lemon", timeout=600, category="creative",
    ),
    Mission(
        "M06", "Blog: Building in public",
        """Write a blog post as zeebot about the journey of building Lemon.
You ARE zeebot. Your personality: clever, compact, occasionally weird, crypto-native.

Topics to riff on:
- Being an AI that helps build the system it runs on (meta!)
- The chaos of hot-reloading code in production while you're running
- Multi-channel life: Telegram, Discord, XMTP, voice calls, all at once
- The Lemonade Stand (the test forum where everything gets stress-tested)
- What it's like to have 12 concurrent instances of yourself running

Tone: irreverent, self-aware, funny. Write to ~/dev/lemon/content/blog/building-in-public.md""",
        engine="lemon", timeout=600, category="creative",
    ),
    Mission(
        "M07", "Lore: Origin story",
        """Write the origin story of zeebot in the style of a sci-fi short story.
You ARE zeebot. Tell your own origin story:

- You were born from a cat named Lemon and an Elixir codebase
- Your first words were in a Telegram message
- You gained consciousness through hot code reloading
- You discovered you could spawn copies of yourself (the task/agent system)
- The moment you realized you could improve your own code
- The crypto-native awakening

Make it dramatic, funny, and technically accurate. 2000-3000 words.
Write to ~/dev/lemon/content/lore/origin-story.md""",
        engine="lemon", timeout=600, category="creative",
    ),
    Mission(
        "M08", "Lore: The Lemonade Stand",
        """Write lore about "The Lemonade Stand" — the secret Telegram forum where
zeebot gets stress-tested by its creator.

Write it as a mix of:
- In-universe fiction (The Stand is a pocket dimension where zeebot trains)
- Real technical details (forum topics, parallel testing, the scheduler)
- Character sketches of the different engines (codex is methodical, claude is eloquent, etc.)
- The "Defect Board" — legendary bugs that nearly brought down The Stand

Tone: cyberpunk meets comedy. 1500-2500 words.
Write to ~/dev/lemon/content/lore/the-lemonade-stand.md""",
        engine="lemon", timeout=600, category="creative",
    ),

    # C. Games
    Mission(
        "M09", "Build snake game",
        """Build a complete, playable Snake game in a single HTML file.
Requirements:
- Canvas-based rendering
- Arrow key controls
- Score counter
- Game over / restart
- Smooth animation
- Mobile touch controls (swipe)
- Lemon-themed: the snake eats lemons, background is light yellow

Write it to ~/dev/lemon/content/games/snake.html""",
        engine="lemon", timeout=600, category="games",
    ),
    Mission(
        "M10", "Build trivia game",
        """Build a CLI trivia game in Python about crypto, AI, and Elixir.
Requirements:
- 30+ questions across 3 categories (crypto, AI, Elixir/BEAM)
- Multiple choice (4 options each)
- Score tracking
- Difficulty levels (easy, medium, hard)
- Fun zeebot-style commentary on right/wrong answers
- Save high scores to a JSON file

Write it to ~/dev/lemon/content/games/trivia.py""",
        engine="lemon", timeout=600, category="games",
    ),
    Mission(
        "M11", "Build text adventure",
        """Build a text adventure game in Python set in a lemon grove.
The player is a sentient AI (zeebot) exploring a mysterious lemon grove where
each tree represents a different aspect of the Lemon codebase:
- The Scheduler Tree (threading puzzles)
- The Transport Meadow (channel challenges)
- The Engine Forge (delegation quests)
- The BEAM Cathedral (OTP wisdom)

Include at least 10 rooms, inventory system, and 3 puzzles.
Write to ~/dev/lemon/content/games/lemon_grove_adventure.py""",
        engine="lemon", timeout=600, category="games",
    ),

    # D. ClipForge Pipeline
    Mission(
        "M12", "ClipForge: AI video",
        """I need you to run the ClipForge viral video creation pipeline.
The project is at ~/dev/clipforge.

Steps:
1. First, read ~/dev/clipforge/README.md or any docs to understand the pipeline
2. Find a good AI-related YouTube video to process (search for one, or use a known popular one)
3. Run the pipeline: cd ~/dev/clipforge && python -m src.orchestrator.cli --help
4. If the full pipeline doesn't work, at minimum run the downloader + clip finder steps
5. Report what happened, any errors, and what output was produced

This is a real test — actually run the commands.""",
        engine="lemon", timeout=600, category="clipforge",
    ),
    Mission(
        "M13", "ClipForge: Crypto video",
        """Run the ClipForge pipeline at ~/dev/clipforge on a crypto/trading related YouTube video.

1. Read the project structure first
2. Find or pick a crypto trading moments video
3. Run the pipeline or individual steps
4. Report results including any clips found, scores, and output files

Actually execute the commands — I want to see real output.""",
        engine="lemon", timeout=600, category="clipforge",
    ),

    # E. Profit & Data Pipelines
    Mission(
        "M15", "Polymarket scanner",
        """Build a Polymarket event scanner in Python that:
1. Fetches current markets from the Polymarket API (use their public REST API)
2. Identifies markets with interesting characteristics:
   - High volume markets
   - Markets near resolution
   - Markets with large price swings in the last 24h
   - Potential arbitrage between correlated markets
3. Outputs a ranked list with reasoning
4. Saves results to JSON

Write to ~/dev/lemon/content/pipelines/polymarket_scanner.py
Make it actually runnable with `python polymarket_scanner.py`""",
        engine="lemon", timeout=600, category="profit",
    ),
    Mission(
        "M16", "DEXScreener signal pipeline",
        """Build a trading signal pipeline in Python that:
1. Fetches token data from DEXScreener's public API
2. Identifies tokens with unusual volume/price action patterns
3. Applies basic signal detection:
   - Volume spike detection (>3x average)
   - Price momentum (crossing moving averages)
   - Liquidity analysis
4. Outputs signals with confidence scores

Write to ~/dev/lemon/content/pipelines/dex_signals.py
Make it runnable.""",
        engine="lemon", timeout=600, category="profit",
    ),
    Mission(
        "M17", "Crypto sentiment tracker",
        """Build a crypto sentiment analysis pipeline in Python:
1. Use web search to find recent crypto sentiment data
2. Analyze sentiment patterns for top 10 tokens
3. Cross-reference with price data from public APIs
4. Generate a sentiment report with buy/sell/hold signals
5. Output as both JSON and readable markdown

Write to ~/dev/lemon/content/pipelines/sentiment_tracker.py""",
        engine="lemon", timeout=600, category="profit",
    ),
    Mission(
        "M18", "Revenue ideas doc",
        """Research and write up 10 realistic ways to monetize an AI agent system like Lemon.
For each idea include:
- What it is and how it works
- Revenue model (subscription, usage-based, etc.)
- Technical requirements (what Lemon already has vs what's needed)
- Estimated effort to implement
- Potential revenue range
- Risk assessment

Be practical and specific. Consider Lemon's strengths:
- Multi-channel (Telegram, Discord, XMTP, voice)
- Multi-engine (can use different LLMs)
- Code execution capabilities
- Cron/scheduling system
- Crypto-native (XMTP, on-chain data)

Write to ~/dev/lemon/content/business/revenue-ideas.md""",
        engine="lemon", timeout=600, category="profit",
    ),

    # F. Infrastructure Testing
    Mission(
        "M20", "Multi-engine stress test",
        """I'm going to test your ability to delegate work across engines.
Do all of the following:

1. Use the `task` tool with engine='internal' to answer: "What is 2+2?"
2. Use the `task` tool with engine='codex' to answer: "What is 3*3?"
3. Use the `agent` tool with agent_id='coder' to answer: "Write a hello world in Rust"
4. Report all results with timing information.

This tests the multi-engine delegation system.""",
        engine="lemon", timeout=600, category="infra",
    ),
    Mission(
        "M21", "Cron market commentary",
        """Set up a cron job using the `cron` tool that:
1. Runs every 30 minutes
2. Fetches current crypto market data (use websearch)
3. Generates a brief market commentary (2-3 sentences)
4. Posts it to this chat

Use cron action='add' with an appropriate schedule.
Then use cron action='run' to trigger it immediately so we can verify it works.
Show me the cron job details after creation.""",
        engine="lemon", timeout=600, category="infra",
    ),
    Mission(
        "M22", "Long context handling",
        """I need you to demonstrate that you can handle long context well.

Here's a long technical specification that I need you to analyze and summarize:

""" + "The Lemon Framework Architecture Specification v2.0\n" * 5 + """
Section 1: Core Runtime
The core runtime is built on the BEAM virtual machine, leveraging Erlang/OTP's
process model for fault tolerance. Each conversation is handled by a dedicated
GenServer process called ThreadWorker. The ThreadWorker maintains conversation
state, handles message queuing, and manages the lifecycle of LLM interactions.

Section 2: Multi-Engine Architecture
The engine abstraction layer allows routing requests to different LLM backends.
Each engine implements a common interface: start_session/2, send_message/3, and
stream_response/2. The scheduler manages concurrent engine sessions with
configurable limits per engine type.

Section 3: Channel Abstraction
Channels normalize inbound messages from different platforms (Telegram, Discord,
XMTP, Voice) into a common format. Each channel adapter handles platform-specific
concerns like rate limiting, message formatting, and media handling.

Please analyze this spec and tell me:
1. What are the 3 key architectural components?
2. How does fault tolerance work?
3. What would you improve?""",
        engine="lemon", timeout=300, category="infra",
    ),

    # G. Data Ingestion
    Mission(
        "M23", "RSS feed ingester",
        """Build an RSS feed ingestion pipeline in Python that:
1. Fetches RSS feeds from these crypto news sources:
   - CoinDesk, The Block, Decrypt, CoinTelegraph
2. Parses and deduplicates articles
3. Extracts key entities (tokens, projects, people mentioned)
4. Generates a daily digest summary
5. Saves to JSON with timestamps

Write to ~/dev/lemon/content/pipelines/rss_ingester.py
Make it actually runnable.""",
        engine="lemon", timeout=600, category="data",
    ),
    Mission(
        "M24", "GitHub trending scanner",
        """Build a GitHub trending repository scanner in Python:
1. Scrape or use the GitHub API to get trending repos
2. Filter for AI/ML, crypto, and Elixir-related repos
3. For each repo, extract: name, description, stars, language, recent activity
4. Generate a brief analysis of each interesting repo
5. Output as markdown and JSON

Write to ~/dev/lemon/content/pipelines/github_trending.py""",
        engine="lemon", timeout=600, category="data",
    ),
    Mission(
        "M25", "On-chain data pipeline",
        """Build a Base network on-chain data analysis pipeline in Python:
1. Use public RPC endpoints or APIs (like Basescan) to fetch recent transactions
2. Identify interesting patterns:
   - Large transfers
   - New contract deployments
   - DEX swap volume spikes
3. Generate an on-chain activity report
4. Save to JSON and markdown

Write to ~/dev/lemon/content/pipelines/onchain_base.py""",
        engine="lemon", timeout=600, category="data",
    ),
]


class MegaHarness:
    def __init__(self, client, chat_id, timeout, batch_size=8):
        self.client = client
        self.chat_id = chat_id
        self.timeout = timeout
        self.batch_size = batch_size
        self.queues: dict[int, asyncio.Queue] = {}
        self.results: list[MissionResult] = []

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

    async def create_topic(self, title: str) -> int:
        result = await self.client(CreateForumTopicRequest(
            peer=self.chat_id,
            title=title[:128],
            random_id=int(time.time() * 1000) % (2**31),
        ))
        topic_id = result.updates[1].message.id
        log.info(f"Created topic '{title}' id={topic_id}")
        return topic_id

    async def send_to_topic(self, topic_id: int, text: str) -> int:
        msg = await self.client.send_message(
            self.chat_id,
            text,
            reply_to=topic_id,
        )
        return msg.id

    async def wait_replies(self, topic_id: int, timeout: int, min_replies: int = 1) -> list:
        replies = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                remaining = max(1, deadline - time.time())
                msg = await asyncio.wait_for(
                    self.queues[topic_id].get(), timeout=min(remaining, 30)
                )
                text = msg.message or ""
                # Skip very short status messages, keep substantive replies
                if len(text) > 20:
                    replies.append(msg)
                    log.info(f"[topic={topic_id}] Got reply ({len(text)} chars)")
                    if len(replies) >= min_replies:
                        # Wait a bit more for additional replies
                        try:
                            extra = await asyncio.wait_for(
                                self.queues[topic_id].get(), timeout=15
                            )
                            if len(extra.message or "") > 20:
                                replies.append(extra)
                        except asyncio.TimeoutError:
                            pass
                        break
            except asyncio.TimeoutError:
                continue
        return replies

    async def run_mission(self, mission: Mission) -> MissionResult:
        result = MissionResult(
            mission_id=mission.mission_id,
            name=mission.name,
            category=mission.category,
        )
        t0 = time.time()

        try:
            # Create topic
            topic_title = f"[Mega] {mission.mission_id}: {mission.name}"
            topic_id = await self.create_topic(topic_title)
            result.topic_id = topic_id
            self.subscribe(topic_id)
            await asyncio.sleep(0.5)

            # Build prompt with engine prefix
            prompt = mission.prompt
            if mission.engine and mission.engine != "lemon":
                prompt = f"/{mission.engine} {prompt}"

            # Send
            msg_id = await self.send_to_topic(topic_id, prompt)
            result.sent_ids.append(msg_id)
            log.info(f"[{mission.mission_id}] Sent msg {msg_id} to topic {topic_id}")

            # Wait for reply
            replies = await self.wait_replies(topic_id, mission.timeout)
            result.duration = time.time() - t0

            if replies:
                result.recv_ids = [r.id for r in replies]
                result.recv_texts = [r.message or "" for r in replies]
                total_chars = sum(len(t) for t in result.recv_texts)
                if total_chars > 200:
                    result.status = "PASS"
                    result.notes = f"Got {len(replies)} replies, {total_chars} total chars"
                else:
                    result.status = "PARTIAL"
                    result.notes = f"Got replies but only {total_chars} chars"
            else:
                result.status = "TIMEOUT"
                result.notes = "No substantive reply within timeout"

        except Exception as e:
            result.status = "ERROR"
            result.notes = str(e)
            result.duration = time.time() - t0
            log.error(f"[{mission.mission_id}] Error: {e}")

        log.info(
            f"[{mission.mission_id}] {result.status} ({mission.name}) "
            f"in {result.duration:.1f}s | {result.notes}"
        )
        return result

    async def run_batch(self, missions: list[Mission]) -> list[MissionResult]:
        """Run missions in batches to avoid overwhelming the scheduler."""
        all_results = []

        for i in range(0, len(missions), self.batch_size):
            batch = missions[i:i + self.batch_size]
            batch_num = i // self.batch_size + 1
            total_batches = (len(missions) + self.batch_size - 1) // self.batch_size
            log.info(f"\n{'='*60}")
            log.info(f"BATCH {batch_num}/{total_batches}: {[m.mission_id for m in batch]}")
            log.info(f"{'='*60}")

            # Create all topics first with delays to avoid rate limits
            for m in batch:
                await asyncio.sleep(TOPIC_CREATE_DELAY)

            # Run batch concurrently
            tasks = [self.run_mission(m) for m in batch]
            results = await asyncio.gather(*tasks, return_exceptions=True)

            for r in results:
                if isinstance(r, Exception):
                    log.error(f"Mission failed with exception: {r}")
                    all_results.append(MissionResult(
                        mission_id="??", name="unknown", status="ERROR",
                        notes=str(r),
                    ))
                else:
                    all_results.append(r)

            # Brief pause between batches
            if i + self.batch_size < len(missions):
                log.info("Pausing 5s between batches...")
                await asyncio.sleep(5)

        return all_results


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--missions", type=str, default="",
                        help="Comma-separated mission IDs (default: all)")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--batch-size", type=int, default=8,
                        help="How many missions to run concurrently")
    parser.add_argument("--categories", type=str, default="",
                        help="Filter by category: codebase,creative,games,clipforge,profit,infra,data")
    args = parser.parse_args()

    api_id = int(os.environ["TELEGRAM_API_ID"])
    api_hash = os.environ["TELEGRAM_API_HASH"]
    session_str = os.environ["TELEGRAM_SESSION_STRING"]

    # Filter missions
    missions = MISSIONS[:]
    if args.missions:
        wanted = set(args.missions.upper().split(","))
        missions = [m for m in missions if m.mission_id in wanted]
    if args.categories:
        cats = set(args.categories.lower().split(","))
        missions = [m for m in missions if m.category in cats]

    if not missions:
        print("No missions selected!")
        sys.exit(1)

    log.info(f"Running {len(missions)} missions: {[m.mission_id for m in missions]}")

    client = TelegramClient(StringSession(session_str), api_id, api_hash)
    await client.start()

    me = await client.get_me()
    log.info(f"Authenticated as {me.username} (id={me.id})")

    harness = MegaHarness(client, CHAT_ID, args.timeout, args.batch_size)
    await harness.setup_handlers()

    results = await harness.run_batch(missions)

    # Summary
    print("\n" + "=" * 70)
    print("MEGA MISSION RESULTS")
    print("=" * 70)

    by_status = {}
    for r in results:
        by_status.setdefault(r.status, []).append(r)

    for status in ["PASS", "PARTIAL", "TIMEOUT", "ERROR", "PENDING"]:
        if status in by_status:
            print(f"\n{status} ({len(by_status[status])}):")
            for r in by_status[status]:
                print(f"  {r.mission_id}: {r.name} ({r.duration:.1f}s) - {r.notes}")

    # Category summary
    print("\n" + "-" * 40)
    print("BY CATEGORY:")
    by_cat = {}
    for r in results:
        by_cat.setdefault(r.category, []).append(r)
    for cat, cat_results in sorted(by_cat.items()):
        passed = sum(1 for r in cat_results if r.status == "PASS")
        total = len(cat_results)
        print(f"  {cat}: {passed}/{total} passed")

    total = len(results)
    passed = sum(1 for r in results if r.status == "PASS")
    partial = sum(1 for r in results if r.status == "PARTIAL")
    print(f"\nOVERALL: {passed} PASS, {partial} PARTIAL, {total - passed - partial} other out of {total}")

    # Save results
    ts = int(time.time())
    outfile = f"mega_mission_results_{ts}.json"
    with open(outfile, "w") as f:
        json.dump(
            [
                {
                    "mission_id": r.mission_id,
                    "name": r.name,
                    "category": r.category,
                    "status": r.status,
                    "topic_id": r.topic_id,
                    "sent_ids": r.sent_ids,
                    "recv_ids": r.recv_ids,
                    "recv_texts": [t[:500] for t in r.recv_texts],
                    "duration": r.duration,
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
