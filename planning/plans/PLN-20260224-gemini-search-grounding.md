---
id: PLN-20260224-gemini-search-grounding
title: Add Gemini (Google Search grounding) as web_search provider
created: 2026-02-24
updated: 2026-02-24
owner: zeebot
reviewer: unassigned
workspace: feature/gemini-search-grounding
change_id: pending
status: in_progress
roadmap_ref: ROADMAP.md
depends_on: []
idea_ref: IDEA-20260224-openclaw-gemini-search-grounding
---

# Summary

Add Gemini as a third web search provider in `CodingAgent.Tools.WebSearch`, using Google's built-in Search grounding tool via the Gemini API. This gives agents access to real-time Google Search results with synthesized answers and citations.

## Scope

- In scope:
  - Add `"gemini"` provider to `websearch.ex` alongside Brave and Perplexity
  - Resolve Gemini's grounding redirect URLs to direct URLs via parallel HEAD requests (5s timeout, graceful fallback)
  - Strip API key from error messages for security
  - Support `GEMINI_API_KEY` and `GOOGLE_API_KEY` environment variables
  - Support `agent.tools.web.search.gemini.api_key` config key
  - Support gemini as a failover provider
  - Tests for all new behavior

- Out of scope:
  - Gemini model selection beyond default (`gemini-2.5-flash`)
  - Dynamic retrieval configuration
  - Streaming responses
  - Changes to Brave or Perplexity providers

## Implementation

### Provider Configuration

The Gemini provider follows the same pattern as Perplexity:

```elixir
# Config (settings_manager):
%{tools: %{web: %{search: %{
  provider: "gemini",
  gemini: %{
    api_key: "...",   # or nil to use env var
    model: "gemini-2.5-flash"  # default
  }
}}}}
```

Environment variable precedence:
1. `agent.tools.web.search.gemini.api_key` (config)
2. `GEMINI_API_KEY`
3. `GOOGLE_API_KEY`

### API Request

Uses Gemini's `generateContent` API with the `google_search` tool:

```
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}
{
  "contents": [{"parts": [{"text": "query"}], "role": "user"}],
  "tools": [{"google_search": {}}]
}
```

### Response Format

Output mirrors Perplexity's format (synthesized content + citations):

```json
{
  "query": "...",
  "provider": "gemini",
  "model": "gemini-2.5-flash",
  "took_ms": 1234,
  "content": "EXTERNAL_UNTRUSTED_CONTENT[...synthesized answer...]",
  "citations": ["https://resolved-url.example.com/..."],
  "trust_metadata": { "source": "web_search", ... }
}
```

### URL Resolution

Gemini grounding chunks contain redirect URLs. These are resolved to direct URLs via parallel `HEAD` requests with `Map.get(headers, "location")` extraction. Graceful fallback to original URL on any failure.

### Security

API key is stripped from error messages using `strip_api_key/2` before surfacing to callers.

## Files Modified

- `apps/coding_agent/lib/coding_agent/tools/websearch.ex` — Gemini provider implementation
- `apps/coding_agent/test/coding_agent/tools/websearch_test.exs` — 6 new tests

## Tests

| Test | Coverage |
|------|----------|
| `returns setup payload when Gemini key is missing` | Missing API key error |
| `runs Gemini search with grounding citations` | End-to-end success path |
| `resolves Gemini grounding redirect URLs via HEAD requests` | URL resolution |
| `falls back to original URL when Gemini HEAD request fails` | Graceful fallback |
| `strips API key from Gemini error messages` | Security |
| `fails over from Gemini to Brave when Gemini key is missing` | Failover |

## Test Results

```
19 tests, 0 failures
```

## Upstream Reference

- Idea: IDEA-20260224-openclaw-gemini-search-grounding
- OpenClaw PR: #13075 (commit 3a3c2da9168f93397eeb3109d521819e10dc44fd)
