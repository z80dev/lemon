---
id: IDEA-20260227-openclaw-telegram-reply-media-context
title: [OpenClaw] Include Replied Media Metadata in Telegram Reply Context
source: openclaw
source_commit: aae90cb0364e
discovered: 2026-02-27
status: proposed
---

# Description
OpenClaw added Telegram reply-context enrichment so replies to media messages include the replied media file context, not just plain text/caption.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon captures `reply_to_text` from `reply_to_message.text || reply_to_message.caption`.
  - Current extraction path in `update_processor.ex` does not include replied media identifiers/types (photo/document/video/audio), so downstream prompts lose critical context for file-centric interactions.
  - This is especially relevant for workflows where users reply "edit this" or "summarize this" to media-only messages.

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M**
- Open questions:
  1. What canonical reply-media payload shape should Lemon expose (`reply_to_media` map, normalized attachment list, both)?
  2. Should media metadata include retrievable file IDs/URLs or only descriptive type/caption fields?
  3. How should this interact with channel capability negotiation and attachment tooling already planned?

# Recommendation
**investigate** — Meaningful UX/reliability gain for Telegram media workflows; coordinate with broader channel capability abstractions.
