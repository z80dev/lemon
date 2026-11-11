---
layout: page
sidebar: false
aside: false
title: Your agents. Your machine. Your move.
description: Lemon is an open-source, local-first AI assistant platform. Work across terminal, browser, and chat with durable sessions, memory, and native multi-agent execution.
---

<LemonHome />

<div class="home-docs-index vp-doc">

## What is Lemon?

Lemon is an open-source, local-first AI assistant platform for developers and
technical operators. A supervised Elixir / OTP runtime connects durable
sessions, memory, skills, tools, provider routing, and native multi-agent
execution. Use it from the terminal, the browser, or a chat channel such as
Telegram or Discord. LemonSim adds deterministic, replay-verified simulation
worlds for evaluating agents. Lemon is pre-1.0; see
[capabilities and boundaries](compare.md) for what is supported today.

## Start with Lemon Bot

[Set up Lemon Bot](getting-started/lemon-bot.md) to create a Bot in your browser,
connect a model, and try a task on your own machine. Standard access asks before
commands run; Chat only leaves local tools off.

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --profile bot
```

The installer sets up the runtime, terminal UI and Bot backend, then runs the
same guided setup as every install with **Browser** preselected. See the
[Lemon Bot guide](getting-started/lemon-bot.md) for prerequisites, Mac app
availability, and private access over SSH.

Prefer the terminal? Use the [terminal quickstart](getting-started/quickstart.md):

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
$HOME/.lemon/bin/lemon
```

For source checkouts and installation options, see [Install](install.md).
Existing users: read the [November 2026 upgrade notes](release/upgrade-2026-11.md)
before updating, especially if you connect from another machine.

## Find your way around

- **[Getting started](getting-started/lemon-bot.md)**: [Lemon Bot](getting-started/lemon-bot.md), [terminal quickstart](getting-started/quickstart.md), [install](install.md), [provider setup and services](user-guide/setup.md), [demo](demo.md), [updates and uninstall](user-guide/updates.md), [support](support.md)
- **[User guides](user-guide/web.md)**: [Browser](user-guide/web.md), [profiles](user-guide/profiles.md), [memory](user-guide/memory.md), [skills](user-guide/skills.md), [reminders](user-guide/reminders-and-heartbeats.md), [backups](user-guide/backups.md), [built-in tools](tools/files-and-search.md), [safety](security/safety.md)
- **[Configuration & CLI reference](config.md)**: [Configuration](config.md), [registry](config-registry.md), [CLI & sessions](user-guide/cli.md), [TUI slash commands](user-guide/tui-commands.md), [control-plane methods](reference/control-plane.md), [skill manifest](reference/skill-manifest-v2.md)
- **[Integrations & channels](getting-started/add-a-channel.md)**: [Channels](getting-started/add-a-channel.md), [gateway](platform/lemon_gateway.md), [OpenAI-compatible API](tools/openai-compatible-api.md), [ACP](tools/acp.md), [MCP and extensions](extensions.md), [omp](user-guide/omp.md), [A2A peers](user-guide/a2a-peers.md)
- **[Developers & contributors](architecture/overview.md)**: [Architecture](architecture/overview.md), [first agent](getting-started/build-your-first-agent.md), [testing](testing.md), [contributing](contributor/public_repo_basics.md), [releases and packages](platform-split.md)
- **[LemonSim & benchmarks](benchmarks/quickstart.md)**: [Benchmark quickstart](benchmarks/quickstart.md), [platform guarantees](benchmarks/platform.md), [VendingBench](benchmarks/vending-bench.md), [run your model](benchmarks/run-your-model.md)

The [documentation index](README.md) lists every page by task. Coming from
Hermes? See [Migrate from Hermes](user-guide/migrate-from-hermes.md).

</div>
