---
layout: home

hero:
  name: Lemon
  text: Local-first AI agent runtime
  tagline: Durable sessions, memory, skills, supervised tools, provider routing, and native multi-agent execution for serious workflows.
  image:
    src: /diagrams/architecture.svg
    alt: Lemon architecture diagram
  actions:
    - theme: brand
      text: Quickstart
      link: /getting-started/quickstart
    - theme: alt
      text: See Demo
      link: /demo
    - theme: alt
      text: Compare
      link: /compare

features:
  - title: Run agents where your work lives
    details: Start native Lemon sessions from a repository, select providers and models, delegate to in-process subagents or named execution nodes, and keep local control of files, tools, and secrets.
  - title: Keep useful context
    details: Persist sessions, search memory, promote reusable skills, and carry project conventions forward without handing everything to a hosted assistant.
  - title: Reach it from real interfaces
    details: Use the terminal UI, web UI, Telegram, or other channel adapters while the supervised BEAM runtime manages runs, queues, events, and recovery.
  - title: Operate it like software
    details: Package release profiles, health checks, doctor diagnostics, support bundles, telemetry, and quality gates make Lemon debuggable after first setup.
---

## What Lemon Is

Lemon is a self-hosted AI assistant platform for developers and technical
operators. It combines a supervised BEAM runtime, coding-agent tools, memory,
skills, provider abstraction, channel adapters, and a JSON-RPC control plane into
one local-first system.

The 1.0 launch goal is mainstream readiness: installability, supportability,
clear docs, stable packaging, credible Hermes-class harness behavior, and enough
interface polish for non-contributors to use Lemon without repo expertise.

## Start Here

| Need | Page |
| --- | --- |
| Install, verify a real chat, and resume it | [Lemon Quickstart](getting-started/quickstart.md) |
| Build an agent on the platform | [Build Your First Agent](getting-started/build-your-first-agent.md) |
| Install and start a first chat | [Install Lemon](install.md) |
| Run a deterministic local demo | [Demo Lemon](demo.md) |
| Compare Lemon to adjacent tools | [Compare Lemon](compare.md) |
| Configure providers, secrets, and Telegram | [Setup Guide](user-guide/setup.md) |
| Chat in the local browser | [Use Lemon in a Browser](user-guide/web.md) |
| Understand why Lemon runs on the BEAM | [Agents Are a Concurrency Problem](why-beam-for-agents.md) |
| Understand the runtime architecture | [Architecture Overview](architecture/overview.md) |
| Review supported behavior and product boundaries | [Compare Lemon](compare.md) |
| Prepare and validate a release | [Release Checklist](release/release_checklist_and_support_policy.md) |
| Configure LSP diagnostics | [LSP Diagnostics](tools/lsp.md) |
| Generate and inspect media artifacts | [Media Tools](tools/media.md) |
| Use OpenAI-compatible HTTP clients | [OpenAI-Compatible API Preview](tools/openai-compatible-api.md) |
| Try ACP-shaped editor/client integration | [ACP Preview](tools/acp.md) |
| Debug a local install | [Support](support.md) |
| Give an agent the docs index | [Machine-readable docs](https://z80dev.github.io/lemon/llms.txt) |

## Current Launch Stage

Lemon is still pre-1.0. Verified release artifacts and a one-line installer now
exist for the documented macOS and Linux targets. Platform breadth, packaged CLI
coverage, management Web UI, native desktop/profile UX, session lifecycle, and
install/update/backup behavior are documented in the task guides linked above.
