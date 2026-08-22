## Review reconciliation (architecture + code read)

Thanks for the detailed pass on the cutover. A few findings look solid and worth prioritizing; a few others misread the **intended end state** of this workstream.

### Intended architecture (what actually landed)

The cutover removed **top-level** engine selection, not delegated task runners:

- **Top-level** (channels, TUI, gateway, control plane): always native `CodingAgent.Executor` → `CodingAgent.Session`. No `LemonGateway.Engine` / `EngineRegistry` / vendor gateway adapters.
- **Delegated** (`task` tool): still uses `LemonCore.SubagentRunner` + `LemonCore.SubagentRegistry`.

At boot today:

| Runner id | Module | Runtime |
|-----------|--------|---------|
| `internal` (default) | `CodingAgent.CliRunners.LemonSubagent` | in-process `CodingAgent.Session` |
| `codex`, `claude`, `kimi`, `opencode`, `pi` | `LemonCliRunners.*Subagent` | vendor CLI subprocess |

`lemon_cli_runners` is still a permanent release app (`mix.exs`), and `Task.Params.valid_engines/0` still accepts registered runner ids. External engines route through `Task.Runner.execute_via_cli_engine/9`.

So **#9 and #10 should be reframed**: root/gateway changelogs saying vendor CLIs remain as delegated task runners are **correct**. `CONTRIBUTING.md` pointing at `LemonCore.SubagentRunner` / `SubagentRunnerCase` is also **correct** — that is the retained extension point for external/delegated work. What was removed is the **gateway engine** contract (`EngineCase`, custom top-level engines), not subagent runners.

`apps/coding_agent/README.md` *does* look stale on a different axis: the paragraph about text-only `codex`/`claude` tasks skipping the CLI for a provider-direct fast path — I couldn't find a matching path in `Task.Execution`; external engines go through the subagent registry when registered.

### Findings that look valid / high priority

**#2 — prose false positives on resume detection**  
`explicit_non_native_resume_engine/1` matches `<word> resume` without requiring a token (e.g. `please resume …` → engine `please`). Telegram/Discord then reject as unsupported external engine instead of routing. Real user-visible regression.

**#8 — unknown `/resume` selectors misclassified**  
When selector resolution fails after a `candidate_non_native_engine` branch, unresolved selectors become `{:unsupported, engine}` instead of session-not-found. Should only use unsupported for explicit retired-engine syntax.

**#3–#4 — config migrator**  
`migrate!/1` appears to report engine/cli issues `check/1` flags but only rewrites legacy section headers; `migrate_agent_section/1` can append duplicate `[defaults]`/`[runtime]` blocks. False-success risk on `mix lemon.update` looks real.

**#5–#6 — repo automation still vendor-CLI**  
`scripts/cron_lemon_loop.sh` and `bin/diag` still invoke `codex`/`claude` directly. Fine as dev tooling if explicitly scoped, but conflicts with a repo-wide "native-only" goal if that includes automation.

**Doc drift (overlaps #9)**  
- `coding_agent/AGENTS.md` / `README.md` still mention router followups using the `echo` engine (Echo was removed; followups are native `RunRequest` now).
- Plan doc still marked "Proposed replacement" though code is largely landed.

### Findings to verify before calling high-severity

**#1 — explicit resume failures crash `LemonGateway.Run`**  
`SessionRunner.init/1` returns `{:stop, reason}` on bad explicit resume. Worth hardening, but current path may be softer than described: on `start_link` error, `CodingAgent.Executor` sends `completed(ok: false)` to the sink and returns `{:ok, run_ref, runner_pid: nil}`; `Run` handles `{:engine_event, completed}` and finalizes. `safe_start_executor_run/4` also catches `:exit`. Suggest a gateway-level test proving whether Run actually dies vs only surfaces `gateway_run_down` / masked `{:ok}` start.

**#7 — thinking levels**  
Likely a real API/execution mismatch, but orthogonal to the engine cutover — track separately.

### Suggested checklist edits

Keep/prioritize: #2, #3, #4, #5, #6, #8, doc cleanup (echo, plan status, README fast-path).

Rewrite: #9 (changelogs are right about delegated runners; fix README fast-path instead), #10 (keep `SubagentRunner` contributor docs; remove references to deleted `EngineCase` / custom gateway engines).

Investigate: #1 with an integration test before max severity.

### Clarification for "native-only"

If the product goal is **SubagentRunner = internal only** (no vendor CLI children), that is a **further** cutover not present today: drop/stop `lemon_cli_runners`, stop registering vendor `*Subagent` modules, and restrict `valid_engines()` to `internal`. Current code deliberately kept vendor CLIs as opt-in `task` delegation while killing top-level engine selection.
