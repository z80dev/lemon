---
id: IDEA-20260224-openclaw-gemini-search-grounding
title: Add Gemini (Google Search grounding) as web_search provider
source: openclaw
source_commit: 3a3c2da91
discovered: 2026-02-24
status: proposed
---

# Description

OpenClaw added Gemini as a fourth web search provider alongside Brave, Perplexity, and Grok. Uses Gemini's built-in Google Search grounding tool to return search results with citations.

Key features:
- Uses Gemini's Google Search grounding via tools API
- Resolves Gemini's grounding redirect URLs to direct URLs via parallel HEAD requests (5s timeout, graceful fallback)
- Default model: gemini-2.5-flash (fast, cheap, grounding-capable)
- Strips API key from error messages for security

# Lemon Status

- Current state: Lemon has web search with Brave and Perplexity providers
- Gap: No Gemini/Google Search grounding support
- Location: `apps/coding_agent/lib/coding_agent/tools/websearch.ex`

# Investigation Notes

- Complexity estimate: M
- Value estimate: H
- Open questions:
  - Does Lemon have Gemini API integration already?
  - How should grounding citations be formatted in results?
  - Should this be a new provider or extend existing websearch tool?

# Recommendation

**proceed** - High value addition as a third web search provider option. Would give users more choice and potentially better search quality for certain queries.

# References

- OpenClaw PR: #13075
- Commit: 3a3c2da9168f93397eeb3109d521819e10dc44fd
