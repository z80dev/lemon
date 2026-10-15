# Lemon Documentation

Lemon is a self-hosted assistant and a deterministic simulation platform. Start
with the workflow you need; source modules and tests define implementation APIs.

## Start here

| Goal | Guide |
| --- | --- |
| Install and get a first model-backed answer | [Quickstart](getting-started/quickstart.md) |
| Choose a supported install or source checkout | [Install](install.md) |
| Explore the assistant on real work | [Demo](demo.md) |
| Watch a keyless simulation | [LemonSim UI](../apps/lemon_sim_ui/README.md#keyless-demo) |
| Understand current limits | [Capabilities](compare.md) and [support](support.md) |
| Understand the message journey | [Architecture overview](architecture/overview.md) |

## Use and operate the assistant

- [Setup/providers/channels](user-guide/setup.md) and [configuration reference](config.md)
- [CLI and sessions](user-guide/cli.md), [TUI](../clients/tui/README.md) and [browser](user-guide/web.md)
- [Profiles](user-guide/profiles.md), [memory](user-guide/memory.md) and [Honcho](user-guide/honcho.md)
- [Delegating to omp](user-guide/omp.md): run, watch, steer and resume omp sessions
- [Skills](user-guide/skills.md), [instruction files and rules](user-guide/context-files.md),
  [file slash commands](user-guide/slash-commands.md),
  [reviewed source learning](user-guide/learn-from-sources.md)
  and [bounded context references](user-guide/context-references.md)
- [Reminders, heartbeats and daily brief](user-guide/reminders-and-heartbeats.md)
- [Backups](user-guide/backups.md), [safe updates](user-guide/updates.md) and [Hermes migration](user-guide/migrate-from-hermes.md)
- [A2A peers](user-guide/a2a-peers.md), [adaptive behavior](user-guide/adaptive.md) and [feature rollout](user-guide/rollout.md)
- [Safety model](security/safety.md), [agent safety contract](security/agent-safety-contract.md),
  [secrets/keychain](security/secrets-and-keychain.md), [secret migration](security/secrets-migration-guide.md),
  [secret obfuscation](security/secret-obfuscation.md) and [threat model](security/threat-model.md)

## Tools and skills

- [Skill implementation/reference](skills.md) and [manifest schema](reference/skill-manifest-v2.md)
- [Web/browser](tools/web.md), [browser tool](tools/browser.md), [Firecrawl](tools/firecrawl.md), [media](tools/media.md), [LSP](tools/lsp.md) and the [omp delegate](tools/omp.md)
- [ACP](tools/acp.md), [OpenAI-compatible API](tools/openai-compatible-api.md),
  [extensions/MCP clients](extensions.md) and [WASM](tools/wasm.md)

The obsolete skills-v2 roadmap is consolidated into the manifest and skills
references. The former introductory tour is consolidated into the architecture
overview and the app guides below, rather than keeping a second runtime catalog.

## Build on Lemon

- [First agent](getting-started/build-your-first-agent.md), [add a tool](getting-started/add-a-tool.md),
  [add a channel](getting-started/add-a-channel.md) and [persist memory](getting-started/persist-memory.md)
- [App boundaries](architecture_boundaries.md), [BEAM lifecycle invariants](beam_agents.md),
  [bus events](platform/bus-events.md) and [model selection](model-selection-decoupling.md)
- [Context](context.md), [bootstrap](assistant_bootstrap_contract.md),
  [long-running harnesses](long-running-agent-harnesses.md) and [parent questions](subagent-parent-questions.md)
- [Hot reload](runtime-hot-reload.md), [telemetry](telemetry.md) and [error reporting](error-reporting.md)
- [Testing lanes](testing.md), [deterministic test patterns](testing/deterministic-test-patterns.md)
  and [Mix tasks](mix-tasks.md)
- [Root contributor/app guide index](../AGENTS.md#ownership-and-app-guides)

## LemonSim and benchmarks

- [Benchmark quickstart](benchmarks/quickstart.md) and [platform guarantees](benchmarks/platform.md)
- [VendingBench](benchmarks/vending-bench.md), [run your model](benchmarks/run-your-model.md)
  and [platform microbenchmarks](benchmarks/platform-microbenchmarks.md)
- [Simulation harness](../apps/lemon_sim/README.md) and [control room](../apps/lemon_sim_ui/README.md)

## Releases and packages

- [Product versioning/channels](release/versioning_and_channels.md) and [deployment flows](release/deployment_flows.md)
- [Release/support checklist](release/release_checklist_and_support_policy.md)
- [Five-package status](platform-split.md) and [Hex publication](release/hex-packages.md)
  — 0.2.0 is published; 0.1.0 is retired
- [Public repository practices](contributor/public_repo_basics.md) and [ownership](contributor/ownership.md)

## Documentation site

Markdown is the source of truth. The VitePress site uses Node.js 24 LTS+ and
Python 3. From the repository root:

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
