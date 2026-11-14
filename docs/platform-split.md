# Lemon platform split — status

Status as of 2026-11-13. This page replaced the August 2026 plan of record, which
aimed to publish a dozen Hex packages and move the products into their own
repositories. The boundary work survived and the package set was cut to five.
The general product extraction was abandoned (D18); LemonSim alone later moved
to its own repository (D19). Git history has the full plan.

## Published packages

| Package | What it is | In repo | On Hex |
|---|---|---|---|
| `lemon_ai` | Provider-agnostic LLM client: providers, model registry, streaming, rate limiting, circuit breaking | 0.2.1 | 0.2.1 |
| `lemon_core` | Bus and event envelope, pluggable Store, secrets, config, paths, boundary contracts | 0.2.0 | 0.2.0 |
| `lemon_agent` | Agent loop, tool registry, subagents, model runtime, workspace stores | 0.2.0 | 0.2.0 |
| `lemon_memory` | Durable memory: document schema, SQLite store, provider behaviour, ingest, search | 0.2.0 | 0.2.0 |
| `lemon_platform_test` | Contract-test kit: `BackendCase`, `EventsCase`, `ProviderCase`, `FakeLLM` (and `PluginCase`, which needs the unpublished `lemon_channels`) | 0.2.0 | 0.2.0 |

These are exactly what `mix lemon.new` generates against. The 0.2 line is the
first installable one: `lemon_core`, `lemon_agent`, `lemon_memory` and
`lemon_platform_test` are published at 0.2.0 and `lemon_ai` at 0.2.1. Every
0.1.0 release is retired on Hex as uninstallable. The mechanics of publishing
and proving the tarballs are in
[`docs/release/hex-packages.md`](release/hex-packages.md).

The packages have one external consumer:
[LemonSim](https://github.com/z80dev/lemon-sim) (D19); its CI builds against the
Hex releases and, daily, against Lemon main, so a platform change that would
break it shows up before it is released.

## In the repository only

Everything else is the **reference runtime and its products**, built and released
together as the umbrella (CalVer), not as packages: `lemon_router`,
`lemon_gateway`, `lemon_channels`, `lemon_media`, `lemon_skills`, `lemon_browser`,
`lemon_control_plane`, `lemon_automation`, `lemon_cli`, `lemon_web`,
`lemon_lsp`, `lemon_mcp`, `lemon_honcho`, `lemon_evals`, `coding_agent`,
plus the TypeScript clients under `clients/`. LemonSim (`lemon_sim`,
`lemon_sim_ui`) is no longer here; it lives in
[z80dev/lemon-sim](https://github.com/z80dev/lemon-sim).

What still holds from the split, and is worth keeping whether or not anything is
published:

- **Dependency boundaries.** `mix lemon.quality`'s architecture check enforces an
  exact per-app `deps/0` policy and cross-app namespace references; the generated
  table is [`architecture_boundaries.md`](architecture_boundaries.md). `lemon_ai`
  and `lemon_core` have no umbrella dependencies.
- **A library-grade `lemon_core`.** Named, multi-instance Stores; optional
  `phoenix_pubsub`, `exqlite`, `file_system`, `sentry` and `finch` with explicit
  degradation; runtime registries instead of compile-time references to
  consumers.
- **Typed bus events** — [`platform/bus-events.md`](platform/bus-events.md).
- **The contract-test kit** and **the generator** (`installer/`), both verified
  against the unpacked tarballs by `scripts/verify_packages`.
- **The sim seam is now a repository boundary.** LemonSim depends only on the
  published `lemon_core`, `lemon_agent` and `lemon_ai` packages and lives in
  [z80dev/lemon-sim](https://github.com/z80dev/lemon-sim); this umbrella has no
  sim wiring left (no sim UI port, release or config blocks).

## Decision log

| # | Date | Decision |
|---|---|---|
| D1 | 08-09 | No merged `lemon_runtime` package; router, gateway and channels stay separate apps. |
| D2 | 08-10 | *Amended.* Gateway sheds only what is a channel: email moved to a `LemonChannels.Plugin`; webhook, SMS and voice stay gateway-owned because `Plugin.deliver/1` cannot answer a synchronous HTTP request. The original "move all five transports" was overturned by the code. |
| D3 | 08-09 | Bench stays inside `lemon_sim`. |
| D4 | 08-09 | `lemon_memory` split out of `lemon_core` as its own app. |
| D5 | 08-09 | Goal, kanban and heartbeat stores moved to `lemon_agent` as `LemonAgent.Workspace.*`. |
| D6 | 08-09 | Store library-ified before publishing; heavy deps made optional. |
| D7 | 08-09 | Vendor channels and tools isolated behind runtime registries (superseded by D17 for X). |
| D8 | 08-09 | LemonSim is the flagship demo, in this repository (see D18). |
| D9 | 08-09 | control_plane ↔ coding_agent inverted through a capability provider. |
| D10 | 08-09 | Umbrella stays CalVer; packages use independent semver, `1.0.0` only after the APIs have real consumers. |
| D11 | 08-10 | *Overturned the plan.* `chat_state`/`chat_state_store` stay in `lemon_core`: channels reads and writes them, so moving them to the router would have created a forbidden edge. The router is their single writer. |
| D12 | 08-10 | Farcaster transport deleted. |
| D13 | 08-10 | `lemon_media` published because router and channels depended on it (reversed by D18). |
| D14 | 08-13 | Publish `lemon_skills` and `lemon_browser` to unblock the coding-agent extraction. Never published; abandoned by D18. |
| D15 | 08-11 | CLI runners split into `lemon_cli_runners` (superseded by D16). |
| D16 | 08-21 | `lemon_cli_runners` deleted; subagents are native-only `CodingAgent.Session`s. |
| D17 | 09-01 | X/Twitter integration removed from the harness. |
| D18 | 09-27 | **Five packages, no extraction.** Publish only `lemon_ai`, `lemon_core`, `lemon_agent`, `lemon_memory`, `lemon_platform_test` — what the generator uses. Abandon Phase 5 (product repos, cross-repo CI) and D14. |
| D19 | 11-13 | LemonSim moves to z80dev/lemon-sim as an application on the published lemon_core/lemon_agent/lemon_ai packages; partially reverses D18. It is the packages' first external consumer; its CI builds against the Hex releases and, daily, against Lemon main, so a platform change that would break it shows up before it is released. |

**Why D18.** The 0.1.0 releases of 2026-08-11 could not be installed: each shipped
a `mix.exs` that required `../../hex_package.exs`, a file outside the tarball, and
every check ran inside the umbrella where that file exists. Nobody reported it,
because there were no consumers. Router, gateway, channels, media, skills and
browser are runtime internals with vendor code; publishing them meant semver on
~100k lines nobody used. Extracting the products would turn every change to
core/agent/ai into a multi-repo release for a single maintainer, while the
architecture check already keeps the seams clean. The published `mix.exs` files
are now self-contained, and `scripts/verify_packages`
(`.github/workflows/packaging.yml`) builds consumer projects from the unpacked
tarballs so this class of break fails CI.

## Known gaps

- **`lemon_new` is not on Hex.** The five packages are published at 0.2.0 and
  every 0.1.0 release is retired, so `mix lemon.new --hex` output resolves.
  `installer/` is publishable as `lemon_new` the same self-contained way, but
  publishing a new package needs an owner key with API write
  ([`release/hex-packages.md`](release/hex-packages.md)); until then the
  generator is built from a checkout.
- **`--channel` is checkout-only.** It depends on `lemon_channels`, which is not
  published; so does `PluginCase`. `--hex --channel` is refused with that
  explanation instead of generating a project that cannot resolve.
- **`lemon_core` is still broader than a core.** The plan's store moves were
  re-measured against real consumers; a module moves only when every non-test
  consumer is the target app or already depends on it, with no new mix edge or
  bridge. Moved: `ProgressStore` → `LemonGateway.ProgressStore` (gateway also
  registers the `:progress` read cache), the memory doctor check →
  `LemonMemory.Doctor.Checks.Memory`, and the skills doctor check →
  `LemonSkills.Doctor.Checks.Skills` (both via `:doctor_checks`). Staying, with
  the consumer that blocks each move:
  - Router targets: `RunStore` (core `SessionLifecycle`/`SessionMetadataStore`,
    gateway `Run`/`Scheduler`/`ThreadWorker`, channels Telegram transport,
    `coding_agent` `SideQuery`/`ControlPlaneProvider`); `RunHistoryStore` (core
    `RunStore.history/2` and its supervision child); `ChatState`/`ChatStateStore`
    (core `SessionLifecycle`, channels Discord/Telegram transports,
    `coding_agent` `ControlPlaneProvider`).
  - Channels targets: `Binding`, `BindingResolver` and `GatewayConfig`
    (`lemon_gateway`, which does not depend on channels); `Cwd` (`coding_agent`
    `BackgroundRun`/`SideQuery`); `ProjectBindingStore` (core `BindingResolver`).
  - Former "runtime platform repo" targets (gone under D18): `ConfigReloader`
    (core-only, reloads core config; no other owner); `UsageStore` (read by
    core `UsageDiagnostics`, which channels `PortableCommand` uses);
    `PolicyStore` (`coding_agent` `SideQuery`, core `SessionLifecycle`; it is
    also the canonical policy plane); `ExecApprovalStore` (core `ExecApprovals`
    and `Events.ApprovalPending`).
  - Doctor: the framework, the core-domain checks (config, secrets, runtime,
    providers, usage, node tools) and the diagnostics core's `SupportBundle`
    reads: `LspDiagnostics` (also `coding_agent` `Tools.LspDiagnostics`),
    `CheckpointDiagnostics` (also channels), `CronDiagnostics`,
    `ExtensionDiagnostics` and `ProviderDiagnostics`.

  Only the repo tooling (`quality/`, `update/`, repo-only `mix lemon.*` tasks)
  is kept out of the tarball.
- **Elixir floor.** The packages declare `~> 1.15`; CI proves 1.19 and runs the
  1.15 leg as advisory.
- **`LemonChannels.Plugin.meta/0`** keeps its flag-map capability vocabulary;
  widening it to typed `Capability.spec()` lists waits for a consumer that needs
  sizes, features or rate limits.
