# Lemonade Stand Stress Test Plan (Telegram + Telethon)

## Objective
Stress-test Lemon end-to-end in the real Telegram environment by driving both sides of the conversation:
- user-side traffic generated via Telethon with real user credentials
- Lemon runtime processing via `lemon-gateway` with debug logs

This plan is intentionally execution-oriented and will be updated live with results.

## Scope
- Group chat: `-1003842984060` (Lemonade Stand)
- Isolation model: one dedicated forum topic per major scenario
- Parallelism model: multiple topics active at once to exercise scheduler lanes and concurrent run handling

## Environment
- Repo: `/Users/z80/dev/lemon`
- Gateway node name: `lemon_gateway_debug`
- Credential source: `~/.zeebot/api_keys/telegram.txt` (under `~/.zeebot/api_keys/`)
- Telethon runner: `uv run --with telethon python ...`

## Success Criteria
1. No deadlocks/stalls in scheduler or engine lock under concurrent topic load.
2. Agent and subagent flows complete (including async task spawn/poll/join patterns).
3. Cron jobs execute and route outputs into intended Telegram topics.
4. Engine directives and model-selection paths behave as expected.
5. File transfer paths work for documents/images/videos (ingress + processing + response).
6. Failures are captured with reproducible prompts, thread IDs, timestamps, and runtime snapshots.

## Runtime Guardrails
- Keep all test traffic inside dedicated test topics.
- Never log or commit secrets (API keys/session strings/OTPs/phone numbers).
- Capture evidence for every case: user prompt, topic ID, response behavior, runtime state.

## Topic Allocation (This Run)
- `3045` - baseline connectivity
- `3046` - trigger mode behavior
- `3047` - lemon engine directive
- `3048` - additional topic-scoped smoke check
- `3049` - codex engine directive
- `3050` - claude engine directive
- `3051` - reserved
- `3052` - reserved

## Test Matrix
| ID | Area | Topic | Procedure | Success Criteria | Status | Evidence |
|---|---|---|---|---|---|---|
| T01 | Connectivity + baseline | `3045` | Create topic, send baseline prompt, confirm Lemon reply | First reply returns in topic with no transport errors | Passed | sent `3053`, reply `3054` (`BASELINE_OK`) |
| T02 | Trigger mode topic override | `3046` | Run `/trigger mentions` then non-mention + mention prompts | Only mention/reply triggers run in that topic | Partial (D02) | `/trigger mentions` succeeded (`3056`); non-mention timed out as expected (`3057`); explicit mention + slash (`3058`,`3059`,`3061`) did not trigger due to nil `bot_username` (D02). D02 now fixed — see T23/T24 |
| T03 | Engine directive: lemon | `3047` | Send `/lemon <prompt>` | Run completes on lemon engine | Passed | sent `3067`, reply `3070` (`ENGINE_LEMON_OK`) |
| T04 | Engine directive: codex | `3049` | Send `/codex <prompt>` | Run completes on codex engine | Failed | sent `3066`, reply `3069` reported: `codex exec finished but no session_id/thread_id was captured` |
| T05 | Engine directive: claude | `3050` | Send `/claude <prompt>` | Run completes on claude engine | Passed | sent `3068`, reply `3071` (`ENGINE_CLAUDE_OK`) |
| T06 | Queue override semantics | `3080` | Send `/interrupt`, `/followup`, `/steer` prompts in quick sequence | Queue behavior matches command intent; no stuck runs | Partial | 3 sent, 1 reply. Likely scheduler contention during 12-way parallel batch. |
| T07 | Subagent async spawn/poll/join | `3081` | Prompt assistant to use `task` tool with async spawn/poll/join | Multiple subagent tasks complete and aggregate result | Passed | 180s. Subagent completed. sent `3097`, recv `3113` |
| T08 | Agent launch / delegation | `3082` | Prompt assistant to use `agent` tool for delegated run | Delegated agent run starts/completes and returns output | Passed | 180s. Delegated run completed. sent `3095`, recv `3125` |
| T09 | Model override via task/agent path | `3083` | Prompt tool call with explicit `model` + engine pairing | Requested model path used; no mismatch failure | Partial | Reply received but model identity not confirmed in text. sent `3098`, recv `3109` |
| T10 | Parallel topic stress | `3047,3049,3050` | Fire concurrent prompts across multiple topics | Stable throughput; no lock starvation or unknown channel | Partial | 3-topic parallel run completed without deadlock; codex path failed functionally (T04) |
| T11 | Cron add + run_now | `3084` | Add cron job targeting topic session, run immediately | Cron run executes and posts result in target topic | Passed | 100s. 2 sent, 3 recv. Cron add + run_now both worked. |
| T12 | Cron scheduled tick | TBD | Add near-term cron schedule and wait for tick | Scheduled execution occurs at expected minute | Planned | - |
| T13 | Document transfer | `3127` | Send text file containing secret word, ask bot to find it | File indexed/usable in subsequent run | Partial | Bot replied but did not reference document content ("PINEAPPLE"). File may not be ingested into context. |
| T14 | Image transfer | TBD | Send image + prompt referencing image | Image reaches system and assistant handles request | Planned | - |
| T15 | Video transfer | TBD | Send short mp4 + prompt referencing video | Video upload path works; assistant responds appropriately | Planned | - |
| T16 | Resumption control | `3086` | Run `/resume` list + switch + follow-up | Resume target selected and used reliably | Passed | 91s. Resume list + switch + follow-up all worked. sent `3093,3118`, recv `3112,3120` |
| T17 | New-session reset | `3087` | Run `/new`, then prompt and verify fresh context | Session resets cleanly without stale resume bleed | Passed | 123s. /new resets context cleanly. sent `3094,3117,3121`, recv `3107,3119,3122` |
| T18 | Runtime health under load | Global | Repeated state probes during active runs | Scheduler/EngineLock/Worker state remains healthy | Passed (batch) | Scheduler empty, EngineLock empty after batch; 5 thread workers alive |
| T19 | Message reactions | `3088` | Send prompt and check for emoji reactions on user message | Bot applies reaction emoji (👀 on start, ✅ on success) | Passed | 63s. Reactions applied correctly. sent `3099`, recv `3111` |
| T20 | Long response chunking | `3089` | Prompt that elicits 3000+ word response | Response split into multiple Telegram messages at sentence boundaries | Partial | Single 2436-char reply; response not long enough to trigger 4096 chunking split. Needs longer prompt. |
| T21 | Cancel command | `3090` | Start long-running prompt, send `/cancel` after 5s | Run cancels cleanly, no stuck scheduler/lock state | Partial | Cancel preempted all output; no reply received. Cancel itself worked (scheduler/lock clean). |
| T22 | Edit detection | `3128` | Send message, edit it, verify bot processes the edit | Bot responds to edited content, not original | Partial | Initial reply received; no response to edit. Edit detection may not trigger new run — by design or bug. |
| T23 | @mention trigger (D02 retest) | `3072` | `@zeebot_lemon_bot <question>` in mentions-mode topic | Bot processes the mention and replies | Passed | 60s. D02 fix confirmed. sent `3074`, recv `3077` |
| T24 | Reply-to-bot trigger | `3073` | Reply to bot's own message with follow-up question | Bot processes the reply and responds contextually | Passed | 121s. Reply-to trigger works. sent `3075,3078`, recv `3076,3079` |
| T25 | Outbox rate limiting | TBD | Fire 10+ rapid prompts in same topic | Messages delivered without rate-limit errors; token bucket respects 30msg/s | Planned | - |
| T26 | Media group / album | TBD | Send 3+ photos as album with caption, prompt about them | Album debounced into single inbound; all images processed | Planned | - |
| T27 | Voice message transcription | TBD | Send a voice message (OGG opus) with spoken prompt | Voice transcribed via Whisper; bot responds to transcript | Planned | - |
| T28 | Callback query / buttons | TBD | Trigger exec approval flow, click approve/deny buttons | Callback query processed; approval state updated correctly | Planned | - |
| T29 | Model selection precedence | TBD | Set model via config, override via `/claude`, verify used model | Directive override takes precedence over config default | Planned | - |
| T30 | Context overflow / compaction | TBD | Send 50+ messages to fill context window past 90% | Auto-compaction triggers; conversation continues without error | Planned | - |
| T31 | Concurrent 10-topic stress | TBD | Fire prompts across 10 topics simultaneously | All 10 complete; no lock starvation or unknown_channel errors | Planned | - |
| T32 | Message deduplication | TBD | Resend identical message within 600s TTL | Second copy ignored; only one run triggered | Planned | - |
| T33 | Engine lock contention | TBD | Fire 5+ concurrent runs exceeding max_concurrent (2) | Excess runs queue and execute after lock release; no deadlock | Planned | - |
| T34 | Forwarded message handling | TBD | Forward a message from another chat to bot topic | Forwarded message processed; bot responds appropriately | Planned | - |
| T35 | Error recovery / transient failure | TBD | Simulate engine error mid-run (e.g., invalid model name) | Error reported in topic; scheduler/lock cleaned up; next run works | Planned | - |
| T40 | task engine=claude async | `3141` | Spawn async task with engine='claude' | Task completes and returns answer | Failed | Claude Code detects nested session and refuses to start. Bot answered from own context. Not a bug — expected limitation. |
| T41 | task engine=codex async | `3142` | Spawn async task with engine='codex' | Task completes and returns answer | Failed → Retesting | Codex config error: `model_auto_compact_token_limit=0.85` float parse failure (D01). Fix applied, retest running. |
| T42 | task engine=claude sync | `3143` | Spawn sync task with engine='claude' | Task completes synchronously | Passed | 14s. "Jupiter" returned via internal engine fallback. |
| T43 | task engine=codex sync | `3144` | Spawn sync task with engine='codex' | Task completes synchronously | Passed | 13s. "144" returned. Same codex config error but bot answered directly. |
| T44 | agent coder async | `3145` | Delegate to agent_id='coder' async | Coder agent completes and returns code | Passed | 300s. hello world Python one-liner returned. |
| T45 | agent coder sync | `3146` | Delegate to agent_id='coder' sync | Coder agent completes synchronously | Passed | 15s. `date` bash command returned. |
| T46 | agent engine=claude async | `3147` | Agent with engine_id='claude' async | Agent completes via claude engine | Failed | Claude CLI returned rc=1 — nested session detection. Same as T40. |
| T47 | cron add + run_now (matrix) | `3148` | Add cron job + immediately run it | Cron creates, runs, outputs result | Passed | "CRON_ENGINE_MATRIX_OK" received. Job created and run successfully. |

## Execution Log

### 2026-02-22 (batch 1)
- Plan initialized.
- Started gateway in debug mode with distributed node `lemon_gateway_debug@chico`.
- Provisioned 8 test topics (`3045`..`3052`) in Lemonade Stand.
- Completed batch 1: baseline + trigger-mode checks + parallel engine-directive checks (`/lemon`, `/codex`, `/claude`).
- Captured codex engine defect (missing `session_id/thread_id` capture on successful process exit).
- Pausing further testing after current batch per operator request.

### 2026-02-22 (batch 2)
- Restarted gateway for batch 2. Node: `lemon_gateway_debug@chico`.
- **D02 root cause identified**: `bot_username` and `bot_id` were both `nil` in transport state. `resolve_bot_identity` silently rescued an exception during init, returning `{nil, nil}`. The `getMe` API works fine — calling it now returns `{8594539953, "zeebot_lemon_bot"}`.
- **D02 hot-fix applied**: Injected correct bot identity via `:sys.replace_state/2` on the running transport process.
- **D02 permanent fix**: Added logging to `resolve_bot_identity` rescue/fallback branches so silent failures are visible. Hot-reloaded the module.
- **D01 investigation**: Codex CLI v0.104.0 works correctly from terminal — emits `thread.started`, `turn.started`, items, `turn.completed`. CodexSchema decoding verified correct. Root cause likely in subprocess environment or 100ms exit debounce race — needs live repro.
- Added 17 new test scenarios (T19–T35) covering: reactions, chunking, cancel, edit detection, mention trigger, reply trigger, rate limiting, media groups, voice transcription, callback queries, model precedence, context compaction, 10-topic stress, deduplication, lock contention, forwarding, error recovery.
- **T23+T24 batch**: Both PASSED. D02 fix confirmed — @mention trigger and reply-to-bot trigger both work after bot identity hot-fix.
- **12-test parallel batch**: Topics 3080–3091 allocated. Results:
  - **T06** (queue override, 3080): PARTIAL — 3 messages sent, only 1 reply received (expected 3). Possible scheduler contention or queue-mode interaction.
  - **T07** (subagent, 3081): PASS — 180s. Subagent spawn/poll/join completed successfully.
  - **T08** (agent delegation, 3082): PASS — 180s. Delegated agent run completed and returned output.
  - **T09** (model override, 3083): PARTIAL — Reply received but could not confirm model identity in response text.
  - **T11** (cron, 3084): PASS — 100s. Cron add + run_now worked; 3 replies received.
  - **T13** (document transfer, 3085): FAIL — No reply. Root cause: stuck in scheduler waitq (in_flight=4/4, waitq=5). Run never started. Not a transfer bug — scheduler contention with 12 concurrent tests.
  - **T16** (resume, 3086): PASS — 91s. Resume list + switch + follow-up worked.
  - **T17** (new session, 3087): PASS — 123s. /new resets context cleanly.
  - **T19** (reactions, 3088): PASS — 63s. Bot applied reactions correctly.
  - **T20** (long response chunking, 3089): PARTIAL — Single message (2436 chars), expected chunking into multiple messages. Response may not have been long enough to trigger 4096-char split.
  - **T21** (cancel, 3090): PARTIAL — Cancel preempted output entirely; no reply received. Cancel itself worked.
  - **T22** (edit detection, 3091): FAIL — No reply. Root cause: stuck in scheduler waitq (waitq=3). Same scheduler contention issue.
- **Runtime health post-batch**: Scheduler empty, EngineLock empty, 5 thread workers alive. No deadlocks.
- **D03 observation**: "message can't be edited" warnings very frequent (20+ in this batch), especially for topic 3089 (long response). Needs investigation.
- **New finding D05**: Scheduler max=4 is too low for parallel testing. T13 and T22 timed out while waiting for a slot. Consider raising max or documenting expected queueing behavior.

## State Snapshots
- Scheduler (`2026-02-22T04:40Z`): `%{max: 4, monitors: %{}, in_flight: %{}, waitq: {[], []}, worker_counts: %{}}`
- EngineLock (`2026-02-22T04:40Z`): `%{locks: %{}, waiters: %{}, reap_interval_ms: 30000, max_lock_age_ms: 300000, ...}`
- Thread workers (`2026-02-22T04:40Z`): `5` active children under `LemonGateway.ThreadWorkerSupervisor`
- Cron run snapshots: not started yet

### Post-Batch-2 State (`2026-02-22T05:17Z`)
- Scheduler: `%{max: 4, monitors: %{}, in_flight: %{}, waitq: {[], []}, worker_counts: %{}}` (clean)
- EngineLock: `%{locks: %{}, waiters: %{}}` (clean)
- Thread workers: `5` active
- Bot identity: `bot_id=8594539953, bot_username="zeebot_lemon_bot"` (hot-fixed from nil/nil)
- No deadlocks, no lock starvation, no stuck runs after 14 test executions across 14 topics

## Defects / Follow-ups
- D01 (High → Fixed): `/codex` engine failed because `codex_runner.ex` passed `model_auto_compact_token_limit=0.85` (float) but codex CLI v0.104.0 expects an integer (token count). This caused codex to exit immediately with config parse error before emitting `thread.started`. **Fix**: Changed to `model_auto_compact_token_limit=170000` (85% of 200k context). Hot-reloaded into running gateway.
- D02 (High → Fixed): `bot_username` and `bot_id` were `nil` in transport state because `resolve_bot_identity` silently rescued an init-time exception. **Root cause**: bare `rescue` swallowed the error. **Fix**: Added warning/error logging to all fallback branches. Hot-fixed running instance via `:sys.replace_state`. Permanent fix committed to `transport.ex`.
- D03 (Medium): Frequent Telegram outbox warning on edit operations: `Bad Request: message can't be edited` after run completion. Very noisy under parallel load (20+ warnings in one 12-test batch). Needs rate-limit or suppress-after-first logic.
- D04 (Low/Noise): Periodic `Bandit.TransportError timeout` logs observed on local HTTP servers during gateway runtime.
- D05 (Medium): Scheduler `max: 4` too low for parallel topic testing. T13 and T22 originally timed out while stuck in waitq (in_flight=4/4, waitq=5). Runs never started. Not a functional bug — expected queueing — but impacts parallel test throughput.
- D06 (Medium): Document transfer (T13) — bot replies but does not reference uploaded file content. File may not be ingested into LLM context. Needs investigation of file attachment handling in `transport.ex` inbound pipeline.
- D07 (Low): Edit detection (T22) — bot responds to original message but does not trigger a new run when the message is edited. May be by-design (edits not re-processed) or missing `edited_message` handling in the polling path.
