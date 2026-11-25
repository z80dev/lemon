# Changelog

All notable changes to Lemon are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [CalVer](https://calver.org/) — `YYYY.MM.PATCH`.

---

## [Unreleased]

### Added

- Read-scoped control-plane method `commands.list(cwd)` returns the file slash
  commands the daemon would expand for a directory, advertised in `hello-ok`.
  The TUI palette, `/help` and autocomplete now use it and `skills.list`
  instead of scanning command, prompt and skill directories locally, so they
  follow the daemon's configured agent directory and drop a deleted command
  file on the next refresh. The palette no longer lists local prompt templates
  (#718).
- Gateway-native webhook, Twilio SMS and voice can now start from global
  `[gateway.ingress]` TOML and per-surface settings, with
  `LEMON_GATEWAY_INGRESS_ENABLED` as the startup override. The generic webhook
  ships pre-registered; all three listeners remain opt-in (#698).
- One-shot CLI commands beside a running runtime never become a second store
  writer: their client store defers every write to the runtime that owns the
  database, and `lemon secrets set|delete|import-env` and `lemon setup
  gateway` token storage go through the new admin `secrets.set` /
  `secrets.delete` control-plane methods; other store writes (provider
  credentials in `lemon setup`/`lemon model`) refuse until `lemon stop` (#667).
- `lemon secrets` is the only secrets command-line implementation; the
  `mix lemon.secrets.*` tasks and their twin tests are removed (#717).
- Kimi Code parity with omp (#525): with a `kimi_coding` credential the model
  picker lists the account's models from `/coding/v1/models` (name, context,
  image input, effort levels, per-family output caps), and `websearch` gains a
  `kimi` provider (`POST /coding/v1/search`) that uses the Kimi Code login,
  omp login or API key. The `kimi` (API-key) K3 and `kimi-for-coding` models now
  send adaptive thinking with effort, like `kimi_coding`. Global (kimi.ai)
  Kimi Code accounts sign in with `lemon model kimi-code --region global`
  (also with `--auth omp`, which then reads omp's `kimi-code-global` login), and
  a stored login refreshes at the host that issued it. Several Kimi Code logins
  in a credential pool (or omp broker) are ordered for new sessions by quota
  headroom, as omp does. Models using the OpenAI Chat Completions wire against
  a Moonshot-native host send tool parameters as Moonshot Flavored JSON Schema.
- `lemon browser stop` (admin control-plane method `browser.stop`) stops the
  local browser driver and the Chrome it launched (#660).
- Operator WebSockets can watch one session at a time with `sessions.watch`.
  The TUI uses that subscription to receive each native text delta once. The web
  shell listens for lifecycle only, and terminal waiters no longer subscribe to
  token streams. Run lifecycle events carry versioned run/attempt identities (#716, #86).

- `lemon setup omp` reuses the provider logins and API keys omp already holds:
  it starts omp's auth broker as the new `omp-broker` service
  (`lemon service install omp-broker`) when none is running, lists omp's
  credentials, checks the ones you pick through the broker and sets
  `auth_source = "omp_broker"` and the default model without hand-editing
  config. `lemon setup` offers it when omp is installed; `lemon setup omp
  status` and `disconnect` inspect and undo it.
- Epic #543 wave 3 (additive, unless marked **Breaking**):
  - Providers preconnect (#567); OpenAI Responses over WebSocket with
    `previous_response_id` chaining is opt-in via `responses_websocket = true`
    (#566).
  - Subagents return structured results through a `submit_result` tool (#602);
    task-tool action usage is measured by telemetry only, with no behavior
    change (#604); idle subagent processes hibernate and completions are
    batched, with published memory figures (#597).
  - Optional advisor: a second model that reviews each turn (#600).
  - Experimental, opt-in `code_mode` tool profile
    (`profile = "code_mode"` / `LEMON_TOOL_DISCLOSURE_PROFILE=code_mode`);
    legacy, coding and auto defaults are unchanged (#598). The arena Lemon
    image includes checksum-pinned Deno 2 for sandboxed code-mode trials.
  - Gateway admission: the EngineLock FIFO is replaced by a fail-fast
    engine-session claim (#610), the Run is the slot waiter and `ThreadWorker`
    is deleted (#611), the router no longer retries gateway admission (#612),
    and one admission-gate inventory and ADR documents the router/gateway stack
    (#613).
  - Diagnostics and status use standard status hooks and published counters
    with redaction instead of `:sys.get_state` (#593).
  - LSP runs one process per language-server session (#578).
  - Callbacks no longer do blocking work and calls into shared servers are
    bounded (#587); `gen_statem` replaces hand-rolled timer/status-flag
    lifecycles (#588).
  - Supervision subtrees, caps and no unsupervised fallbacks, with bounded task
    admission (#585); retry, limiter, dedupe and runtime seams are consolidated
    (#592).
  - Durable steering and follow-up acceptance with withdraw RPCs (#559).
  - Crash and torn-write model tests for the durable cores with mutation checks
    (#555).
  - Default-off `features.crash_resume` (`"off"`; set `"on"` to opt in) resumes
    router runs orphaned by a hard crash (#556) and re-drives cut-off task
    children at boot (#558).
- **Breaking (`lemon_ai`/`lemon_agent` 0.3.0):** provider streaming events are
  delta-only with single accumulation and coalescing (#571); agent queue hooks
  change with durable steering (#559); `RetryHelper`/`OneshotRetry` are removed
  in favor of `LemonAi.Retry` (#592). See the package changelogs for migration.
- `Durable.sync_file` no longer leaks a stray port `EXIT` message to its
  caller (#555).
- Opt-in Terminal-Bench comparisons through a Harbor adapter for Lemon and omp,
  with credentials held only by the arena proxy, paired statistics, retained
  audit containers and explicit post-run metric collection (#544),
  and a re-runnable omp edit-fixture comparison for the `edit` and `patch`
  tools with failure-site attribution and non-tool event filtering (#545).
- `mix lemon.eval.latency`: an offline harness that measures harness overhead
  (request dispatch, token delivery, queued-run handoff, readiness, per-turn
  session stages) with a nightly regression lane (#546).
- Optional, default-off GenAI span export for model and tool calls, with a
  content-free attribute allowlist (#594).
- Isolated task workspaces start warm: copy-on-write clones of allowlisted,
  git-ignored build caches (`deps`, `_build`, `node_modules`, `target`,
  `.venv`); secrets and ignored config are never copied (#601).
- Tool intent is journaled before dispatch: effectful tools carry an `effect`
  class (`:none`, `:idempotent`, `:external` default), coding sessions append a
  synced `lemon.tool_intent` entry first and do not run the tool if that fails,
  and reload reports interrupted calls as `unknown` or `not_started` (#554).
- Per-session sequenced event log: session events carry a gap-free `seq` and a
  versioned cursor, and `sessions.events` replays ordered batches after a cursor
  or returns `cursor_expired`; the TUI dedupes live and reconnect batches (#560).
- `lemon sessions maintain --older-than`: preview-confirm archiving of cold native
  session journals and removal of orphan spill artifacts, plus a session index
  for listing and streamed loading of large journals (#565).
- Stream rules: a rule with `streamPattern` (and `injectionLimit`) stays out of
  the prompt until streamed output matches, then the stream is cancelled and
  retried with a `<system-interrupt reason="rule_violation">` correction (#599).
- Opt-in `[runtime.tools] vendor_dialects` experiment exposing Claude-style
  `Read`/`Edit`/`Bash` and Codex `apply_patch` tool shapes for matching models;
  default stays off, and upstream identities are pinned in a hash manifest (#603).
- `docs/omp-port-ledger.md` inventories omp/pi-mono ports, and the TUI moves to
  `@oh-my-pi` 18.20.2 packages (#609).
- `scripts/check_docs_source_refs.mjs` runs in `scripts/test quality`,
  `scripts/verify_docs_site` and the Docs Site workflow. It fails when a
  telemetry catalog row's linked function does not emit that event, a cited
  `function/arity` or `file.ex:N` line does not exist, or a docs shell command
  references a missing repository path (#735).
- `docs/architecture_boundaries.md` gains a generated package map (every app's
  `mix.exs` version and Hex publish-set membership). `mix lemon.architecture.docs`
  regenerates it and `mix lemon.quality` fails when it is stale or when the
  publish set in `mix.exs` differs from `scripts/verify_packages` (#90).
- Architecture docs reconciled with the code: package status reports the real
  Hex versions (`lemon_ai` 0.2.1) and the CI Elixir legs, its decision log is
  marked historical, the in-repo app list and per-app dependency tables point at
  the generated tables, stale `agent_core`/`ai` app names are corrected, and the
  coding_agent guide no longer claims steer/redirect are unsupported on named
  nodes (#90).

### Changed

- **Breaking:** `[features] routing_feedback` now defaults to `"off"`; set it to
  `"on"` in the global config to record and use routing history. When enabled,
  history no longer outranks `[defaults] model`: it is consulted only for
  un-pinned runs, suggests only models with at least a 75% success rate, and
  replaces the default only where the default itself was measured (5+ samples)
  and did worse, so a changed default takes effect immediately. The router reads
  the flag from the config cache instead of parsing TOML per submission, and
  the history lookup is an index range scan (#647).
- **Breaking (lemon_core package):** the `LemonCore.Testing*` harness is no
  longer published with lemon_core; `use LemonCore.Testing.Case, with_store:
  true` now actually starts the Store; the duplicate Elixir credential scrub
  list (`HermeticEnv.credential_env_vars/0`, `scrub_unit_credentials!/1`,
  `:test_credential_env_vars`) is removed in favour of the single list in
  `scripts/test`; `LemonGateway.AsyncHelpers` is removed (#713).
- **Breaking:** `session.detail` is now a routing projection only: `session`
  carries the next run's model, provider, context window and thinking level
  plus the durable agent, title/pin/archive state, run count and timestamps.
  The `runs`, `runCount`, `summary`, `options` and `contentWithheld` blocks and
  the `limit`/`historyLimit`/`eventLimit`/`toolCallLimit`/include parameters
  are gone, and it no longer reads run history or scans the session directory,
  so a TUI or web session switch costs point reads of that session's index,
  metadata and policy rows. Run and event content come from `chat.history`,
  `sessions.history` and `runs.timeline.get` (#700).
- **Breaking:** learning reminder settings moved from `skills.json` to
  `[skills.learning_nudge]` in `config.toml` (background review under
  `[skills.learning_nudge.background_review]`, operator-only); a project
  `.lemon/config.toml` can only turn reminders off or lengthen their intervals.
  A `learning_nudge` object left in `skills.json` is no longer read and
  `lemon doctor` warns about it. `skills.json` now holds only the `disabled`
  list (#655).
- One app list per runtime: `apps/lemon_core/priv/runtime_profiles.exs` is the
  single source for the `lemon_runtime_min`/`lemon_runtime_full` releases, the
  source launcher, `/healthz`, `lemon doctor` and `lemon setup runtime`, and a
  test fails when they or the deployment docs drift. The minimal runtime is now
  documented as what it is, the full runtime without the web UI (#726).
- The packaged runtime refuses to boot, naming the fix, when its store backend
  is not durable, `exqlite` is unavailable or a required `lemon_core` service
  group is deselected, instead of running with run history silently off (#92).
- **Breaking:** the control-plane `agent` method takes `sessionKey`, `agentId`,
  `queueMode` and an optional fixed `runId`, rejects the old snake_case
  spellings, returns the `chat.send` receipt (`runId`, `sessionKey`, `state`,
  `effectiveMode`, `targetRunId`, `retrySafe`), and runs an `agentId` that names
  a managed profile as that profile's chat in its own workspace (a caller `cwd`
  is refused). A submit whose reply is lost keeps its fixed run ID, and a retry
  with the same `idempotency_key` reconciles to that one run. `lemon print`
  uses the new fields (#620).

- Goal and kanban state, their agent tools and the `/goal`, `/kanban` and
  `/remind` chat commands are owned by `lemon_automation`. The `kanban` and
  `goal` tools register through the runtime tool registry like `cron` (same
  schemas; they now follow it in tool order and their results are untrusted),
  and channels reach the chat commands through `LemonCore.AutomationCommands`
  instead of quoted module names. `config :lemon_core, :workspace_diagnostics`
  names `LemonAutomation.GoalStore`/`KanbanStore`; the
  `:goal_loop_module`, `:kanban_dispatcher_module` and `:reminder_cron_module`
  lemon_channels settings are gone (#721, #729).
- Bot HTTPS moved from the core CLI to the Lemon Bot CLI: run
  `lemon-bot https enable --tailscale|--url HTTPS_ORIGIN`, `status` and
  `disable` instead of `lemon bot https`. Existing `~/.lemon/bot-https.json`
  receipts keep working. A failure after settings changed now says so instead of
  reporting "locked; no concurrent changes". `lemon setup` no longer offers an
  HTTPS step. `lemon doctor`'s read-only `bot.admission_origins` check also uses
  the origin `lemon-bot https` published and the allowlists the admission owners
  actually enforce (#723).
- `LemonCore.Context` moved to `lemon_skills` as `LemonSkills.Context`; it no
  longer ships in the published `lemon_core` package. `lemon context` and
  `lemon learn` are unchanged (#724).
- **Breaking (Hex packages):** the published packages are self-consistent and
  `scripts/verify_packages` proves it by running them: the packaged doctor's
  runtime check no longer calls the excluded `LemonCore.Update.Version` (build
  identity is `LemonCore.BuildInfo.version/0`, `identity/0`, `describe/0`) and
  no longer fails below Elixir 1.20.5 (the application floor is
  `LemonCli.Doctor.Toolchain`'s `runtime.elixir`); sibling requirements are
  `~> 0.3.0`, derived from each package's version, so they cannot resolve
  across a 0.x minor (lemon_memory and lemon_platform_test join the 0.3.0
  line); `PluginCase` leaves the lemon_platform_test package; and
  `mix lemon.store.migrate_jsonl_to_sqlite` is removed (#730).
- **Breaking (Hex packages):** the five published packages require Elixir 1.17
  (was `~> 1.15`, which they did not meet: exqlite 0.43 requires 1.17 and they
  call `String.replace_invalid`, Elixir 1.16; lemon_core did not compile on
  1.15). `packaging.yml` now requires `scripts/verify_packages` on the floor,
  Elixir 1.17.3 / OTP 26.2, and the script fails on functions the running
  toolchain lacks or dependencies that refuse it (#730).
- Duplicate test families are collapsed to one canonical file per module
  (#732): EventStream, Loop, CircuitBreaker, CallDispatcher, ProviderRegistry,
  Google/OpenAI Responses shared helpers, TextSanitizer, CodingAgent session,
  extensions, bash executor and edit tests, about 23K fewer test lines.
  `LemonAgent.EventStream` tests now cover only the facade's abort-signal,
  `:agent` event format and cancel-grace options; queue, drop-strategy,
  ownership and cancellation coverage lives with `LemonAi.EventStream`.
  `mix lemon.check_duplicate_tests` (part of `mix lemon.quality`) now also
  fails when an `_edge_cases`, `_additional_edge_cases`, `_comprehensive`,
  `_extended` or `_consolidation` test file or module sits beside its
  canonical test.
- **Breaking:** channel model and thinking preferences live in
  `LemonCore.PolicyStore`. Telegram and Discord `/model` for this session writes
  the session row (`:model`, as `sessions.patch` does), so web, TUI and the
  control plane show the same model the channel run uses; `/model` for future
  sessions and `/thinking` write `PolicyStore` chat rows (thread, chat, account
  or channel). Channels no longer put `model`, `model_scope`, `thinking_level`
  or `thinking_scope` into run meta: `LemonRouter.ModelSelection` decides
  request > session row > chat row > profile > default (thinking: request >
  session row > chat row) from the session key, and `session.detail` reports
  `modelSource: "chat"` for a chat default. Session reset and delete remove
  every model and thinking override with the session row. `lemon policy` writes
  the same chat rows; `--peer` without `--account` now names the `default`
  account (it used to write a key nothing read) and `--thread` requires
  `--peer`. Preferences stored in the removed `:model_policies`,
  `:telegram_session_model`, `:telegram_default_model`,
  `:telegram_default_thinking` and `:discord_session_model` tables are not
  read: set them again with `/model`, `/thinking` or `lemon policy` (#714).
- The web Automation page no longer rebuilds a full snapshot every three seconds
  (about 77 service calls per open tab). It loads in a background task after the
  connected mount and reloads only on kanban, goal and cron Bus events, so an idle
  tab makes no service calls and kanban changes appear immediately (#687).
- Media provider drivers (OpenAI image/TTS/STT/vision/video, Vertex Imagen/Veo,
  Google TTS, ElevenLabs, Deepgram) moved from `lemon_skills` into `lemon_media`
  behind `LemonMedia.Providers.run/1` with one shared retry helper; Google
  service-account tokens are cached until expiry instead of re-signed per job.
  Channel voice-note transcription and voice replies and the gateway voice
  call's ElevenLabs synthesis and Deepgram streaming now call the `lemon_media` clients;
  transcription errors shown in chat carry a redacted provider error label
  instead of the raw provider message (#722).
- **Breaking:** media tools (`media_generate_image`, `media_generate_speech`,
  `media_transcribe_audio`, `media_analyze_image`, `media_generate_video`) now
  require `provider`; omitting it returns `provider is required` instead of a
  fabricated local preview. Provider-backed calls get provider-sized default
  timeouts (2–15 minutes) instead of the local-preview defaults (#664).
- Native session journals store the system prompt once per digest on a branch,
  as a `lemon.prompt_snapshot` entry, instead of twice in every assistant entry;
  assistant entries reference it by digest and plan revision. With a 56 KiB
  prompt, 100 assistant messages now take 121 KB of journal instead of 11.5 MB.
  Older journals with inline snapshots still resume unchanged (#676).
- Native journal appends, checkpoints and rewrites no longer go through a
  per-directory SQLite index and `:global` lock, so a maintenance run can no
  longer crash a live session's append. `CodingAgent.SessionIndex` and
  `SessionManager.list_sessions/1` (no callers) are removed; leftover
  `.index.sqlite3` files in session directories are unused (#695).
- `scripts/test coverage` runs each app in its own VM, so failures that only
  appeared when one VM re-cover-compiled apps under running processes are
  gone; paths select apps and other arguments go to every app's run (#499).
- The Store bounds the `:runs` table and keeps full-table reads off its
  process (#682). Run events go into a per-run buffer (first 200 + latest,
  2,000 in all, `:events_dropped` counts the rest); `:runs` stores only the
  summary and lifecycle metadata. The summary and frozen buffer expire
  `:runs_retention_ms` (default 24 h) after finalization; a durable `:run_terminals` entry makes
  `RunStore.fetch/1` return `{:error, :evicted}` so a finished run (also after a
  restart) is never reopened by the gateway. `fetch_all/2`, `list/2`, the new
  `fetch_keys/2` and `fetch_range/5`, and introspection listing read the backend
  in the caller's process (SQLite: a private read-only WAL connection). Usage
  pages read only the window's ledger occurrences, never `:runs`; router
  session discovery reads session keys only. **Breaking** for `lemon_core`
  callers: `:runs` cannot be listed whole, `UsageStore.fetch_runs/1` is gone,
  and introspection listing errors are `{:error, :store_unavailable}`.
  tab makes no service calls and kanban changes appear immediately. Each load
  makes seven batched reads whatever the number of boards, goals and cron jobs
  (`KanbanStore.list_tasks_for/2`, `KanbanDispatcher.status_many/2`,
  `GoalLoopManager.status_many/1`, `CronManager.runs_for/2`) (#687).
  session discovery reads session keys only, and session-maintenance previews
  use a bounded metadata index. **Breaking** for `lemon_core` callers:
  `:runs` cannot be listed whole, event readers must use `RunStore.get_with_events/1`,
  `UsageStore.fetch_runs/1` is gone, and introspection listing errors are
  `{:error, :store_unavailable}`.
- Dependencies: Phoenix 1.8 (`lemon_web`), Sentry 14, exqlite 0.43 (SQLite
  3.54.1), plus in-range Hex updates; `req` is pinned to `~> 0.6.0` and
  `websockex` to `~> 0.5` across apps. With `SENTRY_DSN` set, Sentry 14
  redacts scrubbed values as `[Filtered]`.
- The current date and git status now travel in the user turn instead of the
  system prompt, and the stable environment block is journaled once and reused
  on resume, so the cached system prompt stays byte-identical across turns (#562).
- Receipt and admission writes commit with `synchronous=FULL` (plus
  `F_FULLFSYNC` on macOS) instead of a full WAL checkpoint; reads no longer
  checkpoint. Receipt barrier p50 drops from 18.3 ms to 6.5 ms (#550).
- Channels outbox admissions and delivery receipts use durable commits instead
  of per-event WAL checkpoints, preserving acknowledgement-after-durability
  (#543, #550, #557).
- Cancellation is delivered as a message: abort and redirect wake waiters
  immediately instead of on a 20–250 ms polling tick, and the global task
  cancellation sweep is gone (#549).
- Delegated-agent joins, LSP diagnostics waits and bash stop confirmation wake
  on bus, abort and monitor messages instead of 20–250 ms polling loops (#543).
- Named-node tool refusals and unknown outcomes, and tool-start failures, now
  report the shared `details.outcome` vocabulary (`:not_started`/`:unknown`
  with a reason atom) instead of `"not_run"`/`"unknown"` strings or an
  inspected error in `details.reason`; the start error moves to
  `details.start_error` (#552).
- Compaction reserves at least 15% of the context window and only counts a pass
  as successful at or below 80% of the trigger, so it no longer re-compacts every
  turn near the limit (#568).
- Session journals append through one open handle with append-only checkpoint
  markers instead of rewriting the whole file every run; directories are synced
  natively without python3 (#553, #561).
- Background-process output is served from an owner-held ETS snapshot and
  flushed to the durable store on transitions and a coalesced timer instead of
  once per output chunk (#548).
- The control plane uses a Registry for connection presence and fan-out and runs
  async WebSocket methods under a capped supervisor; crashing methods log a
  redacted class and method name (#583).
- Named-node event frames go straight to their invocation owner instead of
  through the `NodeRegistry` process (#584).
- Run processes own their session key; a restarted coordinator rediscovers live
  runs through the Registry (#573).
- The gateway scheduler no longer blocks on workers, and runs hold the engine
  session lock as a Registry name acquired after startup (#547, #572).
- Model-call admission keeps per-provider caps across restarts and fails closed
  with `:admission_unavailable` instead of bypassing the cap (#591).
- Cron schedules the earliest deadline instead of scanning every minute, and
  kanban leases renew while their worker is alive (#596).
- The system prompt is sent to providers as ordered blocks, static first and
  directory-derived last, with a prompt digest journaled per reply, so sessions
  in different directories share the cached prefix (#563).
- Root sessions stay alive across turns and park after five idle minutes or when
  over the 32-root idle budget, instead of being saved and resumed every turn;
  eval kernels survive turns but not parking (#564).
- Compaction first spills old tool-result bodies to `artifact://` references
  (newest 40,000 tokens protected, results under 50 tokens skipped) and skips the
  summary call if that alone is enough (#569).
- One `EventStream` implementation (`LemonAi.EventStream`) backs both stream APIs;
  `push/2` now returns `{:error, :overflow | :canceled}` instead of ignoring them (#570).
- Native joins, swarm scheduling and foreground bash waits wake on Bus
  notifications and monitors instead of 20–100 ms polling; child inboxes get a
  per-child owner (#575).
- Task, process, run-graph and parent-question stores share one durable-table
  module with unchanged DETS files and an in-owner expiry index (#576).
- One request/response client for stdio and socket RPC peers replaces per-client
  pending-request bookkeeping, with deadlines and fail-all on transport loss (#577).
- Store hooks run in a monitored worker with a five-second budget, and secret
  master-key work, config reload and run-history reads no longer run inside the
  `Store` process (#579).
- Bash, background and other OS processes share `ProcessSession` ownership and
  one `ProcessGroup.terminate/2` kill path (#586).
- In-VM locks pass `[node()]` with finite retries and fail with a safe error
  instead of waiting forever; the cross-process `Service.Lock` gains stale
  recovery (#589).
- One shared cap, `:coding_agent, :task_max_concurrency` (default 8), governs
  native task children and background sessions; the unused main/subagent lanes
  and the second semaphore are gone (#590).
- Long-lived caches and tables (extension, web, capability, dedupe, auth) have
  supervised owners and survive their first caller; mutable `:persistent_term`
  use is removed (#595).
- **Breaking:** `sessions.reset` is preview-first and confirmation-bound. A call
  without `confirmToken` (or with `dryRun: true`) mutates nothing and returns a
  redacted state digest (run-history count, chat state, session policy, ACP
  metadata) plus a single-use server-side `confirmToken`; only `dryRun: false`
  with that token resets, after re-verifying the live digest under the session
  lifecycle fence. Each deletion is checked, and failures report
  `retrySafe: false` without raw exception text. Clients that sent only
  `sessionKey` must now preview and confirm. TUI `/reset` and `/session reset`
  show the daemon preview in a confirmation modal that defaults to Cancel (#615).

### Fixed

- `agent.wait` returns `UNAVAILABLE` when the run store cannot be read instead
  of reporting a timeout, and no longer copies a raw exception message into its
  error details (#620).
- `agent.wait` no longer `inspect`s a non-text run error onto the wire: it
  returns `{"kind", "status", "message"}` (provider HTTP status kept, message
  redacted and bounded), a non-text answer is `null`, and `lemon print` renders
  that object. `cron.run` allocates its cron run ID before calling the
  scheduler, which claims exactly that ID, so an unknown outcome names the
  `runId` to reconcile; a trigger blocked by an earlier unresolved run reports
  `PRIOR_RUN_OUTCOME_UNKNOWN` with that run's `priorRunId` instead (#620).
- Preserve committed run outcomes across restarts, retry pending completion
  notifications and projections, and never report an already-completed run
  as failed because answer presentation crashed (#75, #76, #77, #84).

- `bin/lemon start` now starts Honcho memory and computer-use tools when they
  are configured: the source runtime previously never started
  `lemon_honcho` or `lemon_computer_use` (#726).
- Runtime applications start as permanent applications, and `/healthz` answers
  `503` naming the stopped applications instead of a constant `200`; `lemon
  doctor` reports an expected application that failed to start or stopped
  (#726).
- `agent.wait` returns `UNAVAILABLE` when the run store cannot be read instead
  of reporting a timeout, and no longer copies a raw exception message into its
  error details (#620).
- Source (`bin/lemon`) and packaged distributed runtimes start OTP's `rex`,
  `global_name_server` and `global_group` again: `-kernel start_distribution
  false` (#551) had dropped them, so every native session start failed on
  `:global` and the weekly Product Smoke was red (#499).
- `scripts/test quality` passes Credo again: the crash-report stand-in exception
  is `LemonCore.StatusRedaction.RedactedCrashError` (#499).
- The nightly offline latency lane names the failing boot and the probe's fixed
  failure message (or only the exception module) instead of a bare "runtime
  failed" (#499).
- Dialyzer: the five published packages (`lemon_core`, `lemon_ai`,
  `lemon_agent`, `lemon_memory`, `lemon_platform_test`) and the other gated apps
  have zero findings; fixes include `Lemon.Reload` treating a successful code
  change as an error and extension manifests reporting non-object JSON as
  oversized (#499, #734).
- Preemptive compaction compares the context of a run's latest provider call
  (`context_tokens`, else the last call's cache-inclusive input) with the
  threshold, never the run's cumulative usage: a run of five 20K-context calls
  no longer compacts the next prompt because it spent 100K input tokens. Run
  usage is one typed `LemonCore.Events.Usage` read by its canonical field names;
  the router, control plane and usage ledger no longer probe alternative
  spellings (`input_tokens`, `prompt_tokens`, `cache_read_input_tokens`, …),
  so a history record stored under them reports unknown counters. The
  completion's `tokens`/`cost_usd` duplicates of `total_tokens`/`cost.total`
  and the clients' cumulative `contextTokens` fallback are gone (#669).
- Deleting a session (`sessions.delete`, `lemon sessions delete`, prune)
  removes every piece of state kept for it, not only chat state, policy and
  run history: memory documents (recall and search no longer return a deleted
  conversation), session-scoped approval grants, the session goal, Telegram and
  Discord message indexes and model overrides, the web workspace, router
  compaction and agent-messaging state, and native session journals with their
  model pins. `verified: true` now means every owning store verified its
  deletion; a failure restores all of them. `sessions.reset` also revokes the
  session's approval grants and drops message indexes, pending selected
  resumes and compaction markers that could resume the old conversation (#692).
- Verified session deletion also erases run diagnostics, stopped native task
  records and journals, and attributable crash-staged journal copies without
  deleting independent forks or the content-free terminal run decision (#692).

- One-shot CLI commands (`lemon doctor`, `config`, `secrets`, `usage`, `context`,
  `learn`, `learning`, `mcp`, `update`, `migrate`, `providers`, `setup`, and the
  `mix lemon.secrets*`/`lemon.config`/`lemon.usage` tasks) boot the core in a
  client mode that no longer expires a running daemon's pending approvals, sweeps
  its store, starts a second config reloader or run-history store, or installs a
  SIGTERM trap; read-only commands also open the store read-only. A runtime only
  reconciles approvals while it holds the store's ownership lock
  (`<store>.runtime.lock`), so a second runtime on the same store (for example a
  node worker) leaves the owner's approvals alone. `lemon migrate hermes` confirms
  every imported session document and reports unconfirmed writes as
  `outcome_unknown` (#667).
- Exec approvals are indexed by run and session, so run and session end read
  only that owner's approvals instead of the whole approval table. Terminal
  approval receipts are swept after 24 hours
  (`:exec_approval_receipt_retention_ms`); resolving a swept ID returns
  `not_found`. Approval recovery at boot no longer stops `:lemon_core` when the
  store is unavailable (it retries with backoff and refuses resolution
  meanwhile), and native session start gets an error instead of a crash when
  the approval worker does not answer within 2 seconds (#694).
- Config: `[tui] theme = "auto"` (what `/theme auto` writes) and `"system"` no
  longer fail config validation and break every config read and the next
  daemon start; the terminal client owns theme names and core only requires a
  non-blank string (#640).
- Config: after an invalid edit a running Lemon serves the last good config,
  logs the failure once and stops re-reading the file until it changes, instead
  of re-parsing and raising on every config read. Invalid `[features]` states,
  `[runtime] max_tool_turns` values and profile tool policies are validation
  errors instead of silently becoming `off`, unlimited or deny-all. An
  unloadable config fails gateway and channel startup instead of starting with
  every channel disabled (#617).
- Gateway: `[gateway]` is read live from the canonical config, so a reload
  reaches every gateway reader (including `max_concurrent_runs` for the running
  gateway) without a restart. `[gateway.queue] mode = "fifo"` (or any other
  value `lemon config validate` accepted) no longer crashes boot: the section
  was never read and is now ignored with a warning. Binding transports from
  config no longer create atoms, and TOML project roots resolve for channel
  bindings (#697).
- Two follow-ups merged inside the router's 500 ms debounce window (or two
  steers falling back together) now run: the merged run keeps the newest
  message's execution context instead of the earlier one's, which the native
  executor rejected as a run-ID mismatch, and a restart replays the merged
  prompt instead of only the first message (#642).
- Cron never announces a job or run change that failed to persist: when a
  store write fails, `CronManager` emits no event, leaves its in-memory state
  unchanged and returns `{:error, :store_unavailable}` (or
  `{:error, :outcome_unknown}` when the write may have landed) from add,
  update, model refresh, remove, run-now, wake and abort. A run is never
  submitted, and a terminal never delivered or reported as an abort, unless
  its write was confirmed (#87).
- Skill disable state is the union of the global and project `skills.json`
  lists: enabling a skill at project scope (blueprint activation, control-plane
  `skills.enable`, `skill_manage restore`) no longer lifts a global disable or a
  curator archive and no longer writes an empty list. `skills.json` writes are
  atomic under a lock, and an unreadable or malformed file now hides every skill
  instead of re-enabling all of them; `lemon doctor` reports it (#655).
- Discord boots again: `lemon_channels` now starts `:gun`, which Nostrum needs
  for its gateway and REST connections; previously a configured bot token
  failed with `:noproc` and no Discord service started (#670).
- Discord threads have one identity: messages, slash commands and buttons in a
  thread now resolve the same parent channel and thread (from the gateway's
  channel cache, else a channel lookup), so `/cancel`, `/model`, `/new`,
  `/resume`, `/goal`, `/checkpoint`, trigger mode, approvals and thread
  preferences act on the session the thread's runs use. Reactions and
  system replies land in the thread. A channel that cannot be looked up is
  not routed under a guessed key (#649).
- One voice note or file transfer no longer stalls every chat on a channel
  account. Telegram transcribes voice notes and downloads images in the poll
  task and applies updates in a supervised worker, so pairing allowlist
  updates and runtime drains are answered while a note transcribes. Discord
  acknowledges slash commands and buttons on arrival (replies follow as edits
  or follow-ups), so a queued command no longer misses the 3 s window, and
  file transfers, thread creation and media preparation run beside the event
  queue. Telegram start-up, including a retry after another runtime released
  the poller lock, reads the stored offset and resolves the bot identity
  (`getMe`) in a supervised task, so a slow Telegram API no longer blocks
  pairing or drains; allowlist changes made meanwhile apply once it starts
  (#650).
- Skill lockfile and audit-state writes wait up to ten seconds for their file
  lock instead of one, so concurrent skill installs in one runtime are no
  longer refused with `lock_timeout` while the lock is merely busy (#499).
- Channels: XMTP no longer replays its whole inbox after a restart. It persists
  a per-conversation `sent_at_ns` high-water mark and polls only newer messages;
  Telegram confirms its offset after each handled update instead of each batch
  and keeps its dedupe table across transport restarts. Both pass a stable run
  identity so the router admits a replayed message at most once, and the XMTP
  bridge runs commands one at a time (#648).
- Channels: a second runtime holding a Telegram bot's poller lock, or one
  adapter's crash loop, no longer stops Discord, XMTP and Email until restart.
  Telegram stays alive and retries the lock with backoff, each adapter restarts
  behind its own keeper with backoff, and configured adapters are started again
  whenever `AdapterSupervisor` restarts (#686).
- TUI: the session switcher marks sessions started from another directory and
  refuses to switch to them with a notice (focus unchanged, no empty session
  left behind) instead of an unhandled rejection that could end the process;
  failed switches and picker callbacks are reported, and one process-level
  `unhandledRejection` handler turns any stray rejection into a notice and a
  `/debug` entry (#666).
- TUI: a request lost after it reached the socket now fails with an
  outcome-unknown `ConnectionLostError` instead of "not sent"; one
  `classifyMutationError` drives every mutation notice. Only explicit refusals
  (or `retrySafe: true`) count as refused: `INTERNAL_ERROR` on a prompt becomes a
  review item instead of an automatic queued resend, a failed `sessions.prompt.bind`
  keeps the draft without wedging the session (the surface is bound once per
  connection), and an unconfirmed steer the daemon no longer holds can be
  dismissed with `d`. A crashed non-read control-plane method now answers
  `INTERNAL_ERROR` with `retrySafe: false` (#616).
- `agent` delegation is bounded: a synchronous run or join lends the calling
  run's gateway permit while it waits (`LemonGateway.Slots.suspend/2`,
  `resume/3`), so parents waiting on children and delegation chains no longer
  stall admission under `[gateway].max_concurrent_runs`. Joins honour
  `timeout_ms` (default 120000) instead of waiting forever. `BudgetEnforcer`
  refuses delegations from an exhausted parent, reserves each child, sends its
  token/cost limits with the request (the child session stops when it would
  exceed them) and charges its usage back. Aborting the delegating run or a
  synchronous timeout aborts the child through `RouterBridge.abort_run/2`. (#668)
- Coding-agent durable stores (tasks, run graph, parent questions, processes)
  keep their live table when their owner crashes: `CodingAgent.RuntimeTables`
  is the ETS heir and the restarted owner reclaims it, so in-flight tasks stay
  running and their later finishes are accepted. Restart normalization now
  applies only at boot (first start, application restart or clean stop). The
  run graph also marks `:queued` runs `:lost` at boot and persists it, so a join
  returns instead of hanging, and marks queued/running runs idle for
  `:run_graph_stale_ttl_seconds` (default 7 days) `:lost`. `ProcessStoreServer`
  no longer runs caller closures, replies `{:error, :store_unavailable}` instead
  of exiting on storage failure, and starts after `ProcessManager`, so a store
  restart no longer kills running (including foreground) commands. (#677)
- An interrupted `lemon update` (killed, crashed, or halted mid-download) no
  longer leaves `~/.lemon/updates/.operation.lock` behind and every later update
  failing with "Another update operation is active". Update operations use the
  shared owner-recording lock, so the next command recovers a dead holder's lock
  (and logs it) and removes stranded `.partial` staging directories; a live
  holder still blocks (#683).
- The Docker runtime image ships `procps`, so cross-process locks (Telegram
  polling, skills metadata, updates, usage state) can verify holders inside the
  container; boot logs an error when `ps` is missing, and the image smoke test
  takes a lock. A lock acquisition no longer forks `ps`/`id`: the process's own
  identity and uid are captured once at boot (from `/proc/self` on Linux) (#684).
- TUI live replay runs again on current daemons: the client reads the snapshot
  cursor from `consistency.eventCursor` (validated; an unreadable cursor keeps
  the session waiting for a snapshot), buffers `session.event` batches that race
  a snapshot and applies those past its cursor, and spaces snapshot reads of a
  session at least 250 ms apart. `sessions.snapshot` no longer returns
  `snapshot_raced` when only the event cursor moved between its two owner reads
  (#628).
- A TUI session whose replay or snapshot recovery failed no longer stays
  stranded (frozen transcript, `busy` stuck, queued follow-ups never sent): one
  per-session sync state replaces the recovery flags, a failed attempt retries
  with bounded exponential backoff from the retained cursor, and the next live
  batch re-arms it immediately (#665).
- The TUI keeps session stores only for sessions it opened (focused, switched
  to, sent to or acted on): broadcast events for other sessions no longer
  materialize transcripts, start snapshot recovery or inflate unread/busy
  counts, and session-less events no longer land in the focused session.
  Approvals from unopened sessions still reach the approval panel. Each
  transcript keeps its newest 400 blocks, the duplicate per-run text buffer is
  gone, sealed runs beyond the newest 16 release their per-run state, and
  per-session caches are released with the session (#691).
- Stopping a running kanban board from the web Automation page no longer fails as
  stale on every attempt: the dispatcher's control revision now covers only
  operator-visible board/task state, not the lease expiry it renews each tick (#658).
- Telegram and Discord `/goal continue` and `/goal loop once` no longer block the
  transport for the whole judge and continuation (or crash it on a call
  timeout): the chat gets an immediate acknowledgement and the verdict and run ID
  as a follow-up; a timeout is reported as an unknown outcome (#659).
- Media jobs never outlive their tool call: on timeout, abort or caller exit the
  supervised job owner kills the provider task and records it `cancelled` instead
  of leaving it `running` and billing after the tool reported failure; the wait
  uses one fixed deadline that unrelated messages cannot extend, and the
  timeout error names the job id (#664).
- Model streams no longer report a truncated response as finished: Chat
  Completions, Responses, Codex, Bedrock and the Gemini providers fail a stream
  that ends, disconnects, idles out or sends a malformed event before the
  provider's terminal event with a retryable transient error, instead of
  completing it — possibly as a tool call with half-written arguments. Gemini
  events split across network frames are no longer dropped (#636).
- A tool call streamed with an empty argument delta (Anthropic's no-argument
  calls) is read as `{}` instead of spending a continuation on
  `malformed_tool_arguments`, and stream rules scan a tool call that arrives
  as one large delta (Gemini) instead of failing the run with
  `delta_too_large`; a rule that cannot evaluate output now fails only that
  attempt and still records its usage (#639).
- Azure OpenAI Responses streams through the shared provider transport: it
  retries 429/5xx and transport failures before the body per the provider
  retry policy, reports classified errors without dumping the HTTP response,
  cancels its response on every exit and no longer ends or fails on unrelated
  `{ref, :done}`/`{:error, _}` messages. Azure settings are read only from
  `provider_options.azure_openai_responses` (the resolved API key wins over
  `api_key`); the `azure_*` keys in `thinking_budgets` are no longer set or
  read — **Breaking** for callers that passed Azure overrides there (#680).
- Cron: `jitterSec`, `timeoutMs`, `maxRetries` and `retryBackoffMs` must be
  integers within shared bounds (0–86,400 s; 1 s–1 h; 0–10; 0–1 day) on add and
  update through the API, agent tool and blueprints; the agent tool rejects bad
  values instead of silently using defaults. Retry and schedule timers are
  capped at 5 minutes, so one bad job can no longer crash-loop the scheduler
  (#657). **Breaking** for callers that sent values outside those ranges.
- Cron: a scheduled run claimed but never submitted (restart during jitter,
  worker crash before submit) is released as a retryable failure with a
  `claim_released` audit instead of locking its job as `outcome_unknown`;
  aborting such a run no longer calls the router (#624).
- Cron history: the core store sweep no longer deletes cron runs after 48 hours,
  so running and outcome-unknown runs and pending retries survive;
  `automation.run_retention_per_job` is now the only run-history limit. The
  cron audit log is capped at the newest 10,000 events, pruned hourly, and
  `cron.audit` pages with `beforeMs`/`nextBeforeMs` (#675).
- Channel replies that hit a sentence end near the chunk limit no longer crash
  or hang the outbox: the chunker counts sentence breaks in graphemes, always
  makes progress and rejects a non-positive chunk size, and the outbox splits
  replies in the enqueueing process instead of its queue owner (#627).
- Telegram replies are sized by their rendered UTF-16 length (and their
  Markdown source), so padded tables and ZWJ emoji no longer exceed the
  4096-unit limit and get rejected. Splitting never cuts a code fence or a
  table row: oversized fences become several closed fences and oversized
  tables repeat their header in every message (#651).
- Honcho no longer auto-retries calls that change remote state: a slow
  dialectic question (`honcho_reasoning`, the dialectic cadence) is billed once,
  and a timed-out message upload or conclusion write is never duplicated. Such a
  call that got no answer reports that its outcome is unknown. Reads still retry
  transient failures, with a server's `Retry-After` capped at one second per
  pause and two seconds per call (#622).
- A memory transfer whose apply fails definitely (the destination changed after
  the preview, an identity conflict, the destination's preference lock was busy,
  or any verified rollback) now reports that reason instead of
  `transfer_pending`, removes its `.memory-transfer-*` staging directory from the
  agent workspace and frees the mutation id, so the same transfer can be
  previewed and applied again; only genuinely uncertain outcomes stay pending.
  The transfer journal no longer keeps memory after it is gone: a frozen source
  snapshot (summaries, preference facts, `USER.md`/`MEMORY.md` bytes) is deleted
  once the receipt is recorded, when any document it captured is deleted, erased
  by scope or aged out, and after the new `transfer_ttl_ms` Store setting
  (default 24 hours, capped at `retention_ms`) (#623).
- An agent run whose loop forwarder dies (killed, linked exit, failed state
  call) now delivers exactly one terminal `{:error, {:loop_crashed, reason}, _}`
  event, stops the run and leaves the agent idle, so a coding session no longer
  stays `:session_busy` and router run streams complete (#638).
- Tool tasks no longer outlive their agent loop: when the loop is killed,
  raises, or its `Loop.stream/4` consumer stops, the run's abort signal is set
  and pending tools (bash, writes, external calls) are terminated after a short
  grace instead of running on unbounded. Per-tool deadlines are enforced even
  when the loop is stalled (#681).
- `bash` selects the code-mode Python stream relay only when code-mode is
  actually enabled (`enabled: true` and the `code_mode` profile, via
  `CodeMode.enabled?/1`); a disabled `code_mode` profile stays on managed bash,
  and a missing `python3` returns a clear error instead of crashing the call.
  Code-mode remains opt-in per the #598 evaluation (#674).
- A Tern browser pane reconnects to the daemon after its client dies (daemon
  restart or socket error) instead of failing every later request with
  `:closed`; an unopened pane whose daemon is gone falls back like any other
  unavailable Tern connection (#661).
- Remote (named-node) runs no longer abort on event size, delta count or
  delta rate: oversized tool actions (for example a 128 KiB `write`) and
  checkpoint path lists are elided to the event budget, long deltas are split
  at UTF-8 boundaries, deltas that queue behind a slow acknowledgement coalesce
  (bounded by bytes), and the 10,000-delta cap is gone. The completed answer
  is the run's own answer, not a concatenation of streamed deltas (#635).
- Named-node `node.process.*` no longer stops admitting work after 1,000 runs:
  terminal receipts (`completed`, `cancelled`, `failed`) fence their ID for 24
  hours and then retire, only unresolved `running`/`outcome_unknown` receipts
  count toward the 1,000 limit, a spawn or pre-exec failure is reported as the
  new terminal state `failed` instead of `outcome_unknown`, and operators can
  prune receipts preview-first with `ProcessService.prune/2` (#679).
- Instruction files, `@` imports and rule files are bounded and cached: each
  instruction file contributes at most 64 KiB and all of them 256 KiB; rule files
  are read up to 64 KiB, always-apply bodies share 128 KiB, at most 256 rule
  files are read and rulebook descriptions are one line of at most 300
  characters. Truncation leaves a marker naming the file and is logged.
  Sessions no longer re-read every source on each turn: reads are cached per
  session and revalidated by file stat, so an unchanged turn reads no
  instruction or rule file and an edit still reaches the next turn.
  `[:coding_agent, :prompt_sources, :read | :load]` telemetry reports loader
  reads, bytes and time (#693).
- The assistant workspace is seeded from its templates once, by the first
  chat/persona session (marked by `.lemon-workspace-seeded`), instead of on
  every session start: a deleted `BOOTSTRAP.md` (whose template asks to be
  deleted when done), `HEARTBEAT.md` or `memory/topics/TEMPLATE.md` is no longer
  re-created. Templates are copied via a temporary file and rename, so a failed
  copy leaves no partial file; coding sessions no longer write the workspace, and
  an unwritable assistant home no longer fails session start (#672).
- Rule frontmatter (`.cursor/rules/*.mdc` and the other rule sources) is parsed
  without `YamlElixir.read_from_string`, which called
  `Application.start(:yamerl)` on every read and could deadlock session start
  against a stopping application. Skills, subagents and rules now share one
  parser (`LemonSkills.Frontmatter`); a rule or skill manifest that repeats a
  frontmatter key, or a rule whose frontmatter exceeds 16 KiB (skills: 64 KiB),
  is rejected with a warning instead of resolving last-wins (#671).
- The `lsp` tool starts one language server per workspace instead of one per
  member project: the outermost Mix umbrella, Cargo, npm/yarn/pnpm, Go or uv
  workspace inside the working directory is the root (else the nearest marker).
  `LemonLsp.ServerManager` keeps at most eight servers live, evicting the
  least-recently-used one without an in-flight request and failing with
  `{:error, :lsp_session_limit}` when all are busy; `status/0` and the doctor
  report `max_active_count` beside `active_count` (#690).
- The `lsp` tool refuses a non-UTF-8 file with a clear error instead of crashing
  the language-server session it shares with other leases, restarting it and
  telling the model to retry. `LemonLsp.ServerManager` returns
  `{:error, :invalid_document_encoding}` for such documents,
  `{:error, :invalid_message_encoding}` for unencodable messages, and
  `{:error, {:session_crashed, class}}` (never the raw exit reason) for any other
  session exit during a call (#663).
- Session reset no longer exits its caller with a call timeout when aborting
  the active run takes most of the session's 5-second abort wait (#499).
  once the receipt is recorded (on a remote source node through its new
  `memory.transfer.release` worker method), when any document it captured is
  deleted, erased by scope or aged out, and after the new `transfer_ttl_ms`
  Store setting (default 24 hours, capped at `retention_ms`) (#623).
- The Store publishes a table as read-cached only after its warm-up read
  succeeded, and clears the published list when a store starts or stops. A table
  whose warm-up failed stays uncached, so reads reach the backend and surface
  its error instead of an empty mirror (`RunStore.list_sessions`, channel known
  targets and gateway progress no longer read as empty). SQLite table reads
  decode every row and report the number of corrupt rows (#618).
- Fixed-ID run receipts distinguish definite rejection from unknown admission.
  Router-owner loss reconciles unclaimed handoffs without replay, and queued
  runs recheck durable cancellation before starting (#81).
  Receipts remain terminal after run history is evicted; when the router is
  stopped, an unresolved handoff cannot be mistaken for a definitive outcome.
- Bundled WASM tools keep shared and tool-specific WIT metadata sections distinct,
  preventing component-linker failures when building the command tools.
- `kill_process` reports `killing` instead of `running` when the signal ends the
  workload before the root process's exit has been observed.
- Source and packaged Erlang distribution now install the cookie before the
  listener starts, without putting it in any VM or release-client argv. OTP 29
  expands both `ERL_FLAGS` and `vm.args` into argv, so neither is a safe cookie
  channel. The private `0600` cookie and explicit environment selection remain;
  source `--cookie` is removed (#551 follow-up).

- TUI session-event replay consumes the server's canonical `entries` page field;
  shared server/client wire fixtures guard cursor, batch and pagination shapes (#560).

- Concurrent extension loads no longer silently return no extensions when the
  reload lock is busy; they wait a bounded time and log an explicit error.
  Reloading one session's extensions no longer purges another session's.
- Debugger RPC operations release their abort subscription and caller monitor
  before replying.
- Interrupted tool calls (abort, timeout, crash, reload repair, steering skip)
  report one structured `unknown` or `not_started` outcome and tell the model
  not to repeat an uncertain call (#552).
- Acknowledged channel outbox deliveries survive a crash with their idempotency
  keys and order (#557); the send path makes no synchronous calls into other
  processes and delivery concurrency is capped (#582).
- Telegram long polls run in a supervised task so the transport stays responsive;
  retries belong to the outbox only (#580).
- Discord's Nostrum client is supervised and configured at boot; WhatsApp has one
  reconnect authority whose give-up is visible to health checks (#581).
- The hot-reload documentation describes the reload that ships (#607).
- ACP no longer keeps a shadow session table that wrote resume tokens back into
  `ChatState`: ACP session metadata lives on the canonical
  `SessionMetadataStore` record, so `SessionLifecycle.delete/2` removes it and
  ACP touches after a reset never recreate chat state. A store write failure
  after prompt submission returns the run ID with `retrySafe: false` instead of
  raising. ACP sessions created before this release are not carried over;
  start a new ACP session (#652).
- The local browser driver never starts a request after its deadline, never
  overlaps an abandoned one and re-runs only read-only methods after a closed
  tab. A side-effecting browser action (click, type, navigate, upload, ...)
  that did not confirm is reported to the model as an unknown outcome and is
  never retried (#625).
- The local browser driver retries a failed browser start on the next request,
  recycles itself when the selected provider, endpoint or profile changes while
  idle (instead of failing with `Browser identity changed`), and the `local`
  provider honours `LEMON_BROWSER_ATTACH_ONLY`: it is unavailable rather than
  launching Chrome (#660).
- **Breaking:** the managed local Chrome now uses Lemon's own profile,
  `~/.lemon/browser/default/user-data`, instead of `~/.openclaw/browser/openclaw/user-data`
  (`OPENCLAW_STATE_DIR`/`CLAWDBOT_STATE_DIR` and `--openclaw-profile` are no
  longer read; the driver takes `--browser-profile NAME`). Sign-ins made in
  the old profile do not carry over; point `LEMON_BROWSER_USER_DATA_DIR` at a
  copy to keep them. Lemon launches it on a free DevTools port read from
  `DevToolsActivePort` and never adopts a browser listening on
  `LEMON_BROWSER_CDP_PORT`; the driver stops that Chrome when its runtime goes
  away (stdin EOF, stdout EPIPE), and an invalid executable fails the request
  instead of killing the driver (#689).
- The telemetry catalog names the emitting function for every event instead of
  stale line numbers, and now matches the code: `[:lemon, :run, :stop]` is also
  emitted by the router for runs terminalized before an executor owns them,
  `[:lemon_agent, :tool_task, :error]` lists its current reasons (including
  `:skipped`), approvals resolve with `:cancelled` too, and the metrics example
  uses the real `lemon_ai`/`lemon_agent` prefixes. The assistant bootstrap page
  documents the real launchers (`source`/`release`) and runtime profiles
  (`runtime_min`/`runtime_full`) instead of three execution modes that were
  never implemented, and the long-running-harness validation command names
  existing tests (#735).
- Design records (model selection, omp port ledger) moved out of the
  architecture navigation into a "Design records & history" section (#735).
- A conversation no longer hangs when its gateway run dies before it starts
  (killed while waiting for an execution permit, lost permit authority or
  unreadable run state): the router monitors the run from acceptance,
  terminalizes it once and starts the next queued message. An unknown
  submission outcome keeps the run's event subscription and adopts the run
  under its fixed ID instead of failing it; a store error while recording
  terminal evidence no longer drops the final answer; and a timed-out crash
  recovery or carryover replay call leaves only that run pending instead of
  skipping the rest of the boot's recovery (#641).
- A slow native follow-up issuer callback no longer stalls every router
  submission and abort: the callback, durable-receipt compaction and presence
  table reads run outside the run orchestrator's mailbox, and per-submission
  routing-feedback config reads use the config cache instead of parsing TOML.
  Callers fix run IDs before the call, and submit uses the same 20 s window as
  abort, so a timed-out submit is outcome-unknown for that request only (#645).
- A malformed run submission (empty or missing session key, unknown queue mode,
  non-atom origin) or an unreadable config is refused with a definite
  `:invalid_submission` / `:config_unavailable` before the durable admission
  claim, instead of crashing the run orchestrator and restarting every queue.
  The control-plane `agent` method rejects an empty or malformed `session_key`
  as invalid params (#646).
- `cron.run` and `cron.abort` report an unknown outcome (an unresolved earlier
  run, or a scheduler call that timed out or exited) as `UNAVAILABLE` with
  `RUN_OUTCOME_UNKNOWN`/`ABORT_OUTCOME_UNKNOWN`, the job or run ID and
  `retrySafe: false`, instead of a retryable internal error, and log only a
  bounded failure label (#620).
- Streamed answers finalize inside the answer coalescer's serialized loop, so a
  delta still queued at completion can no longer edit a long (multi-message)
  Telegram answer back to one truncated chunk after the final, and a successful
  finalize delivers the answer once instead of up to three times. A finalize
  that delivers nothing returns an error and records `:answer_finalize_failed`
  instead of reporting success (#644).
- Router answer and tool-status coalescers no longer live for the VM lifetime:
  a run that never streamed starts none, finalizing drops the run's text and
  actions, and an idle coalescer whose run is finalized or gone stops after a
  5-second grace (`:lemon_router, :coalescer_retire_after_ms`). Status surfaces
  retain at most 64 actions (older ones are counted as omitted) without their
  args or full results, and the streamed answer tail is capped at the
  65,536-byte ingress message budget instead of 100,000 bytes. 500 sequential
  runs in one conversation previously left 502 coalescer processes
  (≈7.1 MB); they now return to zero (#685).
- Web chat has one transcript pipeline: full-text `chat.history` once per open,
  then sequenced `session.event` batches after the `sessions.snapshot` event
  cursor, with `sessions.events` replay for gaps. Streaming no longer stops at
  the first snapshot or resets every 2 s, long answers and edit diffs stay
  complete after recovery, and the snapshot is state only (at most one read per
  run) through the live run reducer, so **Stopping** and queued follow-ups
  survive it. `not_found`/`unknown` snapshots are explicit and never polled;
  failed reads back off. The Subagents tab shows the snapshot's child runs
  (#653).
- Web chat approval cards keep their command, path, arguments and plan after
  recovery: the snapshot decides which approvals are pending and each card keeps
  (or rereads) the full `exec.approvals.get` record. `sessions.snapshot`
  approvals now carry `command`, `path`, `plan` and an argument preview with
  `truncated`/`planTruncated` flags; a truncated card or plan cannot be approved
  until the full request loads (#654).
- Each native task child now has its own supervised owner instead of one
  node-wide coordinator: a child whose session shutdown blocks no longer stalls
  any other child's cancel, message or completion, the worker sends its
  completion followup before its owner sees the turn end (so a slow or
  restarted owner can neither lose nor repeat it), a crashed owner adopts its
  live worker and session (a second crash terminalizes the child), and terminal
  children are pruned after five minutes (#634).
- A joined task's status, output and error, the Agent Hub and child
  messaging now all read the task's stored record; a run-graph row or owner
  phase can no longer report a task differently from its stored result. A
  completed child that is later cancelled or whose owner gave up stays
  "completed" (#634).
- Task slots are re-entrant per lineage, so a child that waits on its own
  descendants no longer deadlocks the eight-slot pool; `/bg` sessions use their
  own `background_run_max_concurrency` pool; joins without a timeout yield after
  `task_join_timeout_ms` (default 30 minutes) instead of waiting forever (#631).
- A Redirect or stream-rule injection no longer cancels the children launched in
  that run or aborts its task joins; only an abort does (#633).
- A task cancelled before it started (or whose parent died) now terminalizes its
  run graph, budget and progress binding too, so a later join returns at once;
  completion notices come from the stored task record ("was cancelled" when a
  cancellation won), a child cancelled by its parent's abort sends none, joins
  suppress the notice of every task they returned, and a completed child shows
  "completed" in the Agent Hub after a restart instead of "failed" (#673).
- Control-plane reads fail closed: an unreadable store or runtime makes
  `exec.approvals.get`, `config.get`, `logs.tail`, `sessions.preview`,
  `chat.history`, `session.detail`, `cron.runs`, the task lists, ACP session
  listing/lookup and A2A task reads return `UNAVAILABLE` instead of empty or
  not-found results; `cron.status` reports unreadable sections with `null`
  counters and `enabled: null` instead of a disabled scheduler; and an execution
  node whose registry read fails gets a retryable `UNAVAILABLE` instead of being
  parked as `node_not_found` (#619).
- A native session that is slow to start (for example while connecting its
  profile MCP servers) no longer blocks other session starts, stops or listing:
  the session supervisor only admits journal ownership and the session finishes
  initializing in its own process. Root checkout locks only the registry lookup
  and idle-cap decision, so a slow `prepare_root_turn` no longer times out other
  conversations, and `lemon sessions maintain` previews take no lock; confirmed
  runs hash candidates before taking the session-root lock (#632).
- Web blueprint activation that raises, times out or returns an unparseable
  reply no longer says "Nothing changed": a failed call shows an unknown
  outcome (may have been applied, not retried) and locks that bundle/profile
  until a fresh preview reads it; an unparseable success reports "applied;
  details unavailable"; both refresh the catalog. Inspect, validate and preview
  report unconfirmed results as such (#621).
- MCP Streamable HTTP and legacy SSE clients run each request in a supervised
  worker: a slow tool call no longer blocks `state/1`, status probes or other
  calls (so the MCP source stops killing busy clients), a deadline returns
  `:outcome_unknown` after the request worker is stopped, and a 401 refreshes
  the grant once in the background instead of freezing the client. OAuth moved
  to `LemonMCP.HTTP.OAuth` (#662).
- The MCP source releases a project's MCP servers when the last session that
  discovered them exits and keeps at most 16 project scopes loaded
  (`:mcp_max_project_scopes`), so stdio subprocesses no longer accumulate per
  directory. Opening a session elsewhere no longer clears other sessions'
  cached MCP tools. Session start serves the cached snapshot and waits at most
  10 seconds (`:mcp_discovery_wait_ms`) for servers still connecting, which now
  connect in parallel; failed startups use the same jittered backoff and crash
  breaker as lost connections instead of retrying on every tick (#688).
- A watchdog stop or keep-alive cancel no longer lets the next queued message
  fail with `:session_in_use` while the cancelled run's executor is still
  draining: watchdog and keep-alive cancels take the normal abort path and wait
  for the gateway's real completion, which reports the real reason in
  `meta.cancel_reason` (`:run_idle_watchdog_timeout`, `:user_requested`) instead
  of `:run_watchdog_timeout`. A busy engine session refuses the gateway start
  synchronously and the router retries it within its pre-start deadline.
  Gateway cancellation is an asynchronous request that holds the permit and
  claim until the executor exits or the 15-second drain deadline passes, and
  completion persists before releasing them exactly once (#643).
- Compaction (auto, manual and overflow recovery) works again after a
  checkpoint/rewind or branch summary: journal entries are read through the
  canonical message deserializer, so a `branch_summary` entry no longer crashes
  token estimation, and compaction summaries keep each tool result's tool
  name (#629).
- Sessions no longer stay busy after overflow recovery or a compaction
  recovery-band block: abort during recovery ends the run with `canceled`,
  steering or follow-ups journaled while the summary runs no longer strand the
  run, a recovery-band block releases the session for `/compact` and the next
  executor turn, and a late terminal event from an earlier agent run can no
  longer end (or let a second prompt overwrite) a newly accepted prompt (#630).

### Removed

- **Breaking:** the disabled-by-default WASM tool stack and the `tool_auth` tool
  are retired (#707). Decision: epic #543 kept comparable surfaces opt-in
  (#598, #600, #604); this one is retired instead because it had no consumer.
  It shipped only Ethereum Foundry wrappers that CI never built, and keeping
  it would have needed trust-gated loading, non-overwriting secret import, a
  monitored sidecar and a real exec timeout. `tool_auth` was
  registered in every session even with WASM off and could overwrite a named
  secret from an environment variable. Removed: the `native/` Rust runtime and
  tool crates, `CodingAgent.Wasm.*`, `CodingAgent.Session.WasmBridge`,
  `CodingAgent.Tools.ToolAuth`, the `wasm-runtime` CI job, `LEMON_WASM_*`
  variables, the `wasm` extension-manifest host type and `docs/tools/wasm.md`.
  `[runtime.tools.wasm]` is no longer read; delete it. Tool precedence is now
  built-in > extension > MCP. OSV no longer scans the deleted `native/` Cargo
  lockfiles, and their three accepted RUSTSEC findings are removed from
  `osv-scanner.toml`.
- **Breaking:** the `config.get` and `config.set` control-plane methods and
  their `:system_config` store. Nothing read the stored values (setting
  `logLevel` changed only what `config.get` reported); configuration lives in
  `config.toml` (#712).

- **Breaking:** the opt-in session advisor (#600) is retired: `CodingAgent.Advisor`,
  its `AdvisorSupervisor` child and the `advisor:` session option are removed.
  No shipped caller enabled it; `start_session(advisor: ...)` now fails with
  `{:error, {:unsupported_option, :advisor}}` instead of starting a reviewer (#705).
- **Breaking:** `LemonAgent.Proxy` (SSE proxy `stream_fn`) and `LemonAgent.Context`
  (size estimates, truncation, `make_transform/1`) are deleted together with
  `docs/context.md`, the `req` dependency of `lemon_agent` and the
  `[:lemon_agent, :context, :size | :warning | :truncated]` telemetry events. The
  agent loop no longer JSON-encodes the whole history before every request (#708).
- **Breaking:** `bin/lemon-control-plane` is removed; use `./bin/lemon start`
  or `./bin/lemon daemon`. `./bin/lemon-gateway` now runs `./bin/lemon start`
  (node name `lemon_gateway` by default): it reuses a healthy runtime on the
  control port instead of starting a second router and duplicate Telegram and
  Discord adapters, starts the full runtime when none is running, and no longer
  runs `mix deps.get` (#701).
- **Breaking:** the WhatsApp channel adapter, its Node/Baileys bridge
  (`whatsapp_bridge.mjs`), renderer, access-control helpers and model-policy
  child, plus the router's `whatsapp` tool-status branches. It had no
  `[gateway.whatsapp]` config path, so no deployment could start it, yet it was
  registered and reported as a configured channel. Every remaining built-in
  adapter is startable from canonical config; the shared Node port bridge keeps
  only XMTP's automatic restart mode (#699).
- **Breaking:** the OpenAI-compatible `/v1` API (`/v1/models`,
  `/v1/chat/completions`, `/v1/responses`, `/v1/runs`), the single-shot HTTP
  `POST /acp` endpoint, `LEMON_OPENAI_COMPAT_API_TOKEN` (and its
  `LEMON_OPENAI_COMPAT_TOKEN` alias), `LEMON_OPENAI_COMPAT_IMAGE_URL_*`,
  `LEMON_ACP_API_TOKEN` and `LEMON_CONTROL_PLANE_REMOTE_HTTP`. No in-repo or
  known external client used them and support policy made no compatibility
  commitment. Editors use `lemon acp` over the unchanged loopback `/acp/ws`;
  off-loopback peers reach only `/ws` and `/healthz` (#711).
- **Breaking:** `lemon bot https`; use `lemon-bot https` (#723).
- **Breaking:** write-only and unreachable tool features (#706): the
  `report_issue` tool, `read file.json?q=` JSON queries, `write` into archive
  members (`bundle.zip:member`) and SQLite tables (`app.db:table`), the
  `notes://` URL scheme, `FEATURE_REQUIREMENTS.json` progress (the `requirements`
  block of `sessions.active.list` harness snapshots) and the write-only todo ETS
  projection. `todo` is the only todo tool, `ls` the only directory listing
  (`read <dir>` now points at `ls`), and `extensions_status` is status-only: its
  `reload` action, which a model turn could never run, is gone.

- `LemonChannels.ModelPolicy`, `LemonChannels.ModelPolicyStore`,
  `LemonChannels.ModelPolicy.Route`, `LemonChannels.ModelPolicy.CLI` (now
  `LemonCore.PolicyStore.CLI`), the Telegram `StateStore` session-model,
  default-model and default-thinking accessors, the Discord session-model table
  and the WhatsApp session-model ETS owner (#714).
- **Breaking:** the unwritten policy scopes. `LemonCore.PolicyStore` keeps only
  the session row (`fetch_session/1`, `put_session/2`, `update_session/2`,
  `delete_session/1`); `put_agent/2`, `fetch_agent/1`, `put_channel/2`,
  `fetch_channel/1`, `put_runtime/1`, `fetch_runtime/0` and `delete_runtime/0`
  are gone, and the router no longer reads `:agent_policies`,
  `:channel_policies` or `:runtime_policy` (nothing ever wrote them). Admission
  reads the session row once per run for model, thinking level and tool policy.
  The exec-approval node grants (`get_/put_node_policy`), the global and node
  policy maps (`fetch_global_policy_map/0`, `get_/put_node_policy_map`) and the
  `list_*_policies/0` helpers are removed; `exec.approvals.get` drops its
  always-empty `policy` field, `summary.policyCount` and
  `summary.cleanup.includesPolicy`. A guard test fails when a policy table is
  read without a production writer (#709).
- **Breaking:** `lemon_ai` no longer ships omp broker/token/config modules, ambient
  Claude Code/Codex CLI/Kimi device-id discovery, provider `get_env_api_key/0`
  tables or Vertex `gcloud`/`GOOGLE_APPLICATION_CREDENTIALS` minting; they live in
  `lemon_agent`'s model runtime, which injects the results (#719). Vertex tokens are
  minted once per source with caching and a deadline instead of a `gcloud` spawn per
  request, and a refreshed Claude Code login is written back atomically with a
  private (0600) temporary file, so a crash leaves the previous file intact.

- **Breaking:** the `LemonMemory.Provider.search/2` callback, `LemonMemory.Providers.search/2`,
  `LemonMemory.SessionSearch.search/2`, `LemonHoncho.MemoryProvider.search/2`, the
  recall tool's `:search_fn` option and the `ProviderCase` search compliance tests.
  Memory providers are write targets only (`put/2`). `recall` now filters ownership
  in SQL before its result limit for legacy sessions too, so `scope: project` no
  longer comes back empty when matches exist, and it never pays for a remote
  provider search whose results it discarded (#656).
- **Breaking:** the unreachable `controller` and `hybrid` browser backends,
  `ControllerBroker`, `HybridRouter`, their provider ids/status strings and the
  `LEMON_BROWSER_HYBRID_LOCAL_BACKEND`/`LEMON_BROWSER_HYBRID_PUBLIC_BACKEND`
  settings. Configs naming them now fail validation instead of reporting a
  backend that could never serve a request (#702).
- The unenforced `sandbox` tool-policy field; legacy input is ignored with a
  warning and never changes authority (#605).
- `[:lemon, :control_plane, :event_bridge, :dropped]` and
  `[:lemon_agent, :subagent, :end]` are no longer documented: no code emits
  them. Attach to `[:lemon, :control_plane, :event_bridge, :broadcast]` for
  control-plane fan-out (#735).
- `LemonCore.Store.JsonlBackend` (lemon_core 0.3.0). Run
  `mix lemon.store.migrate_jsonl_to_sqlite` before upgrading a JSONL store (#608).
- Obsolete Telegram `outbound_send_delay_ms` and poller stale-time settings (#580).
- **Breaking:** `[gateway.queue]` (never read; now ignored with a warning) and the gateway's
  second config plane: `LemonGateway.Config`, `LemonGateway.ConfigLoader`,
  `LemonGateway.Cwd`, `LemonGateway.BindingResolver`/`Binding`,
  `LemonGateway.Project`, `LemonChannels.GatewayConfig` and
  `LemonCore.EngineInfoBridge.gateway_config/0`. Read `LemonCore.GatewayConfig`
  and `LemonCore.Cwd`. The voice config no longer falls back to
  `:lemon_gateway` application env keys (#617, #697).
- **Breaking:** MCP sampling, which could never produce a result. `LemonMCP.Sampling`
  and the `:sampling_policy`/`:sampling_handler` client options are gone, a
  server `sampling` config entry is ignored, no client handshake advertises
  `sampling`, and a server's `sampling/createMessage` receives method-not-found
  (#703).
- **Breaking (`lemon_ai` 0.3.0):** opt-in request hedging (#567) is retired
  (#696, decided under epic #543): its bounded live measurement showed no
  tail-latency win and nothing enabled it. `config :lemon_ai,
  LemonAi.CallDispatcher, hedging: ...` is no longer read and the
  `hedge_started`/`hedge_skipped` dispatcher telemetry is gone; delete the key.
  Model calls no longer make a synchronous call to a shared dispatcher process:
  provider failure summaries live in ETS.
- **Breaking** (coding_agent): the compaction-only `CodingAgent.Messages`
  user/assistant/tool-result/bash/compaction-summary and content structs,
  `Messages.get_text/1`, `get_tool_calls/1` and `total_tokens/1`; coding
  messages are `LemonAi.Types` structs plus `CustomMessage` and
  `BranchSummaryMessage` (#629).
- Uninvoked and broken proof scripts under `scripts/`: the offline named-agent,
  approval-recovery, multimodal-retry, task-worktree, provider-auth,
  stopped-plan and four duplicate probe-wrapper smokes,
  `scripts/verify_github_release_artifacts` and unused LSP fixtures. Their
  probes now live in the consuming apps' `test/support/probes`; ExUnit covers
  their scenarios. The manual, loopback-only
  `scripts/live_provider_ownership_smoke.exs` stays and loads its probe from there.
  `scripts/test quality` now runs every retained script self-test, the
  crash-model mutation-anchor check and a check that each umbrella module
  named by `scripts/*.exs` exists (#704).

### Security

- The OSV dependency scan is a gate: it uses OSV-Scanner 2.7.1 (2.3.5 failed
  against the current OSV API and reported "No issues found"), scans every
  shipped lockfile including `apps/lemon_web/assets` and `products/lemon_bot`,
  and fails on any finding not accepted, with a reason and expiry, in
  `osv-scanner.toml` (#734).
- db_connection 2.10.2 → 2.10.3 (EEF-CVE-2026-133555: code execution through
  the `:log` option of a forged `DBConnection.Stream`), found by the OSV gate.
- phoenix 1.8.16 → 1.8.17 (EEF-CVE-2026-128361, EEF-CVE-2026-129344) and
  phoenix_live_view 1.2.13 → 1.2.15 (EEF-CVE-2026-126334: a LiveView joined
  without a `url` skipped its `live_session` `on_mount` hooks, which gate the
  LemonWeb operator pages); LemonWeb's vendored Phoenix and LiveView client
  bundles match the new releases, and their OSV acceptances are removed.
- Archive reads and in-place archive writes (`read`/`write` on `x.zip:member`,
  `.tar`, `.tar.gz`, `.tgz`) and SVGZ decoding now inflate through one
  streaming, abort-aware bound: members are rejected as soon as decoded bytes
  pass their declared size or `:format_max_member_bytes`, compressed TARs and
  write-side rebuilds stop at `:format_max_decoded_bytes` (256 MiB), and
  archives over `:format_max_archive_entries` are refused, so a zip/gzip bomb
  can no longer exhaust node memory (#678).
- Delegated and requested tool policies can no longer weaken their parent
  (#71, #72, #73): a request, child or execution-node wire policy cannot waive
  an approval gate that depends on call arguments (for example `write` with
  `diagnostics` under `approval_mode = "write"`) with a per-tool `never`, and
  cannot enable `workspace_read_exempt` the parent or operator policy lacks.
  Router admission narrows operator layers with a request's `tool_policy`
  instead of layering it.
- Model file tools, browser and media outputs and checkpoint restore refuse
  Lemon operator state (`~/.lemon`, the agent directory, configured
  config/key/store/checkpoint/bot paths, extension roots) and the toolchain
  locations Lemon executes; global `skill_manage` changes always need approval.
- `LemonCore.CredentialPaths` keeps Lemon credentials (node tokens, secrets
  key and store, cookie, `env`, web secret, control-plane tokens, bot keys) out
  of every model-directed reader, including rich-read selectors, search, LSP,
  media inputs and browser `file:` pages; child processes and language servers
  get a scrubbed environment; `browser_evaluate` runs only on `http:`, `https:`
  and `about:` pages.
- Confined file I/O is bound to directory descriptors through a new C helper,
  `LemonCore.ConfinedFS`, built by `mix compile` (optional for Hex consumers,
  which then fail closed), so a directory swapped for a symlink after
  validation is refused.
- LSP workspace edits recheck every operation and refuse targets outside the
  workspace; renames never replace an existing file unless `overwrite` is set.
- A repository can no longer set `model_routing`, profile models or
  `secrets.yml`, and `.lemon/skills.json` can only narrow; project-chosen
  models, roles and thinking levels (including through personas and inherited
  parents) pass the operator's `[runtime.task]` per-call gate.
- Secret resolution fails closed: only a definite store miss continues to
  external sources or the environment. Undecryptable, malformed or expired
  records and store, master-key or lock failures return their error, and every
  credential consumer (model providers including Vertex and Bedrock, web tools,
  gateway SMS/voice/AI, Discord, XMTP, media tools, evals) stops instead of
  using another credential, so an ambient token can no longer verify Twilio
  webhooks.
- Cron jobs created by an agent record the creating session's effective
  policy; runs intersect it with the live chat policy, group floor and
  triggering policy. The cron tool reaches only jobs its session owns,
  `pause_all`/`resume_all` are operator-only, cron memory lives in
  `~/.lemon/cron_memory`, and cron runs cannot start goals, kanban work or
  peer messages.
- Goals record the setter's principal, policy and canonical root; judge and
  continuation runs stay inside them, block delegation tools, and are bound to
  the checked directory identity. Goals saved before this release must be set
  again.
- Webhook and A2A runs take channel policy from authenticated provenance and
  get the approval floor unless the integration or peer sets
  `trusted_automation = true` in the global config.
- `write`/`edit`/`patch` that run project diagnostics or formatters need exec
  approval; checkers run as managed, cancellable process groups, and
  repo-local tools need `runtime.tools.edit.repo_local_tools = true`.
- Automatic git commands use `LemonCore.SafeGit`: an operator-trusted binary
  (`[runtime] git_path` or system paths, Git ≥ 2.31) against a private Git
  directory with Lemon-written configuration.
- Remaining outbound clients (skill git and marketplace, Discord/Telegram/
  Twilio downloads, the updater) use pinned, capped, deadline-bound fetches;
  private git hosts need `[skills] allowed_private_git_hosts` and private
  update mirrors `[update] private_mirror = true`. These clients do not use an
  HTTP proxy.
- The raw operator `node.invoke` RPC is removed; remote runs keep their session
  busy until the node proves they stopped.
- `gateway.email`, `gateway.sms` and `gateway.voice` settings are fully
  validated; `tls`/`auth` must be `always`, `never` or `if_available`.
- Extensions and WASM tools load only from operator paths (relative entries
  resolve against `~/.lemon`; project `.lemon/extensions` and `.lemon/wasm-tools`
  never load). Sources are hashed and compiled from the same bytes, modules are
  owned per source, a failed load fails session start, and any module collision
  trips a runtime latch that refuses every tool, hook and extension provider
  until restart.
- WASM secret lookups use an internal host channel checked against the calling
  tool's `secrets.allowed_names`; the runtime and its `exec` commands no longer
  inherit Lemon's environment.
- New `operator.content` scope (default for operator tokens). Read-only
  control-plane methods and the event stream return metadata only; `config.get`,
  MCP previews and `doctor.run` details need `operator.admin`.
- OpenAI-compatible and ACP tokens are owned, confined API principals: own
  runs and sessions only, own session namespace and workspace, no approval
  relaxation.
- One outbound address policy and pinned fetcher (`LemonCore.Net`) for webhook
  callbacks, web fetch, URL context, MCP (including SSE), image URLs and the
  browser egress proxy: metadata and alias addresses refused, no implicit
  redirects, bounded deadlines and bodies.
- Browser: `file:`, `data:` and `blob:` documents need `allowLocalDocument`
  (exec tier) for navigation, reads and captures; cookie values need write tier;
  artifact paths are project-confined; attaching to an unlaunched browser needs
  `LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS`.
- Doctor output and support bundles apply one redaction policy (paths, ids,
  emails, phone numbers, hosts, URLs, names, exception text); config is exported
  as a settings projection.
- The assistant home and profile workspaces are never treated as projects:
  their instructions, rules, commands, personas and `.lemon/config.toml` are
  ignored; bootstrap files load only through the persona gate.
- Channel `/bg` runs use the agent, policy floor and workspace named by the
  session key; Telegram `/model` pickers and buttons bind to their opener; agent
  `poll`/`join` reach only the caller's tasks.
- Restricted tool profiles (`safe_mode`, `subagent_restricted`, `leaf_worker`,
  `no_external`) are allow lists over one tool catalog and deny unclassified,
  MCP, extension and satellite tools. Every tool source passes one final policy
  filter and approval gate, ACP "ask" covers every non-read tool, and
  `allowed_commands`/`blocked_commands` are enforced (best-effort) in bash, with
  `eval`, `debug`, `lsp` and `omp` refused while a list is set.
- `sessions.reset`, `sessions.delete` and `sessions.prune` take a durable
  per-session fence that blocks router admission, native follow-ups,
  `node.invoke` and gateway direct runs; remote work keeps a session busy until
  proven stopped, and history deletion is verified.
- Kanban dispatch uses Lemon-owned controller repositories under
  `~/.lemon/kanban/repos/<board>.git`; publishing needs an operator grant pinned
  to exact URLs, worker mutations are confined, and Discord `/kanban` is read-only.
- MCP OAuth binds discovery, endpoints and credentials to the configured server
  and an exact issuer. A configured refresh token requires `oauth.issuer`, and
  cached grants are reused only for the recorded issuer and client id.
- Computer use is off unless `[runtime.tools.computer_use] enabled`. Native-app
  and website approvals are once-only (lasting grants only for
  `lasting_grant_apps`), and local, interface-resolving, Lemon Bot and
  approval-channel web origins are declined.
- Exec approvals commit their receipt before any grant, and timed-out Store
  mutations report `:outcome_unknown` end to end, including execution-node relays,
  without automatic retry.
- `peer`, `task` and `agent` take identity only from the launching session;
  model-supplied `session_key`/`agent_id` and `interrupt` queue modes are
  rejected, and inbound A2A serves inbound records only.
- LemonWeb accepts exact trusted origins on `/live`, refuses foreign `Host`
  headers (421), drops dev reloaders and committed secrets (per-install secret in
  `~/.lemon/web_secret_key_base`), adds `LEMON_WEB_SECURE_COOKIES`, and reloads
  router profiles after every profile write.
- Tool results are untrusted unless an in-memory struct carries exactly
  `:trusted`; a final fence runs before every provider request, persisted results
  load untrusted, and memory files, contributed sections, child completions and
  branch summaries are fenced.
- Instruction files, `@` imports, rules, commands, personas and project skills
  load only from a validated trusted root (a real same-owner Git repository, else
  the working directory). Project stream rules need
  `[rules] allow_project_stream_rules`.
- Skills: one bundle layout policy, an audited set equal to the activated set,
  operator-side verdicts and exact-hash load grants (`lemon skill audit <key>
  [--approve]`), confined mutations, and a Hermes import through the audit.
  Upgrading: unchanged agent-directory installs are re-audited once in the
  background; edited, project and imported skills need `lemon skill audit`.
- TUI: untrusted text is sanitized on ingestion, and control, bidi and format
  characters are shown as markers (pi-tui's entity decoder is patched). `/reset`
  and switcher close preview and require `--confirm <exact key>`.
- SMS: webhook signatures are always validated. Inbox reservations are
  exclusive and released only explicitly or by operator `sms.inbox.clear`.
  Ingestion is atomic per MessageSid. Webhook per-integration `false` flags
  override global `true`, and media sends require physical containment.
- Admission, resume, prune and patch fail closed on unreadable policy, history
  or metadata. Idempotency claims keep their run id until reconciled; usage replay
  never double counts.
- Native sessions are bound to their creating chat. Checkpoint restores need
  durable single-use tokens, `/file` and `send_file` use physical containment with
  case-insensitive denies, `adminOnly` commands are enforced, and chat `/reload`
  is removed.
- A project `.lemon/config.toml` is untrusted: it may set only an allowlist of
  preferences (default provider/model/thinking, model roles and routing, TUI
  presentation, compaction, persona models, disclosure profile) and may only
  narrow policy (stricter `approval_mode`, lower budgets and caps, enable guards,
  disable features or LSP servers, intersect profile tool policy against the
  effective operator policy). Provider `base_url`/`location`/credentials, secret
  sources, web hosts and SSRF switches, executables, extension paths, routing
  pools, logging and update settings are operator-only; ignored keys are
  reported by `lemon config validate` and `lemon doctor`. The terminal client
  applies the same allowlist. `.env` autoload no longer reads the launch
  directory: only `~/.lemon/.env` or an explicit `LEMON_DOTENV_DIR`.
  **Upgrade:** move project-only operator settings and a launch-directory `.env`
  to the global config.
- Secrets: the master key is never replaced or silently forked. Init, setup,
  rotation and credential restore serialize on a cross-process key lock and
  publish keys without replacing existing ones; the store records an HMAC key
  verifier, and writes or rotation under another key are refused
  (`:master_key_mismatch`) and never answered from env or external fallbacks.
  Every entry point resolves the same provider chain and different keys in two
  providers fail with `:conflicting_master_keys`. An unconfirmed rotation stays
  pending until `lemon secrets rotate-key --resume` or `--abandon
  --confirm-abandon`.
- Honcho memory is partitioned by owner (agent profile, person, and legacy or
  verified-private memory) in a clean `v2` namespace: peers, assistant peers,
  sessions and message tags never cross people, profiles or private contexts;
  searches require and filter by owner; unmapped sessions refuse; conclusion
  deletes are ownership-checked. Honcho memory written before this release is
  not read, so every owner starts empty.
- Checkpoints: IDs are validated as `chk_<16 hex>` at every filesystem
  boundary; ownership is the trusted session id for capture and access (never a
  model-supplied session key); user-facing diff/restore/delete require an
  owner; restore and diff are confined to the roots recorded at capture, and
  diff refuses symlinked parents. Checkpoints captured before this release are
  refused, and chat `/checkpoint` is unavailable until channel ownership lands.
- Execution nodes: the launchers remove `LEMON_NODE_OPERATOR_TOKEN` and
  `LEMON_NODE_TOKEN` at startup and hand them to `lemon node` on a pipe drained
  before any application starts. Bash, PTY, process, eval, debug, host-command,
  task-worktree Git and stdio MCP children never inherit `LEMON_NODE_*TOKEN*`,
  `LEMON_SECRETS_*` or `LEMON_*_API_KEY`.
- Crash reports no longer leak prompts, answers or process state: a primary
  `:logger` filter sanitizes OTP crash, terminate, supervisor and Task reports;
  agent, session and run processes redact `format_status`; and a Sentry
  `before_send` scrubber drops state, messages, crash reasons, exception bodies,
  frame variables and breadcrumbs.
- Email inbound only accepts `From` mailboxes listed in
  `gateway.email.inbound.allowed_senders` that carry a passing provider verdict
  stamped with `gateway.email.inbound.authserv_id`; without it all inbound mail
  is refused unless the startup-warned `sender_auth = "from_only_unsafe"`
  opt-out is set. Refused senders get 403 before any state write. Thread state is
  owned per inbox and sender, outbound replies refuse header-breaking values, and
  email content reaches the model inside the untrusted fence. **Upgrade:** set
  `allowed_senders` and `authserv_id`.
- Voice webhooks and the media-stream WebSocket require a valid
  `X-Twilio-Signature` over the configured https `[gateway.voice] public_url`
  (403 otherwise; http and missing `public_url` are refused). `<Stream>` uses a
  query-free `wss://` URL with `<Parameter>` metadata and an expiring per-call
  token verified before any paid resource is created. Recording downloads only
  contact `https://api.twilio.com` and never forward credentials on redirects;
  filenames are sanitized. Deepgram sockets are owned by the call. SMS signature
  URLs no longer insert the backend port behind proxies.
- OAuth sign-in for Anthropic, OpenAI Codex, Gemini CLI, Antigravity and Z.AI
  requires the returned `state` to equal the one Lemon sent, byte for byte;
  missing or different state is refused before any token exchange. The loopback
  listener completes only on a `GET` to its path with a matching Host and state
  and keeps waiting through other requests. Antigravity no longer uses the PKCE
  verifier as `state`. MCP authorization providers must echo state, the MCP
  loopback flow no longer logs the authorization URL, and local PKCE sign-in
  without an approval channel or observer fails with
  `mcp_oauth_authorization_channel_required`. OpenRouter bare codes remain
  accepted (PKCE, no state by design).
- Debug tool: adapter-reported `systemProcessId`s are never signalled;
  `startDebugging` from user-chosen remote DAP endpoints is refused;
  adapter-requested sessions are capped at 16 per root (256 globally);
  non-loopback `attach` requires `debug_allow_remote_attach`; stop excerpts are
  read with descriptor-relative `O_NOFOLLOW` traversal (none without python3);
  large output spills only to exclusive session artifacts.
- Browser: CDP endpoints are no longer passed on the driver's argv or kept in
  process state; inline provider and Camofox keys live in a private,
  session-scoped credential vault; credential-bearing provider URLs are
  rejected; connection errors drop URL credentials; the driver and local Chrome
  no longer inherit credential variables; LSP sessions no longer keep
  `initialization_options` in state.
- Browser navigation classifies destinations after normalizing IP aliases and
  resolving DNS, blocking cloud metadata and link-local addresses on every
  route. Lemon-launched Chrome routes HTTP(S), WebSocket and service-worker
  traffic through a driver-owned egress proxy that checks the IP it connects to.
  Raw CDP is limited to read-only methods. Attached, relay and hosted browsers
  are not egress-filtered (documented).
- The control plane refuses WebSocket upgrades whose Origin is not exactly its
  own origin, a configured LemonWeb origin, or an entry in
  `LEMON_CONTROL_PLANE_ALLOWED_ORIGINS`; loopback peers of the main and A2A
  listeners must send a loopback, bind or configured Host on every route.
- `lemon migrate hermes` no longer archives `auth.json` or credential-bearing
  config, imports only recognised skill content (`--include-skill-assets` for
  the rest), creates secrets only if absent and bound to the migrated store,
  runs apply and rollback offline under the backup lifecycle locks, takes a
  Lemon backup bundle beforehand, and stages config rewrites in a private
  directory. `lemon backup` always excludes `migration/`. Legacy plaintext
  archives are reported with rotation guidance. New `lemon migrate hermes
  rollback DIR`.
- Patch tool targets (including move destinations and unified diffs) go through
  `FileValidation.check_mutation_target` with `mutation_root: cwd`; absolute
  paths outside cwd are rejected unless `allow_path_traversal` is set.
- TUI: `!cmd` and `{!cmd}` run only after the user confirms the exact command
  text in a modal (Cancel by default; Run disabled when the command can't be
  shown in full). Pasted, template, skill and restored text is sanitized and
  escaped. Interactive `!cmd` is no longer killed after 120 s.
- PDF, image-preview (`sips`) and `ast_grep` backends resolve only from absolute
  operator PATH entries outside the workspace or explicit overrides; project
  `.lemon/read-formats-venv` interpreters are never run; PDF Python runs with
  `-I`.
- Media tools never send one provider's API key to another provider's host, and
  Perplexity web search picks its destination from the credential it sends.
- Automatic project-memory capture keeps the verified private memory context and
  skips unproven contexts; cron forwarded summaries are not ingested; Telegram
  `/new` reflection only uses history with matching ownership.

- In a cloned repository, Lemon no longer starts or connects project MCP
  servers until the operator runs `lemon mcp trust` for that project's exact
  content. This covers Lemon's own `.lemon/mcp.json` (including
  `enabled_servers`/`disabled_servers`/`enabled` overrides of global servers)
  and other tools' project files (`.mcp.json`, `.vscode/mcp.json`,
  `.cursor/mcp.json`, `.claude/`, `.codex/config.toml`, `.gemini/`,
  `opencode.json[c]`, `.windsurf/`, `.omp/`). Trust is stored in
  `<agent_dir>/mcp_project_trust.json`, bound to a digest of every project file,
  and re-checked before every spawn and reconnect. Project files never expand
  `${VAR}`, `{env:}` or `{file:}`, Codex env keys, or OAuth secret references.
  `lemon mcp list --all`, `lemon doctor`, `mcp.servers.list` and `/mcp` show
  pending trust read-only.

- Channel ingress now applies per-channel tool policy and the group-chat
  approval floor: `LemonChannels.RunRequestBuilder` derives `channel_context`
  and sender `channel_identity` from the transport-normalized message, ignores
  caller-supplied values, and also covers Telegram/Discord `/new` memory
  reflection. Any peer kind other than a DM gets the approval floor. Senders
  without a transport id, and all email senders, get unverified identities that
  are never the owner and never map to a configured, pinned or aliased Honcho
  peer. Channel session key components containing `:` are stored as reserved
  `~sha256-` digests (existing keys are unchanged), and delivery restores such
  ids only from matching run provenance. Channel requests without transport
  provenance, including work persisted before this fix, are refused at
  admission, carryover and crash recovery. The dead `Router.handle_inbound/1`
  and `RouterBridge.handle_inbound/1` are removed.

- The execution node controller link, Deepgram voice, `lemon acp` and the CLI
  control-plane client now build WebSocket options through
  `LemonCore.Net.web_socket_options/2`: `wss://` verifies the peer certificate
  against the OS trust store with hostname checking and SNI (WebSockex
  previously defaulted to `verify_none`). Plaintext `ws://` is allowed only to a
  literal loopback IP or to `localhost` pinned to `127.0.0.1` (never
  `*.localhost`), unless the node's explicit `--allow-insecure-controller`
  override is set. The OpenAI Responses WebSocket transport applies the same
  plaintext rule, so remote `http://` provider endpoints no longer send bearer
  tokens over plaintext `ws://`. Restart Lemon after changing system CA roots.

- XMTP now authorizes inbound senders and fails closed: only inbox ids in
  `gateway.xmtp.allowed_inboxes` can start runs, and the policy is re-read for
  every message, so a reload that revokes an inbox or turns `allow_all` off
  applies to the next message. With no allowlist every inbound message is
  dropped unless `allow_all = true` is set explicitly. Group messages must
  mention the bot (`@<inbox id>` or `@<wallet>`). Rejected messages are not
  deduped, replied to or submitted, and their log lines carry no content. The
  bridge no longer syncs, lists or streams `DENIED` conversations and re-checks
  consent before every send. **Upgrade:** add senders' inbox ids to
  `allowed_inboxes` (shown in the `reason=unpaired` warning); messages dropped
  before a sender is authorized are not replayed.

- Updated the XMTP bridge's viem pin to 2.57.20, the browser driver's
  Playwright pin to 1.65.1, and patched documentation/browser development
  dependencies within their supported ranges. XMTP's npm audit is clean.
  The remaining documentation and browser audit findings stem from
  picomatch's unfixed repeated-extglob ReDoS (GHSA-fc5q-39xc-vjpf), propagated
  through fdir/tinyglobby into Vite/VitePress and browser development tools.
- OSV now scans the WASM runtime and all WASM tool Cargo lockfiles. Removed
  the unused diagram npm project and its scanner entries.

- The WASM sidecar now uses patched Wasmtime/WASI 36 LTS (36.0.21), closing
  sandbox escape and filesystem permission bypass advisories. All native WASM
  crate lockfiles are refreshed, including TLS, Tokio, and compression fixes.
- The Erlang distribution cookie no longer appears in process arguments of the
  launcher or lifecycle restarts (#551).
- `plug` 1.20.4 fixes EEF-CVE-2026-120287 (multipart length limit) for the
  channel and SMS webhook routers.

---

## [2026.11.11]

### Added

- Run tools on other machines: with the new `nodes` tool allowed, `bash`,
  `bash_output`, `kill_process`, `process_input`, `read`, `write`, `edit`, `ls`,
  `grep`, `find` and `eval` take a `node` argument that runs that one call on a
  connected named node, with its files, shell and network, while the model loop
  and provider credentials stay on the controller. `nodes` lists connected
  machines with a live host summary. Nodes keep per-session shell state,
  background processes and kernels for 30 idle minutes. A call cut off by a
  dropped connection, deadline or cancel is reported as an unknown outcome and
  is never retried or moved to another machine; the node aborts it.
  See [run tools on other machines](docs/tools/nodes.md).

- `eval` code mode: cells call session tools through a global `tools` object
  (`await tools.bash({command: "uptime", node: "build-box"})` in JavaScript,
  `await tools.bash(command="uptime")` in Python, or `tools.call(name, args)`),
  fanning out concurrently with `Promise.all` / `asyncio.gather`. Calls resolve
  through the session's policy- and approval-wrapped catalog, run at most 16 at
  a time, inherit the cell's session mutation lock and are aborted with the
  cell; only what the cell prints or returns reaches the model.

---

## [2026.11.10]

### Added

- Graceful restarts and updates: `lemon stop`, `lemon restart`, `lemon update`,
  `system.stop`/`system.restart` and service-manager stops now drain first.
  Telegram stops fetching (unfetched updates wait at Telegram), webhooks answer
  503 with `Retry-After`, active runs get 5 s to finish and are then paused at
  the next point where no tool is executing (forced, and marked uncertain,
  shortly before the 20 s deadline). Queued messages and paused runs are
  persisted and resubmitted after the restart: a paused run continues its
  session, and one cut off mid-tool is told the outcome is unknown so it checks
  state and asks before repeating anything. Chats see "Paused for a Lemon
  restart" instead of a failure.

- Source checkouts: `lemon reload` hot-loads recompiled modules into the
  running runtime and refreshes idle sessions' tools; changes that need a
  restart are reported.

- TUI: `/new [key] [first prompt…]` is now a shorthand for `/session new`.

- omp auth broker: Lemon now lists every broker account for a broker-backed
  provider (omp's selection order; `omp_account` still pins one identity). When
  a provider rate-limits an account (429/quota), Lemon reports a catch-all
  rate-limit block to the broker (`POST /v1/credential/:id/block`) so omp and
  other broker clients avoid it too, and retries the same turn on the next
  broker account before falling back to another provider. Reporting is
  asynchronous and best-effort.

- `lemon_ai` emits a `[:lemon_ai, :model_call, :start | :stop | :exception]`
  telemetry span for every admitted model call. The stop carries the duration,
  time to first content event, token usage, outcome and a bounded error
  category; streaming calls stop when the stream ends, not when dispatch
  returns. Rejected dispatches emit no span. See `docs/telemetry.md`.

### Changed

- The broker snapshot is kept current by a background long-poll
  (`GET /v1/snapshot?wait=…` with `If-None-Match`) instead of 15 second TTL
  polling, so rotations, revocations and blocks apply immediately. Failed
  long-polls fall back to the TTL cache; endpoints unused for about 10 minutes
  stop being polled.

- Bash commands and MCP stdio servers are now stopped by process group
  (SIGTERM, a bounded grace period, then SIGKILL) instead of a `pgrep` child
  walk, so backgrounded children whose parent shell already exited no longer
  survive an abort, timeout or owner exit, and an MCP server that ignores stdin
  EOF is killed when its transport closes. Background process sessions also
  kill their process group when the session terminates while the command runs.

### Fixed

- Manual `/compact` and branch summaries no longer run their model call inside
  the session process. The session keeps serving status and abort while they
  run; abort cancels them with `{:error, :aborted}`, and conflicting operations
  report busy.
- A native session whose agent process dies now reports a terminal error and
  stops, instead of staying registered with a dead agent. The next run resumes
  from the session journal.

### Removed

- LemonSim (`lemon_sim`, `lemon_sim_ui`) moved to its own repository,
  [z80dev/lemon-sim](https://github.com/z80dev/lemon-sim), where it builds on
  the published `lemon_core`, `lemon_agent` and `lemon_ai` packages. Lemon no
  longer ships the `sim_broadcast_platform` release, the launchers' `--sim-port`
  flag, `LEMON_SIM_UI_PORT` or any `LEMON_SIM_UI_*` handling, and
  `lemon_runtime_full` no longer bundles the sim UI.

---

## [2026.11.9]

### Security

- Updated HTTP dependencies past published advisories: Bandit 1.14.1 (HTTP/1,
  HTTP/2 and WebSocket resource-exhaustion, smuggling and host-spoofing fixes),
  cowlib 2.22.0, hackney 4.10.2 (pinned-CA trust, redirect credential leak,
  unbounded body buffering), ssl_verify_fun 1.1.9 (wildcard hostname matching),
  phoenix_html 4.4.0 and plug_crypto 2.2.1. `mix hex.audit` reports no
  advisories.

---

## [2026.11.8]

### Added

- TUI: assistant replies draw ```mermaid fences as ASCII diagrams, and, in
  terminals with inline images, ```svg fences as images and a chart under each
  numeric Markdown table. The coding agent's system prompt tells the model
  about these visuals in TUI sessions only.
- TUI: Ctrl+R searches saved prompts (stored with time and folder). The
  transcript "expand latest" key moves from Ctrl+R to Alt+E.
- TUI: `[tui] vim_mode = true` starts the composer in vim mode; the composer
  completes `:emoji:`, `^provider:model` mentions (submitting one switches the
  session model) and `#123` GitHub references to `pr://`/`issue://`.
- TUI: `/copy` without arguments opens a fullscreen transcript picker; `/rewind`
  and Esc-Esc on an empty composer open a fullscreen rewind picker.
- TUI: Alt+L opens a fullscreen link browser with keyboard hint tags.
- TUI: `/context` shows an occupancy map; notifications route through tmux,
  screen, zellij and other multiplexers, with a Linux desktop fallback.
- TUI: plan approvals open a fullscreen sectioned plan review (`v` from the
  panel); refine feedback is staged in the composer.
- TUI: `/usage` opens a dashboard with limits, per-provider cards and a daily
  activity heatmap; `/usage text` keeps the text report.
- `/jobs` lists the session's background processes with live output and
  cancel, backed by new `process.jobs.list|inspect|cancel` control-plane methods.
- `ask` accepts an agent-written HTML `<form>`, rendered as a form in the TUI;
  surfaces that cannot render forms fail with `unsupported_surface`.
- `read pr://N` includes the pull request's changed-files list.
- The `task` tool accepts `steps` (up to four prompts) instead of `prompt` to
  run staged work in one child session; the last step's answer is the result.
- `task` gains a bundled read-only `seance` persona: `agent: "seance"` with
  `source_session` (a session id or journal path of the caller's own
  conversation: its lineage, its task children, or runs recorded under its
  session key) forks that past transcript, compaction included, into a fresh
  child that answers questions about it. The source journal is never modified,
  its historical spend does not count against the consult, unused forks are
  deleted, other conversations and unscoped callers are refused before launch,
  and the child defaults to the source's model.
- TUI Agent Hub (Alt+A or `/hub`; `/tasktree` and `/subagents` are aliases):
  the focused session's `task` subagents, nested children included, with status
  (queued/running/idle/parked/completed/failed/cancelled), name and persona,
  model, clock, current activity and usage, a parent/child tree or flat
  roster, and a filter. Enter opens an agent's bounded transcript, which
  follows its newest line until scrolled up and stops re-reading once the
  agent is final or after three failed reads, with a message line that steers
  a running agent, follows up an idle one or revives a parked one through the
  task tool's own delivery; `x` cancels. Backed by new session-scoped
  control-plane methods `subagents.list`, `subagents.transcript`,
  `subagents.send` and `subagents.cancel`; another session's task IDs are not
  found.

### Changed

- Async task completions name the child (`Task <name> (<id>) [<persona>]`) and
  state whether it completed or failed. A failed child's partial answer is no
  longer delivered as if it had succeeded. Answers over 12,000 characters are
  cut to a preview that points at `read agent://<task_id>`.
- The `task` tool description now tells the model how to write self-contained
  assignments, when to fan out or sequence work, and how to continue a
  finished child.
- Plan mode can delegate read-only exploration: `task` runs, batches and swarms
  launch children limited to read/search/web tools with no further spawning.
  Worktrees, merge-back, write-capable personas and child messaging are refused
  while planning; `poll`, `get`, `join`, `wait` and `cancel` keep working.
- **Breaking:** the model can no longer choose a child's model by default. A
  `model` or `thinking_level` on `task` (including `tasks[]` items and swarm
  nodes), or a `model` on `agent`, now fails before any child starts unless the
  operator sets `[runtime.task] per_call_model = "on"`; the optional
  `per_call_model_allow` list restricts which `provider/model` or `@role` values
  are accepted. Project `.lemon/config.toml` files can only narrow this gate.
  Persona models and `[runtime.task].agent_models` are unaffected.
- `task` batches start each `tasks[]` item while the model is still streaming
  the call (`[runtime.task].speculative_launch`, default on). Dispatch adopts
  children whose parameters match the finished call; a differing, invalid,
  aborted or unexecuted call cancels them, terminalized without followups and
  with budget reservations released. Calls that need approval, extension tool
  hooks and plan mode never speculate. Tools can observe streaming arguments
  through `AgentTool.on_stream`.
- `task` batches start each read-only `tasks[]` item (read-only persona or a
  tool policy limited to read tools) while the model is still streaming the
  call (`[runtime.task].speculative_launch`, default on); write-capable and
  worktree items still launch at dispatch, so top-level options written after
  `tasks` can never reach a child that already edited the checkout. Dispatch
  adopts children whose parameters match the finished call; a differing,
  invalid, aborted or unexecuted call cancels them, terminalized without
  followups and with budget reservations released. Calls that need approval,
  extension tool hooks and plan mode never speculate. Tools can observe
  streaming arguments through `AgentTool.on_stream`.

---

## [2026.11.7]

### Fixed

- OpenAI-compatible streams that report an upstream failure as a mid-stream
  `{"error": ...}` chunk (OpenRouter, omp's auth gateway) now fail the response
  instead of completing with empty output.
- Lemon Bot's desktop iPhone pairing uses one explicit **Codes match — Pair
  iPhone** action instead of a comparison toggle followed by a separate button.
- Native Bot transcripts use measured scroll position to follow replies without
  snapping readers away from history; loading older messages preserves the
  message anchor, and keyboard resizing no longer creates a new-message badge.
- Bot capability inspection no longer serializes slow probes in the worker's
  mailbox. Concurrent reads share one fresh probe without retaining stale grants.
- Messages confirmed to fail before runtime dispatch settle as rejected instead
  of keeping Mac/iPhone composers trapped in “Checking whether your last message
  was sent”; uncertain dispatched work is never automatically repeated.
- JavaScript-only client and Bot test lanes no longer require an installed
  Elixir toolchain; release-gate cleanup handles Tern lifecycle return values
  explicitly.
- The Bot web type checker uses the same SDK source alias as Vite, so copied
  local SDK dependencies no longer lose their sibling contract imports.
- Credential redaction protects bounded auth/authorization/OAuth URL fields again,
  preventing embedded URL credentials from leaking through execution approvals
  while preserving validated, usable OAuth links and ordinary parser token text.
- Lemon Bot marks interrupted, never-dispatched messages “Not sent” and permits explicit resend; uncertain dispatched messages remain fenced.
- Apple push registration accepts bounded variable-length hexadecimal device tokens.
- Connect iPhone shows a copyable single-use pairing link alongside its QR, with the same expiry and usage state.
- Product release preparation now works with stock macOS/BSD sed and restores
  every changed version file and the changelog if any preparation step fails.
- The Tern palette's **Focus existing session** finds Lemon panes by program,
  not only by the old `Lemon · ` title prefix.
- Kimi Code omp authentication fails closed at the model-request boundary,
  normalizes auth-source spelling consistently for status and logout, and
  serializes access-token cache refreshes so stale fetches cannot replace them.
- Every Kimi Code request now sends one consistent Kimi CLI fingerprint (the
  catalog's stale `KimiCLI/1.0` user agent is gone), and the device id is
  persisted in `~/.lemon/kimi-device-id` so a host rename no longer changes it.
  `lemon doctor --live` checks Kimi Code with bearer authentication and the
  fingerprint. A refresh that loses to another Lemon process adopts that
  process's fresh token instead of failing.

---
- Product release preparation now works with stock macOS/BSD sed and restores
  every changed version file and the changelog if any preparation step fails.
- Lemon Bot's Mac **Connect iPhone** window explains missing HTTPS setup, links
  to the routing/allowlist guide and observes updated advertised addresses without
  an app restart. Debug-only local pairing is limited to the iOS Simulator and
  the browser's exact loopback hosts; Release and physical-device checks stay strict.
- Apple onboarding response decoding no longer inherits main-actor isolation
  across the HTTP transport boundary.
- Lemon Bot can finish interrupted creation/import in place, showing the failed
  step and checking owning receipts before continuing. Existing Bots can update
  their callback/tool address after `LEMON_BOT_PUBLIC_URL` changes, without
  replacing their identity or conversation. Rejected callback origins name the
  controller allowlist to fix; interrupted deletions offer a receipt-checked
  Delete action again. Recovery actions survive sync/overview refreshes, imported
  resources retain their owning reservations, and address migration refreshes
  the matching tool permissions under one exclusive lifecycle owner. Resumed
  imports preserve disabled-skill selections, including when an older import
  stopped between installation and disabling the copied skill.
- The Tern palette's **Focus existing session** finds Lemon panes by program,
  not only by the old `Lemon · ` title prefix.
- Kimi Code omp authentication fails closed at the model-request boundary,
  normalizes auth-source spelling consistently for status and logout, and
  serializes access-token cache refreshes so stale fetches cannot replace them.
- Every Kimi Code request now sends one consistent Kimi CLI fingerprint (the
  catalog's stale `KimiCLI/1.0` user agent is gone), and the device id is
  persisted in `~/.lemon/kimi-device-id` so a host rename no longer changes it.
  `lemon doctor --live` checks Kimi Code with bearer authentication and the
  fingerprint. A refresh that loses to another Lemon process adopts that
  process's fresh token instead of failing.

---

### Added

- Lemon integrates with omp's auth broker and auth gateway:
  `auth_source = "omp_broker"` reads any provider's credential from
  `omp auth-broker serve` (refresh stays with the broker; optional
  `omp_provider`/`omp_account`), and the `omp_gateway` provider routes models
  through `omp auth-gateway serve` with per-model Anthropic Messages, Responses
  or Chat Completions wires. Readiness, doctor and provider status understand
  both. See [configuration](docs/config.md#omp-auth-broker-and-auth-gateway).
- **Lemon Bot HTTPS setup (#530).** `lemon bot https enable --tailscale` sets
  up private tailnet HTTPS, or `--url` registers an existing HTTPS reverse proxy.
  `status` reports readiness; `disable` removes only tool-owned configuration
  and routes while preserving other origins. Browser setup offers HTTPS as an
  explicit opt-in and keeps local-only access by default.
  Managed HTTPS refuses source startup and remote-controller configurations
  rather than checking the wrong runtime. It owns only its exact private MCP
  approval, restores adopted public URLs, retains pending receipts after failed
  reconfiguration, and preserves existing env-file permissions.
  Backend configuration changes force the existing service restart path and
  verification observes its loaded approval, not only the config file. Planning
  shares the service installer's backend projection while retaining caller XDG
  paths and callback allowlists. Credential-port checks use the saved endpoint
  before the installer's desired-port override and fail before mutation.
  Installed and desired controller endpoints must match; HTTPS setup never
  changes the controller as a side effect of reinstalling the backend.
- Lemon Bot backend tests and the web build/tests now gate CI and run in the
  changed-file/premerge lane. Web tests run in separate processes so module
  mocks cannot leak between suites.
- **lemon.food home page comes alive.** The hero is now an animated Lemon Bot
  chat that plays three example conversations (fixing a flaky test behind a
  Terminal approval card, recalling a decision and setting a reminder, and
  fanning a review out to helpers). Visitors can press **Allow** or **Deny**
  themselves, switch or pause examples, and squeeze the mascot, which now
  reacts to the conversation from behind a turning lemon slice. Sections rise
  in on scroll and the terminal, browser and chat mocks play out. Reduced-motion
  visitors see each conversation's final state without animation.
- Native follow-up admission exposes an admin-only reconciliation receipt with a
  token SHA-256 digest, never the token or secret reference. Callback rejections
  distinguish malformed URLs, HTTPS requirements and non-allowlisted origins.
  `LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS` is declared in the environment registry;
  `lemon doctor` checks both admission allowlists for `LEMON_BOT_PUBLIC_URL`.
- **lemon.food home page comes alive.** The hero is now an animated copy of the
  Lemon Bot web app that plays three example conversations (fixing a flaky test
  behind a Terminal approval card, recalling a decision and setting a reminder,
  and fanning a review out to helpers). Visitors can press **Allow** or **Deny**
  themselves, switch or pause examples, and squeeze the mascot, which reacts to
  the conversation from behind a turning lemon slice. The "doors" section now
  shows faithful miniatures of the real terminal UI and the Mac and iPhone apps.
  Reduced-motion visitors see final states without animation, and the top
  navigation collapses to its menu button wherever the full menu would overflow.
- **Tern media previews.** In a Tern pane, a whole-file `read` of an image,
  SVG, PDF, audio/video file or 3D model, and a saved browser screenshot, shows
  the file in its tool card through Tern's media viewer, as omp's does. The
  model-facing result is unchanged; partial reads and remote-only files keep the
  textual card.
- **Tern pane cards and status messages.** In Tern the TUI title is a card
  (`🍋 LEMON: <session>`, or a session's own card-form name such as
  `🧪 FLAKY: Fix flaky tests`), which Tern heads parked panes with. Program
  status (OSC 7501) for approvals, questions and failures carries a one-line
  summary, so Tern's inbox and banners say what needs you.
- **`lemon tern install --agent-block`** makes Tern's **New agent block** open
  Lemon's TUI by setting Tern's `agent_command`. Without the flag an existing
  agent command is left unchanged.
- **Tern browser.** Browser tools of a TUI run in a Tern pane (local daemon)
  drive Tern's native browser picture-in-picture over that pane and can adopt
  the user's open browser blocks, releasing rather than closing them. An
  automatically chosen Tern browser falls back to the next provider when Tern
  cannot show one; explicit `provider = "tern"` fails closed. Opt out with
  `runtime.tools.browser.tern = false` or `LEMON_BROWSER_TERN=0`. `lemon setup`
  in a Tern pane opens consented sign-in URLs as a Tern browser block beside it.
- Kimi Code can reuse an omp-managed login with `auth_source = "omp"` or
  `lemon model --provider kimi-code --auth omp`. Lemon resolves access tokens
  through `omp token kimi-code` without copying refresh credentials, storing
  tokens, or falling back to ambient API keys.
- Kimi Code requests match omp's: adaptive thinking with effort for the K3 and
  `kimi-for-coding` models, the model's full output budget by default, and a
  per-session prompt-cache identity. `lemon model kimi_coding --status` shows
  the subscription quota (5-hour window and month).

### Changed

- The TUI uses pi-tui 18.18.9 (native buttons, path-based syntax highlighting
  in Tern) and source development now needs Bun 1.4.4+.

---

## [2026.11.6]

### Changed

- The TUI startup banner has a new pixel-art lemon with a half-block `lemon`
  wordmark, and a highlight sweeps across the logo once on startup.

### Fixed

- Lemon Bot for Mac: the sidebar's Search and New Bot buttons work again on
  macOS 26 (they sat under the window toolbar, which swallowed clicks or hit
  the sidebar toggle); they are now native toolbar buttons.
- Lemon Bot for Mac and iPhone: **Create Bot**/**Save changes** sit in the
  sheet's confirmation position instead of at the bottom of the long form, and
  a failed save scrolls its error into view. Bot replies show `- item` lists as
  bullets and `## headings` in bold instead of raw Markdown markers.
- Lemon Bot for Mac: replies no longer pop a "Notifications are not allowed"
  error when macOS notifications were never enabled; the error banner's
  **Open Settings** link only appears for the choose-a-Bot error and opens
  **This Mac**. The Settings window title follows the selected pane (it always
  said "Preferences"). Notification clicks reopen a closed workspace window.
  Machines, Skills and Routines toolbar actions are separate icon buttons
  instead of one run-together label ("Add a machineRefresh").
- Lemon Bot for Mac: ⌘[ / ⌘] (Previous/Next Bot) work right after launch;
  sidebar previews update when a reply finishes instead of sticking on
  "Needs a look"; attached files keep their own name (they showed and
  uploaded as `<UUID>-name`); Finder files can be dropped onto the composer;
  clicking an approval button no longer rings the whole message; the Bot name
  pill no longer shows messages through it; Devices list says Mac/iPhone/Web
  browser instead of `macos`/`web`; **Connect iPhone** errors appear beside the
  step that failed; the shortcut recorder says why a key was refused.
- The Lemon Bot iPhone app compiles again: a macOS-only home-directory
  initializer in `LemonBotKit` is no longer built for iOS.
- Lemon Bot for iPhone and iPad: a saved session signs in on launch instead of
  asking again; pairing explains reused, denied, expired and unreachable links;
  shared photos land in the composer and close the share sheet. Text and
  status colours meet WCAG AA contrast in light and dark mode, small buttons
  have 44 pt touch targets, and the composer, live status, approval buttons
  and Settings wrap instead of truncating at the largest text sizes.
  **Unread only** with nothing unread offers a way back instead of a blank
  list. Attached files keep their own name on iPhone too.
- CI builds the Mac and iPhone apps and runs the shared `LemonBotKit` tests on
  every change that touches them.
- Lemon Bot replies again. Since 2026.11.3, every Bot run failed before
  reaching the model ("The runtime reported that this run failed"): MCP
  requests to a local or private Lemon Bot address carried two
  `content-type` headers, which Lemon Bot rejected.
- On macOS, `lemon service install` no longer leaves a changed service stopped
  ("blocked", `service_command_failed`): it waits for launchd to finish
  removing the old unit before loading the new one.
- Bot runs no longer fail intermittently ("The runtime reported that this run
  failed") while Lemon Bot is busy: the worker's same-user check on a local
  Lemon Bot connection ran before Lemon Bot had accepted the connection, found
  no owner, and refused it. It now waits briefly for the accept, still failing
  closed without positive ownership evidence.
- `runs.receipt.get` reports `state: "aborted"` for a fixed run ID that an abort
  fenced before dispatch (it never ran and never will) instead of
  `outcome_unknown` forever, and run presence no longer counts such a claim as
  unknown work. Clients can now settle Stop pressed during submission.
- Lemon Bot in the browser: Settings scrolls again on small windows, and a Bot
  left "Working" after a restart or lost run settles on its own instead of
  staying stuck. Tool steps finish (or show as stopped) when a run ends,
  instead of spinning forever, and show the real tool name. Run failures say
  what went wrong instead of a generic error. Activity names the Bot, unread
  notices clear when read, and allowing a tool for a chat no longer counts as
  an unknown outcome. See the
  [Lemon Bot changelog](products/lemon_bot/backend/CHANGELOG.md) for the full
  list.
- Docs: [Lemon Bot in 3 minutes](https://lemon.food/getting-started/lemon-bot)
  now explains how to give Lemon Bot an HTTPS address for iPhone, another
  browser or a remote worker. That includes the controller allowlists
  (`LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS`, `LEMON_CRON_ADMISSION_ALLOWED_ORIGINS`
  in `~/.lemon/env`); without them, creating a Bot fails with a generic error.
  The install, quickstart and setup guides describe the **How will you use
  Lemon?** step and state that the Mac and iPhone apps are built from source
  for now.
- lemon.food: the home page shows both install commands in full instead of
  clipping the flags that tell them apart. Secondary text meets WCAG AA
  contrast, and the skill examples on the Skills page render as single code
  blocks.

---

## [2026.11.5]

### Fixed

- `lemon setup` failed to open Lemon or finish Lemon Bot setup with
  "/dev/tty: Device not configured": programs started by setup's VM have no
  terminal. Setup now hands the TUI and `lemon-bot up` to the `lemon` launcher,
  which runs them in your terminal after the setup questions.

---

## [2026.11.4]

### Added

- `websearch` provider: Keenable (`keenable`), opt-in with `KEENABLE_API_KEY` or
  `runtime.tools.web.search.providers.keenable.api_key`. Thanks @KGKallasmaa.
- One setup wizard for every install: after connecting a model, `lemon setup`
  asks **How will you use Lemon?** (Terminal, Browser with Lemon Bot, or Both).
  Browser downloads and verifies the Lemon Bot backend for the installed version
  and hands off to `lemon-bot up --this-machine`, reusing the connected model;
  Terminal offers a login service. Setup then offers Telegram/Discord. Pre-answer
  with `--use terminal|browser|both` and `--background`/`--no-background`.
- `lemon-bot up --this-machine` uses this computer's Lemon without asking when no
  controller choice is saved.

### Changed

- The `--profile bot` installer preset also installs the terminal UI
  (`LEMON_NO_TUI=1` skips it) and finishes with `lemon setup --use browser`
  instead of running `lemon-bot` directly.

---

## [2026.11.3]

### Fixed

- Packaged `lemon daemon` (and `stop`, `rpc`, `remote`) failed with "daemon
  started but its pid could not be determined" when the machine's hostname
  resolved to a non-loopback address, because distribution is now
  loopback-only. Short-name release nodes default to the `localhost` host.

---

## [2026.11.2]

### Added

- Include bundled Python in the actual darwin runtime tarballs, not just the
  assembly directory, and reject archives missing its interpreter or licenses.
- `lemon service install|status|repair|uninstall` manages controller, Lemon Bot
  backend and named worker services with launchd/systemd, identity-verified
  takeover, application readiness, truthful persistence and a manual fallback.
- `lemon uninstall` previews the exact units, programs and shell changes and
  requires a fresh confirmation digest; data is preserved unless `--purge`.

### Changed

- Secret writes refresh the master key inside the mutation lock even during a
  cached setup command, preventing credential loss after concurrent key rotation.
- Codex login import warns about shared refresh-token sign-outs before consent;
  setup also offers independent ChatGPT browser sign-in directly.
- Bind uninstall confirmation and deferred deletion to canonical filesystem
  identities; reject symlinked ancestors and stale replacement targets.
- Wait for a new controller process at the selected root during supervised
  restarts, and recognize launchd units when HOME contains XML-special characters.
- Restart the Bot backend once after changing controller selection, verify its
  selected-controller connection, and persist non-default local controller ports
  in backend service units.

- Source launchers now reuse a private random per-install distribution cookie;
  dedicated control-plane and gateway launchers also default distribution and
  epmd to loopback. Both primary launchers honor the saved node-gateway port,
  including `0` to disable it, without overriding explicit environment settings.
- Harden Lemon Bot installation: reject chained archive symlink escapes and
  cycles, preserve release pins in Terminal commands, invalidate setup plans
  when either component pointer changes, and stage both combined-preset
  components before promotion with rollback on failure.
- Keep Files-enabled Bot folders outside trusted extension, configuration,
  persona and project-prompt discovery during session startup, reload and rebuild.

- Managed controllers route start/restart through their service manager.
  Deliberate stops stay down; updates restart only previously running units,
  stop workers before restarting the controller, and update an installed Lemon
  Bot backend in lockstep with the runtime.
- Reject invalid destination ports before URI normalization or default-port
  fallback in MCP origin authorization, context/web fetches and redirects,
  webhook callbacks, and node enrollment URLs on Elixir 1.20.
- Add a shell-only supervised reverse SSH tunnel for second-machine node gateway
  and Lemon Bot access, with private status, credential-free SSH environments,
  stale same-user sshd cleanup and terminal host-key/auth/forwarding failures.
- Added the embedded Lemon Bot Worker helper, non-prompting macOS grant probes,
  and explicit local-machine Permissions controls with System Settings links.
- Named workers now bind loopback credential checks to the established peer's
  exact connection tuple, including every new tunneled MCP request; cached DNS
  pins and replacement listeners cannot authorize a foreign peer. Listener
  preflight matches address, family and port. Deliberate cross-user deployments
  can opt out with `LEMON_NODE_TRUST_LOOPBACK_LISTENER=1`.
- SSH machine setup rejects IPv6/localhost product origins before forwarding;
  the supported loopback product origin is HTTP on `127.0.0.1`. Mac setup retries
  preserve the SSH destination and machine ID for direct links as well as tunnels.
- Pairing preview reports node-gateway health; tunnel invitations bind the exact
  destination loopback port without selecting a controller-local source checkout.
- Build Mac DMGs in release CI with a signed runtime-manifest pin, credential
  gating, notarization and verified receipts. Unconfigured builds remain
  unpublished preview artifacts; stable signed releases include a fixed DMG alias.
- Combined `--profile bot` installer preset: bot-verified full runtime without
  the TUI and the same-version backend, with a single Lemon Bot setup hand-off.
  Backend-only `--profile lemon_bot` remains available for manual deployments.
- `lemon service` manages controller, backend, worker and tunnel services, reports actual
  persistence, and supports headless stdin enrollment. Worker join commands use
  services by default; `--foreground` opts out. Preview-confirmed `lemon uninstall`
  removes managed programs and services, keeping data unless `--purge` is chosen.
- Node-only gateway on loopback port `4044` for secure node tunnels/proxies:
  node/enrollment `/ws` and `/healthz` only, never operator or tokenless access.
  Setup reserves the gateway port and doctor reports exposed listeners.
- Supervised reverse SSH tunnels for second-machine node gateway and Lemon Bot
  access, with private status, credential-free SSH environments, stale same-user
  sshd cleanup and terminal host-key/auth/forwarding failures. Pairing preview
  reports gateway health; invitations bind the exact destination loopback port
  without selecting a controller-local source checkout.
- Embedded Lemon Bot Worker helper, non-prompting macOS grant probes, and explicit
  local-machine Permissions controls with System Settings links.
- Release-pinned Mac app setup verifies and installs missing runtime/backend
  components without developer tools; darwin runtimes bundle checksum-pinned
  CPython and avoid Apple's Python shim when Command Line Tools are absent.
- Release CI builds Mac DMGs with a signed runtime-manifest pin, credential gating,
  notarization and verified receipts. Unconfigured builds remain unpublished
  preview artifacts; stable signed releases include a fixed DMG alias.

- Source toolchain, CI and release builds now use Elixir 1.20.5 and Erlang/OTP 29.1.2 (was Elixir 1.19.5 / OTP 28.5); source checkouts must upgrade before building.
- **Breaking security change:** control-plane, web and simulation listeners now
  bind `127.0.0.1` by default, as do launcher epmd/distribution defaults. Existing
  LAN clients must opt into `*_BIND_IP`, configure operator authentication, and
  restart. Non-loopback main traffic is restricted to `/ws` and `/healthz`;
  remote OpenAI/ACP APIs require explicit opt-in and dedicated tokens.
- OpenAI/ACP require bearer authentication by default (falling back to the
  operator token); tokenless local OpenAI/ACP/A2A requires the explicit loopback
  compatibility flag. Containers explicitly bind inside their namespace and
  require an operator token.
- **Breaking update-order change:** local updates and rollbacks stop running
  managed workers before restarting the controller, then restart those workers
  only after the controller is healthy. A managed Lemon Bot backend updates with
  the runtime and restarts afterward if it was running. Remote workers are never
  silently updated; update each host explicitly.
- Consolidated the canonical [Lemon Bot getting-started guide](docs/getting-started/lemon-bot.md)
  around the three setup paths: Mac app, Terminal/browser (local or headless),
  and adding a second execution machine. Documentation distinguishes listener exposure, service persistence,
  destination-local model readiness and explicit access consent.

### Fixed

- Profile memory transfers enforce the complete source snapshot's JSON size budget
  before scanning document credentials, rejecting oversized snapshots consistently
  instead of reporting memory unavailable when Elixir 1.20.5 raises a regex match limit.
- Source and packaged launchers use portable GNU/BSD permission probes and
  consistently abbreviate controller log paths with `~` in status output.
- CLI setup and service handling honor their typed readiness and error contracts
  under Elixir 1.20 / OTP 29 without unreachable fallback clauses.
- Harden runtime text screening for Elixir 1.20 regex match-limit exceptions:
  redaction withholds unscannable values, secret obfuscation withholds
  an incompletely screened batch, and skill audits, shell guards and schema
  validation fail closed. SMS matchers return explicit errors without claiming
  messages; service readiness keeps its managed handle. Document/web extraction,
  search, previews and provider-error classification now handle adversarial text
  predictably. Remove overlapping dotenv/config, path-redaction and compaction
  patterns instead of relying on regex backtracking limits.
- Named workers refuse credential-bearing loopback connections unless the listener
  belongs to their OS user, including tunneled MCP requests. Deliberate cross-user
  deployments can opt out with `LEMON_NODE_TRUST_LOOPBACK_LISTENER=1`.
- Isolate named workers' DETS state from the controller, guard against concurrent
  VM writers, back up and rebuild the controller's legacy DETS files once, and
  expose local worker state with `lemon node status --name NAME --json`.
- Execution-node sessions renew while connected and expire after seven days
  without contact. Rejected or missing credentials park the worker until repair
  saves new credentials, while controller outages retry without restart loops.
- Stop the Lemon Bot transcript (Mac and iPhone) from pinning a CPU core in an
  endless SwiftUI layout loop while a conversation is open.
- Setup caches Keychain lookups only for the command lifetime, reports model
  readiness truthfully, and checks Codex account model access without generating
  a message. `lemon setup model` and opt-in provider-management readiness/check/
  import methods support explicit connection and destination-local login consent.
- Load the certificate provider and core secrets store before Telegram and Discord
  setup make their first HTTPS request, preserving TLS verification and avoiding
  `store_unavailable` crashes in cold source and packaged CLI invocations.

### Removed

- Removed software-factory project registration, test-runner lease routing, and
  factory-only CI checkout attestations and contract fixtures.

---

## [2026.11.1]

### Changed

- Refresh `lemon_ai` model catalogs for current models, including GPT-6.1 Terra,
  Gemini 4 Argon, Kimi K3.1 Pro, MiniMax M3.1 Flash and newer gateway offerings,
  with updated pricing, token limits and capability metadata.

### Fixed

- The terminal integration check waits for the rendered answer as well as
  completion signals, avoiding a race that could fail the client release gate.

---

## [2026.11.0]

### Added

- Address existing conversations with durable agent handles and stable addresses:
  `/agent-name`, `/agents`, and `/tell` in the TUI, plus separate Lemon Bot handles,
  discovery, and addressed messaging. Renaming a handle preserves the conversation
  and stable ID; titles, personas, file references, and family task addresses remain
  separate. Replies return to the originating conversation, with explicit accepted,
  completed, failed, or outcome-unknown receipts and owner-scoped Bot visibility.

---

## [2026.10.25]

### Fixed

- An execution-node worker on the same machine as Lemon could still report a
  Bot's profile memory as unavailable, so deleting the Bot or forgetting its
  memory failed. Workers now load every module at startup, as the main runtime
  does, so memory written by either process reads back everywhere.

---

## [2026.10.24]

### Fixed

- After connecting the Lemon Bot Mac app to **This Mac** or an SSH host, the
  sidebar no longer stops at **Attach a machine** with a manual join command. It
  makes that machine a Bot machine by itself — enrolling it as a Lemon execution
  node and keeping its worker running with a LaunchAgent (macOS) or systemd user
  service (Linux) — then shows **Create a Bot**, with the machine preselected.
  An already-enrolled machine just gets its worker restarted under supervision.
- Creating a Bot on the machine Lemon Bot runs on no longer fails with "This
  server needs a secure address your machine can reach". Lemon Bot proves the
  machine is its own host and lets that Bot reach it over loopback, and Lemon
  now trusts the same-machine Lemon Bot origin (`http://127.0.0.1:4100`) for
  admission callbacks by default. Other machines still need an HTTPS address.
- Execution-node workers load their modules up front, so profile memory written
  by an earlier run (or by Lemon on the same machine) is no longer reported as
  unavailable. This blocked deleting Bots and forgetting their memory.
- Deleting a Bot whose profile has several saved preferences no longer fails
  with "not found".

---

## [2026.10.23]

### Changed

- Redesigned the <https://lemon.food/> website and README banner around the
  Lemon Bot mascot and palette: a new illustrated homepage, Fraunces and
  Instrument Sans typography, restyled documentation pages in light and dark
  mode, a mascot favicon, a social preview image, and a 404 page.
- Lemon Bot's Mac app now connects in one click with no email, password or
  setup code. **This Mac** starts Lemon Bot if it isn't running and signs in
  as its owner, creating the owner on a fresh install; **Another machine**
  does the same for any host you can `ssh` into and keeps a loopback tunnel
  open. Proof is the backend's new private `~/.lemon/lemon_bot/local-access.key`
  (`POST /v1/auth/local`). The looping **Find Lemon Bot** / sign-in sheets and
  duplicate `localhost` entries are gone, **Start Lemon Bot** starts the backend
  directly instead of copying a Terminal command, and an expired session
  reconnects on its own. The Mac app is no longer sandboxed so it can run
  `ssh` and `lemon-bot` as you; password and SSO sign-in remain one link away.

---

## [2026.10.22]

### Changed

- The documentation website moved to <https://lemon.food/>, served at the
  domain root instead of the `/lemon/` project path.
- `lemon-bot` now works with no configuration on the same machine as Lemon.
  It serves `http://127.0.0.1:4100` (moved from 4080, which Lemon Web uses),
  keeps state in `~/.lemon/lemon_bot`, and finds and signs in to the local
  Lemon through the launchers' port settings and managed operator credential.
  On first start in a terminal it asks whether to use the Lemon on this
  machine, offering to start it if stopped, or another machine's controller
  address and operator token, verifies the connection and saves the choice
  (`lemon-bot --choose-lemon` asks again). A new workspace's one-use owner
  setup code is shown in that terminal and the web app opens in the browser
  (`--no-open` skips it). If Lemon is down, Lemon Bot keeps waiting and
  connects when it starts; owners can also choose **Start** in the app.
  Explicit `LEMON_BOT_*` environment settings still take precedence.
- The Lemon Bot Mac app's **Start Lemon** command prefers an installed
  `~/.local/bin/lemon-bot` over a source checkout, and its local discovery and
  onboarding default use port 4100.
- `install.sh --profile lemon_bot` says how to run `lemon-bot` and how to
  install Lemon itself when it is missing.

### Removed

- Releases no longer publish `sim_broadcast_platform` tarballs, and
  `install.sh` no longer accepts `--profile sim`. Build that release from
  source or with `apps/lemon_sim_ui/Dockerfile`. A GitHub release now contains
  12 tarballs.
- CI no longer tests LemonSim. Pull requests, `main`, release preflight and
  nightly coverage skip the `lemon_sim` and `lemon_sim_ui` suites. The
  `sim-bench` job and the release-smoke Sim UI container job are gone. Run
  LemonSim checks locally with `scripts/test changed` and
  `scripts/sim_bench.sh`, which replaces `scripts/ci_sim_bench.sh`.

---

## [2026.10.21]

### Fixed

- The TUI no longer warns `could not recover …: NOT_FOUND` when it starts or
  `/new` opens a session that has not run a prompt yet. The warning still
  appears if the daemon reports a session missing while the TUI has a run or
  transcript for it.

---

## [2026.10.20]

### Changed

- First-run install and setup are quieter. The installer prints one line
  before and after the download (with a compact progress bar on a terminal)
  and ends with a single next step; it no longer prints checksums, paths or a
  command list. Setup no longer asks about the runtime profile or a Hermes
  import (`lemon migrate hermes` is unchanged), and skips status and file
  chatter on a first run. Installs default to the full runtime
  (`install.sh --profile min` for the minimal one).
- Setup asks about ports only when a default one is taken by another program,
  suggesting the next free port. The choice is saved to `~/.lemon/ports.env`,
  which the launchers load into unset port variables; `lemon setup runtime`
  now saves there too instead of printing `export` lines.

### Removed

- The built-in daily brief (`[automation] daily_brief`, `lemon setup
  --daily-brief`). Schedule a brief as an ordinary cron job instead, e.g. ask
  the agent for a daily 7:30 brief that replies `[SILENT]` when there is nothing
  to say, or use `/remind every day 7:30 ...` in Telegram.

---

## [2026.10.19]

### Fixed

- `lemon stop`, `lemon restart`, and `lemon update apply` recognize a managed
  daemon started on the default control-plane port without
  `LEMON_CONTROL_PLANE_PORT`, instead of refusing it as foreign. Launchers from
  2026.10.18 and earlier still refuse such a daemon; stop it with
  `kill <pid>` (pid from `lemon status`) before `lemon update apply`.

---

## [2026.10.18]

### Fixed

- `lemon --help`, `lemon help <command>`, and launcher-command `--help` from a
  `lemon_runtime_full` release no longer crash with a missing
  `LEMON_WEB_SECRET_KEY_BASE`; help skips runtime configuration like
  `lemon --version` does.

---

## [2026.10.17]

### Added

- Runtime releases bundle the local browser driver, so a packaged install uses
  the managed local browser with only Node.js 24+ and Chrome/Chromium. Building
  `lemon_runtime_min` or `lemon_runtime_full` now requires `npm`.

### Changed

- The local browser driver resolves from `LEMON_BROWSER_DRIVER_PATH`, then the
  release-bundled driver, then a source checkout under `LEMON_PATH`; the current
  working directory is no longer searched.

### Fixed

- `lemon doctor` from a release install no longer warns that `LEMON_PATH`
  points at the build machine when `LEMON_PATH` is unset. Without a running
  runtime, the memory-store and cron-pause checks now skip with a hint to start
  Lemon instead of warning that runs are not recorded or held back.
- Local browser diagnostics name the missing prerequisite (Node.js, driver,
  outdated driver build, or Chrome) instead of one generic install message.

---

## [2026.10.16]

### Fixed

- Release publication refuses truncated or corrupt archives from an interrupted
  artifact download instead of publishing them with a matching manifest
  checksum. 2026.10.15 shipped truncated macOS arm64 and Linux x86_64 TUI
  archives, which made the installer fail during extraction.

---

## [2026.10.15]

### Fixed

- Controller-only native root admission binding maps are excluded from remote
  execution metadata under every atom/string/camel alias, preserving their
  admission-store ownership.
- Preserve missing provider usage and cost as null through native session history,
  run-ledger occurrences and CLI JSON, including successful multi-turn tasks.
  Aggregate only complete per-counter observations, retain cache breakdowns without
  counting reasoning twice, and keep request observers attached to native trace
  options instead of replacing map-valued callbacks.
  Preserve long-cache subsets and component prices across occurrence aggregation,
  and keep semantic-search usage details aligned with the canonical nullable ledger.
  Prompt diagnostics, simulation artifacts, context projections and usage dashboards
  retain unknown counters safely. Count each provider attempt independently of
  transcript history so failed retries and empty continuations remain spent without
  exposing budget estimates as provider telemetry.
  Keep legacy usage callers without occurrence metadata safe and preserve known
  token totals and context gauges across existing control-plane and terminal clients.

- Persist paired attempts interrupted during disposal, verification, pricing or
  report finalization before exiting, retaining paid counters and prior failures
  and refusing unsafe resume. Anchor recovery logs, both ledger opens and
  post-attempt files to the original trial-root descriptor, including concurrent
  root replacement during recovery. Pin Darwin directories before permission
  repair and retain evidence when safe descriptor access is unavailable.

- Paired coding trials verify both private process ledgers after bounded runtime
  shutdown, without forwarding credentials to offline recovery. Unverified native
  teardown, fixture disposal or finalization halts later trials while retaining
  private evidence, paid counters and prior failures. SDK paths survive isolated
  HOME resets; private TMPDIR captures share the fixture's evidence lifetime.
- Apple Providers confirmations survive dialog dismissal, explicit device-login
  status checks remain available after expiry, and new sessions can safely retire
  unreachable login fences without replaying or claiming settlement of old work.
- CI records isolated checkout identities before repository code runs, including
  the required `CI result` summary, so factory integration can verify exact runs.
- Added read-only Lemon Bot phone readiness diagnostics and an operator-owned
  physical iPhone/Tailscale and provider-onboarding acceptance runbook; no
  networking, service, credential or device changes are performed.

- Telegram final transcript edits confirm delivery when Telegram reports that
  the message is already unchanged, including retries after a lost acknowledgement,
  so opt-in voice synthesis proceeds exactly once. Voice usage falls back to
  configured model-specific character pricing when speech APIs omit usage;
  unpriced requests retain their character count and explicitly unknown cost.
- Profile defaults and model-less managed follow-ups remain subject to automatic
  routing and its cost cap. Retry continuations retain model-selection provenance;
  reviewer/judge defaults stay automatic, while explicit cron model pins and
  legacy nullable explicit selections still win.
- Automatic model routing keeps persona model/role and configured task-agent
  defaults subject to routing rules and cost caps across native and router-backed
  delegation, while preserving explicit child and inherited explicit selections.
- Lemon Bot iPhone pairing verifies the advertised backend and workspace before
  connecting, shows device/code/expiry while waiting for desktop approval, and
  restores saved sessions read-only without replaying sends or approvals.
  Pinned Apple accounts recover from temporary HTTP 502/503/504 preflight outages
  while retaining their credentials and blocking transport until verification succeeds.
- Withdraw only ACP permission callbacks on approval resolution, not their
  requester/publisher, so native tools reliably receive approval and denial
  decisions, including **Refine plan** responses to `propose_plan`. Cancellation
  also rejects permission requests that register after the approval is resolved.
- Grep keeps invalid UTF-8 bytes from an over-budget first ripgrep match
  instead of crashing while truncating it.
- Document extraction keeps its backend port under an independent guardian,
  stopping the witnessed backend process group (including reparented children)
  on timeout, abort and caller death. A startup handshake witnesses a trusted
  leader before converters execute and retains it through cleanup, including
  when a short-lived converter forks a child and immediately exits.
- Global cron pause invalidates claimed-but-unsubmitted scheduled and retry runs
  before acknowledging success, including workers preparing submission and
  delayed jitter timers. Resume strictly reloads the durable job inventory and
  keeps the pause in force if job/retry enumeration or any required skipped-slot/
  retry persistence fails, including after a paused restart with unreadable jobs.
  Startup storage failures hold scheduled work and retries while durable restoration
  retries with capped backoff, without restarting automation sibling services.
  Unreadable pause markers require normal expired-slot/one-shot restoration before
  dispatch resumes; confirmed pauses still preserve schedules until explicit resume.
  Status exposes `restorationPending` separately from the durable `paused` marker:
  resume may clear the marker while scheduled dispatch, wake triggers, and retries
  remain blocked until restoration succeeds. Explicit manual `run_now` remains
  available while restoration is pending.
- Setup/readiness preserve native colon model IDs, including multi-colon IDs.
  Live setup strips only actual provider qualification, honors declared/discovered
  full IDs in the effective provider scope and model overrides, and rejects known
  foreign provider/custom-provider selectors before HTTP.
- Preserve failed and canceled native-turn terminals instead of reporting success
  or reusing an earlier answer. Validator correction attempts use fresh delivery
  generations so delayed events cannot consume retries or complete a later turn.
- Serialize bounded Bus admission across concurrent publishers without treating
  lock contention as overflow. Monitored admission workers bound pending requests,
  release waiters on shutdown, and fence unavailable admission after a finite wait.
- Session recovery selects only an unambiguous native root and scopes descendant
  approvals to that owner's active tasks. New subscribers receive the selected
  journal todo plan immediately; unreadable plans warn without clearing known
  state, and stale tool receipts or reminders cannot replace journal truth.

- Approving a channel pairing code now updates the running Telegram/Discord
  adapter's allowlist, so the sender's next message is accepted without
  restarting the gateway or daemon. New `lemon pairing revoke <platform>
  <chat_id>` removes a chat from the config and the running adapter live.
  `channels.pairing` gains local-operator `activate`/`revoke` actions; unknown
  senders stay rejected and a failed live update exits non-zero. Transports now
  read the persisted gateway allowlist on every supervised restart instead of a
  startup snapshot, and an emptied Discord `allowed_channel_ids` list stays
  deny-all across restarts (revoking the last channel no longer reopens every
  channel).

- Run tool-schema snapshot events carry schemas without execute closures, so
  sessions with many tools no longer exceed the 1 MiB subscriber event limit,
  fence direct subscribers and drop `agent_end`.

- Pin skill-synthesis candidate timestamps in ordering fixtures and cover
  recency/ID tie-breaking independently of wall-clock scheduling.

- Derive computer-use approval test origins from configured control-plane/web
  ports so non-default test listeners retain Lemon self-surface protection.

- Run status preserves unavailable counts as unknown instead of zero and restores
  UTC daily terminal totals after tracker restarts, including crashed runs.
- Preserve delegated run identity when polling recovers a durable completion, so
  the task and RunGraph both become terminal even without a live watcher.
- Make coordinator/session/watcher/environment regressions synchronize with their
  actual lifecycle and isolate resource discovery from protocol fixtures.

- Assert LSP owner cleanup by the exact managed server ID rather than a global
  active-count delta that races unrelated idle-server cleanup.

- Keep Telegram `/model` reply-keyboard choices stable for the picker conversation
  without repeating model/credential discovery on every navigation step.

- Probe real LLDB launch capability before enabling host-backed debugger tests,
  and drain PTY output through exit so terminal backpressure cannot stall tests.

- Keep bash streaming previews advancing after the first 50 KB, including delayed
  output, while preserving bounded replacement snapshots and managed capture.

- Resolve qualified model selectors against their own provider when a preset or
  default provider was inherited, while preserving native colon IDs for explicit
  provider/model pairs.

- iOS share builds without App Group access explain the in-app Camera, Photos and
  Files alternative without exposing signing identifiers or offering a futile retry.
- Apple composer controls have iPhone-sized touch targets, a stable corner radius,
  bounded pasted-filename previews and appearance-aware code inset colors.

### Added

- Lemon Bot iPhone and Mac share Providers settings for target-local API-key
  add/replace, Codex device login in the system browser, and confirmed local
  disconnect. Capability/readiness and the current default are separate, with a
  deliberate confirmed default change. Secure input is transient and cleared on
  submission, failure or cancellation; uncertain actions are never auto-retried.
- `lemon connect iphone --backend ORIGIN [--origin HTTPS_ORIGIN]` pairs with an
  already-running Lemon Bot from source or packaged Lemon. It uses interactive
  owner product login, HTTPS preflight, explicit exact-request approval, and
  consumed-link confirmation without starting services or accepting secret flags.
- Opt-in channel voice replies mirror inbound voice messages using the configured
  TTS provider, always retain the text transcript, and fall back to text on
  synthesis failure. Speech runs asynchronously after every transcript chunk is
  confirmed, with stable final-answer deduplication and a 20 MiB audio limit.
  Successful streamed final edits count toward transcript delivery, while
  intermediate tool-turn handoffs never claim the completed answer's identity.
  Synthesis usage records cost when known without inventing a zero price for
  unpriced speech.
- Telegram gateway setup prints the `https://t.me/<bot_username>` link once the bot token validates.
- TUI prompt history persists across sessions by default in the private local
  SQLite database `~/.lemon/tui-history/history.sqlite3` (mode `0600`, directory
  `0700`), using Bun's built-in SQLite. Transactional append, bounded pruning
  (100 prompts / 256 KiB of encoded content) and clear preserve concurrent
  writers without stale snapshots; full auto-vacuum and rollback journaling
  bound physical storage growth separately from the logical content limit.
  Only submitted prompts are saved. Legacy JSONL and retained backups migrate
  once; `/clear-history` clears saved rows and legacy sources without reimport
  after a crash, and reports permission/lock/cleanup failures truthfully.
  `[tui] prompt_history = false` disables persistence. History stays client-local,
  outside doctor support bundles; backups may include it.
- One durable switch pauses every cron job across profiles: `lemon cron pause
  --all` / `resume --all`, `cron.pause`/`cron.resume` with `all: true`, and the
  `cron` tool's `pause_all`/`resume_all` actions. The pause survives restarts and
  holds back scheduled runs, retries and wake triggers while in-flight and manual
  runs continue. Resuming never catches up: slots and retries missed during the
  pause are skipped and audited, and each job continues at its next scheduled
  time. `cron.status`, `lemon cron status`, the cron tool and `lemon doctor`
  report the paused state.
- TUI status bar shows the session's cumulative cost, updated after each run
  (including snapshot-managed sessions, counted once per run). Runs without
  cost data, resumed history, and events lost to a reconnect make it a lower
  bound (`session ≥$0.42`), and a session with no known cost shows
  `session cost unknown` instead of $0.00. The daemon's `sessions.context`
  ledger reports a missing cost as zero, so a resumed total is never exact.
- `mix lemon.eval.coding --campaign`: a resumable, offline-tested multi-provider
  run of repeated paired disclosure trials (baseline vs the opt-in coding profile)
  for the #107 evidence campaign. One documented command takes the providers,
  variants, repeats, per-trial timeout, isolated control-plane port and output
  directory; trials get stable provider/task/variant/pair/trial IDs,
  counterbalanced order, and a fresh runtime, home, store and fixture each, with
  only the named provider's credential forwarded. Failed and timed-out trials are
  retained, missing counters stay null, and `--resume` continues after
  interruption without re-running recorded trials. The sanitized report adds a
  computed equivalent-spend column (recorded tokens x public catalog list price,
  with the pricing basis recorded and labelled "list-price equivalent, not
  billed"; Codex uses the OpenAI API list price for the same model, GLM the Z.AI
  catalog), cost per verified success (undefined at zero successes), paired
  wall-time differences, exact revision and sanitized commands. Without `--live`
  it only writes a plan; tests use local fixtures and make no paid calls.
- `lemon doctor --live --provider NAME` checks one named provider and
  `--live --provider all` checks the default plus every configured provider
  (first eight), each with its own `providers.live.<id>` result from the same
  bounded, redacted, non-generating models-list request. Plain `--live` still
  checks only the default provider, and `--provider` without `--live` is a usage
  error; offline doctor is unchanged.

- Unified configurable browser provider selection across browser tools, LCU Chrome
  control, doctor and control-plane browser status. Auto selection prefers ready
  LCU, then an authenticated relay, then local Chrome; explicit providers fail
  closed. Diagnostics expose fixed redacted reasons without starting browsers;
  tool lists probe the provider at most once per build, never when browser tools
  are excluded, and name only the selected provider in tool descriptions.
  Document provider configuration and the shared LCU native-host connector's
  Codex/ChatGPT impact, backup requirements and rollback limitations.

- Status exposes `failed_today` and per-field run-count availability, with
  null-safe TUI and web diagnostics.

- Manage scheduled jobs with `lemon cron` and TUI `/cron`: inspect failures,
  pause/resume, trigger manually, and remove with confirmation by ID or exact name.
- Setup offers local inference servers and custom OpenAI-compatible endpoints,
  optional encrypted keys, and consent-based model discovery with manual fallback.

- TUI startup shows pending setup steps above the prompt, hides them once ready,
  and points empty model lists to `lemon setup provider`; `setup.status` exposes
  read-only, content-free readiness for clients.

- Telegram and Discord support chat-scoped `/approve [id]` and `/deny [id]`
  fallbacks for approval buttons, with unique prefixes and safe disambiguation.

- Lemon Bot for Mac has an optional desktop pet: an original pixel lemon that
  floats above all windows and Spaces, reacts to thinking, tool work, approvals
  and questions, completions, failures and disconnects, and opens the relevant
  conversation when clicked. It loads Codex-format pets (V1 and V2), imported from
  a folder, ZIP or HTTPS URL with size, dimension and path validation; pet
  packages are images only and never run code.

- The lemon desktop pet artwork and its generator are dedicated to the public
  domain under CC0 1.0 (the rest of Lemon stays MIT). The generator can export a
  reproducible Codex pet ZIP with the license included, ready for pet galleries.

- `read` of SQLite `file.db:table:key` now matches canonical numeric keys in
  untyped primary-key columns (`1`, `2.5`) without coercing noncanonical text
  keys (`001`, `1.0`); typed columns are unchanged.

- Inspect per-run lifecycle, tool outcomes, child tasks and usage with
  `lemon runs show <runId>` and TUI `/runs <runId>`, backed by redacted completion events.

- Opt-in, expiring Telegram/Discord DM pairing codes with local-owner approval
  through `lemon pairing`, replacing manual allowlist edits.

- Discord voice notes and audio attachments can use the shared voice transcription
  settings, with bounded CDN downloads and URL fallback on failure.

- Add opt-in `lemon doctor --live` for bounded, redacted provider models-list and
  Telegram/Discord bot identity checks without generating completions.

- Provider status exposes circuit-breaker state, failure counts and recovery delay
  without starting breakers; CLI and TUI status views surface open circuits.

- Rate-limited cron failure and recovery alerts, persistent failure streaks,
  owner-chat fallback, and doctor warnings for failures without a delivery route.

- Provider status and Lemon Bot instance panes now expose the last observed
  provider failure with a timestamp and bounded, credential-free category summary.

- Lemon Bot exposes an authenticated, provider-specific voice catalog for native
  pickers without calling speech providers or generating billable audio.

- Configure TUI shortcuts with `[tui.keys]`, including opt-in plan-mode toggle
  and model cycling, with safe startup notices for invalid or conflicting bindings.

- The debug tool supports adapter-requested DAP child sessions, including js-debug
  launch/attach configurations, child session targeting, and recursive teardown.

- Agent runs continue up to three times after empty replies or malformed tool
  arguments, preserving streamed output and tool results without replaying tools.

### Changed

- Onboarding (`lemon_cli`) resolves canonical provider ids and runtime aliases
  through `LemonAgent.ModelRuntime.ProviderNames`, including `gemini_cli`.
  Onboarding-only conveniences such as `zhipu` and `kimi-k2` remain accepted and
  write canonical ids (`zai` and `kimi`). They are not new runtime aliases, so
  existing custom provider tables, qualified selectors, routing, model overrides
  and credentials retain their identities and behavior.
- The Lemon Bot desktop pet's click-through, drag, click-to-open and live-status
  reaction logic now lives in `LemonBotKit` (`PetInteraction`) and is covered by
  automated Swift tests; behaviour is unchanged. The remaining GUI-only checks are
  listed in `DesktopPet.md` as a manual checklist.

- Outbox message delivery is now at-least-once for the channels whose adapters report an unknown outcome: an unknown
  outcome (`{:outcome_unknown, _}`, adapter exception or worker exit) is retried
  with the same payload and idempotency key within the bounded `max_attempts`
  budget instead of being dropped, and dedupe still suppresses confirmed sends.
  The root `AGENTS.md` never-retry rule for `:outcome_unknown` now exempts
  outbox message delivery only, since a duplicate message costs less than a lost
  one.

- SMTP and WhatsApp deliveries that may already have reached the platform now
  follow that at-least-once outbox policy. An email whose connection to the
  relay is lost once DATA was issued, and a WhatsApp send whose bridge `sendMessage`
  call threw, are reported as `{:outcome_unknown, _}` and redelivered with the same
  payload and idempotency key; the bridge flags such errors `outcome_unknown`.
  XMTP deliveries whose transport call exits are treated the same way. Rejections
  (4xx/5xx replies, authentication failures), a connection lost before DATA and
  failures before a message is handed to Baileys (not connected, unreadable media
  file) stay terminal. An adapter contract test now asserts every built-in adapter
  normalizes ambiguous send outcomes to outcome-unknown.

- Usage budgets now check projected input and maximum output cost/tokens before
  sending model requests, stopping requests that would exceed run or session caps.

- Ordinary bash commands now continue under the session-owned process manager
  when their foreground wait expires, returning a process ID without rerunning
  the command or interrupting output capture. PTY and ACP-client terminal
  timeouts still terminate their commands.

- Lemon Bot web explains channel and X setup, terminal access, file uploads and
  machine-operation progress in plain language. Memory sources have descriptive
  links, template identifiers stay under Details, and machine measurements
  become visibly out of date while their page remains open.

- Clarify Lemon Bot web notification setup and browser registration, distinguish
  server and browser voice samples, and use plain-language microphone guidance.
  Owner settings now name Network access, Startup scripts and Spend limits
  consistently.

- Lemon Bot Apple clients explain uncached offline previews and expose sidebar
  section/selection accessibility state. Mac global shortcuts use an explicit
  native recorder, and Previous/Next Bot have one discoverable menu binding.
  Recorded shortcuts display native Mac modifier symbols while preserving their
  saved combinations.

- Apple voice settings use provider-specific built-in choices instead of requiring
  raw voice IDs, while preserving existing custom voices and explicit saves.

- Pending approvals now expire when their run or session ends, with no grace
  window. The orphaned request resolves as expired (denied), including
  computer-use approvals that have no time limit; a waiting tool call is denied,
  and answering the approval afterwards is refused as expired instead of
  installing a grant. Telegram and Discord approval prompts are edited to
  "Approval: Expired (the run ended)" with their buttons removed, the TUI
  transcript shows `approval expired … — the run ended` (and no longer reads
  timed-out or withdrawn approvals as granted), and `exec.approval.resolved`
  carries `decision: "expired"`. Time-based timeouts are unchanged.

---

## [2026.10.14]

### Security

- Upgrade locked Mint from 1.10.1 to 1.10.2 to fix HTTP/1 response smuggling
  (EEF-CVE-2026-94194), HTTP/2 decoded-header memory exhaustion
  (CVE-2026-91043 / GHSA-9x8p-qrf4-jq7g), and oversized HTTP/2 frame buffering
  (EEF-CVE-2026-92103), without changing dependency constraints or other locks.

### Changed

- Setup finishes with a first coding prompt, a success check, optional Telegram
  and Web UI commands, and an offer to open Lemon immediately after verification.

- Add short, availability-gated system prompt guidance for questions, conversation
  and filesystem checkpoints, structural code rewrites, language servers, debugging
  and external agent delegation, with stable ordering for prompt caching.

- Rotate to healthy alternate credentials or fallback candidates immediately on
  rate limits; bench quota-exhausted credentials for 15 minutes to one hour.

- Native task and swarm subagent spend now counts toward parent run/session token
  and dollar caps without duplicating per-session usage reports; exhausted parents
  cannot spawn further children.

### Added

- Publish a generated TUI command and global-key reference, expose overlooked tool guides in site navigation, and guard against orphaned pages and command-reference drift.

- Show Telegram and Discord typing indicators for chat-originated runs, with
  topic/thread-scoped refreshes and bounded cleanup on completion or cancellation.

- Interactive setup audits an existing Hermes home and offers a confirmed,
  backed-up import without secrets or overwriting conflicts.

- Add offline `lemon usage` date ranges and day/provider/model/session reports,
  plus TUI `/cost --by` breakdowns with explicit completeness and session omissions.

- Add read-only `lemon runs`, `lemon runs active`, `lemon cron runs`, and
  `lemon logs` for headless operators, with bounded redacted offline launcher
  logs and interruptible two-second follow polling.

- Expose `ask` in Telegram and Discord native runs with origin-user-bound option
  buttons, consumed free-text replies, and finite no-answer deadlines.

- Surface-aware Telegram and Discord command help, including model, resume,
  file, checkpoint, and goal controls, plus automatic registration of Telegram's
  public `/` command menu without blocking transport startup on API failures.

- Notify when a TUI `ask` question is waiting, with shared `[tui] notifications`
  modes and a terminal-bell fallback for questions, approvals, and turn completion.
- Add `/copy`, `/copy code [n]` (first block by default), `/copy prompt`, and
  Alt+Shift+C, sharing OSC 52 plus local native clipboard fallbacks with message
  Copy buttons; SSH never invokes host clipboard tools.

- Cron schedules accept relative one-shots such as `in 30m` and timezone-aware
  local ISO timestamps, rejecting past times and retiring after execution.
- Successful prompt jobs can reply with exactly `[SILENT]` to retain history
  without delivering a notification or session summary.
- Cron lifecycle actions accept case-insensitive exact job names and refuse
  ambiguous names with a list of candidates.

- Show per-run tokens, recorded cost, model and provider in recent run history
  and the TUI `/runs` output when usage records are available.

- Dollar-capped sessions warn when the active model has no known catalog pricing.

- Forward Telegram photos and image documents and Discord CDN image attachments
  to vision-capable models, with bounded downloads and text fallback on failure.

- Share one initialized language-server process per server/workspace/config
  across sessions, with reference-counted owners, configurable idle shutdown,
  central document versions, diagnostic fan-out and next-use crash recovery.

- Add default-on `[runtime.tools.bash] git_guard` checks for destructive Git
  commands before all shell launch modes, with a verified task-isolation worktree
  exemption and actionable refusal messages.

- Opt in to a dedicated managed Chrome user-data directory and profile with
  `LEMON_BROWSER_USER_DATA_DIR` / `LEMON_BROWSER_PROFILE_DIRECTORY`, with
  default-directory and profile-lock safety checks and fail-closed identity binding.
- Add opt-in `[runtime.tools.bash.interceptor]` dedicated-tool routing with
  configurable rules, session-tool availability checks and piped-stdin exemptions,
  applied before foreground, background and named-service launches.
- Layer language-server defaults with global/project
  `[runtime.tools.lsp.servers.<id>]` overrides, custom servers, disabling,
  initialization options and environment settings across catalog consumers.

- Native task subagents now have a configurable soft assistant-request budget
  (default 200, per-item override, `0` disables), one optional wrap-up steer, and
  a graceful hard stop at 1.5x that auto-delivers partial findings. Revived runs
  receive fresh budgets, including structured-output correction requests.

- Ask `read` image questions with `?q=` (including SVG `:img?q=`), using a
  configured vision model role or the active image-capable model and returning
  bounded, untrusted answer text instead of pixels.

- Extension tool-call, tool-result and session-start hooks can return bounded,
  ordered `additional_context` for the model, including blocked tool calls,
  without changing result trust, error status or mutation receipts.

- Keep finished native task children addressable: wake idle sessions or revive
  parked sessions with prior context through `write agent://`, with configurable
  idle TTL, explicit delivery receipts and coalesced concurrent revival.

- Read SVG/SVGZ markup as text and render explicit `:img` views as bounded PNG
  previews with librsvg; decoded SVGZ sources enforce the rich-read size limit.
- Expose anchored-edit seen-line enforcement through the validated
  `[runtime.tools.edit] enforce_seen_lines` config key (default false), carried
  through session settings into registered edit tools.

- Add default-on optional `i` tool intent in provider schemas, preserving original
  transcripts while keeping intent out of execution arguments and telemetry;
  show it in approval rationales and existing ACP tool-call titles.

- Add opt-in `enforce_seen_lines` coding-tool options for snapshot-anchored edits:
  remember displayed lines across read windows and refuse unseen targets or
  insertion anchors with actionable range-read hints, including during recovery.

- Add `ls tree: true`: depth-limited newest-first trees with file sizes,
  12 children per directory and explicit omitted-sibling counts.

- Emit content-free tool-call start/stop/exception telemetry with native-unit
  duration, tool name, error outcome and timeout flag, including failed workers.

- Add `report_issue` for short tool-misbehavior notes in a private, bounded
  session-local JSONL log, with timestamp and optional tool name. It requires
  no approval by default and makes no network requests.

### Fixed

- Start core credential storage before cold CLI setup-readiness checks, so
  configured source installs are recognized without starting the agent runtime;
  surface readiness failures instead of silently rerunning setup.

- Preserve observed input, output and cache-token breakdowns in cancelled and
  failed native runs when budget accounting arrives before terminal completion.

- Hermes provider-config import now reports conflicts instead of replacing
  existing values unless `--overwrite` is explicitly requested.

- Stop replaying ambiguous Telegram sends and outbox failures; preserve unknown
  enqueue outcomes and deduplicate Discord transport retries with stable nonces.
- Fail closed for Telegram's unimplemented `local_transcript` voice provider
  instead of submitting synthetic transcript text to the model.

- Classify aborted and crashed run history truthfully, include bounded redacted
  error labels, filter before limiting, and report unavailable history instead of
  an empty list when storage fails.

- Cron restarts catch up one missed slot within a bounded grace window and retire
  expired one-shot reminders instead of moving them to next year.
- Cron run history is pruned hourly to 100 terminal runs per job by default,
  preserving active attempts and pending retries.

- Escape angle-bracket placeholders in generated configuration registry prose so
  VitePress treats paths such as `<root>/agent-tools/node/bin/node` as text, not
  unclosed HTML tags, while preserving existing inline code and alias line breaks.

- Restore the LSP Dialyzer gate by explicitly discarding idle timer cancellation
  results and removing an unreachable nil working-directory branch.

- Re-enter setup for incomplete saved configurations on interactive launch, and
  recognize keyless local providers and environment-only credentials in readiness,
  doctor, and setup verification.

- Make injected SVG rasterizer fixtures portable across BSD and GNU base64, and
  explicitly exclude only the named real-rasterizer test when librsvg is absent.

- Synchronize task-surface regression fixtures with the owning run's delta
  admission before flushing a reused conversation coalescer.

- Keep missing local provider API keys out of shared circuit-breaker health, so
  they cannot block other sessions that have valid credentials.

- Isolate intentional provider outages in ownership probes so their circuit and
  rate-limit state cannot contaminate later cases or repeated runs.

- Gate manual product releases on the source commit before bumping versions or
  pushing tags, build artifacts from the prepared cut, and skip existing CalVer
  tags without deleting unpublished orphan tags.


- Bind TUI fake control-plane listeners to their advertised IPv4 loopback address,
  preventing random test ports from reaching unrelated IPv4 services and timing
  out during command-harness setup.

- Make coordinator active-session lifecycle tests deterministic with per-test
  admission and explicit completion, timeout, cancellation and process-down fences
  instead of racing short deadlines against shared session startup.

- Preserve file-operation details from native assistant tool calls during
  compaction, including patch additions, updates, deletions, and rename paths,
  so subsequent summaries retain the affected files.

---

## [2026.10.12]

### Added

- Read `path:conflicts` to index Git conflict regions, then resolve a session-scoped
  `conflict://N` with `write` and ours/theirs/base/both expansion tokens. Stale ids
  are rejected after file changes.

- Native TUI sessions can now use `ask` through a session-level user-prompt port,
  with question/answer RPC events, multi-choice and free-text UI, and optional
  fail-closed deadlines. ACP form elicitation remains supported. Decline,
  cancellation and disconnect never choose a recommendation or grant approvals.

- Bash supports session/project-scoped named services with log-regex or loopback
  TCP readiness checks, restart-by-name, and existing process inspection/stop tools.

- Opt-in model `checkpoint(goal)` / `rewind(report)` retain exploration findings
  as branch context without restoring files or prompting for confirmation.
  Enable `[runtime.tools.checkpoint] enabled = true` (default off). The former
  filesystem `checkpoint` tool is now `fs_checkpoint`, with no alias.

- Web search parses common query operators, reports dropped constraints, and
  preserves freshness across capable fallback providers. Guarded web fetches
  halt oversized response streams at a configurable 5 MiB default.

- Add opt-in `memory.write_approval` and `skills.write_approval` for human review
  of agent-authored durable facts and skills through existing execution approvals.
  Previews are bounded, escaped and redacted; denied/unavailable approval writes
  nothing, and unattended background review, cron and unsupported channels fail closed.

- Add `lemon learning`: a bounded, redacted, profile-isolated timeline over
  existing memory and skill timestamps, with kind filters and JSON output.
- Add a protected Learning page in Lemon Web, grouped by UTC day with profile
  and kind filters, escaped previews, and links to existing memory/skill management.

- MCP hosts refresh cached tools, resources and prompts on server list-change
  notifications, reconnect dropped clients with bounded backoff, and suspend
  crash storms with redacted unavailable status.

- Native tool policies support read/write/exec approval tiers and configurable
  ask/write/yolo defaults, preserving per-tool overrides and parent floors.
  Approval is resolved against hook-rewritten arguments. Canonical web config
  now retains the guarded-fetch response body cap.

- Lemon Web omp adds parallel worker starts and a live usage grid, searchable
  free-marked model selection, live model/thinking configuration with explicit
  partial-failure receipts, and bounded subagent transcript drill-down.

- Preserve tool-owned deadlines for omp waits, media workers, A2A peers, MCP,
  SMS verification, computer use and configurable Honcho requests instead of
  cutting them off at the generic five-minute tool deadline.

- Admin-only control-plane `system.restart` and `system.stop` acknowledge before
  acting, serialize runtime lifecycle requests, and preserve launcher ports and
  source distribution identity across a detached restart.
- Hermes migration previews and imports supported Honcho settings from global or
  profile-local JSON, preserves active-host precedence, and reports unsupported
  options. API keys use the gated encrypted-secret path, with conflict protection
  and no plaintext fallback. Honcho reads persistent global `[honcho]` settings
  and encrypted credential references without adding a platform dependency.

- Control-plane status reports the real Lemon release version, build identity,
  offline provider credential presence, timestamped redacted channel health,
  lifecycle availability and safe summary counts.
- Computer use can be configured in `[runtime.tools.computer_use]` (`enabled`,
  `chrome`, `lcu_root`, `node`, `declined_origins`); environment variables still
  take precedence. Execution-node capability inspection reports a
  `computer_use` item, and tool cards and approvals name the computer-use
  action, app or site.
- omp tool cards show parallel worker grids, combined usage and task errors,
  approval waits, isolated worktrees, child activity, model prices and transcript tails.
- TUI omp delegates support redirect, interrupted-session continuation, approval
  mode and isolated starts; the typed control-plane client exposes batch starts,
  model discovery, configuration and subagent transcripts.
- `recall` can browse owned recent sessions and scroll chronological, bounded
  run summaries around a document/run ID without crossing owner/profile boundaries.
- The omp panel resolves pending approvals through the shared approval controller,
  selects free-marked omp models, and drills into subagent transcript tails.
- Main-session learning reminders suggest saving durable facts/preferences with
  `remember` every 10 user turns without a save, and creating/patching a skill
  after a completed run uses at least 15 tools without `skill_manage`.
  Configurable through global/project `skills.json`, these bounded volatile
  reminders exclude subagents and make no extra model calls.

- Lemon-run omp sessions now keep private history under Lemon's per-user
  `omp/sessions` directory instead of mixing with interactive omp sessions.
  `LEMON_OMP_SESSION_DIR` / `config :lemon_omp, :session_dir` selects a custom
  directory; `omp` opts out. Read-only discovery tags both sources and resume
  continues the matching original history in place. Live smoke transcripts
  now use temporary directories, not the developer's omp history.

- Live omp workers can change model and/or thinking without restarting through
  owner-scoped `LemonOmp.configure/3` and the chat tool's `configure` action.
  Changes apply from the next model call, including during running turns;
  correlated acknowledgements, refreshed snapshots and partial-application
  errors preserve truthful outcomes without rollback or automatic retries.
- omp discovery includes sessions in kept managed Git worktrees, and resume
  automatically reuses a validated worktree in the caller's repository with
  conservative cleanup ownership restored.

- omp task subagents expose bounded activity, tool counts, tokens/cost, model,
  duration, final output and retry errors in status and streamed progress.
  Owner-scoped `LemonOmp.subagent/3` and the `omp` tool's `subagent` action read
  sanitized transcript tails from live parent sessions.
- omp's chat tool and Elixir API can redirect a running turn atomically with
  `abort_and_prompt`. Existing waits follow the replacement turn; asynchronous
  prompt failures are reported without acknowledging the same command twice.
- Explicit omp crash continuation (`resume` with `continue: true`) through a
  state-review prompt, plus a bounded read-only discovery `interrupted` hint.
  This does not revive subagents; omp's native `--restore` is interactive-only.
- omp workers support opt-in per-worker Git worktree isolation through `isolate`
  on starts and batch tasks, with managed branches, merge instructions, and
  bounded cleanup that preserves uncommitted or committed work.
- Cached omp model catalog through `LemonOmp.models/1` and the `omp` tool's
  `models` action, with cheap/free filtering, pricing and upstream availability warnings.
- Computer use: with `LEMON_COMPUTER_USE_ENABLED=true`, Lemon agents get
  `cua_js`/`cua_js_reset` to operate native apps through the ChatGPT desktop
  app's computer-use runtime via LCU. Per-app approval requests become Lemon
  approvals (once or for the session); Lemon's own apps are never approved.
  See [Computer use](docs/tools/computer-use.md).
- Computer use can drive Chrome tabs (`LEMON_COMPUTER_USE_CHROME=true`, LCU's
  `--chrome` surface through the official ChatGPT extension). Website access
  requests become Lemon approvals for the origin; Lemon's own local web and
  control-plane origins are never approved.
- Computer use also never approves the Lemon Bot web client (its
  `LEMON_BOT_PUBLIC_URL` origin and development port) or origins listed in
  `LEMON_COMPUTER_USE_DECLINED_ORIGINS`.
- omp sessions can select an approval mode and bridge tool approval prompts to
  Lemon's conversation/channel approval UI or operator `exec.approval.resolve`.
  Snapshots and wait progress expose pending approvals and decision counts;
  cancelled dialogs and ended sessions clean up pending prompts.
- MCP clients accept an optional asynchronous `notification_handler` callback for
  server notifications, including tool, resource and prompt list changes.
- Expanded the LSP registry from six to 42 primary language servers, with
  installation hints, unique extension ownership, and case-insensitive
  `LemonLsp.Servers.language_id/1` lookup.
- Parallel omp workers: the `omp` tool can start a validated batch concurrently
  with `start_many`, gather all or any worker with `wait` and `ids`, stream
  throttled combined progress, and report per-task failures and total usage.
  The Elixir facade exposes `start_many/2` and `wait_many/3` with owner scoping.
- Opt-in real omp lifecycle smoke using a free model, covering tool writes,
  follow-ups, cancellation, process cleanup, discovery and resume.

### Changed

- **Honcho behavior change:** unaliased non-owner gateway senders now get their
  own platform-qualified peer even without a runtime prefix. Explicitly paired
  Telegram owners retain `user_peer`; use `pin_user_peer = true` or aliases to
  restore pooled memory. CLI/TUI/web identity is unchanged.
- Add opt-in bounded background learning reviews, with private-memory ownership,
  draft-only skill creation, restricted tools, per-session rate/concurrency
  limits and no conversation/channel delivery; reminders remain the default.
- Honcho channel turns support pinned users, many-to-one sender aliases and
  platform-qualified peer prefixes. Per-peer context follows each sender,
  bot-authored turns are not uploaded, and Hermes migration imports these settings.
- Bring Lemon Web's omp controls to parity with approval decisions and overrides,
  isolated starts, interrupted continuation, redirect, and worktree/discovery details.
- Expand `lemon omp` with approval modes, isolated and parallel starts, explicit
  interrupted-session continuation, redirect, model browsing/configuration,
  subagent transcripts, and richer approval/worktree/discovery output.
- Extend the omp operator API with bounded parallel starts, model discovery,
  child transcripts, live configuration, approval overrides, isolated starts,
  interrupted-session continuation and redirect delivery; preserve actionable
  partial-application and outcome-unknown errors.
- Preserve portable Agent Skills string-valued metadata (including `metadata.lemon`)
  and support 1024-character Unicode descriptions. Add conformance/discovery
  coverage for spec fields and bundled resources; document legacy leniency and
  clarify that synthesized skills remain drafts until promotion.
- Remember supports exact-entry or unique-substring edits consistently across scoped
  and legacy memory, with actionable ambiguity, safety, and capacity feedback.
- Agent prompt memory blocks show deterministic character/fact/byte capacity
  headers and recommend consolidation above 80%; subagents remain isolated.

- Internal callers use canonical agent trust/abort helpers and `LemonCore.Id`;
  obsolete wrappers, unused renderer/coalescer behaviours and unused translation
  backends are removed without changing active tool or simulation behavior.

### Removed

- The broken `bin/lemon-dev` launcher, which passed flags the TUI no longer
  accepts. Use `./bin/lemon` (source runtime plus TUI) or `./bin/lemon-tui`.

### Fixed

- Serialize environment-mutating diagnostic and configuration fixtures so a
  temporary extension-disable flag cannot leak into unrelated tool inventories.
- Isolate status metadata tests from CI commit variables while retaining packaged
  GitHub build provenance coverage, and wait for coordinator registry cleanup in
  controlled restart fixtures.
- Repair TUI protocol-test lint, document the onboarding terminal error's
  non-returning contract, and explicitly opt automated source-install onboarding
  into non-interactive mode.

- Release preflight fixtures retain built-in provider registrations, distinguish
  pending approvals from retained resolutions, and exercise typed provider errors
  and asynchronous subagent cleanup without cross-test state leaks.
- The Learning page reads its bounded, profile-scoped timeline through the
  authenticated control plane instead of adding a forbidden Web-to-Skills dependency.
- The TUI stops retrying rejected operator credentials, shows token recovery
  steps, and keeps offline prompts in the editor instead of silently queueing.
  Connection failures and `/reconnect` report actionable outcomes; `/status`
  includes profile/model, theme changes say whether they were saved, and
  command suggestions no longer mistake `/faq` for the `/q` queue alias.
- Make source and packaged launcher lifecycle results truthful: foreground health
  is visible to status, unreachable runtimes fail status, foreign listeners fail
  stop/restart, and failed daemon health waits clean up their processes. Validate
  lifecycle ports, explain missing Mix/curl, show selected home/ports/logs, and
  render source help without compiling or creating credentials. Status RPC adds
  the runtime profile and configured default model ID without exposing home paths.
- Configuration loads now reject invalid resolved values, report expected types
  without echoing supplied values, and name input files. CLI and Mix summaries
  agree on unset/false values and identify environment overrides.
- Remove obsolete runtime-theme and vendor-CLI environment documentation, refresh
  the generated environment registry, make example credentials/bindings opt-in,
  and resolve XMTP wallet environment references before connecting.
- Normalize non-OpenAI control-plane HTTP errors to code/message envelopes,
  name authentication headers and credential sources, omit non-JSON error
  details safely, and distinguish unavailable status subsystems from empty results.
- Web chat model-list and compaction failures now show plain-language next steps
  pointing to Diagnostics instead of exposing service error terms.

- Channel status details no longer mistake a running adapter process for an
  observed connection; Discord READY/resume and startup failures update the
  redacted health projection.
- All skill curator entry points now protect cron-referenced skills, including
  disabled jobs, while preserving explicit exemptions. Automatic archival fails
  closed with a reported reason when the automation provider is unavailable.
- Recall browse/scroll now require the same verified private ownership as history
  search; legacy or partially verified contexts fail closed.
- Skill usage recording no longer depends on the introspection handler. Pinned
  skills reject content edits, never-used skills retain a stale-age grace floor,
  and background curation preserves skills referenced by disabled or active cron jobs.

- Chat, task, provider and goal/cron failures use plain-language recovery steps
  instead of raw Elixir terms; provider authentication names the credential to
  check, and Discord approvals distinguish expired controls from unavailable service.
- Setup now hides pasted API keys, fails safely without a terminal, re-verifies
  existing providers before claiming completion, distinguishes pending onboarding
  from failure, and validates runtime input; packaged remediation, setup flags,
  diagnostics hints, help errors, and duplicate completion entries are corrected.
- Configuration commands reject malformed TOML with file-specific guidance,
  doctor continues after failed checks, and CLI validation and migration show
  actionable recovery steps instead of internal error terms.

- Provider-ownership probes inspect complete events and logs so large tool
  schemas cannot hide credential refusal or leaked values. Integration tests
  retain committed-output retry fences and drain bounded session subscriptions.
- Native config-watcher crashes fall back to polling instead of shutting down
  the core application and its dependants.
- Execution admission validates supplied tool policies and intersects inherited
  restrictions instead of accepting malformed or authority-widening overrides.
  Root and delegated execution contexts bind identity, workspace, capabilities
  and limits; named nodes apply their destination-local capability ceiling.
- Failed selected OAuth logins cannot borrow static or environment credentials
  or transmit encoded OAuth records. Public selected-credential callbacks preserve
  `nil` refusal rather than reviving a cached token; successful access-token
  authority and explicit credential-pool/default fallback remain supported.
- Anthropic-compatible providers no longer implicitly send another provider's
  `ANTHROPIC_API_KEY`; exact-target API-key and keyless behavior remain supported.
- Stopped native plan transitions journal the configured `@plan` model and
  preserve the prior execution model. Restart uses that journal, and exit or
  approval restores the prior model without rewriting invalid transitions.
- Provider sign-in status and logout distinguish missing credentials from
  encrypted-store, journal and master-key failures. Failed reads refuse the
  command without deleting logins or clearing the selected OAuth authority;
  logout also reports deletion failures without changing provider settings.
- Keep omp worktree cleanup ownership until the Session monitor and pending
  cleanup finish, even when ended-session cache eviction runs after an early
  terminal snapshot.

- Lemon Bot for iPhone keeps the composer and Send button above the keyboard,
  follows the latest message as the viewport resizes, and uses Return for a newline
  instead of submitting and dismissing the keyboard; transcript dragging dismisses it interactively.
- Operator-owned omp approvals bind session-scoped grants to one omp invocation,
  preventing a grant from approving identical actions in another operator session.
- New memory backdoor/exfiltration screening no longer invalidates retained facts
  or prevents editing/deleting them; new text and patched results remain screened.
- Correct stale install, quickstart, browser authentication/routes, and TUI
  instructions, provider-model examples, and documentation navigation.
- Durable preference/project memory supports exact-first unique-substring
  patch/delete and rejects persistent backdoor/exfiltration instructions.
- Web chat keeps run status visible on mobile, distinguishes unavailable checks,
  improves recovery guidance, and makes login and navigation more accessible.
- Honcho tool schemas now register only when the integration is configured and
  enabled, matching its memory provider and context contributor instead of adding
  five inactive tools to prompts on unconfigured hosts.
- Native dynamic-preset resolution binds discovered context, output limits,
  reasoning and input capabilities to the effective endpoint, headers and
  selected credential. Default/environment cached metadata no longer bleeds into
  configured native sessions; qualified defaults, provider-native colon IDs and
  existing credential fallback semantics remain supported.
- Custom-provider discovery and cache-only model resolution use the selected
  healthy credential-pool principal, keeping picker and native request authority
  aligned without exposing another pool or ambient provider credentials.
- Native provider routing preserves credential-rejection sentinels instead of
  clearing them, so Codex cannot fall back to ambient tokens without a valid
  `auth_source`.

### Lemon Bot

- Instance status exposes release/build metadata, provider credential health and channel errors. Owner-confirmed restart/stop can use a remote controller, with lifecycle completion observed from link events; clients use explicit available action lists.
- Apple clients show Lemon build, provider credentials and channel errors, with action-aware local launcher and remote lifecycle controls.
- Lemon Bot web shows build identity, provider credentials and timestamped channel health, with available-action lifecycle controls and clear local-launcher versus remote-controller guidance.

- Apple Mac message actions appear only on hover or keyboard focus, with matching VoiceOver actions and context menus instead of permanent transcript toolbars.
- Apple conversation and composer screens explain uploads, unconfirmed sends and offline drafts without resending, simplify delivery/gate/privacy copy, and use grouped Mac sheet layouts with clear actions.
- Web clients use plain-language recovery and account/pairing flows, retry failed history loads, hide technical references in Details, confirm deletions in-app, and improve touch actions, status labels and contrast.
- Web machine enrollment uses consistent machine labels and clearer trust and connection guidance; Bot creation recovery headings explain checking existing Bots and groups before creating another.
- Apple clients simplify Bot lifecycle, account deletion, apps, notifications and voice copy, use workspace/machine terminology, and apply shared semantic color and typography tokens.
- Apple clients recover from failed Bot loads and terminal closes, explain unavailable actions, preserve Preferences across pane switches, and confirm sign-out.
- Web Settings adds Lemon instance details, live service/link/runtime measurements, owner-confirmed lifecycle controls and operation output, with direct recovery and About links.
- Apple clients use plain-language errors with copyable details, clearer iPhone pairing labels, and status checks for unconfirmed actions without automatically resending them.
- Web clients explain service, network, session and Lemon-link failures with live retry timing, real connection restart and owner recovery actions instead of silent sign-out or stuck disconnected screens.
- Apple Settings adds a shared Lemon instance pane with live backend/controller/Lemon measurements, owner-confirmed start/stop/restart, operation polling and output details, plus direct recovery/About links.
- Apple clients explain backend, network, sign-in and Lemon-link failures with live retry timing, service discovery and shared recovery controls; sandboxed Macs offer copyable local-start commands rather than launching a daemon.
- Name missing required Lemon Bot startup settings without a stack dump, keep
  operator configuration details in server diagnostics rather than owner errors,
  and clarify backend/SDK setup and contributor documentation.
- Add truthful attached-instance status, controller reconnect (including rejected
  credentials), and opt-in owner-only local runtime start/stop/restart with
  bounded operation receipts. Publish TypeScript SDK helpers, Swift Codable
  mirrors and a shared backend-produced fixture.

---

## [2026.10.9]

### Changed

- Lemon Bot clients are redesigned around messaging. Mac, iPhone and web share
  one design: a sidebar with pinned lemon avatars and Bot status lines, a
  floating Bot header that opens an Activity/Details/Library inspector, grouped
  bubbles, a live working row with Stop, quiet failed-run rows with Details,
  a floating composer, and admin grouped under Settings. The web app supports
  iPhone Safari and Add to Home Screen.

### Fixed

- iOS builds without the App Group (for example, Personal Team installs) keep
  in-app attachment staging working, and the passive staged-file refresh no
  longer raises a stuck "native input" error.

---

## [2026.10.8]

### Fixed

- Lemon Bot standalone backend/web release artifacts now build with the Bun
  version their lockfiles require (`products/lemon_bot/.bun-version`). The
  2026.10.7 tag was cut but never published because those artifacts failed to
  build; this release publishes everything listed under 2026.10.7, including
  the first owner-only Lemon Bot preview and the secure host join flow.

---

## [2026.10.7]

### Added

- Lemon Bot for Mac and iPhone is now a messaging-first app. The sidebar lists
  your Bots with pinned avatars, label chips, last-message previews and unread
  dots. Each conversation has a floating Bot pill, grouped bubbles in the Bot's
  color, date separators, hover and long-press message actions, a typing
  indicator, and a quiet "Couldn't finish this. Retry · Details" row in place of
  empty failed-run bubbles. Retry only restores your message to the composer.
  The composer is a floating pill, and a live "working…" row shows the current
  step. A right-hand inspector, a sheet on iPhone, has Activity, Details and
  Library tabs. Machines, connectors, channels, policies, usage, account,
  devices, Connect iPhone and workspace admin now live in Settings. Bots use the
  recolorable wonky-face lemon mascot. Dark and light modes, Reduce Motion and
  keyboard shortcuts are supported: ⌘K search, ⌘N new Bot, ⌘F find, ⌘[ and ⌘]
  or ⌥↑ and ⌥↓ to switch Bots, ⌘1–9 to jump to a Bot, and ⌥⌘I for the
  inspector. A DEBUG-only `LemonBotSnapshots` scheme renders fixture screens
  to PNG.

- Keep native root target/policy/destination bindings through durable admission
  compaction, including proofless startup receipts and queued activation fences.
  Native agent/task follow-ups allocate their fixed ID before proof admission.
  Synchronous start failures retain their known error and terminal replay fence
  when terminal persistence races admission acknowledgement.

- Machine invitations now return a short, credential-free repository join-script
  command and a separate one-use code. The script reads hidden terminal input,
  sends enrollment only through `--invite-code-stdin`, restores echo on exit,
  and reuses compatible pinned Lemon installs before invoking the existing
  installer. Source selection, exact version and capability gates remain
  fail-closed; the argv enrollment-code flag is removed. Unknown enrollment
  exchanges stop instead of replaying the invite. Packaged commands fetch
  `join-node.sh` and canonical `install.sh` from the same exact release tag,
  never mutable `main`; installation requires a bot-capable full/min runtime
  via `--require-bot`, not the standalone backend artifact. `--require-bot`
  installs no TUI and promotes a runtime only after its own exact-version
  `node capabilities` gate passes; an exact pin accepts its manifest's channel
  (preview/nightly) unless `LEMON_CHANNEL` is explicit. Invitations issued by a
  packaged release always pin that release instead of its build machine's
  checkout. Source commands invoke the provisioned checkout's join script directly.

- Standalone Lemon Bot release bundles contain the native backend and complete
  external web assets for Linux x86_64/arm64 and macOS arm64. Schema-2 release
  metadata records their checksums and sizes; the canonical installer verifies
  the selected bundle and keeps backend installation isolated from Lemon runtimes.
- Correct destination-local MCP URL parsing so normal HTTPS authorities and
  Unicode hostnames reach the existing exact-origin and DNS-pinning checks;
  credentials, malformed ports and unsafe authorities remain rejected.
- Host join reuses a compatible existing PATH installation and starts its
  worker without binding the desktop runtime's health-server ports. Enrollment
  stdin also supports standard in-memory IO devices without accepting argv secrets.

- Operator `chat.send` and `profile.chat` accept fixed upstream run IDs with
  durable same-intent replay protection and conflict rejection. Queue-owned
  receipts report actual new/queued/merged/steering/interrupt targets rather
  than echoing requested modes; `runs.receipt.get` reconciles lost responses
  without dispatch. Unknown outcomes retain the original nonretryable ID.
  Stable-storage barriers precede dispatch and merge effects and protect receipt
  acknowledgements/readback; failed barriers never authorize another send.
  Private invocation-context keys isolate shared-session queue controls, merging
  and native standing approvals across principals, policy and connector epochs;
  changed execution capabilities queue their own run instead of steering an
  older runtime with broader credentials.
  Verified memory identities keep private native recall/capture separate from
  shared rooms; standing session/agent grants and native resume/compaction history
  cannot cross execution contexts. Explicit admin shared-memory intent remains
  separate from private automatic capture. Bound per-run MCP proofs mask only
  their exact attested header value during context comparison, never transport.
  Fresh native task/background/delegated follow-ups reserve their own ID, verify
  sealed lineage through a private backend issuer and provision new proofs before
  independent execution; unknown outcomes never replay a completed root proof.
  Remote private execution requires fresh advertised privacy-context support and
  atomic exact-node/connection/session-generation fences. Public raw native node
  calls reject private attestation and lineage aliases rather than minting trust.
  `agent.wait` supports answer-free terminal status queries. `runs.active.list`
  reports complete pre-limit active/queued/unknown presence, actual profile/source
  dependencies and explicit unavailable failures instead of unsafe empty results.
- Lemon Bot product architecture and dependency-free client/backend contracts:
  authenticated local/OIDC accounts and SCIM directory provisioning, durable
  named teammates on user-owned swarm machines, typed REST/realtime/MCP,
  scoped cards/approvals/drafts, attachments/voice/push, skills/routines/memory,
  provider integrations, applied host policies and self-hosted usage controls.
  Includes web/macOS/iOS screen contracts, all 101 Grok behavioral mappings
  and all 16 adopted Muse companion/control features, with explicit provider
  prerequisites and no virtual-desktop or demonstration-recording claims.
- Lemon Bot owner-only live-resource cutover: removed Team publishing,
  managers/default Bots, other-human groups and cross-human connector lending.
  Chat, cron, channel, handoff and helper work retain the actual Bot owner.
  Added named desktop-to-iPhone QR preview/claim/approval/completion contracts,
  private fixed-nonce same-device/session receipt recovery and explicit null
  paired-session expiry until revocation; ordinary sessions stay bounded.
  Updated owner-first screens, card taxonomy and all 101+16 design mappings.
- Lemon Bot secret-free integration/channel/email/X provider discovery,
  verified own-account channel linking initiation and exact event-filter
  schemas, with operator-reviewed connector/private-origin/setup inputs.
- Lemon Bot broad channel-message routine opt-in and a strictly read-only,
  metadata-only audit collector scope for workspace integration tokens.
- Clarified Lemon Bot file chunks retain the owning node's total source-file
  size, with actual chunk length measured from decoded bytes for progress.
- Lemon Bot mailbox accounts expose optional measured provider indexing
  status/time instead of fabricated eventual-indexing warning labels.
- Lemon Bot group receipts distinguish proven per-target rejection from
  admitted work and genuinely uncertain dispatch without automatic replay.
- Lemon Bot groups have explicit own-member leave and successor selection,
  preserving other members' history and truthful membership-loss events,
  with owned active room work terminalized before membership revocation.
- Lemon Bot Owners can observe bounded account-teardown receipts after
  session revocation, with explicit OAuth revocation/introspection settings
  and no deleted-account restoration or mutation replay.
- Pending Lemon Bot X OAuth connections keep unverified identities null
  rather than exposing fabricated or empty account IDs/usernames.
- Lemon Bot OIDC uses explicit operator-approved HTTPS origins, private-IdP
  DNS exceptions and exact client/secret-reference destination bindings.
- Canonical Lemon Bot private configuration now types delivered host/export
  grants, OIDC mappings, separate public X credentials, actual provider spend
  sources and fixed channel app principals without an untyped extras bag.
- Named execution-node runs now stream live chat deltas, tool activity and
  checkpoints through the controller's normal run/session events. Invocation-bound,
  sequenced `node.invoke.event` frames reject foreign/stale node sessions, ignore
  duplicates and enforce bounded payload/backpressure limits. Remote tool approvals
  use the controller approval store and return decisions to the owning worker;
  disconnects and timeouts fail closed. Terminal results, cancellation and
  steer/redirect retain their existing semantics.
- Profile placement for arbitrary `chat.send` sessions and cron agent jobs via
  `profileId`, resolved at execution time for routines. `profiles.update` edits
  persona, model, node and per-profile Streamable HTTP MCP servers. MCP headers
  are write-only in management responses and excluded from run persistence.
- Profile-scoped `memory.list`, `memory.search`, `memory.get`, `memory.add` and
  exact-confirmation `memory.delete` control-plane methods. They reuse durable
  memory lifecycle and assistant workspace preference services, enforce separate
  read/admin scopes, and return bounded redacted previews. Named-node profiles
  execute memory operations on their destination through authenticated node
  invocations, without controller paths or credentials crossing the boundary.
- Private, admin-only `memory.transfer` for machine moves: full scoped memory
  and assistant preferences copy through authenticated node invocations with
  durable mutation-bound receipts, create-only defaults, exact source/target
  digest-bound overwrite previews, and explicit read-only `memory.transfer.status`
  reconciliation after uncertain outcomes. Placement stays unchanged until the
  caller explicitly switches it.
- Explicit private/shared memory management selections, exact worker scope echoes,
  full-fact preference search and owned indexed search with bounded 512-codepoint
  queries. Private preferences remain in the existing memory owner rather than
  shared workspace files; intentional shared facts have canonical provenance.
- Attached-machine control-plane APIs: destination-local host information,
  policy-rooted chunked file transfer, connection-owned real PTY terminals and
  write-only encrypted node secrets. Single-use, expiring, name-bound node
  invitations install and enroll a bot machine without sharing the operator
  credential; node listings include purpose and labels. See
  [attaching a bot machine](docs/user-guide/attaching-a-bot-machine.md).
- Attached-machine safety: exact durable-ID routing cannot be hijacked by a node
  named after another node's ID. Worker-owned file CAS, atomic no-overwrite moves
  and revision/candidate-bound deletion previews use descriptor-relative root
  admission. Revocable repair invites retain durable identity and generation
  fences; label records and enrollment proofs support reliable reconciliation.
  Machine inspection reports measured host resources and explicit capability/
  OS-grant states without fabricated metrics or permissions.
  Supported shell inventory includes the actual registered `lsp_diagnostics`
  builtin for destination-local checks; diagnostics remain file-and-shell
  read-interact operations with tool approval, never baseline permission.
- Worker compatibility is measured by `lemon node capabilities --json --require-bot`
  and authenticated `node.runtime.features`, not inferred from a release number.
  Invite commands select the actual integrated source checkout or an explicitly
  pinned operator-supported artifact, verify the installed version/features, and
  fail before enrollment when required APIs are absent. No published build is
  silently treated as supporting new bot APIs.
- Fixed secret operation IDs persist an atomic private receipt with the encrypted
  destination vault row. Admin-only `node.secrets.receipt` reconciles lost replies
  without replay, plaintext or digest exposure; replacement, deletion, expiry
  and rotation safely invalidate current binding while retaining historical proof.
  Vault/lease error diagnostics are redacted. PTY opening cwd uses the filesystem
  descriptor resolver, and browser availability inspection never launches a browser.
- Registry dispatch can atomically pin a preceding inspection to an exact live
  node PID and require the native privacy-context protocol before sending private
  arguments. Reconnect or missing protocol support is a definite admission failure,
  never a request sent to an old worker and rejected only after its response.
  Bot readiness requires the actual native privacy descriptor as well as the
  large-policy JSON helper, preventing a nominally compatible old protocol from
  being reported ready for private bot execution.
- Profile MCP headers support explicit `${LEMON_SECRET:NAME}` references resolved
  exclusively from the encrypted secret store on the execution host. Missing or
  failing secret reads fail closed before MCP clients start; controller requests
  keep references unchanged and never substitute environment values.
- Canonical read-only `usage.records` with millisecond range/run/session filters,
  filter-bound pagination and native local/named-node run attribution. Actual
  response prices preserve known zero versus unknown cost; missing historical
  attribution and aggregate-only history are explicitly incomplete. Durable
  run/usage-occurrence dedupe survives ledger restart. `usage.cost` now identifies
  its known-cost subtotal and completeness, delegates recording to the core owner,
  and propagates unavailable storage as an error.
- Profile-backed cron jobs can require private, authenticated product admission
  before every dispatch. Decisions bind the actual owner/workspace/profile and
  fixed run receipts; denial or unavailable admission never launches or retries
  work. Trusted operators provision encrypted per-routine tokens through
  `cron.admission.set`; callback credentials remain absent from public cron
  projections. Origins are explicitly allowlisted, with HTTPS except literal
  loopback HTTP for local development.
- Destination-local `node.mcp.discover`, exact executable `enabledTools`
  allowlists, and principal-specific `chat.send.invocationMcpServers` replacement
  without inheriting owner credentials. Product MCP origins are checked and DNS
  pinned on the worker before secret resolution; transports retain Host/TLS
  identity, reject redirects, and separately authorize OAuth metadata origins.
- Acknowledged `profiles.sync` persona provisioning on a selected destination
  before placement changes, preserving destination credentials and mutable
  memory with verified revision/mutation bindings.
- Read-only `profiles.sync.status` reconciles lost provisioning responses with
  durable destination mutation/digest receipts, distinguishing acknowledged,
  pending, unknown and unavailable without replaying private persona content.
- Persistent native profile `toolPolicy` and restrictive
  `chat.send.invocationToolPolicy` floors apply to canonical, task, DM, group
  and cron execution; caller overrides cannot widen native hard ceilings.
  Profile HTTP discovery exposes stable `executionName` aliases whose actual
  calls obey native denial and required approvals, not advisory server hints.
- Profile names support 120 Unicode scalar values and exact 128 KiB system
  prompts. Rich execution JSON budgets support complete 16,384-entry native
  grants without changing unrelated JSON traversal limits.
- Read-only `node.profile.paths` exposes authoritative destination workspace/
  skill paths for selected profile provisioning without guessing controller
  state or granting new filesystem roots.
- Pure operator-read `mcp.execution_names` projects exact native profile HTTP
  tool aliases before profile creation, without HTTP/DNS initialization, secret
  configuration or JavaScript guesses at the native identity encoding.
- Authenticated cron admission receipts can project a Team routine creator's
  current execution/private-memory scopes, destination-only connector references,
  restrictive native policy, and fresh fixed-run core proof. The shared native
  factory checks the actual profile-built request before launch; stale proofs
  and shared-memory grants fail closed, without storing the private projection
  in cron job metadata, runs, events, or audits.

### Fixed

- Node-only control-plane methods (invocation results/events/control results,
  native follow-up and lineage floor) now require the authenticated node role
  before any scope check, so operator credentials carrying node scopes are
  refused.

- Lemon Bot clients normalize trailing-slash backend origins without duplicate
  API path separators. Web form labels and body text remain legible in dark
  appearance, including onboarding before sign-in.
- Lemon Bot native startup defers macOS Services registration until AppKit is
  initialized. UIKit terminal colors, Carbon sizes and nested voice bindings use
  their actual platform APIs without replacing capture owners or masking errors.
- Pending execution-approval events redact nested credentials and rationale
  secrets before reaching clients, while preserving visible review targets.
- Private cron admission accepts valid allowlisted callback URLs without
  depending on URI's deprecated authority field; malformed empty ports remain
  rejected without weakening callback origin or receipt checks.
- Cron jobs now evaluate IANA timezone names with real UTC offsets and
  daylight-saving rules. Missing spring-forward slots are skipped; repeated
  fall-back slots use only their first occurrence. Invalid/unavailable zones
  are rejected on creation/update instead of silently scheduling in UTC, and
  timezone-only updates recompute the next run.

- Execution approval resolution now returns an owner-verified outcome and actual
  decision instead of acknowledging stale or unknown prompts. Optional exact
  session/run bindings are atomically checked with the pending snapshot; expired,
  cancelled and conflicting decisions fail closed. Redacted retained receipts
  allow only exact-bound same-decision replays, without reinstalling grants.
  Named-node workers retain failed approval resolutions for teardown and bind
  successful decisions to their invocation's run and session.
- Standing session/agent tool approvals for context-owned team runs are now
  isolated by their trusted private principal/policy context. Another user or
  changed policy cannot inherit a grant through a shared bot session, nor fall
  back to a legacy unscoped grant. Public identities are unchanged; private
  context remains in typed owner storage and is excluded from wire projections.
  Explicit operator global/node grants and nil-context native scopes are retained.
- Named-node profile chat no longer inherits the controller's default working
  directory. Profile persona instructions and MCP connections accompany the
  execution request, while provider credentials remain destination-local.
- Subagent coordinators remain responsive to active-session queries and cancellation
  while child sessions are starting, rather than blocking those requests behind
  synchronous session initialization. Terminal answers and provider errors survive
  cancellation during cleanup, and late admissions retain a cleanup owner even if
  their execution worker dies during startup.

- Execution-node workers no longer crash when cancellation, disconnect or event
  delivery failure occurs after a native runner has finished but its live events
  are still draining. Finished runners are not cancelled again, concurrent runner
  exits are tolerated, and invocation/approval cleanup still completes.
- Mutable `USER.md` preference memory is destination-owned, never replaced by
  controller persona snapshots. Subsequent session bootstrap reflects real
  user-memory additions and deletions.
- Profile sessions no longer inherit ambient machine-global MCP credentials;
  selected destination-owned skills remain available with an independent
  execution cwd and load their full bodies lazily through `read_skill`.
- Remote image-only requests encode validated native image blocks as the
  established wire format, preserving five-image/10 MiB aggregate admission,
  strict MIME/Base64 validation, configured transport bounds and vision checks.
- Implicit profile synchronization now prefers an exact stored durable node ID
  even while offline, preventing a node with that ID as its name from receiving
  another machine's private persona. Legacy names resolve only without an ID
  record; explicit target IDs remain ID-only.
- PTY descriptor-policy startup no longer imports a running filesystem packet
  server that consumes the terminal's policy frame. The filesystem helper has an
  import-safe direct-execution entrypoint; real binary terminal startup and queued
  input retain their own framing and descriptor-rooted cwd admission.
- Context-owned native recall/bootstrap and remember/capture now use admitted
  stable actor partitions across local and destination-worker completed runs.
  Other actors, unproven summaries and raw legacy USER/MEMORY bytes cannot enter
  owned recall; retained data is not rewritten or silently promoted to shared.
  Transfers preserve persisted ownership rather than trusting retained raw claims.
  Scoped worker calls require fresh capabilities and exact checked connection
  binding before enqueue, with no private-to-legacy fallback.
- Automatic native skill synthesis excludes indexed private/unproven documents
  instead of publishing their summaries into global/profile draft files. New
  memory indexes omit runtime credential configuration and ephemeral admission
  proof artifacts; canonical preferences/project facts survive ordinary history
  pruning, without promoting or rewriting legacy rows.
- Remote execution metadata now canonicalizes atom-key proof/grant/context
  presence before JSON encoding, so forged string/camel aliases cannot replace
  explicit false/null values. Untrusted meaningful scope/proof claims fail
  closed instead of downgrading to legacy context; unresolved references remain
  execution-host owned.
- Factory-only native source profile/session identifiers, managed-context
  sentinels, connection generations and follow-up/floor callbacks no longer
  survive remote execution metadata encoding under atom or string/camel aliases.
- Lemon Bot host management and probes require direct noninteractive native
  destination process execution; PTY is reserved for user-facing terminals.
- Private invocation proof secrets use the owning pending lineage destination
  and atomically pin both live PID and credential generation before provisioning.
  Only strict absence permits a fresh root; stale/mismatched/finished lineage
  never falls back. Trim-normalized reserved names require their exact fixed
  operation ID, and missing privacy support rejects before any proof value is sent.
  Successful vault replies are revalidated against the same pre-provision session
  and current owning pending target before acknowledgement; lost ownership or
  configuration/policy changes report a non-retry-safe potentially applied mutation,
  never a positive private proof authority acknowledgement.
- Automated host-driver actions and read-only probes can use admin-only
  `node.process.run|get|cancel`: literal executable argv, descriptor-admitted
  destination cwd, bounded raw stdin with EOF, independent non-TTY stdout/stderr,
  and observed exit receipts. Fixed IDs persist immutable private admission and
  spent/cancel fences; uncertain work is queried, never redispatched. Cancellation
  before admission durably prevents a later run, and active cancellation/timeout/
  overflow cleans the real process group. Outputs stay private to the RPC caller,
  missing output is null rather than invented empty data, and interactive PTYs
  remain exclusively explicit user terminals—no automated PTY/shell/SSH fallback.
- Native process overflow, drain and final cleanup share one successful
  process-group stop request instead of repeatedly signalling an already-stopped
  group. First-stop permission failures remain errors and owned descriptors
  still close; no fabricated cancellation receipt is returned.
- JSONL-backed native process receipts can pass real macOS durability admission:
  the owning Core barrier uses a packaged Python 3 descriptor helper for file
  and directory fsync plus F_FULLFSYNC. Missing/refused barriers remain errors,
  not a weaker global-sync success or a switch to another persistence backend.

---

## [2026.10.6]

### Added

- **Custom providers and models.** A `[providers.<id>]` table with `api`,
  `base_url`, `api_key_env`/`api_key`/`api_key_secret`, optional
  `auth = "none"`, `headers`, `discovery = "openai" | "ollama"` and
  `[[providers.<id>.models]]` defines an OpenAI-, Anthropic- or
  Google-compatible endpoint (omp `models.yml` parity). Its models resolve as
  `<id>:<model>` / `<id>/<model>` for the default model, `/model`, model roles,
  task/compaction selectors and fallback providers, appear in the `/model`
  picker and `lemon providers status`, and are checked by
  `lemon config validate`. On built-in providers, `headers` are sent with every
  request and `models` entries add or replace catalog models. See
  [Custom Providers and Models](docs/config.md#custom-providers-and-models).
- **More provider sign-ins in `lemon model`.** `lemon model openai-codex
  --auth device` signs in to ChatGPT with a device code (headless, also
  `--non-interactive`). `openrouter` adds browser sign-in that mints an API key,
  `xai` adds SuperGrok / X Premium+ device sign-in, `kimi_coding` (`kimi-code`)
  adds Kimi Code device sign-in, and `zai` adds GLM Coding Plan sign-in that
  provisions an API key. xAI and Kimi logins refresh automatically;
  `--status`/`--logout` cover all of them. See
  [CLI](docs/user-guide/cli.md#other-provider-sign-ins).
- **API-key sign-in for every catalog provider.** `lemon model` now offers
  Google Gemini API, Groq, Cerebras, DeepSeek, Mistral, Hugging Face, Qwen
  (DashScope), Vercel AI Gateway, OpenCode Zen/Go, MiniMax China and every
  hosted OpenAI-compatible preset (model choice lists the endpoint's models);
  the key is stored encrypted and referenced as `api_key_secret`.
- OAuth logins can be force-refreshed after the provider rejects an unexpired
  token (`Credentials.refresh_provider_api_key/4`, used by 401 recovery).
- **Local and open-model provider presets.** Ollama, LM Studio, llama.cpp,
  vLLM and LiteLLM work without an API key (`ollama:qwen3:32b`), with omp's
  default endpoints and `OLLAMA_HOST`/`*_BASE_URL` overrides; hosted presets
  cover Ollama Cloud, Together, DeepInfra, NVIDIA, Novita, Baseten, Venice,
  Synthetic, NanoGPT, ZenMux, AIML API, SiliconFlow, GMI Cloud, Qianfan, ai&,
  Wafer and Kilo. `lemon models --provider <id> --discover` lists an endpoint's
  models, and the `/model` picker includes discovered models for configured
  presets. See [OpenAI-Compatible Endpoints](docs/config.md#openai-compatible-endpoints).

### Fixed

- Session context queries fall back to saved accounting when the live owner
  retires during the read, instead of exiting on a stale registry PID. Timeouts
  and unexpected owner crashes still surface.
- Background process launches no longer bypass admission after queue failures.
  Fixed, owner-bound launch identities reconcile lost acknowledgements and
  reject conflicting retries instead of risking duplicate external effects.
- Background execution now holds a validated live-process capacity limit until
  confirmed termination, bounds pending admission and waiting, prevents canceled
  or expired queued commands from starting, and retains unknown capacity through
  restart. Yielded launches remain owner-scoped and inspectable; cancellation
  receipts no longer claim termination before it is confirmed.
- Local Unix background capacity now stays held when the root shell exits but
  descendants survive. Owned process groups are bound before command execution;
  live members are retained before forwarding stdin that can end the root, so
  verified cancellation still works after natural root exit. Groups reconcile
  until confirmed empty; stale ownership and unsupported workload witnesses
  remain unknown rather than freeing slots or signaling recycled PIDs.
  Repeated cancellation also requires the backend-aware workload witness:
  an empty host wrapper group cannot release SSH, container or PTY capacity.
  TUI tool cards and compact shelves also preserve queued and outcome-unknown
  receipts instead of presenting them as started or failed.
- Unknown Bash launch outcomes now preserve their structured process identity
  through the actual agent event and TUI render path. Late or reopened durable
  storage restores retained capacity and owner monitors before new admission.
  Pre-execution startup rejections retain the real failure reason.
- Unix process admission now uses a portable POSIX stdin gate, including dash
  on Linux, preserving subsequent command input and refusing an unreleased gate.
  Verified group signals use fixed argv with an OS-owned kill executable.
- JSONL storage rejects unreadable or corrupt journals rather than publishing
  empty state. Failed loads remain recoverable after repair; rejected writes
  return bounded errors before cache mutation without crashing the Store.
- Stored OAuth refreshes bind persistence to the selected login's opaque
  revision. Atomic saves cannot overwrite a concurrent login, logout, or
  delete/recreate; stale or failed saves cannot return the rotated credential.
  Persistence callbacks take `(name, encoded, expected_revision)` and require
  revision-bearing reloads and explicit success acknowledgements. Transient
  fallback reselects authoritative storage; non-persisting refresh stays ephemeral.
- Copilot token-endpoint HTTP 401/403 requires a fresh sign-in rather than
  returning a cached token, including near-expiry refreshes.
- Provider header defaults no longer override per-model headers on the wire.
  OpenAI Completions/Responses, Anthropic and Google compatible endpoints merge
  header names case-insensitively: provider defaults, then model overrides,
  then explicit caller overrides, without duplicate mixed-case headers.
- Provider CI checks use the existing OAuth decode branching convention without
  changing refresh locking, and Codex CLI import regressions check rejection
  and non-mutation rather than incidental error wording.
- OAuth callback parsing and xAI endpoint validation reject malformed URL
  authorities and ports before extracting codes or exchanging credentials.
- Provider sign-in failures no longer print credential payloads or arbitrary
  token-endpoint response strings. Token grants and model discovery do not
  follow redirects; Z.AI callbacks require the returned state, and device-code
  deadlines include callback and HTTP time.
- Copilot, Gemini CLI and Antigravity refreshes serialize by stored login,
  reload after waiting, and fail closed on deleted/replaced logins or expired
  access tokens. Google `invalid_grant` requires a fresh sign-in.
- Named `lemon model --status`/`--logout --secret-name NAME` targets that account
  without deleting another login or clearing its selected provider settings.
- Discovery cache metadata is isolated by endpoint, protocol, credential and
  headers, rather than the last listing for a provider id. Custom Google
  endpoints no longer inherit Google account options; explicitly keyless
  custom Anthropic and Google endpoints omit generated credential headers.
- Unknown provider ids in `default_model`/`default_provider` and custom
  provider option keys no longer create atoms from config input.
- `lemon model github_copilot --status`/`--logout` no longer crash once a
  Copilot login is stored.
- With `auth_source = "oauth"`, a provider's API-key env var (for example
  `GOOGLE_GEMINI_CLI_API_KEY`) no longer overrides the stored sign-in.
- Concurrent ChatGPT (Codex) token refreshes no longer replay a rotated refresh
  token: refresh is single-flight per stored login and re-reads the secret.
- OpenAI-compatible providers no longer fall back to `OPENAI_API_KEY`: a
  DeepSeek, Together or other non-OpenAI request without its own key fails
  instead of sending the OpenAI key to that endpoint. Groq, xAI, Cerebras,
  DeepSeek, Mistral, Hugging Face, Qwen and Vercel AI Gateway now resolve their
  key environment variables and default `llm_<id>_api_key` secrets.

---

## [2026.10.5]

### Added

- **omp and Claude Code subagent definitions.** Task personas are also
  discovered from project `.omp/agents/` and `.claude/agents/` (cwd up to the
  Git root) and from `~/.omp/agent/agents/` and `~/.claude/agents/`, below the
  `.lemon` directories. Those files are read tolerantly (ID from `name`,
  unknown fields ignored, invalid files skipped). All definitions accept
  comma-separated `tools`/`model`, omp/Claude tool names, thinking-level
  aliases, `spawns`, and an `output` schema in JSON Schema or JTD form (JSON
  Schema constraints are preserved even without an explicit `type`). New
  shipped personas: read-only `security-reviewer` and the `@smol` mechanical
  worker `sonic`.
- **Task worktrees can merge back.** `task` gains `merge` (`none`, `patch`,
  `branch`; default `[runtime.task].worktree_merge`) for `worktree: true`
  children. `patch` replays the parent's uncommitted work into the worktree
  and, when the child succeeds, applies its changes to the parent checkout,
  failing closed on conflicts with the patch kept for review. `branch` commits
  the child's work on its kept `lemon/task-<id>` branch without merging it.
  Merge-back rechecks cancellation before mutation and retains detached or
  switched-branch worktrees for manual review. Both patch and branch modes retain
  committed or staged submodule changes, including index-only pins, and initialized
  HEAD/content changes even under `ignore = all`, without overwriting the original
  index or deleting recoverable work. Results report `details.merge`.
- **Task runtime parity with omp.** `task` accepts a top-level `context`
  shared by every child of a run, batch, or swarm. Persona thinking levels and
  output schemas become child defaults. Invalid structured output is
  re-prompted in the same child up to twice; `schema_mode: "permissive"`
  returns the text with `structured_output_error` instead of failing.
  `read agent://<id-or-name>` returns an owned child's status and output (even
  after it finishes), and `agent://<id>/<key>/…` extracts a `structured_output`
  field. New `[runtime.task]` settings: `max_depth` (default 2) caps nesting
  and persona `spawns` grants allowlisted delegation below it,
  `max_runtime_ms` limits each child, `disabled_agents` hides personas, and
  `agent_models` overrides persona models.
  Child depth/allowlists survive extension reloads, resumed user forks can
  still delegate, and live `agent://` names override completed namesakes.
- Context parity hardening: overlapping secret sources are redacted without
  exposing credential fragments; malformed secret YAML does not echo values
  into logs. Private plan tools restore placeholders and enforce interception
  hooks without bypassing their directory boundary. Foreign-global MCP configs
  still require opt-in when launched from home, enabling a server clears every
  matching denylist entry, and hidden skills stay out of missing-key suggestions.
  File commands preserve empty positional arguments, consume one-shot submission
  modes, and expand on local steering/redirect without expanding internal or
  named-destination prompts. Inline-code imports respect matching backtick runs
  across lines.
- Secret placeholders now protect friendly labels against every contextual
  regex value in the current input and previously matched session values,
  including overlap constituents, cached labels and forged token-shaped
  prefixes. Regexes retain context across protected tokens, and self-overlapping
  literal secrets redact their complete union without leaving a credential
  suffix visible. Provider batches collect regex values and reserve original raw
  tokens before emitting any message, block or nested argument, preventing
  cross-field label leaks and accidental restoration of original token-shaped
  text while retaining the existing system/image/metadata exclusions.
- Skills with `hide: true` or `disable-model-invocation: true` frontmatter are
  omitted from the model-visible skill listing and per-turn relevant-skill
  hints, yet stay listed and loadable by name (`read_skill`, `skill://`,
  `/skill:<name>`). See [skill manifest](docs/reference/skill-manifest-v2.md).
- File slash commands from Claude Code (`.claude/commands`, nested `a:b`),
  Codex (`.codex/prompts`), Copilot (`.github/prompts/*.prompt.md`), Gemini
  (`.gemini/commands/*.toml`), omp and `.agents` roots, plus their user-global
  dirs: `/name args` expands server-side for TUI, ACP and channel prompts, and
  the TUI palette, `/help` and ACP command list show them. Skills also load from
  `.codex/skills`, `.github/skills` and `~/.codex/skills`. See
  [File slash commands](docs/user-guide/slash-commands.md).
- **Secret obfuscation (opt-in).** With `[runtime.secret_obfuscation]
  enabled = true`, native sessions replace secret-shaped environment values,
  `secrets.yml` entries (global and project; plain or regex, obfuscate or
  replace) and GitHub/GitLab/OpenAI/Anthropic-style tokens in provider-visible
  messages with keyed `$$…$$` placeholders, and restore them in tool arguments
  before a tool runs. Session history keeps the original text. See
  [Secret obfuscation](docs/security/secret-obfuscation.md).
- **MCP servers from other tools.** Lemon now also loads MCP servers declared in
  omp, Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Windsurf and VS Code
  configs and root `mcp.json`/`.mcp.json` (project files by default; other
  tools' `~/` files with `LEMON_MCP_EXTERNAL_USER_DISCOVERY=1`), below Lemon's
  own files. `lemon mcp enable|disable NAME` toggles any server per project or
  `--global`, and `lemon mcp list --all` shows the effective set with sources.
  Turn the import off with `LEMON_MCP_EXTERNAL_DISCOVERY=0`. See
  [Skills: Servers from other tools](docs/skills.md#servers-from-other-tools).
- Native sessions load other agents' instruction files: `GEMINI.md`,
  `CLAUDE.local.md`, `.gemini/`, `.agent(s)/`, `.omp/` and
  `.github/copilot-instructions.md` per directory, plus Gemini, Codex, OpenCode,
  `.agents` and Copilot globals, with `@path` imports expanded. Cursor,
  Windsurf, Cline, GitHub Copilot, `.agents` and `.lemon/rules` rule files are
  injected when always-apply and otherwise listed in a rulebook the model reads
  on demand. See [Instruction files and rules](docs/user-guide/context-files.md).
- Extension hooks can intercept tools: `on_tool_call` blocks a call or
  replaces its arguments (a raising handler blocks), and `on_tool_result`
  replaces a successful result's content/details. New `on_session_start` and
  `on_session_shutdown` hooks observe session lifecycle. See
  [Extensions: Intercepting tool calls](docs/extensions.md#intercepting-tool-calls).

### Fixed

- Extension result presentation hooks preserve authoritative checkpoint receipts
  and affected paths. Content-only or custom display details cannot erase real
  mutation provenance or fabricate receipts; omitted details retain the original.
  Reserved diff aliases, resolved locations and mutation line numbers are protected
  in both key forms; omitted snapshots and absent location lines remain absent.
- Direct, deferred and WASM-host targets restore secrets before interception
  under both disclosure profiles, including after reload. Private plan writes
  retain their restricted file boundary, and repeated plan refreshes no longer
  capture earlier wrapper generations.
- Active plan-mode extension reload now binds private writes, edits and proposals
  to newly loaded hooks immediately, preventing stale handlers from bypassing a
  new mutation blocker.
- OpenCode MCP discovery substitutes environment and file placeholders once in
  decoded JSONC string values. Quotes, backslashes and multiline environment
  values no longer invalidate the config and silently drop servers; inserted
  text cannot trigger another interpolation or file import. File path resolution,
  trimming and missing-value behavior are preserved.

---

## [2026.10.4]

### Added
- Opt-in `runtime.tools.disclosure.profile = "coding"` keeps a coding core
  directly exposed and defers optional registry-resolved built-ins behind
  `tool_search` / `tool_invoke`. Explicit pins and per-session overrides support
  isolated trials; defaults and caller-supplied toolsets remain unchanged.
  Disclosure diagnostics include resolved inventories, estimated schema size
  and a safe catalog/policy digest. Bridged calls retain approval, plan-mode,
  checkpoint, cancellation and sequential execution constraints. No cost or
  latency improvement is claimed; see [Tool Disclosure](docs/config.md#tool-disclosure).

### Fixed

- WASM host aliases resolve permitted deferred built-ins from the same frozen,
  wrapped disclosure catalog under both profiles, retaining plan-mode and reload
  authority boundaries while refusing WASM and disclosure-bridge recursion.
- Background process output now enforces finite retained-memory, artifact,
  owner and runtime storage byte quotas before capture growth. Oversized
  chunks/partial lines retain a bounded diagnostic tail; polling and artifact
  handles report incomplete output honestly. Write failures stop capture
  without changing execution status, and failed cleanup keeps its storage
  charge instead of allowing quota bypass. TTL cleanup removes expired closed
  captures even while their completed sessions linger for final polling.
  Capture accounting now serializes record mutations with reclamation, preserves
  live capture state across store-only restart, and rejects unpersisted
  reservations or unknown legacy artifact usage before process launch.
- Native idle and live model switches bind provider-owned request options before
  classification or completion. Selected-login refusal and keyless transitions
  retain their intended authority; fallback credentials and headers use the
  current invocation rather than the session's startup provider.
  Same-provider rebinding replaces source-model header defaults while preserving
  genuine caller overrides; generated headers are not promoted to caller authority.
- Setup verification resolves canonical credential authority and effective
  endpoint/model settings, preventing OAuth-record disclosure and false successful
  skips for unavailable selected logins. Offline, keyless and credential-pool
  behavior remain supported.
- **Todos follow the selected branch.** The `todo` tool's list is now journaled
  in the session history instead of living only in memory, so rewind, branch
  navigation, restart/resume and forks show the list that branch last wrote,
  with stable IDs, and plan mode/approved plan and todos always agree. A todo
  write is reported as saved only after its journal entry is recorded, and a
  write prepared before a branch switch is rejected. Sessions saved before this
  change recover the latest successful todo write recorded on each branch;
  checkpoint resume no longer copies a session-wide todo snapshot onto the
  current branch. ACP load/resume and branch changes replace the client plan
  from the same journal, including cleared lists; progress survives cache loss.
  Restoring a branch never refunds spend, restores revoked policy or reruns tools.
  WASM host calls now execute the same wrapped tools in supervised, Session-owned
  workers, avoiding a todo journal self-call. Host requests retain invocation
  ownership, abort signals and deadlines; cancellation/disposal kills pending
  work, rejects queued late writes and preserves policy/approval failures as errors.
### Added

- A shared, bounded `sessions.snapshot` recovery response for TUI and browser
  chat, composed from the selected native branch and existing lifecycle owners.
  Reconnect and overflow recovery replace stale approvals, tools and branch
  progress without replaying mutations or retaining every text delta.

### Fixed

- TUI snapshot recovery preserves the real IDs of multiple pending approvals and
  resolves each independently without changing the public approval-method contract.
  Invalid, unavailable and truncated approval reads cannot revoke omitted requests;
  foreign-session resolution events cannot clear another session's approval.

- Slow session and operator-event consumers are fenced at bounded delivery
  admission, with an explicit resynchronization signal. Native execution keeps
  a reconstructable terminal path, and recovered client state cannot be revived
  by late packets from a terminal or abandoned attempt. Remaining best-effort
  transport boundaries are documented rather than claimed to be globally bounded.
- Recovery races now include overflow notifications without any delivered data.
  Idle live rewinds cannot reuse an abandoned invocation's answer, and cancellation
  before new assistant output cannot recycle the preceding turn's answer.
  Delivery admission accounts for oversized sub-binary backing; old bridge epochs
  and late coalescer finalizers cannot corrupt newer recovered work. Web inspectors
  disclose truncated todo, child and process recovery previews.
- Web branch recovery discards pending coalesced text instead of flushing obsolete
  rows into the replacement stream. TUI recovery also fences replacement session
  instances when a branch or revision identifier is reused.
- Recovered TUI runs now release one known-unsent local followup after a verified
  canonical terminal snapshot. Owner-proven native branch/attempt continuity and
  current client projection fences prevent old snapshots, focus races or repeated
  completion previews from advancing newer work or replaying uncertain sends.
  Background recovered sessions retain this behavior without switching focus or
  replacing another session's transcript; per-session owner reads survive unrelated
  focus changes while stale selection/deletion responses remain fenced.
- Fresh router-admitted native runs register their live recovery owner before
  their first durable lifecycle index. Owner-written invocation provenance in
  existing native user entries preserves exact terminal/branch association when
  start-event receipt follows prompt creation, including repeated prompts and
  rewind; malformed declared bindings never fall back to timing guesses.
### Added

- Repeated paired disclosure trials in the production coding benchmark, with
  seeded counterbalanced ordering, fresh per-attempt runtimes and fixtures,
  exact experiment/approval digests, bounded deadlines, and an explicit
  operator-approved spend plan backed by a hard external provider/account cap.
  Plan-only mode makes no model calls. Sanitized reports retain failed/timed-out
  attempts, incomplete cost data, and exploratory task-cluster uncertainty,
  separately from schema-size diagnostics. Negated paired authorization cannot
  fall through to the paid legacy lane; deadline-owned process groups are cleaned
  up even after their leaders exit. Missing, unmatched, or nested usage
  observations cannot certify parent-only cost as complete spend. Only baseline
  versus opt-in coding is supported: ineffective schema-budget variants were
  removed and `--schema-budgets` is rejected before any model call, because coding
  intentionally ignores `budget_tokens`. Defaults remain unchanged and the
  coding profile remains opt-in; rollout awaits authorized live evidence.
  See [the paired workflow](docs/benchmarks/paired-disclosure.md).

---

## [2026.10.3]

### Added

- Provider resilience now supports ordered model fallback chains (including
  same-provider alternatives), one OAuth refresh on HTTP 401 before credential
  rotation, retry-after-aware credential cooldowns, and model-aware session
  pinning. Fatal requests and context overflow do not walk fallback chains;
  no automatic recovery replays committed text, thinking, or tool-call output.
- Generic OAuth provider selection now keeps the same stored account through
  initial resolution and 401 refresh, honoring `oauth_secret` without falling
  back to ambient or inline keys when that login is missing. Codex refresh
  failures no longer log raw provider error bodies.
- Opt-in `thinking_level = "auto"` classifies each user prompt with an explicitly
  configured tiny/smol model and maps its effort to the active provider's
  supported levels. `@plan` and `@commit` join the built-in model role selectors.
- **Session lifecycle parity.** `lemon sessions export` and `/session export`
  gain `html` (self-contained, escaped, no scripts) and `jsonl` formats;
  `sessions.context` returns session usage (tokens, estimated cost, input/output/
  cache) shown by `/context` and `/session info`; `[runtime.compaction]` accepts
  `threshold_percent` and `threshold_tokens`; context-overflow recovery now uses
  the structured provider error classification before text matching.
  Recovery retries only pre-output provider failures; an overflow after visible
  output or tool commitment is not silently replayed.

- `bash` tool: per-command `cwd` and validated `env` parameters (foreground,
  PTY, background and ACP terminals; approvals show env names only), and
  `skill://`/`artifact://` references in commands expand to absolute file paths.
- `eval` coding tool: persistent per-session Python (`python3`) and JavaScript
  (Bun, or Node) kernels with streamed output, trailing-expression display,
  top-level `await`, `reset`, and timeout/abort that kill the kernel tree.
  Output follows the `bash` cap and spill handle. See [Eval](docs/tools/eval.md).
- **`lsp` coding tool.** Agents can ask a real language server for diagnostics,
  definitions, type definitions, implementations, references, hover, document
  and workspace symbols, renames (previewed unless `apply: true`), code actions
  (listed, or one applied including server commands) and raw requests. Servers
  are chosen by file extension, reused per session and workspace root, and stop
  with the session; applied edits are locked, checkpointed and written
  atomically. Server edit acknowledgements follow actual application, and
  multi-batch actions retain all checkpoints on success, partial failure or
  cancellation for complete rewind. `status` shows which servers are installed
  or running. See [LSP tools](docs/tools/lsp.md).
- `debug` coding tool: a Debug Adapter Protocol client for `lldb-dap`, `gdb`,
  `debugpy` and `dlv` with breakpoints (source, conditional, function), launch
  and attach, stepping, stack/scope/variable inspection, expression
  evaluation, captured program output and raw `custom_request`. Debug sessions
  are owned by the coding session and killed with it. See
  [Debugger](docs/tools/debug.md).
- **Lemon Web, rebuilt.** The browser UI is now a full workspace on the same
  control-plane methods and events as the TUI. Chat streams Markdown with
  highlighted code, thinking blocks and rich tool cards (shell output and exit
  status, diffs, reads, searches, todos, subagents), with attachments,
  follow-up/steer/redirect queueing, stop, inline approvals, model/thinking/
  tool-policy pickers, plan mode with Approve & execute / Refine, a context
  usage inspector with Compact, a git Changes viewer, fork and split view. New
  pages: omp, session manager, automation (kanban, goals, cron create/edit),
  blueprints, skills, memory, MCP, nodes, models, usage, diagnostics and
  settings; plus a ⌘K command palette with global search, `?` shortcut help,
  `g` navigation chords, run/approval notifications, light/dark themes and
  phone layouts. See [Use Lemon in a Browser](docs/user-guide/web.md).
- Control-plane methods for the web UI: `sessions.changes` (git status and
  bounded diffs of a session workspace), `doctor.run` (read-only `lemon doctor`
  checks), skill, MCP and node listings and lifecycle actions, `usage.cost`
  breakdowns by provider/model/session/day, and model pricing in
  `models.list`. `ProviderConfiguration` can set the default model and thinking
  level with the same preview/apply revision flow.
- **Delegate work to omp.** Lemon can run tasks in
  [omp](https://github.com/can1357/oh-my-pi) sessions: ask in chat ("run this
  in omp"), use the TUI's `/omp` panel, or `lemon omp start`. Lemon starts omp
  in the workspace over its RPC protocol and reports live status — activity,
  tools, todos, subagents, tokens and cost, latest output — and can steer,
  queue follow-ups, cancel, close and resume sessions. `lemon omp discover`
  lists omp's stored sessions for a workspace (read-only). omp output is
  treated as untrusted data, control fails closed, omp processes end with the
  runtime, and everything degrades to "omp is not installed" without the
  binary. See [Delegating to omp](docs/user-guide/omp.md).
- `lemon config migrate` rewrites deprecated sections (`[agent]`, `[agents.*]`,
  `[tools.*]`) in the global and project config to the current schema, keeping
  comments and a `config.toml.bak-<timestamp>` backup; `lemon setup` does the
  same for an existing config.

- **TUI startup logo.** `lemon` now opens with a block-glyph lemon painted in a
  yellow gradient with a green leaf, beside the version and key hints. It uses
  only `█ ▀ ▄` cells, so it renders in Tern and any UTF-8 terminal; ASCII
  locales and terminals narrower than 50 columns keep the one-line banner.
- **`lemonup` version switcher.** `bin/lemonup` switches `~/.lemon/bin/lemon`
  between installed releases (`lemonup use 2026.10.2`) and a source checkout
  (`lemonup use local [checkout]`), installs and removes releases, and moves a
  running runtime to the new selection. `lemonup update` installs the latest
  stable release if needed and activates it, from a release or from source.
  `install.sh --resolve-version` prints the version an install would pick. It
  was briefly `bin/lvm`, which collides with the Linux LVM2 command; replace a
  `~/.lemon/bin/lvm` link with one to `bin/lemonup`. Selections made with the
  old name are still recognized. See
  [Source development](docs/install.md#switching-between-releases-and-source-with-lemonup).
- **Tern-native TUI surfaces.** `lemon tui` in Tern now uses the same native
  surfaces as omp instead of painted rows. The composer shows a context meter,
  attachment chips, clickable model and effort chips, status facts, last-run
  usage, and Send/Stop. Tool calls are structured cards: shell run boxes with
  exit status, native diffs, numbered reads, file rows, web-search sources, a
  todo checklist, and subagent rows. Prompts show their send time, finished
  turns get a Copy/usage footer, and thinking shows a live spinner. The
  transcript also has error frames, a working row with Stop, editable queued
  prompts, and approval buttons. Pickers (sessions, models, command palette,
  `/output`) open as native sheets, and the welcome card draws the lemon as an
  image. Other terminals render as before.
- **Claude Pro/Max sign-in.** `lemon model anthropic` (and the Anthropic choice
  in `lemon setup`) signs in with a Claude subscription in the browser using
  Anthropic's OAuth PKCE flow, without Claude Code installed. The login is
  stored encrypted, refreshed automatically with one refresh per runtime, and
  fails closed when Anthropic rejects it. Headless sessions paste the
  `code#state` from Anthropic's code page. Anthropic currently bills these
  requests to the account's extra usage, not the plan's included limits.
- `lemon model PROVIDER --status` shows the auth source, stored login, expiry
  and whether credentials are usable; `--logout` deletes the stored OAuth login
  and its config keys.
- **Context-window usage breakdown.** `/context` (alias `/ctx`) in the TUI and
  `/context` in ACP chat, plus `lemon sessions context <key>`, show how the next
  request spends the model's context window: system prompt, tool definitions,
  skills, context files, memory, messages, tool results, summaries and free
  space, with the largest contributors and the auto-compaction threshold. In
  Tern the TUI renders it as a native sheet whose meter matches the composer's
  context meter (click the meter to open it); the status-bar gauge and composer
  meter also use the measurement for resumed sessions before their first run.
  All surfaces read the new read-scoped `sessions.context` control-plane method;
  category splits are estimates scaled to the provider-reported total.
- **Continue and resume sessions from the command line.** `lemon -c` /
  `--continue` reopens the most recently updated TUI session started from this
  directory (a new session when there is none), and `lemon -r [key]` /
  `--resume [key]` attaches to a known session or, without a key, opens the
  session switcher; `lemon tui --continue` works too. New TUI sessions carry a
  short directory tag in their key so `--continue` can find the current
  project's sessions. `--continue`, `--session` and `--resume` are mutually
  exclusive.
  A bare `--resume` waits for the switcher's rows and mounted picker before
  startup completes, rather than opening it in a detached background task.
- **`/retry` in the TUI.** After a failed or aborted turn, `/retry` rewinds
  history (never files) to the last prompt, keeps the discarded turn in `/tree`,
  and resends the prompt; `/retry --force` also retries a completed turn.
  Retry now checks authoritative original-message replay metadata and refuses
  stored images or other non-text content before confirming any rewind; it
  never silently resends just their text projection, including after resume or
  with `--force`. Missing replay metadata also refuses without history mutation.
  Recovery drafts now clear only after a concrete run acknowledgment. Rejected
  sends retain the draft; uncertain sends keep their fixed request/run identity
  for explicit queue review and never automatically replay. Exact resume uses
  the durable lifecycle lookup, not a truncated history-search page, and local
  TUI navigation refuses foreign-directory or untagged keys rather than replace
  their native history.
- **Switch branches, label entries and fork from any point in `/tree`.**
  Selecting an entry in the TUI's `/tree` now opens its actions: inspect it,
  switch the active branch to it (optionally summarizing the abandoned branch in
  the background), bookmark it with a label (`/tree label <entryId> <text>`,
  `/tree unlabel <entryId>`), or fork a new session whose history ends at it.
  New write-scoped control-plane methods `sessions.navigate` and
  `sessions.label`, an optional `entryId` on `sessions.fork`, and a `label` on
  `sessions.tree` entries back it. Switching never deletes the old branch and is
  refused while a run is active.
  Background summaries apply only to their unchanged destination revision and
  update live and resumed context together; stale results never move another
  branch. Automatic resume also refuses an unavailable journal already mapped
  to a logical session instead of silently replacing its history.
  Native startup shares journal admission with stopped branch/label/rewind
  mutations, and live navigation/label receipts capture their own mutation
  atomically. Lost mutation receipts report an unknown outcome with automatic
  retries disabled, rather than implying nothing changed.
  Duplicate native startup returns an `already_started` error without sending an
  abnormal linked exit to its caller or rewriting the live owner's journal.
- `read` accepts path line selectors (`file:50-80`, `file:50+20`, `file:50`,
  `file:-30`, `:raw`) on files, archive members and internal references, and
  opens SQLite databases read-only (`app.db`, `app.db:table`,
  `app.db:table:key`, `app.db:table?limit=&offset=&where=&order=`,
  `app.db?q=SELECT ...`).
- `grep` gains `skip` paging plus `hidden`/`no_ignore`; ignored and hidden files
  are now skipped by the Elixir fallback too, matching ripgrep.
- `webfetch` converts PDF responses to page text and handles GitHub blob URLs
  (raw file) and issue/pull request URLs (REST API rendering).
- `websearch` providers: Tavily, Kagi (V1 API) and Jina.

### Changed

- **Lemon Web sign-in uses the operator token.** Every page now requires the
  control-plane operator token (the launcher-managed token by default) through
  a login page; `lemon web` signs in automatically via the URL fragment. The
  separate `LEMON_WEB_ACCESS_TOKEN`, `?token=` login, the optional unauthenticated
  chat route and the `/manage/*` pages are removed. Without a token the UI fails
  closed unless tokenless loopback compatibility is explicitly enabled and the
  peer is loopback; failed logins are throttled.

- Anthropic OAuth sign-in no longer runs `claude setup-token` or copies Claude
  Code's credentials; a pasted setup token is still accepted.
  `LEMON_ANTHROPIC_CLAUDE_PATH` is removed.

- **Plan mode works like omp's `/plan`.** `/plan` toggles plan mode in the TUI
  and in ACP chat (`/plan <request>` enters it and sends the request). While on,
  only read-only tools run; the agent drafts `<slug>-plan.md` in a
  session-private plan directory and calls `propose_plan`, which asks
  **Approve and execute** / **Refine plan**. Approving turns plan mode off and
  the agent implements the plan in the same turn; `/plan` again exits without
  approving. The TUI status line shows `plan` while active. ACP no longer
  advertises Code/Plan session modes or a `mode` config option, so Tern shows no
  plan-mode selector; `session/set_mode`, `/approve-plan`, `/discard-plan` and
  the `sessions.plan` `approve`/`discard` actions are removed (`exit` replaces
  discard). Sessions saved with the previous reviewed-plan lifecycle keep their
  plan mode or approved plan when loaded.

- **`lemon` opens the TUI in Tern.** Plain `lemon` in a Tern pane now opens the
  Lemon TUI on Tern's native surfaces, as `lemon tui` does, instead of
  redirecting to `tern acp lemon`. The native ACP chat stays available with
  `tern acp lemon` (or any ACP client running `lemon acp`). `lemon tern install`
  no longer turns on Tern's `agents.auto_acp`, which only wraps Tern's built-in
  agent CLIs (`claude`, `codex`, `copilot`); an existing value is left as is.

### Fixed

- `sessions.patch` tool policies (web picker, TUI `/toolpolicy`) now reach runs;
  the router previously merged the whole policy row instead of its tool policy.
- Usage is recorded: `usage.status`/`usage.cost` were always zero because
  finished runs were never added to a ledger. `logs.tail` now returns recent
  runtime log lines from a bounded in-memory buffer.

- The TUI no longer rewrites `~/.lemon/config.toml` with a deprecated `[agent]`
  table when you pick a default model (Ctrl+G / **Make default**) or run
  `/theme`. That rewrite dropped `[defaults]`, `[runtime]`, `[gateway]` and
  `[tui]`, and the `[agent]` table then stopped the runtime, `lemon setup` and
  every test run from starting. The TUI now edits only `[defaults]
  provider`/`model` and `[tui] theme` in place.
- A config with a legacy `[agent]` table loads again: it is read as
  `[defaults]`/`[runtime]`/`[tui]` with a warning (log, `lemon doctor`,
  `lemon config validate`) instead of failing boot.
- Fresh `lemon setup` no longer leaves an `[providers.anthropic]` reference to
  a credential that does not exist when you sign in to another provider, and
  non-interactive setup without `--model` no longer writes the model
  `<provider>:fallback`.
- Config edits by setup match table headers written with quoted keys
  (`[providers."openai-codex"]`) instead of appending a duplicate table.
- Umbrella tests run with an isolated `HOME`, so a personal
  `~/.lemon/config.toml` can no longer fail or skew them.

- Document reads (PDF and other converted formats) no longer report
  "Cannot start document backend" when the converter exits while its port is
  being closed; the real result or size/time-limit error is returned.
- Durable project-fact capture no longer skips a finished turn as busy or
  unavailable in the moment after an earlier capture for that project or
  another one ends; a worker that has exited no longer holds its project or
  one of the eight capture slots.

---

## [2026.10.2]

### Fixed

- **ChatGPT model discovery.** Codex requests and model discovery send client
  version 0.159.0 (matching omp). With 0.153.0 the ChatGPT backend omitted
  GPT-6 Luna, GPT-6 Sol and GPT-6.1 Sol, so they never appeared as available.

### Removed

- **Retired ChatGPT models.** `openai-codex` no longer lists `gpt-5.5`,
  `gpt-5.4`, `gpt-5.4-mini` or `gpt-5.3-codex-spark`, matching omp and the live
  ChatGPT model list. Configs that pin them should switch, for example to
  `openai-codex:gpt-6.1-sol` or `openai-codex:gpt-6-luna`. Sim and eval
  defaults now use the GPT-6 models.

---

## [2026.10.1]

### Added

- **Current model catalogs.** Bundled catalogs gain the latest models from
  each provider shared with the oh-my-pi reference catalog, including
  ChatGPT/Codex GPT-6 Luna, GPT-6 Sol and GPT-6.1 Sol, Claude Sonnet/Haiku 5.5,
  and current Grok, Gemini (Antigravity), GLM, Kimi, MiniMax, DeepSeek,
  Mistral, Fireworks, Copilot, OpenCode and aggregator entries. Existing model
  ids are unchanged; earlier ChatGPT models stay selectable for existing
  configs.

### Fixed

- **Setup model picker.** `lemon setup` lists models newest first and
  defaults to each provider's current flagship instead of an alphabetical,
  oldest-first list. Model pickers no longer treat snapshot dates, parameter
  counts or vendor prefixes as version numbers.
- **Quiet setup.** `lemon setup` no longer prints runtime log lines, such as
  the config reloader noticing setup's own config write.

---

## [2026.10.0]

### Added

- **`mix lemon.new --hex`.** The generator can emit `~> 0.2` Hex requirements
  for `lemon_core`, `lemon_ai`, `lemon_agent` (and `lemon_memory` with
  `--memory`) instead of path dependencies, so a project needs no checkout of
  this repository. It resolves once 0.2.0 is on hex.pm. `--hex --channel` is
  refused with an explanation, since `lemon_channels` is not published. The
  `installer/` package (`lemon_new`) now carries Hex package metadata, a
  license and a changelog so it can be published; an installer built outside a
  checkout generates the `--hex` form by default. Path mode and
  `--packages-path` are unchanged.

- **Tern integration.** `lemon acp` is a runtime-attached ACP stdio agent and
  `lemon tern install` registers Lemon as a native Tern chat agent plus a
  managed plugin ("New session in split", "Focus existing session"). In a Tern
  pane, `lemon` opens the native chat (`lemon tui` keeps the terminal UI).
  ACP sessions are durable and forkable, stream rich tool cards, diffs, plans,
  thoughts, usage and subagent updates, run bash in native client terminals,
  bind client MCP servers to the session, support plan mode with reviewed
  revision approval, `ask` forms via `elicitation/create`, and exact-preview
  permissions. The TUI emits Tern-native surfaces (prompt/reply marks, Run
  controls, working/approval states, Carly delegation, `/fork` in a split) and
  file links that open at the exact line.
- **Non-interactive coding.** `lemon -p`/`lemon run` take stdin prompts, emit
  text/JSON/stream-JSON, continue sessions, select model/cwd, control tool
  approvals, report usage and budgets, and use automation-friendly exit codes.
- **Subagents.** Parallel fan-out with live progress, optional git-worktree
  isolation, named personas (`.lemon/agents/*.md`; built-in scout, reviewer,
  task-executor), configurable model roles, schema-validated results, scoped
  `agent_message` messaging, first-result waits, and dependency-aware
  `task(action="swarm")` DAGs.
- **Sessions.** Checkpoint-backed `/rewind` (preview-bound, with explicit
  consent for partial restore across shell effects), `/tree`, `/name`, search,
  independent forks, plan mode (`/plan`, `/approve-plan <revision>`),
  `/compact <focus>`, context-budget snapshots, and bounded per-repository
  project memory recalled as labelled background context.
- **Coding tools.** Snapshot-anchored edits, bounded directory/archive/PDF/
  notebook/image reads, optional ast-grep structural search/replace, native
  plans, `skill://` and session-scoped `artifact://` URLs with ranged recovery
  of complete shell output.
- **TUI.** Image drafts and `@` file mentions, fuzzy command/skill/prompt
  palette, live subagent tree, full tool/diff inspector, faster bytecode
  startup (first frame ~48 ms), and fixed shutdown/editor handoff hangs.
- **Providers.** Opt-in import of an existing Codex CLI login, per-account
  Codex model discovery, refreshed GPT/Claude/Gemini catalogs and pricing,
  Codex prompt-cache affinity, and per-run/per-session token and cost budgets.
- **MCP.** `lemon mcp add|list|remove|test`, session-owned connections,
  capability-aware discovery and per-tool approvals; omp/Claude-compatible
  skill layouts are discovered.
- **Automation.** Goals, cron and kanban dispatch repository-targeted coding
  runs with persisted results; opt-in reviewed kanban workflows (isolated
  worktree, independent read-only review, exact-tree commit, explicitly
  configured publication; never pushes by default); channel notifications and
  exact-preview Telegram/Discord approvals; `/manage/work` web dashboard with
  live sessions, tool output and subagent trees.
- **Operations.** `lemon update` with verified daemon restart and rollback,
  build identity in `--version` and doctor, image input on
  `chat.send`/`profile.chat`, and an opt-in 12-task live coding benchmark
  (`mix lemon.eval.coding`) with omp comparison and token profiling.
- **Secrets master-key rotation.** `lemon secrets rotate-key` previews how
  many stored secrets will be re-encrypted and prints a confirmation token;
  `--confirm <token>` generates a new master key, re-encrypts every secret, and
  replaces the key in the Keychain entry or key file. It refuses stale tokens,
  changes nothing if any secret does not decrypt, never touches external
  sources or environment fallback, refuses while a runtime is running, and
  keeps every secret readable if interrupted at any step. A key file is
  rotated only where the host can flush the rename synchronously (GNU
  coreutils); on macOS keep the master key in the Keychain. Secret writes and
  OAuth token refreshes report a held secrets lock instead of claiming success.

### Fixed

- TUI cancellation keeps its interrupted marker when a notice has already
  sealed the current text segment.

- `lemon doctor`'s `skills.directory` check inspects the global skills
  directory Lemon actually installs into (`~/.lemon/agent/skill`, or
  `LEMON_AGENT_DIR`), not the unused `~/.lemon/skills`. The check now lives in
  `lemon_skills` and the memory check in `lemon_memory`; both register with the
  doctor through `config :lemon_core, :doctor_checks`.

- Accepted runs always receive durable, ordered terminal receipts across
  admission, queue retirement, cancellation and crash recovery; cancelling
  drains in-flight events so tool output and partial prose persist with honest
  unknown/not-started outcomes; uncertain admissions keep their fixed run ID.
- WebSocket clients no longer disconnect on streamed tool results, encoding
  failures, or after 60 s of inbound idle time (server keepalive pings).
- Transient transport errors (closed/reset/timeout) retry inside the agent
  loop using structured error metadata; permanent failures and exhausted quotas
  do not.
- Coding tools reject ambiguous edits, bound reads, refuse binary content,
  keep long shell output retrievable, and kill shell process trees on forced
  cancellation.
- Source startup is faster, reuses healthy daemons, preserves the caller's
  directory and keeps CLI JSON stdout clean; setup selects usable defaults and
  doctor diagnoses unreadable credentials and port conflicts.
- Wire usage counts native cache read/write tokens; session restores preserve
  provider identity and costs; cold checkpoint reads no longer create atoms.

### Changed

- The agent `cron` tool moved from `lemon_gateway` to `lemon_automation`, which
  registers it with `LemonAgent.ToolRegistry` at boot; the gateway no longer
  references automation. The tool's name, schema and results are unchanged. As
  with every registered tool it is now subject to session tool policy and
  approval (so cron-run prompt sessions, which block `cron`, no longer see it).
- Source and packaged launchers now share command dispatch, help, completion,
  and lifecycle semantics. Running `lemon` in a terminal opens the TUI;
  `lemon start` starts the foreground runtime. Non-interactive
  no-argument calls return usage with exit code 2. `send`, `media`, `models`,
  `policy`, `skill`, `usage`, and `migrate hermes` also work without Mix in
  runtime releases.
- Native coding sessions no longer stop at an incidental default turn cap.
  Explicit limits remain available; retries, thinking state, and tool results
  survive the appropriate session transitions.
- Durable memory is recalled automatically into the next user message using
  agent-scoped full-text search and the selected workspace's `USER.md`.
  Recall is bounded to 2 KiB, stays out of the cached system prompt, and can
  be disabled with `[memory] auto_recall = false`. The model-facing memory
  tools are now `remember` and `recall`.
- Heartbeats use cron rather than a second session scheduler. Reminder and
  proactive jobs preserve their originating delivery target.
- Shared credential redaction now covers session, profile, memory, config,
  diagnostic, webhook, and Web surfaces while preserving their stricter
  content allowlists and output bounds.
- Standalone packaging is limited to `lemon_ai`, `lemon_core`, `lemon_agent`,
  `lemon_memory`, and `lemon_platform_test`. Version 0.2.0 tarballs are locally
  installable; these packages have not been published by this change.
- Consolidated contributor and architecture guides; removed duplicate
  walkthroughs and generate machine-readable documentation during site builds
  instead of committing copies.

- Refreshed the public website, README, and onboarding docs with a shared Lemon
  visual identity, clearer task navigation, and current feature guidance.

- `CodingAgent.Session` keeps automatic-compaction and overflow-recovery
  bookkeeping in subsystem-owned state structs. The persisted session format
  is unchanged.

### Removed

- The duplicate `clients/lemon-web` application, `coding_agent_ui`, and
  `lemon_tcg`; the supported clients are the Bun TUI and Phoenix LiveView Web.
- `execute_code`, `python_repl`, their persistent Python/RPC bridge, the MCP
  server surface, and obsolete agent factories. Native tools and the MCP
  client remain; browser actions use explicit browser-tab tools.
- Unused control-plane methods: the built-in registry is reduced from 188 to
  79 methods used by retained clients. Retired device, proof/readiness,
  heartbeat, and other unsupported APIs have no compatibility aliases.
- Long-tail simulation arenas, generated proof/readiness machinery, orphaned
  modules, and duplicate or implementation-only tests. LemonSim's product
  focus is Werewolf, Poker, and VendingBench.
- The `memory_topic`, `session_search`, and `search_memory` tool names. Use
  `remember` and `recall`; no deprecated aliases are retained.

- The built-in `x_api` satellite, its X/Twitter tools and channel adapter,
  OAuth helpers, credential registry entries, release wiring, and developer
  authentication script. Vendor-specific social integration now belongs in an
  external package that registers through Lemon's existing channel and tool
  extension points.

### Fixed

- Requests to the `opencode_go` provider (OpenAI-completions and Anthropic
  transports) now send the `x-opencode-session` header OpenCode Go requires
  since 2026-09, avoiding `400 MissingSessionID`. The id is
  `StreamOptions.session_id` (LemonSim sets one per game and player), with a
  stable per-system-prompt fallback. Other providers are unaffected.

- Finished LemonSim spectator games now display `COMPLETED`, rather than
  `STOPPED`, after their runner exits. Live Werewolf playback keeps its
  playback indicator until the final scene has been shown.

- Router callback defects now reach callers or OTP supervision instead of
  being acknowledged as success. Durable replay/admission and cancellation
  fences remain intact; rejected final deliveries remain retryable.
- Channel delivery no longer replays an external write after an adapter crash
  or lost acknowledgement. A failed Telegram update does not stop the rest of
  its fetched batch; WhatsApp acknowledgement timeouts report unknown outcome.
- File edits handle normalized whitespace and Unicode without damaging
  original UTF-8, BOM, line endings, or surrounding content. Read freshness
  and mutation locks prevent stale or concurrent overwrites.
- Provider handling preserves Retry-After delays, image tool results, and
  usage/cost accounting. Telegram access checks remain fail-closed, including
  pairing, group policy, and attachment-size refusal.
- LemonSim replay verification checks artifact integrity and replays recorded
  batches; seeded randomness makes retained offline arenas reproducible.
- Removed unreachable and unused Elixir paths rather than suppressing
  compiler diagnostics.
- Hermes migration now treats omitted confirmation/overwrite flags as false:
  declining confirmation writes nothing, and conflicts fail closed rather
  than raising.
- Source and packaged `--json` commands keep application-startup logs out of
  machine-readable stdout. The duplicate-test checker resolves nested module
  names, avoiding false collisions between independently scoped helpers.
- Updated locked Bandit, Mint, LiveView, LazyHTML, Gun, and Cowlib releases
  after Hex reported upstream security advisories; refreshed the vendored
  LiveView browser client to match. Cowlib's
  [structured-header](https://cna.erlef.org/cves/CVE-2026-43966.html) and
  [cookie-encoder](https://cna.erlef.org/cves/CVE-2026-43969.html) advisories
  still have no fixed Hex release and remain tracked upstream.

- Bash streaming previews retain the most recent 50,000 output bytes plus an
  omission marker, preserving UTF-8 boundaries without retaining discarded
  source binaries. Final results and full-output files are unchanged.

- Restricted tool profiles deny alternate hashline editing, memory writes,
  and task delegation through `hashline_edit`, `remember`, and `task`.
  Full-access and orchestrator profiles are unchanged.

- Tool approval failures now block execution on exceptions, exits, throws,
  malformed replies, and unsupported approval scopes without exposing raw
  service error payloads. Approval timeout results also render safely when
  the configured wait is infinite.
- Session reset and termination now cancel both automatic-compaction and
  overflow-recovery workers, clear their monitors and timeout refs, and ignore
  late task messages from the previous session identity.
- The LemonSim UI test-only `lazy_html` dependency now uses a bounded
  compatible-version requirement instead of accepting every future release.
- A2A message replays now return the original task without duplicate router
  submission, webhook idempotency storage failures fail closed with retryable
  503 responses instead of reporting acceptance, and exact synchronous webhook
  responses have an independent durable replay receipt. Ambiguous goal-loop
  submissions retain their fixed run ownership until reconciliation or an
  explicit hard stop.
- Fixed run IDs now have durable semantic admission claims and compact permanent
  accepted/aborted outcome fences; only safe never-enqueued claims and volatile
  caches expire. Replays cannot cross session, content, or execution identity,
  transport-local attachment paths do not create false conflicts, and surviving
  run ownership is indexed without probing unrelated run processes. Exact
  webhook response receipts are swept together with their completed primary
  reservation after the replay horizon using transactional or fence-last
  exact-snapshot deletion, and raw webhook idempotency keys are hashed before
  any durable key, receipt, router request, or run metadata is built. Legacy
  raw webhook receipts migrate behind the hashed fence without reopening
  execution, invalid payload idempotency values are rejected before hashing,
  released pending receipts without run identity return a permanent,
  non-retryable duplicate ambiguity receipt, and
  failed cleanup scans do not advance their watermark. Store diagnostics also
  sanitize nested idempotency-key context, and sensitive multi-delete failures
  return bounded error categories instead of backend payloads. Legacy router
  receipts are compacted and abort reasons sanitized during replay and
  background cleanup; goal hard stops persist abort intent before dispatch.
- Telegram memory-reflection and per-chat abort helpers no longer collapse
  router mutation failures into success-like results. Ambiguous cancel and
  keepalive callbacks now direct users to check run status before retrying,
  retain their inline controls, and log only bounded failure classes.
- Gateway webhooks now acknowledge ambiguous router submissions with an
  explicit non-retry-safe receipt instead of a redelivery-triggering 5xx,
  profile chat preserves a reconciliation run ID without retrying or exposing
  raw failures, and goal-loop hard stops report sanitized one-shot abort
  outcomes.
- Email webhooks now reserve a hashed provider Message-ID and stable run
  reference before router submission. Definite rejection remains safely
  retryable, while an ambiguous handoff returns a truthful non-retrying receipt
  and retains dedupe state so provider redelivery cannot create a second run.
  Telegram and WhatsApp busy-query fallbacks no longer log raw session keys or
  exception terms.
- MCP configuration validation now rejects non-boolean OAuth token-persistence
  flags and empty token secret names consistently before HTTP or SSE sources
  reach runtime startup.
- `LemonCore.RouterBridge` query calls now distinguish an idle router from an
  unavailable one: `session_busy?/1`, `active_run/1`, and
  `list_active_sessions/0` return explicit result tuples/errors, and command
  callbacks accept only `:ok` or `{:error, reason}`. All channel, web, A2A,
  control-plane, and portable-command callers were migrated atomically;
  user-facing run controls no longer report success for a request the router
  did not accept.
- Run finalization no longer reports success when session indexing fails.
  Retrying the same immutable summary repairs the derived index without
  incrementing `run_count` twice; conflicting summaries fail closed, and
  finalize hooks document their at-least-once delivery contract.
- Hermes skill install/update requests no longer block their own control-plane
  WebSocket while waiting for approval or Git work. Approval events and
  liveness probes remain deliverable, and the TUI keeps the correlated skill
  mutation request open long enough for human approval and installation.
- Hermes imports now report security-audit refusals directly, and escaped
  Markdown examples such as `curl ... \\| bash` no longer trigger the
  executable-pipeline rule. Real unescaped remote-script pipelines remain hard
  blocks, but operators can accept an exact audited bundle through a separate,
  conspicuous security-override approval that cannot be satisfied by ordinary
  install approval or reused after content changes.
- Telegram, Discord, and WhatsApp tool-status bubbles now omit fixed internal
  engine provenance and reasoning-only actions, so step counts reflect
  user-relevant tools. Automatic filesystem checkpoint lifecycle events remain
  auditable internally and available through explicit `/checkpoint` and
  `/rollback` commands without being pushed into ordinary channel chats.
- Source `./bin/lemon start` detects and reuses a healthy local control plane
  before compilation or Erlang distribution startup, avoiding duplicate
  `lemon@host` registration.
  Web health probes tolerate bounded slow responses and trailing whitespace,
  and the quality lane exercises both direct-launch and `web --no-open` reuse.

### Added

- Background shell execution with session-owned `bash_output` and
  `kill_process` tools, explicit millisecond timeouts, and preserved partial
  output on timeout or cancellation.
- Structured TUI tool cards with real-line-number edit diffs, bounded command
  output, and reasoning display; LiveView chat improvements for streaming,
  Markdown, and tool approvals.
- A keyless `mix lemon.sim.demo` Werewolf spectator demo and offline
  Werewolf/Poker run bundles for local replay verification.

- `mix lemon.eval --output <path> --revision <full-sha>` writes versioned,
  redacted contract reports with check outcomes and explicit revision metadata,
  including when completed checks fail. The manually dispatched Live Eval
  workflow retains these reports for 14 days without uploading raw details.
- `LemonCore.Store.Table` ownership metadata for incremental generic-store
  migrations. The architecture gate now analyzes generic Store calls from the
  AST across every supported operation and default/explicit server arity,
  resolving aliases, module attributes, direct and `apply/3` forms, and every
  table in multi-entry operations while rejecting dynamic or cross-table access
  from an owner module. The metadata is non-operational in this change; backend
  registration, retention, and domain migrations remain separate.
- `LemonCore.PolicyStore` now declares the four existing policy tables it owns.
  This is metadata-only; policy access still uses the specialized Store API and
  its public functions are unchanged.

- `LemonCore.ChatStateStore` now adopts that ownership contract for the cached
  `:chat` table and its existing `:expires_at` retention policy without moving
  TTL, expiry, sweep, or cache behavior out of the specialized Store runtime.
- `LemonCore.RunStore` now declares ownership of the `:runs` and
  `:sessions_index` tables through `LemonCore.Store.Table`, with cache and
  persistence policy recorded explicitly. The existing run lifecycle and
  finalization behavior is unchanged.

- Configured engine runtimes are now checked against
  `LemonCore.EngineRuntime` when the router starts. Invalid wiring is reported
  once and disabled while preserving router-only boot and the existing
  unavailable-runtime handling.
- Persistent source and packaged launchers now provision a private,
  port-scoped control-plane operator credential under `~/.lemon/run`, allowing
  later TUI processes to attach automatically without exposing the bearer in
  argv or enabling tokenless loopback access. Explicit operator tokens remain
  caller-managed and are never persisted by this handoff.

- Bidirectional A2A v1.0 peer interoperability for durable Lemon-Hermes
  conversations: Agent Card discovery, authenticated JSON-RPC and SSE,
  persistent context/session mapping, peer-scoped task lifecycle and
  cancellation, untrusted-content boundaries, and a built-in `peer` tool that
  resumes one long-running default conversation per configured agent.

- Bun TUI portable-blueprint management over the authenticated shared catalog:
  content-free `/blueprints` browsing and `/blueprint` inspect/validate/preview,
  exact fresh-digest activation, stale/refused-plan clearing with preserved
  profile drafts, nonqueueable offline mutation, and duplicate-safe replay.
  The terminal retains and renders only bounded IDs, counts, actions, booleans,
  and digests; real Bandit/Bun proof verifies planted manifest prose, prompts,
  skill bodies, commands, environment values, paths, tokens, and secrets stay
  out of terminal state and proof output.
- Token-required Web durable-memory management at `/manage/memory`, backed by
  a shared `LemonMemory.Lifecycle` over the canonical SQLite/FTS store. The
  responsive browser supports bounded search and safe scope/agent/workspace
  digest/kind filters, Safety-redacted run and learned-source previews,
  digest-only provenance, and exact single-record delete preview/confirmation.
  Deletion binds the document ID to a deterministic revision of every
  persisted field, compares it in constant time inside the same transaction
  that removes the document and FTS row, and fails stale/forged/malformed
  requests without mutation. Memory updates now replace their prior FTS row,
  preventing duplicate search hits for an updated document ID.

- Source and packaged `lemon learn` plus authenticated `learn.review` /
  `learn.confirm` control-plane methods for auditable learning from existing
  bounded file, folder, URL, diff, document, and redacted-session references.
  Review is non-mutating and content-free; confirmation is bound to an exact
  fresh digest and writes only canonical durable memory plus an audited skill
  draft, with traversal/SSRF defenses, redaction, collision checks, and
  idempotent re-review. Exact create-if-absent writes prevent stale destination
  overwrites, provenance-bearing records remain removable through their
  existing stores, and selected source content never enters LLM audit.

- Registry-driven source/packaged `lemon update check|plan|apply|history|rollback`
  with non-mutating manifest/current-bound plans, exact fresh-digest apply,
  serialized checksum/size-authenticated staging, pre-extraction archive
  confinement, verified private checkpoints, atomic pointer recovery,
  content-free receipts, and exact receipt/digest rollback. Source checkouts
  keep binary mutation fail-closed; schema-2 publisher-signing and exact
  in-flight `:httpc` byte cancellation remain explicitly documented residuals.
- Explicitly enabled, read-only 1Password, Bitwarden Secrets Manager, and
  argv-only command secret sources integrated behind the encrypted Lemon store,
  with exact schema validation, supervised time/output bounds, minimal child
  environments, fail-closed fallback behavior, optional bounded in-memory
  caching, and source/packaged `lemon secrets sources status|test` diagnostics
  that expose readiness/provenance only.
- Source and packaged `lemon blueprints` catalog list, sanitized inspect and
  validate, non-mutating default preview, and exact-digest activation over the
  existing authenticated control-plane/`CronManager` path, with stable redacted
  JSON/exit codes, registry-driven help/completion, duplicate-safe results, and
  real source plus assembled minimal-runtime proof.
- Token-required Web blueprint management at `/manage/blueprints`, backed by
  the shared `LemonAutomation.Blueprint.Catalog` service. The responsive page
  lists only safe IDs/counts, validates bundles, previews profile-local skill
  and schedule actions without mutation, requires the exact fresh digest, and
  reports create-once or unchanged replay without retaining manifest prose,
  prompts, skill bodies, paths, commands, environment values, or secrets.
- Authenticated Web provider-routing management at `/manage/providers`, with
  redacted effective status, ordered fallback controls, credential-pool and
  credential-reference lifecycle, preview-first writes, exact confirmation for
  destructive changes, and stale-preview rejection through opaque config
  revisions. Credential references are password-masked, filtered from logs,
  re-entered for apply, and never retained or rendered by the LiveView.
- Source and packaged `lemon sessions` commands for bounded list/search/show,
  exact redacted aggregate statistics with capped agent/origin breakdowns,
  and redacted history, title/pin/archive lifecycle, always-redacted
  JSON/Markdown export, exact-candidate preview-confirm prune, and verified
  exact-key delete; plus registry-generated `lemon completion bash|zsh|fish`
  scripts that preserve source and release launcher-specific commands.
- Bun TUI session lifecycle parity over the same authenticated control-plane
  service: live `/sessions` search/filter/picker UX; `/session` inspect, resume,
  title, pin, archive, redacted preview/export, exact-candidate guarded prune,
  and verified export-before-delete. Destructive mutations are never queued
  offline, refused/stale results do not discard drafts, and list/status/error
  rendering omits paths, prompts, credentials, and unredacted content.
- Source and packaged `lemon providers` readiness and routing management with
  comment-preserving fallback and credential-pool reference edits, stable
  redacted JSON/exit codes, exact confirmation for destructive changes, and a
  matching admin-scoped `providers.configure` control-plane method.
- A client-independent `LemonCore.Context` preview/resolve contract and
  packaged `lemon context` command for bounded `@file`, `@folder`, `@git-diff`,
  `@url`, and redacted `@session` references. PDF, DOCX, XLSX, PPTX, notebook,
  and text content is format-sniffed with explicit byte/page/item/depth/time
  limits, archive-bomb/traversal and symlink defenses, SSRF-safe pinned URL
  fetching, sensitive-value redaction, and structured omission metadata.
- Versioned portable skill + automation bundles with bounded manifest and
  filesystem policy, deterministic source-and-stage audit, profile-local skill
  enablement, content-free control-plane list/inspect/validate/preview, exact
  digest confirmation, and create-once idempotent cron activation.
- An authenticated Lemon Web session-management shell with runtime and live-node
  status, durable search/resume, title/pin/archive controls, redacted structured
  run/tool inspection, bounded JSON/Markdown export, and exact-candidate guarded
  prune. Query-token bootstrap redirects server-side to a clean URL before
  rendering, and named chat routes reconstruct durable history before resuming.
- A shared `LemonCore.SessionLifecycle` service and control-plane
  `sessions.metadata.patch`, `sessions.export`, and `sessions.prune` methods.
  Export fails closed against raw run/event payloads and secrets; prune commits
  canonical history last, verifies deletion, and binds confirmation to exact
  parameters and stable candidate state.
- Source and packaged `lemon backup contract|create|list|verify|restore`
  commands backed by a versioned `~/.lemon` data contract, atomic private
  directory bundles, exact file-set and SHA-256 verification, credential
  exclusions, permission-widening rejection, target-bound overwrite
  confirmation, staged restore, rollback receipts, stable JSON, and documented
  exit codes.
- First-class user-managed profiles over the existing router agent plane, with
  atomic/comment-preserving create, list, show, clone, rename, credential-safe
  export, and guarded recoverable delete; isolated profile workspaces for
  bootstrap/memory/skills; stable `agent:<id>:main` chats; node-aware rosters;
  packaged `lemon profile` commands; matching control-plane methods; and TUI
  `/profiles` roster/picker plus `/profile` inspection, canonical-chat, and
  guarded lifecycle commands. Normal TUI prompts in an opened profile route
  through `profile.chat`, preserving derived workspaces and named nodes. The
  authenticated Web shell now adds a responsive `/manage/profiles` roster and
  preview-first create/clone/rename/recoverable-delete journey with stale
  revision refusal, exact delete confirmation, canonical-chat links, and no
  profile paths or system prompts retained in LiveView state.
- `lemon web [--no-open]` in source and full packaged launchers, with daemon
  auto-start, exact Web health polling, browser opening, and actionable profile
  or startup errors.
- A shared `LemonCore.Setup.Readiness` contract plus a fail-closed Web first-run
  guide, live config/secret refresh, active-run stop control, and accessible
  responsive status/composer states.
- Cron-backed TUI `/heartbeat`/`/hb` commands and channel `/remind` scheduling
  reuse the automation scheduler rather than retaining session heartbeat
  state or a `sessions.heartbeat` API.
- Portable Hermes-compatible slash-command discovery metadata for channel and
  interactive clients, exposed through the read-only `commands.catalog`
  control-plane method while preserving Lemon's router/session ownership and
  active-run-only `/stop` semantics.
- End-to-end Hermes-compatible `/queue`/`/q`, `/steer`, `/reset`, `/reasoning`,
  `/stop`, `/status`, `/usage`, `/agents`/`/tasks`, `/compress`, `/commands`,
  `/help`, `/bg`, and `/btw` support across Telegram, Discord, the TUI, and the
  control plane. Background runs are isolated full-tool sessions; side
  questions use bounded no-tools transcript snapshots without changing parent
  history.
- Channel `/bg` receipts now retain the complete durable job id and Telegram and
  Discord expose `/bg list`, `/bg status <id>`, `/bg result <id>`, and `/bg
  cancel <id>`. Discord portable slash commands also enforce configured
  guild/channel and binding policy before execution, and channel command errors
  no longer render arbitrary internal runtime reasons. Background lifecycle
  access is scoped to its originating channel session so foreign ids are hidden
  as not found, and Discord now applies the same policy gate to every application
  command before reset/reasoning/cancel or other command dispatch.
- Hermes-compatible `/bg` backend sessions with durable lifecycle ids,
  isolated full-tool execution, status/result/list/cancel APIs, and
  restart-safe lost-run reporting; plus bounded `/btw` no-tools queries over
  immutable live snapshots or durable channel session-key history without
  mutating the parent conversation.
- Extensible capability-aware web search/extraction providers with deterministic
  fallback, provider isolation, request-level selection, extension registration,
  keyless DuckDuckGo, configurable SearXNG, Exa search/highlights and batch
  contents extraction, and concurrent
  single-flight request coalescing
- Backend-neutral multi-tab browser control with stable target IDs, safe
  attached-browser lifecycle semantics, authenticated single-use controller
  tickets, and a bundled token-gated Manifest V3 relay for existing signed-in
  Chrome tabs
- Hosted browser lifecycle adapters for Browserbase, Browser Use Cloud,
  Firecrawl, and Camofox; explicit public/local hybrid routing; bounded
  `browser_exec` programs with developer-gated raw CDP; and cross-platform
  `computer_use` backed by exact-session cua-driver state
- Redaction-safe live leadership acceptance harnesses covering real
  `gpt-5.6-luna`/`xhigh` search fallback, multi-source synthesis, multi-tab and
  stale-target browser control, screenshot analysis, extension relay ownership,
  and fail-closed controller consent boundaries
- Named execution nodes can now pair with a Lemon controller through
  `./bin/lemon node join`, advertise live presence under a unique name, and
  run native delegated `CodingAgent.Session` work selected by the `agent`
  tool's `node` parameter. Pairing persists a private, controller-bound token
  on the destination machine; remote runs keep credentials and default working
  directories destination-local and support targeted cancellation plus
  invocation-bound steer/redirect with authenticated destination
  acknowledgement and fail-closed terminal races.
- The control-plane chat surfaces and TUI now preserve redirect as a distinct
  active-run mode. The TUI exposes `/redirect` and cycles queue, steer,
  redirect, and interrupt without conflating redirect with non-canceling steer.
- Lemon Web now discovers an already-active session run and presents explicit,
  responsive follow-up, steer, and redirect choices. The text-only controls
  recheck run eligibility at submit time, keep stop bound to the real active
  run, preserve a refused draft, and report bounded user-facing outcomes
  without rendering internal node/runtime errors.

### Changed

- Lemon AI's 25 provider-module literal catalogs now live in 26 JSON resources
  under `apps/lemon_ai/priv/models/` and are embedded at compile time by
  `LemonAi.Models.Catalog`. Google uses a base catalog plus Antigravity extras;
  the Google Antigravity registry derives from both, while OpenAI Codex derives
  from the direct OpenAI catalog plus OAuth-only IDs. Provider modules retain
  their existing names and `models/0` APIs, catalog files are registered as
  external resources for recompilation, malformed entries fail compilation
  with their model key, and atom-valued API/provider/input/compatibility fields
  accept only explicit allowlists.
- Packaged and Mix `secrets check` output now reports only `present` and source
  category counts; it no longer reveals credential prefixes or suffixes.
- Lemon Web now ships compiled CSS inside the release instead of loading
  Tailwind from a runtime CDN, so the local chat shell works offline.
- Vendored Phoenix and LiveView browser clients now match the locked server
  dependencies, removing the live asset-version mismatch warning.
- Lemon Web declares and serves a bundled favicon instead of logging a missing
  route on each new browser session.
- Background and side-query public APIs now use stable content-free failure
  classifications; their control-plane RPCs allowlist lifecycle fields and
  return fixed bounded error codes/messages without provider terms, persisted
  errors, filesystem paths, or credential details.
- Background and durable side-query launches now normalize string-valued
  reasoning policy to the native atom contract before provider execution.
- Packaged and Mix secrets check/import commands now share one ordered
  environment-credential catalog instead of maintaining three copies
- LemonSim scenarios now share one bounded model/provider/credential resolver;
  unknown provider input no longer creates BEAM atoms, while scenario-specific
  setup errors and provider aliases remain intact
- LemonSim Mix tasks now share ordinary runtime, option, and bounded
  provider/model helpers instead of maintaining two dozen private copies;
  arbitrary provider CLI input no longer creates atoms
- Fifteen LemonSim scenario logs now share one JSONL lifecycle and encoding
  implementation while retaining their existing public APIs and domain fields
- XMTP and WhatsApp now share one supervised Node bridge port lifecycle while
  retaining their adapter-specific `PortServer` callback/process identities,
  scripts, event tags, and module-scoped warning logs
- Documentation quality checks now use a compact catalog with shared defaults,
  explicit lifecycle/visibility metadata, and Git-index-based coverage that
  ignores untracked local drafts
- Pull-request client quality now exercises Lemon Web startup from clean
  generated artifacts, and release smoke evaluates the MCP library contract
  inside both packaged runtime profiles and their release tarballs
- Local coding-agent patches now preflight every hunk before mutation, reject
  duplicate paths and destructive move overwrites, revalidate each operation,
  exclusively create new targets, and report any committed prefix or partial
  current operation when a later mutation fails. Local writes canonicalize the
  path used for both validation and mutation, then reject symlink redirection
  and special-file targets by default.
- Skill manifests now reject unsafe or oversized prompt metadata, relevance
  searches use cached excerpts/status views outside the Registry server, and
  prompt listings expose bounded source/trust provenance with deterministic
  ordering.
- Turn-specific skill relevance no longer changes the cacheable system prompt;
  missed-skill introspection uses turn-local keys, and local file/search/shell
  plus community skill results are fenced as untrusted data before model calls.
- Skill discovery now invalidates content-addressed caches after file, directory,
  lockfile, environment, or disabled-config changes; malformed typed metadata is
  rejected without crashing. Pre-LLM tool fencing ignores spoofed trust metadata,
  bounds hostile text, avoids double-fencing web output, and attests builtin skill
  content against the bundled release copy before granting instruction trust.
- Product releases can now be cut and published from one manual Release
  workflow dispatch; the workflow derives CalVer, consumes the Unreleased
  notes, commits and tags the release, verifies every artifact, publishes the
  GitHub Release, and only then promotes mutable container channel tags
- Lemon Web shared/server `dist` directories are generated by their build
  commands instead of being tracked as source.

### Fixed

- Redirect acknowledgement now waits until the correction is queued and the
  active model request is signaled, preventing a fast completion from silently
  racing ahead of an accepted redirect.
- Persistent Python kernels now preserve parent/child stdout and stderr ordering
  instead of allowing block-buffered parent output to appear after child-process
  output.
- MCP HTTP transports now supervise the protocol server and Bandit listener as
  one lifecycle and track live node-local instances through supervised members,
  preventing stale or orphaned processes across child failures, concurrent
  starts, and transport shutdowns
- Lemon Web now builds its ignored shared/server entrypoints before clean-checkout
  `npm run dev` and `npm start`; the client quality lane exercises that
  clean-artifact startup contract
- Authenticated TUI control-plane handshakes now send the token in the server's
  `params.auth.token` envelope
- Packaged minimal and full runtimes now assemble the MCP client library, so
  configured MCP tools are discoverable without starting a no-op application
  supervisor
- Named execution nodes now recover the same durable identity after their
  seven-day session expires, survive controller-side renames, revoke older
  sessions on rotation, and provide an explicit repair path for legacy local
  credentials. Non-loopback plaintext controller connections now fail closed
  unless development or a verified encrypted overlay is explicitly selected.
- Named-node challenge exchange and per-identity credential replacement are now
  atomic. Rotation closes stale live sockets, binds result settlement to the
  authorized connection generation, retains a monotonic generation floor
  against delayed handshakes, and withholds ID-based recovery material unless
  the exact stored controller is supplied.
- Closed unauthenticated named-node operator access on the control-plane
  WebSocket: non-loopback operators now fail closed, configured operator tokens
  use constant-time validation, unknown session identities cannot escalate, and
  node pairing reports credential problems without exposing secrets. Tokenless
  loopback operator access is now a default-off explicit compatibility opt-in,
  and browser clients keep operator credentials out of WebSocket URLs.
- The source TUI launcher now gives a fresh launcher-owned daemon and client the
  same high-entropy process-scoped operator token, keeps it out of arguments and
  disk, stops every daemon it starts with the TUI regardless of whether the
  token was generated or preconfigured, and fails closed when attaching to an
  existing runtime without its configured token.
- Named execution nodes now cancel destination work when callers time out,
  disappear, reconnect, or lose their controller socket; bind stored tokens to
  the paired node identity; persist fast results without racing dispatch; and
  resolve relative/default working directories from the joining shell. Node
  sockets now send idle keepalives, pairing resumes safely after approval or a
  lost challenge response, bounded JSON request/result limits prevent
  unbounded worker output, and durable status/events retain only redacted
  result summaries while private source delivery remains intact.
- Router and gateway launch lifecycle now bounds pre-start runtime submission
  and run-launch retries, emits one structured terminal failure before queue
  cleanup, deduplicates tokenized scheduler requests, preserves engine-lock
  exclusivity for live owners, and observes over-age live locks without stealing
  them. Gateway cwd fallback also accepts mixed-key proplists without crashing.
- Async task lifecycle, event retention, and join-followup suppression are now
  serialized and terminal state is first-writer-wins. Run-budget usage and
  child admission are atomic, repeated child completion aggregates once, and
  RunGraph finishes DETS recovery before accepting live calls.
- Corrected context truncation ordering, hard bookends character limits, and
  atomic tool-call/result retention; made pending-compaction retries survive
  submit errors with injection-safe whole-entry history envelopes; and cleared
  stale session follow-up diagnostics/background compaction when turns end or a
  new prompt supersedes the snapshot.
- Automation submit-and-wait paths subscribe before submission through one
  fixed-run-id lifecycle, closing synchronous-completion races in cron,
  goal, heartbeat, and Kanban runs.
- Cron retries now persist due time and lineage across manager restarts, claim
  deterministic attempt IDs, and share one terminal policy path for normal,
  stale, aborted, start-failed, and crashed-worker outcomes. Cron work is
  monitored under the automation task supervisor, with unsupervised execution
  reserved for explicit standalone mode.
- Kanban board stop now hard-cancels owned workers and reclaims their exact
  leases immediately; lease-guarded completion rejects late results, and board
  restart reconciles unexpired leases from the prior dispatcher. Board-scoped
  mutation locks also prevent concurrent dispatchers from leasing the same task
  or racing a stale terminal write against a replacement lease. Goal-loop hard
  stop now claims the fixed run ID before submission, aborts that authoritative
  router run once, and prevents another tick. Router abort tombstones close the
  accepted-before-callback window without delaying stop; graceful stop still
  lets the bounded loop finish and API deadlines enclose configured
  judge/continuation waits.
- Async subagent launches now fail and terminalize their bookkeeping when the
  supervised worker cannot start, completed task/agent followup delivery
  contains router exits, and lane-scheduled jobs no longer process a duplicate
  normal monitor event after every result. Delegated agent runs now participate
  in the run graph used by `agent action=join`, and explicit joins suppress the
  redundant automatic completion followup.
- Child `ask_parent` requests now wake idle parent sessions and release parents
  blocked in task/agent joins so clarification cannot deadlock. Parent-question
  creation and terminal transitions are serialized, resolver authorization is
  exact to both session and agent, and terminal lifecycle events emit once.
- Multi-task `wait_any` joins now suppress automatic followup only for the
  completed winner; failed, aborted, crashed, and restarted joins release
  transient suppression.
  Lane queues discard abandoned callers and contain per-job admission failure,
  while delegated watcher timeouts preserve still-running router authority and
  reconcile late completion from a `tracking_lost` state.

### Removed

- Breaking: top-level engine selection and custom Gateway engine extensions
  were removed. Every conversation now uses the native `CodingAgent.Executor`;
  `LemonGateway.Engine`, `EngineRegistry`, Echo, vendor gateway adapters,
  `LemonCore.EngineCatalog`, and `LemonPlatformTest.EngineCase` no longer
  exist.
- The `engine_id`, `default_engine`, `preferred_engine`, and
  `[gateway.engines.*]` configuration/API selectors are rejected with migration
  guidance. Delegated `task` runs use the native in-process `internal` engine
  only; vendor CLI task runners and `[runtime.cli.*]` configuration were removed.

---

## [2026.08.1]

### Added

- First-run onboarding in packaged `lemon_runtime_min` and
  `lemon_runtime_full` releases, including interactive provider/model setup,
  setup-readiness gating before TUI startup, and installer handoff to the
  setup wizard
- Packaged runtime CLI parity for setup, model, gateway, configuration,
  secrets, channels, and diagnostics commands
- Telegram and Discord gateway setup flows with encrypted credential storage
  and verification
- New Bun/`pi-tui` terminal client with streaming transcripts, tool cards,
  approvals, queue/steer/interrupt controls, multiple sessions, themes, mouse
  support, resolved-model display, and per-run usage
- Persistent supervised Python kernels for `execute_code`, with authenticated
  RPC, bounded requests and execution, cancellation, lifecycle cleanup, and
  redacted telemetry

### Changed

- Installation and onboarding documentation now describes the packaged
  first-run flow and distinguishes installed-runtime commands from source
  wrappers
- Release verification now proves packaged onboarding, source setup
  dispatch, readiness isolation, credential scrubbing, and release artifact
  summaries

### Fixed

- Closed an argument-injection path in packaged doctor dispatch
- Hardened persistent Python kernel ownership, teardown, timeout, spill
  cleanup, and late-frame handling
- Preserved installer `--modify-path` behavior while adding setup handoff
- Corrected provider routing circuit-breaker iteration and hermetic channel
  credential handling
- Made stream-result subscription synchronous so user cancellation cannot be
  miscounted as a provider circuit-breaker failure
- Made the live coding-repair release eval specify the patch tool contract
  explicitly, preventing model-dependent shell-edit detours
- Cleaned cached release assembly directories before packaging so artifacts
  cannot retain stale application or dependency versions
- Corrected secret error type specifications and unreachable CLI config
  branches so the allowlisted `lemon_cli` Dialyzer gate remains clean

---

## [2026.08.0]

### Added

**Distribution — prebuilt install story**
- Prebuilt release tarballs for `linux-x86_64`, `linux-arm64`, and
  `darwin-arm64` (`lemon_runtime_min`/`lemon_runtime_full` everywhere,
  `sim_broadcast_platform` on Linux), each boot-verified on its native
  runner before publication, described by a schema-2 `manifest.json`
- One-line installer (`install.sh`): checksum-verified install into
  `~/.lemon/versions/<version>` with an atomic `current` symlink, plus an
  offline CI verification harness (`scripts/verify_install_script`)
- `bin/lemon` launcher shim shipped inside every release
  (start/daemon/stop/status/version/update/doctor and friends)
- Stage-2 self-update: `lemon update` checks the published manifest,
  stream-downloads with mandatory sha256, stages, flips atomically, and
  supports `--rollback`; the control-plane `update.run` method now rides
  the same code path
- Multi-arch container image `ghcr.io/z80dev/lemon` (amd64 + arm64),
  smoke-tested in CI before tagging; a failed image blocks the release

**Platform (since 2026.05.0)**
- Platform split: 12 packages published to Hex, one native top-level executor,
  delegated CLI runners, and standalone `lemon_browser`/`lemon_skills`
  packages
- Always-on model arenas (werewolf, space station, stock market, survivor,
  poker) with leagues, ratings, and spectator UI
- Provider resilience: failover classifier, unified routing fallback,
  multi-key credential pools with health/cooldown
- Redirect-style interruption end to end, including Telegram/Discord
  `/redirect`
- Learning loop on by default: session search (scoped), routing feedback,
  scheduled skill synthesis
- Tool-search tiered disclosure, programmatic tool calling
  (`execute_code`), cron monitor mode/chaining/drift guard/preflight
- Channel delivery observability, hermetic Telegram test API, and the
  three-tier product verification stack

### Changed
- `lemon_runtime_full` releases now ship digested static assets for both
  web endpoints (previously booted with a static-manifest warning)
- Release artifact naming switched to runner-agnostic platform tags

### Fixed
- Control-plane `update.run` no longer buffers downloads in memory or
  skips checksum verification on unrecognized prefixes
- Sim UI Dockerfile references the post-rename app paths and the shared
  `hex_package.exs`

---

## [2026.05.0]

### Added

**M8 — Documentation and release**
- Condensed root README to 5-minute orientation
- New user-guide docs: `setup`, `skills`, `memory`, `adaptive`
- Architecture overview doc (`docs/architecture/overview.md`)
- CONTRIBUTING.md, SECURITY.md, LICENSE, CHANGELOG.md
- GitHub issue/PR templates
- `product-smoke.yml` CI: packaged runtime boot, control-plane HTTP/WebSocket health, full-profile web health, release support-bundle generation, skill lint, adaptive eval gates
- `release.yml` CI: CalVer tag validation, multi-profile artifact build, manifest.json, GitHub Release publication
- `scripts/bump_version.sh`: coordinated CalVer version bump across mix.exs and client package.json files
- VitePress docs site (`docs/.vitepress/config.js`, `docs/package.json`): optional generated site from repo markdown
- `docs-site.yml` CI: docs build, markdown link checking, and GitHub Pages deployment on push to main
- Lemon 1.0 mainstream readiness ledger, launch website scaffold, install/demo/support pages, comparison page, interface proof pack, fresh-install proof, and release-artifact proof docs
- Linux `x86_64` release support policy for `lemon_runtime_min` and `lemon_runtime_full`, including rollback and downloaded-artifact verification steps
- `scripts/verify_release_artifacts`: verifies release `manifest.json` file names, sizes, and SHA-256 checksums against downloaded or assembled artifacts
- Source and clean Docker install proof on Elixir 1.19.5 / Erlang/OTP 28 with `mix deps.get`, `mix compile`, and redacted doctor bundle generation
- Web operations UI proof for `/ops`, run detail pages, support-bundle download, runtime health, sessions, approvals, cron, skills, channels, memory/log activity, and core config controls
- Telegram source-runtime proof for `/cwd`, progress rendering, prompt round trip, bare `/cancel`, approval-button resolution, and concise invalid-model failures
- TUI source-runtime proof for deterministic echo, rendered tool failure, and real-run cancellation
- Launch-focused safety coverage for web fetch output, inbound email prompts, skill prompt rendering, and extension-style untrusted tool results

**M7 — Adaptive routing and skill synthesis**
- Skill synthesis draft pipeline: candidate selector, draft generator, draft store, orchestration pipeline
- `mix lemon.skill draft` subcommands: `generate`, `list`, `review`, `publish`, `delete`
- Task fingerprinting for routing and synthesis (`LemonCore.TaskFingerprint`)
- Routing feedback store (`LemonCore.RoutingFeedbackStore`)
- Explicit run outcome model (`RunOutcome`: `:success`, `:partial`, `:failure`, `:aborted`)
- Offline evaluation and feedback reporting (`mix lemon.feedback`)

**M6 — Memory and feedback**
- Durable memory store and ingest pipeline (`LemonCore.MemoryStore`)
- Session search API and `search_memory` tool
- Memory management tasks and retention controls
- Memory performance and correctness guardrails

**M5 — Session memory**
- `LemonCore.SessionStore` — JSONL-backed session persistence
- `LemonCore.SessionSearch` — full-text search across past runs
- Memory management and pruning

**M4 — Skill quality**
- Skill audit engine with 5 rules (`LemonSkills.Audit.Engine`)
- Skill install policy with trust tiers
- Official registry namespace and trust policy
- `mix lemon.skill` expanded: `inspect`, `check`, `browse`, `update`

**M3 — Progressive skill loading**
- Unified skill prompt view and activation logic
- Stop inlining full skill bodies in prompts
- Upgrade `read_skill` to structured partial loads
- Prompt/token regression tests

**M2 — Skill installer and registry**
- Manifest v2 parser and validator
- Expanded `LemonSkills.Entry` with lockfile storage
- Source abstraction and source router
- Refactored installer and registry around inspect/fetch/provenance
- Legacy skill migration path

**M1 — Runtime and tooling**
- First-class OTP releases (`lemon_runtime_min`, `lemon_runtime_full`)
- `mix lemon.setup` with interactive subcommands
- `mix lemon.doctor` diagnostics framework with redacted source-dev and release-runtime support bundles
- Staged `mix lemon.update`
- Gateway setup adapters (Telegram, Discord)
- Release smoke tests and packaging docs

**M0 — Foundation**
- Ownership model and CODEOWNERS
- Feature flags and rollout config scaffolding (`LemonCore.Config.Features`)
- Frozen shared schemas and invariants

### Changed

- Root README condensed from 3127 lines to 184 lines (deep content moved to `docs/`)
- CI and docs now target Elixir 1.19.5, Erlang/OTP 28.5, and Node.js 24 LTS.
- Setup docs and config examples now include an OpenAI-compatible endpoint path.
- Public docs now clearly distinguish source install, local artifact proof, and bounded 1.0 support claims.

### Fixed

- Untrusted tool output can no longer bypass the external-content wrapper simply by including both boundary markers.
- Inbound email prompts are wrapped as external untrusted content before router submission.
- Telegram bare `/cancel` now aborts active runs even when the command is not a reply to a progress message.
- Telegram invalid model/config errors now render concise failure text instead of exposing BEAM stack traces.

---

## Release Channels

| Channel | Cadence | Stability |
|---|---|---|
| `stable` | Monthly | Fully tested |
| `preview` | Weekly | Feature-complete, light testing |
| `nightly` | Daily | Automated, may be broken |

See [`docs/release/versioning_and_channels.md`](docs/release/versioning_and_channels.md).
