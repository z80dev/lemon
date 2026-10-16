# Lemon Documentation

Lemon is a self-hosted assistant and a deterministic simulation platform. This
index follows the site navigation: Getting started, User guides, Configuration
& CLI reference, Integrations & channels, and Developers & contributors, plus
LemonSim & benchmarks. Source modules and tests define implementation APIs.

## Getting started

| Goal | Guide |
| --- | --- |
| Install and get a first model-backed answer | [Quickstart](getting-started/quickstart.md) |
| Choose a supported install or source checkout | [Install](install.md) |
| Configure providers, secrets and channels | [Setup](user-guide/setup.md) |
| Explore the assistant on real work | [Demo](demo.md) |
| Update safely, or roll back | [Safe updates](user-guide/updates.md) |
| Understand current limits | [Capabilities](compare.md) and [support](support.md) |
| Understand why Lemon runs on the BEAM | [Why BEAM for agents](why-beam-for-agents.md) |
| Watch a keyless simulation | [LemonSim UI](../apps/lemon_sim_ui/README.md#keyless-demo) |

## User guides

- Interfaces: [browser](user-guide/web.md), [TUI](../clients/tui/README.md) and [CLI and sessions](user-guide/cli.md)
- [Profiles](user-guide/profiles.md), [memory](user-guide/memory.md), [skills](user-guide/skills.md),
  [instruction files and rules](user-guide/context-files.md),
  [file slash commands](user-guide/slash-commands.md),
  [reviewed source learning](user-guide/learn-from-sources.md)
  and [bounded context references](user-guide/context-references.md)
- [Reminders, heartbeats and daily brief](user-guide/reminders-and-heartbeats.md)
- [Attaching a bot machine](user-guide/attaching-a-bot-machine.md) and
  [execution-node files, secrets and processes](user-guide/node-files-and-secrets.md)
- [Backups](user-guide/backups.md) and [Hermes migration](user-guide/migrate-from-hermes.md)
- [Adaptive behavior](user-guide/adaptive.md) and [feature rollout](user-guide/rollout.md)
- Built-in tools: [file and search](tools/files-and-search.md),
  [shell and background processes](tools/shell.md), [user questions](tools/ask.md),
  [checkpoints/rewind](tools/checkpoint.md), [todo plans](tools/todo.md),
  [local tool issue reports](tools/report-issue.md), [Web/browser](tools/web.md),
  [browser tool](tools/browser.md), [Firecrawl](tools/firecrawl.md), [media](tools/media.md),
  [LSP](tools/lsp.md), [eval kernels](tools/eval.md), [debugger](tools/debug.md),
  [omp delegate](tools/omp.md) and [computer use](tools/computer-use.md)
- Safety: [safety model](security/safety.md), [agent safety contract](security/agent-safety-contract.md),
  [secrets/keychain](security/secrets-and-keychain.md), [secret migration](security/secrets-migration-guide.md),
  [secret obfuscation](security/secret-obfuscation.md) and [threat model](security/threat-model.md)

## Configuration and CLI reference

- [Configuration reference](config.md) and [configuration registry](config-registry.md)
- [CLI and sessions](user-guide/cli.md) and the [TUI slash-command reference](user-guide/tui-commands.md),
  generated from the terminal command registry
- [Control-plane methods](reference/control-plane.md)
- [Skill implementation/reference](skills.md) and [manifest schema](reference/skill-manifest-v2.md)
- [Product versioning/channels](release/versioning_and_channels.md)

The obsolete skills-v2 roadmap is consolidated into the manifest and skills
references. The former introductory tour is consolidated into the architecture
overview and the app guides below, rather than keeping a second runtime catalog.

## Integrations and channels

- [Add a channel](getting-started/add-a-channel.md) and [lemon_gateway](platform/lemon_gateway.md)
- [Lemon in Tern](user-guide/tern.md)
- [OpenAI-compatible API](tools/openai-compatible-api.md), [ACP](tools/acp.md),
  [extensions/MCP clients](extensions.md) and [WASM](tools/wasm.md)
- [Delegating to omp](user-guide/omp.md): run, watch, steer and resume omp sessions
- [A2A peers](user-guide/a2a-peers.md) and [Honcho memory](user-guide/honcho.md)

## Developers and contributors

- Build: [first agent](getting-started/build-your-first-agent.md), [add a tool](getting-started/add-a-tool.md),
  [add a channel](getting-started/add-a-channel.md) and [persist memory](getting-started/persist-memory.md)
- Architecture: [overview](architecture/overview.md), [app boundaries](architecture_boundaries.md),
  [BEAM lifecycle invariants](beam_agents.md), [bus events](platform/bus-events.md),
  [model selection](model-selection-decoupling.md) and [execution policy](execution-policy.md)
- [Context](context.md), [bootstrap](assistant_bootstrap_contract.md),
  [long-running harnesses](long-running-agent-harnesses.md) and [parent questions](subagent-parent-questions.md)
- [Hot reload](runtime-hot-reload.md), [telemetry](telemetry.md) and [error reporting](error-reporting.md)
- [Testing lanes](testing.md), [deterministic test patterns](testing/deterministic-test-patterns.md),
  [platform test harness](platform/lemon_platform_test.md) and [Mix tasks](mix-tasks.md)
- [Public repository practices](contributor/public_repo_basics.md) and [ownership](contributor/ownership.md)
- Releases: [deployment flows](release/deployment_flows.md),
  [release/support checklist](release/release_checklist_and_support_policy.md),
  [five-package status](platform-split.md) and [Hex publication](release/hex-packages.md)
  — 0.2.0 is published; 0.1.0 is retired
- [Root contributor/app guide index](../AGENTS.md#ownership-and-app-guides)

## LemonSim and benchmarks

- [Benchmark quickstart](benchmarks/quickstart.md) and [platform guarantees](benchmarks/platform.md)
- [VendingBench](benchmarks/vending-bench.md), [run your model](benchmarks/run-your-model.md),
  [platform microbenchmarks](benchmarks/platform-microbenchmarks.md)
  and [paired disclosure protocol](benchmarks/paired-disclosure.md)
- [Simulation harness](../apps/lemon_sim/README.md) and [control room](../apps/lemon_sim_ui/README.md)

## Documentation site

Markdown is the source of truth. The VitePress site uses Node.js 24 LTS+,
Python 3, and Bun 1.3.14+ for the TUI command-reference drift check. From the repository root:

```bash
npm --prefix docs ci
npm --prefix docs run dev
npm --prefix docs run build
scripts/verify_docs_site
```

Both dev startup and build generate `docs/public/llms.txt` and `llms-full.txt`
through `scripts/generate_docs_llms.py`. These assets are ignored, not committed;
VitePress copies them into the site root. The generator fails if a curated page
is missing. Its optional `--check` compares already generated files, not the git
index. No clean-tree generated diff is required.

`bun clients/tui/scripts/generate-commands-doc.ts` regenerates the committed
TUI command reference without connecting to a daemon. Pass `--check` to fail on
drift. `verify_docs_site` runs this check in the original checkout (the registry
is its source), keeping documentation drift in the docs gate rather than only
the client lane. Install TUI dependencies with
`bun install --frozen-lockfile --cwd clients/tui` if needed.

The same gate checks every Markdown page against the actual VitePress sidebar.
Add user-facing pages to the matching section of the sidebar in
`docs/.vitepress/config.js` (Getting started, User guides, Configuration & CLI
reference, Integrations & channels, Developers & contributors, or LemonSim &
benchmarks); intentionally unlisted
contributor/internal pages need a reason in `scripts/check_docs_navigation.mjs`.
Hidden directories, `generated`, `node_modules`, and `public` are excluded.

`verify_docs_site` copies docs and the generator into a temporary workspace,
installs locked dependencies, runs source-link tests, builds, checks both output
assets, then runs the shared Markdown link-check entrypoint against the original
checkout so repository-relative links resolve. `npm --prefix docs run link-check`
uses that same recursive entrypoint, including root-level docs pages. CI uses
the same npm build/link commands. Links to repository files are rewritten for
the website; site navigation must work under the `/lemon/` base path.

Update the canonical page for a changed behavior, not four prose copies. Keep
contributor guides operational, API detail in moduledocs, and workflows here.
When consolidating a page, migrate its inbound links and site navigation. Existing
Excalidraw/SVG diagrams are supporting illustrations; the architecture overview
and generated dependency table are the current app/boundary inventory.
