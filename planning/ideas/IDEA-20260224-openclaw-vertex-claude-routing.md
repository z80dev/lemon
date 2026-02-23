---
id: IDEA-20260224-openclaw-vertex-claude-routing
title: Allow Claude model requests to route through Google Vertex AI
source: openclaw
source_commit: eb4ff6df8
discovered: 2026-02-24
status: proposed
---

# Description

OpenClaw added support for routing Claude model requests through Google Vertex AI (GCP). This provides an alternative way to access Claude models via Google's infrastructure.

Key features:
- New `anthropic-vertex` provider for Claude via GCP Vertex AI
- Requires GCP project configuration
- Provides enterprise-grade access to Claude through Google's infrastructure
- Includes documentation and validation for Anthropic Vertex project env

# Lemon Status

- Current state: Lemon has `:google_vertex` provider listed in supported providers
- Gap: Unclear if Claude routing through Vertex is implemented
- Location: `apps/ai/lib/ai/providers/`

# Investigation Notes

- Complexity estimate: M
- Value estimate: M
- Open questions:
  - Does Lemon's existing `:google_vertex` provider support Claude models?
  - What's the difference between `:google_vertex` and this new routing?
  - Are there specific model definitions needed for Claude-on-Vertex?

# Recommendation

**investigating** - Need to understand current Vertex AI implementation in Lemon before proceeding. Could be a documentation gap rather than a feature gap.

# References

- OpenClaw PR: #23985
- Commit: eb4ff6df8165320d88c6a45747c5a780c9646990
