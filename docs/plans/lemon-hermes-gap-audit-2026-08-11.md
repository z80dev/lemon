# Lemon ↔ Hermes Deep Gap Audit — 2026-08-11

Status: point-in-time audit (refreshes the 2026-05-12 parity matrix)

## Method and baseline drift

- Hermes source: `/home/z80/dev/hermes-agent`, working tree at `0713fb2ab`
  (2026-08-11, ~82 commits behind `origin/main` — effectively current).
- Lemon source: this repo at `0810fc0b` (post platform-split rename, D15).
- The prior ledger (`lemon-hermes-feature-parity-matrix-2026-05-12.md`) was
  pinned to Hermes `94c523f0c`. **Hermes has landed ~13,000 commits since that
  baseline.** This audit does not restate the old matrix row-by-row; it
  identifies (a) new Hermes surfaces the matrix has never seen, (b) the
  largest standing gaps, (c) Lemon-only advantages, and (d) recommended
  priorities.
- Evidence: five parallel code-inventory passes (Hermes runtime; Hermes
  learning loop/automation; Hermes channels/UX; Lemon runtime/channels; Lemon
  memory/automation/sim), plus docs diffs `94c523f0c..origin/main`.

## Headline verdict

Lemon has genuinely closed or exceeded several May-era gaps (cron engine,
goal loops, kanban dispatch, skills self-improvement pipeline, MCP
client/server, multi-engine execution, deterministic eval arenas, contract
test kits). But Hermes is compounding fast on **surface area** (34 messaging
platforms, desktop app, egress proxy, secrets managers, voice stack) and on
**agent-loop refinement** (three-way interruption, tiered tool disclosure,
programmatic tool calling, credential pools, cache-aware background
learning). The "Hermes, but better, on the BEAM" claim currently holds for
runtime operability, benchmarking, and multi-agent simulation; it does not
yet hold for channel breadth, desktop/voice UX, provider resilience
plumbing, ecosystem distribution, or install friction.

---

## 1. New Hermes surfaces since the May baseline (not tracked in the old matrix)

These are net-new or newly documented upstream; each needs an explicit
in-scope / out-of-scope decision rather than silent omission from the ledger:

| Surface | What it is | Hermes evidence |
| --- | --- | --- |
| Hermes Desktop | Electron app (macOS/Win/Linux), onboarding, chat, HUD, command palette, starmap, plugin SDK; Tauri bootstrap installer | `apps/desktop/` (1,561 files), `apps/bootstrap-installer/`, `docs/user-guide/desktop.md` |
| Egress proxy ("iron proxy") | Outbound credential-injection firewall for remote sandboxes; sandbox only holds opaque proxy tokens, real keys never leave host | `website/docs/user-guide/egress/`, `agent/proxy_sources/iron_proxy.py` |
| Secrets managers | 1Password, Bitwarden SM, arbitrary-command secret sources; managed scope (admin-pinned, user-immutable config) | `agent/secret_sources/`, `user-guide/secrets/`, `user-guide/managed-scope.md` |
| New messaging platforms | IRC, ntfy, Photon (iMessage sidecar), Raft, Relay, Buzz (Nostr), A2A (agent-to-agent), WhatsApp Cloud API — total now ~34 | `plugins/platforms/`, `gateway/platforms/` |
| Relay connector protocol | Gateway dials out over one authenticated WS to a connector holding bot tokens; per-connector capability negotiation; works behind NAT | `gateway/relay/`, `docs/relay-connector-contract.md` |
| Multi-profile gateways | Many isolated profiles (own tokens/sessions/memory) as managed services on one machine; profile routing per guild/channel/thread | `gateway/profile_routing.py`, `user-guide/multi-profile-gateways.md` |
| Session heartbeats | `/heartbeat every 10m <prompt>` — recurring prompt re-entering the *same session* when idle (distinct from cron) | `user-guide/features/heartbeat.md` |
| Mixture of Agents | Named MoA presets that appear as selectable models; reference-model fan-out per turn, Hermes loop keeps tool control | `agent/moa_loop.py` (2,384 lines) |
| Tool search | Tiered progressive tool disclosure: 3 bridge tools replace MCP/plugin tool schemas when catalogs blow the context budget | `tools/tool_search.py` |
| Deliverable mode | Generated charts/PDFs/spreadsheets shipped as native attachments per platform | `user-guide/features/deliverable-mode.md` |
| Computer use | Background desktop control (cua-driver) that doesn't steal cursor/focus | `tools/computer_use_tool.py` |
| Wake word + voice mode | "Hey Hermes" on CLI/TUI/desktop; CLI push-to-talk/VAD; Discord voice channels (listen + speak); streaming TTS | `tools/wake_word.py`, `tools/voice_mode.py`, discord `voice_mixer.py` |
| Import from other agents | One-command import of `~/.claude` / `~/.codex` (instructions, allowlists, MCP servers, skills, memories) | `hermes import-agent` |
| Automation blueprints + suggestions | Parameterized automations rendered as forms/slash-commands; consent-first suggestion engine with latched dismissals; blueprint-as-skill distribution | `cron/blueprint_catalog.py`, `cron/suggestions.py` |
| Subscription proxy / tool gateway | Nous Portal subscription as OpenAI-compatible endpoint; managed tool routing (search/imagegen/TTS/cloud browser) without per-service keys | `user-guide/features/subscription-proxy.md`, `tool-gateway.md` |
| Journey / learning graph | Timeline + constellation visualization of learned skills/memories with pruning UI | `agent/learning_graph.py`, `hermes_cli/journey.py` |
| Pets / skins / personality | Petdex mascots (CLI/TUI/desktop), skins/themes, SOUL.md personas | `ui-tui/src/components/petSprite.tsx`, `hermes_cli/skin_engine.py` |
| Document extraction | `read_file` converts PDF/Office/notebooks to text | `user-guide/features/document-extraction.md` |

Lemon has partial counterparts for a few (heartbeats exist in
`lemon_automation` as *cron health checks*, not same-session recurring
prompts; `HEARTBEAT.md` exists in the assistant workspace contract; Hermes
import exists as `mix lemon.hermes.migrate`). The rest are absent.

---

## 2. Largest standing gaps (Hermes has, Lemon lacks or is preview)

### 2.1 Provider resilience plumbing (highest runtime leverage)

- **Live fallback chains**: Hermes has an ordered fallback-provider chain
  driven by a structured `FailoverReason` classifier (1,842-line
  `agent/error_classifier.py`), with prompt-cache breakpoints re-laid on
  failover. Lemon's `ProviderRouting` is explicitly preview — its moduledoc
  says dispatch can consume the ordering "once the fallback execution path
  is wired" (`apps/lemon_agent/lib/lemon_agent/model_runtime/provider_routing.ex`).
  Session-layer fallback (`coding_agent/session/provider_fallback.ex`) and a
  pool rotator exist but aren't the unified path.
- **Credential pools**: Hermes rotates multiple same-provider credentials
  (env/OAuth/CLI-borrowed) on 429/auth failure with cooldowns and lease
  semantics for subagents (`agent/credential_pool.py`, 3,178 lines). Lemon
  has single-credential resolution per provider.
- **Turn retry state**: Hermes collapses ~16 recovery paths (OAuth refresh,
  long-context restart, thinking-signature strip, image shrink, …) into one
  `TurnRetryState`. Lemon has strong error *normalization* (`LemonAi.Error`)
  and circuit breaker/rate limiter/dispatcher, but fewer automated recovery
  behaviors on top.

### 2.2 Interruption semantics

Hermes distinguishes **interrupt** (hard stop), **steer** (inject into last
tool result, nothing stops), and **redirect** (cancel only the in-flight
model request, keep completed tool results, append correction, retry —
degrades to steer during tool execution). Lemon has abort (cooperative ETS
signal) and steering/follow-up queues, but no redirect equivalent — a
mid-stream correction today either waits or kills the run.

### 2.3 Context-cost engineering

- **Programmatic tool calling**: Hermes `execute_code` gives the model a
  Python RPC stub over 7 allowlisted tools; intermediate results never
  enter context, and a file-based RPC transport makes it work inside
  Docker/SSH/Modal backends. Lemon has no equivalent (bash + tools only).
- **Tool search / progressive disclosure**: with many MCP servers, Hermes
  swaps tool schemas for 3 bridge tools with a tiered catalog (including a
  names-alone-too-big tier). Lemon sends registered tool schemas directly.
- **Tool-result offloading**: Hermes persists oversized tool output *into
  the sandbox filesystem* with a preview + path so the model can grep it.
  Lemon's `context_guardrails.ex` blob-spills to disk with stable
  references — partial parity; worth verifying the model-facing retrieval
  ergonomics match.
- **Micro-compaction / native compaction**: incremental post-turn
  absorption and OpenAI server-side compaction (gpt-5.6-gated). Lemon has
  truncation/summarization/hybrid compaction and overflow recovery, no
  incremental variant.

### 2.4 Learning loop mechanics

Lemon's loop (memory ingest → skill synthesis → curator → routing feedback,
all rollout-gated) is real but conservative; Hermes's is aggressive and
per-turn:

- **Background review fork**: after turns (10-turn / 10-iteration nudge
  counters, hydrated across resume), a daemon fork replays the conversation
  against the same prefix cache and writes memory/skills, routable to a
  cheaper aux model with digest replay. Lemon's synthesis mines *finalized
  run documents* on a schedule — slower feedback, and `session_search` /
  durable recall ships **off by default** (`lemon_core/config/features.ex`),
  so the loop is inert until opted in.
- **Anti-capture policy**: Hermes's review prompt forbids learning negative
  tool claims and unresolved failures ("these harden into refusals").
  Lemon's synthesis selector filters on outcome/quality but has no
  equivalent explicit anti-capture policy.
- **`/learn`**: open-ended skill acquisition from URLs/dirs/books with
  knowledge-base distillation. No Lemon counterpart.
- **Memory providers**: 9 pluggable providers (Honcho dialectic with
  two-layer injection, Mem0, Supermemory, …) vs Lemon's behaviour with
  exactly one implementation (`providers/local.ex`) and no auto-injection
  (tool-mediated recall only).
- **Journey**: visualization + pruning surface for what the agent learned.
  No Lemon counterpart.

### 2.5 Channels and gateway

- **Breadth**: ~34 platforms vs 6 (Telegram, Discord, WhatsApp, XMTP,
  Email, X) + 3 transports (webhook, SMS, Twilio voice). Missing entirely:
  Slack, Signal, Matrix, iMessage (×2 paths), Teams, Google Chat,
  Mattermost, Feishu/DingTalk/WeCom/QQ (CN market), LINE, SimpleX, IRC,
  ntfy, Nostr, A2A.
- **Access control**: Hermes has DM pairing codes (rate-limited, lockout,
  0600 storage), per-platform allowlists, DM/group policies, slash-command
  access tiers, relay per-tenant keys. Lemon has `allowed_chat_ids` on
  Telegram, one WhatsApp access module, and control-plane device/node
  pairing — no unified channel ACL/pairing subsystem.
- **Voice**: 11 TTS + 8 STT providers, streaming TTS, voice memos on 5
  platforms, Discord VC duplex, wake word. Lemon: Twilio call transport +
  Deepgram STT + TTS control-plane methods + `media_generate_speech` —
  much narrower, no voice mode on any chat channel.
- **Cross-platform continuity**: Hermes `/handoff`, delivery mirroring,
  shared session store across CLI/TUI/desktop/gateway. Lemon's agent
  directory/endpoints/bindings cover addressing, but there's no live
  session handoff between surfaces.

### 2.6 Cron/automation deltas

Lemon's cron core is competitive (durable store, atomic slot claim, jitter,
retries with lineage, cron memory ≈ Hermes notepad, heartbeat suppression,
goal loops, kanban dispatch). Hermes extras Lemon lacks: **monitor mode**
(hash-suppressed change detection), **wakeAgent $0 pre-run gates**,
**no-agent script jobs**, **job chaining** (`context_from`), **model drift
guard** (fails closed when the global default model changed under an
unpinned job), **pre-dispatch preflight** (no LLM call on misconfig),
**blueprints + suggestions**, ~20 delivery targets vs Lemon's
Telegram/Discord outbox, and a pluggable scheduler provider (Chronos
managed cron).

### 2.7 Ecosystem and distribution

- **Skills**: 78 bundled + ~120 optional skills, an 8-source hub
  (skills-sh, well-known, GitHub taps incl. openai/anthropics/huggingface,
  clawhub, lobehub, browse-sh), security-scanned installs, publishing.
  Lemon: solid installer/trust/audit machinery, agentskills-style format
  compat, but a placeholder official registry (`https://skills.lemon.agent`)
  and a small builtin set.
- **Plugins**: typed plugin families for providers/memory/web/browser/
  image/video/cron/observability/platforms with per-user override dirs.
  Lemon's extension points exist (engine, channel plugin, store backend,
  memory provider + contract kits) but the third-party story is gated
  "not yet supported" in `docs/compare.md`.
- **Install**: one-line installer, native Windows, Termux, Docker s6, Nix
  flake + NixOS modules, signed desktop installers, `hermes update`.
  Lemon: source install on Linux (honest, but a major adoption gap).
- **Docs**: ~401-page Docusaurus site + zh-Hans mirror vs Lemon's VitePress
  docs (good architecture/reference coverage, far fewer task guides).

### 2.8 Terminal backends

Hermes: local, Docker, SSH, Singularity, Modal (direct or managed), Daytona,
Vercel Sandbox, with `EnvironmentConnectionError` degraded-mode semantics
and file sync. Lemon: local, local_pty, SSH, Docker behind
`LemonCore.TerminalBackends` + policy. Missing: serverless backends
(Modal/Daytona — the "hibernates when idle" story), Singularity, and remote
live proof.

### 2.9 State/session layer details worth copying

Schema-derived read probes and export column lists (anti-drift by
construction), compression-triggered session splitting with lineage chains,
three FTS5 tables incl. CJK bigram tokenizer (C extension), per-(model,
provider, mode, task) usage rollups with typed cost provenance
(`CostStatus`/`CostSource`), archived/pinned/read-unread session lifecycle.
Lemon's stores are cleaner architecturally (pluggable backends, separate
purpose DBs) but thinner on these ergonomics; cost accounting uses a rough
4-chars-per-token estimator where Hermes carries provider-actual costs.

---

## 3. Lemon advantages (Hermes has no equivalent)

- **Supervision/operability as substrate**: OTP trees with restart
  recovery everywhere (cron manager reload + orphan recovery, arena
  reconciliation, checkpointed sim resume, hosted-game epochs), explicit
  loop state machine, hot config reload, `LEMON_FEATURE_*` kill switches,
  architecture-rules CI check, typed env registry (~262 vars), 3 TODOs in
  the whole tree. Hermes is a decomposing monolith with 27k/878k-line god
  files and thread-based concurrency.
- **Multi-engine execution**: first-class `Engine` behaviour running
  Claude Code, Codex, Droid, Kimi, OpenCode, Pi CLIs *and* the native
  engine through one run graph, with per-CLI subagents. Hermes has the
  codex app-server runtime and skills that shell out to other agents, but
  no engine abstraction.
- **Simulation/benchmark arena**: `lemon_sim` (~118k LOC): event-sourced
  kernel, 19+ scenarios, leagues, Bradley-Terry ratings, tamper-evident
  recomputable artifacts, external-agent JSONL protocol, always-on arenas,
  hosted human multiplayer, replay→video. Hermes's evals (readtool A/B,
  toolperf traps) are sharp but narrow; its batch trajectory tooling
  targets training data, not benchmarking.
- **Distributed control plane**: ~170 JSON-RPC methods, node pairing/
  presence/invoke, device pairing, agent inboxes — a real multi-node
  story. Hermes multi-gateway coordination is kanban-board-scoped.
- **WASM tool sandbox** (`coding_agent/wasm/`): sandboxed tool execution
  tier Hermes lacks (its sandboxing is per-backend).
- **Contract-test kits**: published compliance suites for all four
  extension points. Hermes plugins have no equivalent conformance kit.
- **Budget inheritance**: token+cost budgets propagated parent→child
  through the run graph with enforcement, vs Hermes's iteration counting.
- **Deterministic-by-construction benchmarking + usage/cost persistence
  across restarts** — Hermes has nothing comparable.
- **lemon_tcg**: live on-chain trading desk with pure-Elixir signing —
  out of Hermes's scope entirely.

---

## 4. Hygiene findings inside Lemon (from this audit)

1. **11 orphaned tool modules** in `apps/coding_agent/lib/coding_agent/tools/`
   (`exec`, `await`, `ask_parent`, `restart`, `multiedit`, `glob`,
   `todoread`, `todowrite`, `webdownload`, `fuzzy`, likely `process`) —
   registered nowhere; delete or wire.
2. **`session_search`/durable recall off by default** — the entire memory→
   synthesis loop is inert on a fresh install.
3. **Scorecard drift**: `lemon-hermes-agent-harness-parity-scorecard.md`
   still narrates Web `/ops` slices that no longer map to `lemon_web`
   (dashboard removed; monitoring moved to `clients/lemon-web`).
4. **`lemon_web` has 1 test file for 20 modules**; `lemon_lsp` is metadata
   only; email inbound off by default mid-port.
5. **Observability**: bare `:telemetry` with no metrics/poller/dashboard
   layer; Sentry wiring near-zero (known, being made optional in split
   item 1.4).
6. **Placeholder skills registry URL** (`https://skills.lemon.agent`).
7. The May matrix baseline is 13k commits stale — either re-pin it or mark
   it historical and adopt this audit as the live ledger.

---

## 5. Recommended priority order

P0 — runtime leverage, small surface:
1. Wire live provider fallback through `ProviderRouting` ordering; add
   credential-pool rotation (Hermes `credential_pool.py` semantics).
2. Add `redirect` interruption (cancel in-flight model call, preserve
   completed tool results, append correction).
3. Turn on `session_search` + memory ingest by default (with the existing
   redaction gate); consider a Hermes-style anti-capture policy in the
   synthesis selector.

P1 — context-cost + loop quality:
4. Tool-search-style progressive disclosure for MCP-heavy sessions.
5. Programmatic tool calling (script-over-RPC; BEAM port or WASM sidecar
   could make this cleaner than Hermes's file-RPC).
6. Cron: monitor mode, job chaining, model drift guard, preflight — all
   small, all high-perceived-quality.

P2 — surface area (pick deliberately, don't chase all 34 platforms):
7. Slack + Signal or Matrix as next promoted channels; unified pairing/
   allowlist subsystem in `lemon_channels` (Hermes pairing-code UX).
8. One-line installer + binary release; Modal/Daytona-class serverless
   terminal backend for the "cheap when idle" story.
9. Voice: one chat channel with voice-memo STT round-trip (Telegram
   already has inbound transcription — close the TTS reply loop).

Explicit non-goals (recommend declaring in `docs/compare.md`): desktop app,
pets/skins, CN-market platforms, wake word, subscription proxy — unless the
product direction changes.

## Sources

- Prior ledger: `docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md`
  (statuses as of 2026-05-18), harness scorecard, channel command matrix.
- Hermes: `README.md`, `website/docs/**` (user-guide features/messaging,
  developer-guide), `agent/*.py`, `tools/*.py`, `gateway/**`, `cron/**`,
  `plugins/**`, `hermes_state*.py`, `acp_adapter/`, `apps/desktop/`.
- Lemon: `apps/**` moduledocs and registries, `docs/compare.md`,
  `docs/platform-split.md`, `bin/lemon`.
