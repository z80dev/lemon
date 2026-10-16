---
layout: page
sidebar: false
aside: false
title: Your agents. Your machine. Your move.
description: Lemon is an open-source, local-first AI assistant platform. Work across terminal, browser, and chat with durable sessions, memory, and native multi-agent execution.
---

<LemonHome />

<div class="home-docs-index">

## What is Lemon?

Lemon is an open-source, local-first AI assistant platform for developers and
technical operators. A supervised Elixir / OTP runtime connects durable
sessions, memory, skills, tools, provider routing, and native multi-agent
execution. Use it from the terminal, the browser, or a chat channel such as
Telegram or Discord. LemonSim adds deterministic, replay-verified simulation
worlds for evaluating agents. Lemon is pre-1.0; see
[capabilities and boundaries](compare.md) for what is supported today.

## Install

Prebuilt releases target macOS Apple Silicon, Linux x86_64, and Linux ARM64.
The installer needs `curl`, `tar`, and `python3`, installs under `~/.lemon`,
and opens the setup wizard to configure a provider:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
$HOME/.lemon/bin/lemon
```

Source checkouts, non-interactive installs, channels, and updates are covered in
[Install](install.md); the [Quickstart](getting-started/quickstart.md) walks
through a first provider-backed chat.

## Find your way around

- **[Getting started](getting-started/quickstart.md)**: [Quickstart](getting-started/quickstart.md), [install](install.md), [provider setup](user-guide/setup.md), [demo](demo.md), [updates](user-guide/updates.md), [support](support.md)
- **[User guides](user-guide/web.md)**: [Browser](user-guide/web.md), [profiles](user-guide/profiles.md), [memory](user-guide/memory.md), [skills](user-guide/skills.md), [reminders](user-guide/reminders-and-heartbeats.md), [backups](user-guide/backups.md), [built-in tools](tools/files-and-search.md), [safety](security/safety.md)
- **[Configuration & CLI reference](config.md)**: [Configuration](config.md), [registry](config-registry.md), [CLI & sessions](user-guide/cli.md), [TUI slash commands](user-guide/tui-commands.md), [control-plane methods](reference/control-plane.md), [skill manifest](reference/skill-manifest-v2.md)
- **[Integrations & channels](getting-started/add-a-channel.md)**: [Channels](getting-started/add-a-channel.md), [gateway](platform/lemon_gateway.md), [OpenAI-compatible API](tools/openai-compatible-api.md), [ACP](tools/acp.md), [MCP and extensions](extensions.md), [omp](user-guide/omp.md), [A2A peers](user-guide/a2a-peers.md)
- **[Developers & contributors](architecture/overview.md)**: [Architecture](architecture/overview.md), [first agent](getting-started/build-your-first-agent.md), [testing](testing.md), [contributing](contributor/public_repo_basics.md), [releases and packages](platform-split.md)
- **[LemonSim & benchmarks](benchmarks/quickstart.md)**: [Benchmark quickstart](benchmarks/quickstart.md), [platform guarantees](benchmarks/platform.md), [VendingBench](benchmarks/vending-bench.md), [run your model](benchmarks/run-your-model.md)

The [documentation index](README.md) lists every page by task. Coming from
Hermes? See [Migrate from Hermes](user-guide/migrate-from-hermes.md).

</div>
