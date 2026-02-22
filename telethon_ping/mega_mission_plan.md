# Mega Mission Plan — Lemon Stress Test & Feature Validation

Generated: 2026-02-22

## Overview

Launch 20+ parallel missions against the running Lemon gateway via Telegram forum topics.
Each mission is a real conversation that exercises a different capability.
Goals: stress the scheduler, validate all engines, test creative & practical features,
verify XMTP, and push Lemon to its limits.

---

## Mission Categories

### A. Codebase Improvement (ask Lemon to improve itself)

| ID   | Mission | Prompt Summary | Engine |
|------|---------|----------------|--------|
| M01  | Write tests for market_intel | "Write comprehensive ExUnit tests for the MarketIntel app" | lemon |
| M02  | Add typespecs to agent_core | "Add @spec annotations to all public functions in agent_core" | codex |
| M03  | Document the tool system | "Write detailed docs for how tools work in coding_agent" | lemon |
| M04  | Improve error handling in scheduler | "Review and improve error handling in LemonGateway.Scheduler" | lemon |

### B. Creative Content (Zeebot persona)

| ID   | Mission | Prompt Summary | Engine |
|------|---------|----------------|--------|
| M05  | Blog post: What is Lemon? | "Write a blog post as zeebot explaining what Lemon is" | lemon |
| M06  | Blog post: Building in public | "Write about the journey of building Lemon, from zeebot's POV" | lemon |
| M07  | Lore: Origin story | "Write the origin story of zeebot — how did you come to be?" | lemon |
| M08  | Lore: The Lemonade Stand | "Write lore about the Lemonade Stand — the secret forum" | lemon |

### C. Games

| ID   | Mission | Prompt Summary | Engine |
|------|---------|----------------|--------|
| M09  | Build snake game | "Build a browser-playable snake game in a single HTML file" | lemon |
| M10  | Build trivia game | "Build a CLI trivia game about crypto and AI in Python" | codex |
| M11  | Build text adventure | "Build a text adventure game set in a lemon grove" | lemon |

### D. Viral Video Pipeline (ClipForge)

| ID   | Mission | Prompt Summary | Engine |
|------|---------|----------------|--------|
| M12  | ClipForge: AI compilation | "Run the clipforge pipeline on an AI-related YouTube video" | lemon |
| M13  | ClipForge: Crypto moments | "Run clipforge on a crypto/trading moments video" | lemon |
| M14  | ClipForge: Comedy clips | "Run clipforge on a standup comedy special clip" | lemon |

### E. Profit & Data Pipelines

| ID   | Mission | Prompt Summary | Engine |
|------|---------|----------------|--------|
| M15  | Polymarket scanner | "Build a Polymarket event scanner that finds high-probability arb opportunities" | lemon |
| M16  | Trading signal pipeline | "Build a data pipeline that ingests DEXScreener data and generates trading signals" | lemon |
| M17  | Crypto sentiment tracker | "Build a Twitter/X sentiment tracker for crypto tokens" | lemon |
| M18  | Revenue ideas doc | "Research and write up 10 realistic ways to monetize an AI agent like Lemon" | lemon |

### F. Infrastructure & Protocol Testing

| ID   | Mission | Prompt Summary | Engine |
|------|---------|----------------|--------|
| M19  | XMTP smoke test | Send a message via XMTP and verify round-trip | xmtp |
| M20  | Multi-engine stress | Send same prompt to lemon, codex, claude engines simultaneously | mixed |
| M21  | Cron pipeline | Set up a cron job that posts market commentary every hour | lemon |
| M22  | Long context test | Send a very long message (4000+ chars) and verify handling | lemon |

### G. Data Ingestion & Analysis

| ID   | Mission | Prompt Summary | Engine |
|------|---------|----------------|--------|
| M23  | RSS feed ingester | "Build an RSS feed ingestion pipeline for crypto news" | lemon |
| M24  | GitHub trending scanner | "Build a script that scans GitHub trending repos and summarizes them" | lemon |
| M25  | On-chain data pipeline | "Build a pipeline to ingest Base network on-chain data for analysis" | lemon |

---

## Execution Strategy

1. Create one Telegram forum topic per mission in the Lemonade Stand group
2. Send the prompt to each topic
3. Wait for Lemon to respond (timeout: 10 min for code tasks, 5 min for content)
4. Collect all responses
5. Grade: PASS if substantive response received, PARTIAL if response but incomplete, FAIL if no response or error

## Success Criteria

- 80%+ missions get substantive responses
- No gateway crashes
- Scheduler handles 12+ concurrent runs
- At least one ClipForge run produces output
- XMTP round-trip works
- Multiple engines exercised successfully
