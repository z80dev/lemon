# Lemon ↔ Hermes-Class Agent Harness Parity Scorecard

Status: working scorecard; first through forty-first parity slices merged core learning, memory, skill, delegation, tool-lifecycle, transcript, scheduling, and live-model eval contracts; forty-second slice sanitizes OpenAI-compatible tool-call arguments before request encoding; forty-third slice preserves recoverable truncated streamed tool-call arguments; forty-fourth slice honors provider retry delays; forty-fifth slice normalizes context-length provider errors; forty-sixth slice normalizes Req-style rate-limit headers; forty-seventh slice normalizes OpenAI Responses HTTP errors; forty-eighth slice adds a live-model delegation side-effect verification eval; forty-ninth slice adds leaf/orchestrator toolset contracts; fiftieth slice sanitizes OpenAI-compatible tool-call arguments before request encoding; fifty-first slice sanitizes OpenAI Responses function-call identity fields before request encoding; fifty-second slice sanitizes OpenAI Responses tool schema fields before request encoding; fifty-third slice makes internal task children leaf workers by default; fifty-fourth slice rejects secret-looking memory documents before ingest; fifty-fifth slice adds live-model durable-topic memory coverage; fifty-sixth slice documents the composed agent safety contract; fifty-seventh slice adds a deterministic untrusted prompt-injection contract; fifty-eighth slice preserves structured tool failure metadata in LemonRunner action events; fifty-ninth slice exposes tool failure metadata in router status intents; sixtieth slice preserves nested engine action metadata at the control-plane event boundary; sixty-first slice treats Anthropic overloaded HTTP 529 responses as transient retryable provider errors; sixty-second slice records skill prompt-render decisions in telemetry and introspection; sixty-third slice adds a deterministic workspace memory-file inspection contract; sixty-fourth slice normalizes millisecond retry-after provider headers; sixty-fifth slice parses provider rate-limit reset duration headers; sixty-sixth slice adds live-model workspace memory-file inspection coverage; sixty-seventh slice adds live-model relevant-skill audit coverage; sixty-eighth slice classifies provider rate-limit and overloaded text independently of exact HTTP status; sixty-ninth slice parses HTTP-date Retry-After headers; seventieth slice backs dedicated memory/skill tool preference with prompt contracts; seventy-first slice adds live-model untrusted prompt-injection coverage; seventy-second slice adds an explicit AgentCore loop state-machine contract; seventy-third slice writes durable curator run reports; seventy-fourth slice sharpens curator prompts toward active skill updates; seventy-fifth slice restricts background curator reviews to learning tools; seventy-sixth slice links curator reports to submitted review runs; seventy-seventh slice handles nullable and union schema tool arguments; seventy-eighth slice converts empty and thinking-only terminal responses into structured assistant errors; seventy-ninth slice normalizes provider rate-limit body hints; eightieth slice normalizes malformed OpenAI Responses streamed function-call identities; eighty-first slice normalizes malformed OpenAI-compatible streamed tool-call identities; eighty-second slice locks in tool-batch abort closure for pending and queued calls; eighty-third slice uniquifies duplicate OpenAI-compatible streamed tool-call ids; eighty-fourth slice uniquifies duplicate OpenAI Responses streamed function-call ids; eighty-fifth slice normalizes provider error arrays; eighty-sixth slice preserves standalone LemonRunner tool error metadata; eighty-seventh slice normalizes provider detail arrays; eighty-eighth slice normalizes nested provider messages; eighty-ninth slice preserves gateway action result metadata; ninetieth slice preserves tool result details in model-turn and stored agent transcripts; ninety-first slice normalizes provider detail maps and top-level error arrays; ninety-second slice normalizes provider error description fields; ninety-third slice locks router session and status metadata propagation; ninety-fourth slice preserves streamed partial tool arguments through empty terminal provider messages; ninety-fifth slice locks request-boundary invalid UTF-8 sanitization for OpenAI-compatible and OpenAI Responses providers; ninety-sixth slice ignores late router stream deltas after finalized delivery; ninety-seventh slice adds a deterministic agent-loop skill refinement contract; ninety-eighth slice preserves recoverable truncated OpenAI Responses function-call arguments; ninety-ninth slice preserves recoverable final-only OpenAI Responses function-call arguments; one hundredth slice adds deterministic workspace memory refinement coverage; one hundred twenty-seventh slice adds deterministic local media smoke proof for all five no-credential media providers; one hundred twenty-eighth slice adds Streamable HTTP MCP refresh-token grant retry and rotation proof; one hundred twenty-ninth slice routes configured stdio MCP sampling review through Lemon's BEAM approval surfaces; one hundred thirtieth slice adds Streamable HTTP MCP authorization-code PKCE callback proof; one hundred thirty-first slice adds Streamable HTTP MCP OAuth token cache persistence/resume proof; one hundred thirty-second slice adds configured-source Streamable HTTP MCP loopback OAuth callback capture proof; one hundred thirty-third slice routes configured Streamable HTTP MCP OAuth authorization through Web `/ops` operator approvals; one hundred thirty-fourth slice exposes pending approval action metadata through the control plane; one hundred thirty-fifth slice exposes approval action metadata on live control-plane approval events; one hundred thirty-sixth slice renders MCP OAuth approval events as TUI notifications; one hundred thirty-seventh slice resolves approvals from the TUI; one hundred thirty-eighth slice lists pending approvals from the TUI; one hundred thirty-ninth slice preserves approval resolved event context; one hundred fortieth slice backs approval WebSocket event payloads with explicit control-plane schemas; one hundred forty-first slice renders structured MCP sampling approval metadata in Web `/ops`; one hundred forty-second slice renders structured approval metadata in the TUI; one hundred forty-third slice renders structured approval metadata on Web run detail pages; one hundred forty-fourth slice resolves run-scoped approvals from Web run detail pages; one hundred forty-fifth slice records redacted approval lifecycle events and renders run approval history; one hundred forty-sixth slice broadcasts approval timeouts to operator clients; one hundred forty-seventh slice renders skill and memory learning events on Web run detail pages; one hundred forty-eighth slice renders Telegram and Discord channel events on Web run detail pages; one hundred forty-ninth slice renders cron lifecycle events on Web run detail pages; one hundred fiftieth slice renders subagent and delegation events on Web run detail pages; one hundred fifty-first slice distinguishes Discord Message Content Intent proof drift in doctor channel checks; one hundred fifty-second slice carries that drift into Web /ops channel drilldown; one hundred fifty-third slice adds Web /ops Discord Message Content Intent config controls; one hundred fifty-fourth slice adds stable Discord slash client-click proof failure reason kinds; one hundred fifty-fifth slice adds copy-ready Web /ops provider-backed media proof commands; one hundred fifty-sixth slice captures the redacted missing slash client-click proof artifact; one hundred fifty-seventh slice carries missing slash client-click proof state into Web /ops channel drilldown; one hundred fifty-eighth slice adds copy-ready provider-media proof commands to doctor remediation; one hundred fifty-ninth slice enforces redacted proof-path commands in CI docs lint; one hundred sixtieth slice normalizes provider detail-array error descriptions; one hundred sixty-first slice splits long Discord finalized edits into ordered follow-ups and suppresses duplicate finals; one hundred sixty-second slice makes Telegram/Discord final idempotency file-sensitive; one hundred sixty-third slice normalizes JSON:API title fallbacks and nested validation error objects; one hundred sixty-fourth slice preserves string error codes with sibling provider message text; one hundred sixty-fifth slice reads common provider body retry hints; one hundred sixty-sixth slice preserves tool exception metadata in router status intents; one hundred sixty-seventh slice preserves nonzero command exit metadata in LemonRunner and router status intents; one hundred sixty-eighth slice preserves tool-reported exit codes in existing structured LemonRunner failure metadata; one hundred sixty-ninth slice locks exit-code result metadata through gateway and control-plane event boundaries; one hundred seventieth slice preserves nested details messages from symbolic provider error maps; one hundred seventy-first slice uses nested provider details when top-level provider messages are placeholders; one hundred seventy-second slice preserves symbolic provider error prefixes with direct or nested effective messages; one hundred seventy-third slice normalizes atom-key provider error bodies at the parse boundary; one hundred seventy-fourth slice aligns public context-length helper detection with normalized atom-key provider maps; one hundred seventy-fifth slice normalizes atom enum provider values for parsed classification and direct helper checks; one hundred seventy-sixth slice aligns public rate-limit helper detection with provider-body classifications; one hundred eighty-third slice makes provider-media smoke proof handoffs match the documented `--proof-path` operator contract; one hundred eighty-fourth slice lets provider-media smoke proofs resolve one-off encrypted Lemon secret names without exporting raw API keys; one hundred eighty-fifth slice surfaces the provider-media secret-backed proof command directly in Web `/ops`; one hundred eighty-sixth slice makes the final readiness handoff mention secret-backed provider-media proof commands and lint that contract; two hundred ninth slice adds final-readiness provider-media reason diagnostics.

Latest media slice: two hundred forty-second slice carries redacted provider-backed media proof lane state into control-plane `media.status`, including safe reason kinds, proof hashes, rerun commands, and bounded next actions for image, TTS, STT, vision, and video.
Latest cron slice: two hundred thirty-seventh slice carries the same BEAM scheduler health into control-plane `cron.status`, adding active-lock, failed-run, retry-run, suppressed-slot, stale-recovery, scheduled-retry, status-count, trigger-count, and audit-action counters for non-Web operator clients.
Latest terminal slice: two hundred thirty-eighth slice carries terminal backend live-proof state into control-plane `terminal.backends.status`, adding completed/failed/skipped/missing proof counts, per-backend proof statuses, proof timestamps/hashes, and redacted Docker hardening fields for non-Web operator clients.
Latest proof-status slice: two hundred fortieth slice makes control-plane `proofs.status` launch-gate summaries pagination-safe by computing gates from the full redacted proof inventory while still honoring response limits for returned proof rows and checks.
Latest control-plane summary slice: three hundred twenty-seventh slice redacts sensitive wizard-step response data while preserving non-sensitive wizard progress fields.
Latest LSP slice: two hundred forty-first slice carries recent redacted LSP proof artifacts and latest LSP proof checks into control-plane `lsp.diagnostics.status`, matching Web `/ops` promotion visibility for non-Web operator clients.
Latest browser slice: two hundred forty-third slice carries recent live browser proof state, latest browser proof checks, browser proof booleans, proof hashes, and cleanup booleans into control-plane `browser.status`.
Latest checkpoint slice: Slice 313 adds explicit path/diff/restore cleanup summaries to control-plane `checkpoint.diff` and `checkpoint.restore`, while preserving hashed session identifiers.
Latest channel slice: three hundred fifty-seventh slice adds compact launch-gate status and reason-kind maps to `channels.status` summaries.
Latest channel readiness slice: four hundred eighth slice preserves Discord DM reason kinds in shared channel/readiness unresolved-gate summaries.
Latest provider slice: two hundred forty-sixth slice carries redacted provider fallback live-proof status into control-plane `providers.status`, matching Web `/ops` provider proof visibility for non-Web clients.
Latest channel proof slice: three hundred fifty-eighth slice refreshes the real Discord slash client-click missing-proof artifact and verifies operator surfaces keep the gate warning actionable.
Latest supply-chain slice: three hundred fifty-ninth slice adds a pinned OSV Scanner workflow over first-party Mix, npm, and uv lockfiles and refreshes the Hermes source baseline to `94c523f0c`.
Latest memory slice: three hundred sixtieth slice adds a Hermes-compatible no-LLM `session_search` tool over Lemon's BEAM memory and run-history stores.
Latest prompt slice: three hundred sixty-first slice teaches native Lemon prompts and deterministic prompt contracts when to prefer Hermes-compatible `session_search` over shell/session-file spelunking.
Latest social/search slice: three hundred sixty-second slice adds a first-party read-only `x_search` tool over the existing BEAM X API adapter, including bearer-token-only search credentials and coding-agent registry/policy coverage.
Latest CI integrity slice: three hundred sixty-third slice adds a PR-only history-check workflow that rejects unrelated-history branches before they can graft a second root into Lemon's main history.
Latest package-check slice: three hundred sixty-fourth slice adds a non-publishing Python CLI package lane for `lemon-cli` lint, tests, wheel build, and source distribution build.
Latest script-send slice: three hundred sixty-fifth slice adds `./bin/lemon send` and `mix lemon.send` for Hermes-style script notifications to Telegram and Discord.
Latest script-send ergonomics slice: three hundred sixty-sixth slice completes the credential-free Hermes script-send ergonomics for forced stdin, filtered target listing, and built-in help.
Latest script-send JSON slice: three hundred sixty-seventh slice exposes sanitized `message_id` and `extra_message_ids` in script-send results without returning raw platform responses.
Latest script-send exit-code slice: three hundred sixty-eighth slice aligns `mix lemon.send` / `./bin/lemon send` exit codes with Unix script expectations: success `0`, delivery failure `1`, usage/config/input failure `2`.
Latest script-send target-discovery slice: three hundred sixty-ninth slice adds bounded Telegram known-target discovery to `mix lemon.send --list` / `./bin/lemon send --list`, sourced from the BEAM `LemonChannels.Telegram.KnownTargetStore` without expanding beyond Telegram/Discord.
Latest Discord target-directory slice: three hundred seventieth slice adds bounded Discord known-target discovery to `mix lemon.send --list` / `./bin/lemon send --list`, sourced from BEAM-indexed allowed inbound Discord channels/threads.
Latest Discord named-target slice: three hundred seventy-first slice resolves unique Discord known names such as `discord:#ops` and `discord:#ops:deploys` through the BEAM known-target directory while failing closed on missing or ambiguous names.
Latest script-send attachment slice: three hundred seventy-third slice lets `mix lemon.send` / `./bin/lemon send` upload up to 10 local files to Telegram or Discord through the existing file adapters, with body text used as the caption and sanitized attachment metadata returned to scripts.
Latest script-send batch-id slice: three hundred seventy-fourth slice preserves batch Telegram file delivery ids by returning the first delivered platform id as `message_id` and the rest as `extra_message_ids`.
Latest script-send dry-run slice: three hundred seventy-fifth slice adds credential-free `--dry-run` validation for Telegram/Discord script notifications, including target/default/name resolution, body/caption handling, and attachment metadata without delivery.
Latest Telegram named-target slice: three hundred seventy-sixth slice resolves unique Telegram known names such as `telegram:#chat`, `telegram:@username`, and `telegram:#chat:topic-name` through the BEAM known-target directory while failing closed on missing or ambiguous names.
Latest script-send alias slice: three hundred seventy-seventh slice includes exact reusable Telegram/Discord named-target aliases in bounded `--list` output so script authors can copy the selectors Lemon can resolve.
Latest script-send account slice: three hundred seventy-ninth slice adds `--account` so script notifications select the outbound channel account and scope known-target listing/name resolution across multi-account BEAM deployments.
Latest script-send thread slice: three hundred eightieth slice adds standalone `--thread` and `--topic` overrides with conflict checks for script notifications.
Latest script-send default-account slice: three hundred eighty-first slice adds env/config-backed default account ids for account-scoped script notifications.
Latest script-send reply slice: three hundred eighty-second slice exposes adapter-backed message replies through `--reply-to`.
Latest source policy slice: three hundred eighty-ninth slice exposes `mix lemon.policy` through `./bin/lemon policy` and adds model-policy listing to the source-install proof lane.
Latest source models slice: three hundred ninetieth slice adds `mix lemon.models`, exposes it through `./bin/lemon models`, and proves source-wrapper model catalog listing without credentials or secret values.
Latest source providers slice: three hundred ninety-first slice adds `mix lemon.providers`, exposes it through `./bin/lemon providers`, and proves source-wrapper provider readiness listing through the same redacted BEAM `ProviderStatus` snapshot as `providers.status`.
Latest source secrets slice: three hundred ninety-second slice exposes the existing `mix lemon.secrets.*` task family through an allowlisted `./bin/lemon secrets` dispatcher and proves `./bin/lemon secrets status`.
Latest source skill slice: three hundred ninety-third slice exposes the existing `mix lemon.skill` lifecycle task through `./bin/lemon skill` and proves source-wrapper skill listing.
Latest source media slice: three hundred ninety-seventh slice adds `mix lemon.media`, exposes it through `./bin/lemon media`, and proves source-wrapper media diagnostics without prompts, raw artifact paths, generated bytes, provider responses, channel message bodies, raw proof paths, or secret values.
Latest source readiness slice: four hundredth slice extracts the compact launch-readiness rollup into `LemonCore.Doctor.ReadinessSummary` and includes `readiness_summary.json` in support bundles.
Latest readiness reason slice: four hundred ninth slice carries provider-media unresolved-gate reason kinds into CLI readiness, support bundles, JSON-RPC, and Web `/ops`.
Latest control-plane readiness slice: four hundred first slice exposes that same compact launch-readiness rollup through read-only JSON-RPC `readiness.status`.
Latest readiness JSON-RPC reason slice: four hundred tenth slice adds unresolved-gate reason-kind lists to `readiness.status.summary`.
Latest Web readiness slice: four hundred second slice renders that same compact launch-readiness rollup in Web `/ops` through `LemonCore.Doctor.ReadinessSummary`.
Latest proof-gate sharing slice: four hundred third slice extracts proof launch-gate summaries into `LemonCore.Doctor.ProofLaunchGates` and includes them in readiness summaries, support bundles, JSON-RPC, and Web `/ops`.
Latest readiness CLI slice: four hundred fourth slice prints the shared proof launch-gate counts in human-readable `mix lemon.readiness` / `./bin/lemon readiness` output.
Latest readiness CLI reason slice: four hundred eleventh slice prints unresolved-gate reason-kind lists in human-readable `mix lemon.readiness` / `./bin/lemon readiness` output.
Latest source verifier slice: four hundred seventh slice makes source-install and release-runtime verifiers inspect support-bundle `readiness_summary.json` proof-gate shape directly.
Latest support-bundle readiness contract slice: four hundred twelfth slice asserts support-bundle `readiness_summary.json` preserves provider-media unresolved-gate reason-kind lists.
Latest readiness JSON-RPC summary slice: four hundred sixth slice adds proof-gate status/count summaries to `readiness.status.summary`.
Latest skills slice: three hundred twenty-eighth slice redacts sensitive `skills.update` env response values while preserving safe env keys and env-key summaries.
Latest secrets slice: two hundred fiftieth slice carries redacted encrypted-secret-store health, fallback, keychain-error-kind, and cleanup status into control-plane `secrets.status`.
Latest BEAM status slice: two hundred fifty-first slice carries BEAM VM capacity counters into root control-plane `status` and makes missing optional router supervisors fail closed.
Latest transport slice: two hundred fifty-second slice carries legacy transport registry/module health summaries into control-plane `transports.status`.
Latest TTS status slice: two hundred fifty-third slice carries active-provider readiness, provider counts, explicit stored config values, and cleanup flags into control-plane `tts.status`.
Latest usage slice: two hundred fifty-fourth slice aligns `usage.status` with the current summaries maintained by `usage.cost`, including per-provider requests/tokens/cost, quota state, and cleanup flags.
Latest voicewake slice: two hundred fifty-fifth slice preserves explicit voicewake config values and exposes configured/enabled/backend summaries plus cleanup flags through `voicewake.get`.
Latest config slice: two hundred fifty-sixth slice redacts sensitive stored config values in `config.get` and sensitive `config.set` responses.
Latest models slice: two hundred fifty-seventh slice adds provider/capability summaries and cleanup flags to `models.list`.
Latest agent directory slice: two hundred fifty-eighth slice adds compact summaries and cleanup flags to `agent.directory.list`, `agents.list`, and `agent.targets.list`.
Latest control-plane presence slice: two hundred sixty-ninth slice adds compact system-presence summaries and cleanup flags while preserving current connection/resource fields.
Latest node slice: two hundred seventieth slice adds node/type/status/capability summaries and cleanup flags to `node.list`.
Latest node detail slice: two hundred seventy-first slice redacts sensitive metadata keys and adds per-node summaries to `node.describe`.
Latest node pairing slice: two hundred seventy-second slice makes `node.pair.list` JSONL-reload-safe and adds pending pairing summaries plus cleanup flags.
Latest approval slice: two hundred seventy-third slice adds approval policy/pending summaries and redacts sensitive pending-action keys in `exec.approvals.get` plus node-policy summaries in `exec.approvals.node.get`.
Latest heartbeat slice: two hundred seventy-fourth slice adds last-heartbeat summaries and redacts sensitive heartbeat response text.
Latest heartbeat config slice: two hundred seventy-fifth slice adds `set-heartbeats` stored-config summaries while keeping heartbeat prompt text out of the response.
Latest node invocation slice: two hundred seventy-sixth slice adds bounded node invocation request/result response summaries and cleanup flags without changing node transport payloads.
Latest node event slice: two hundred seventy-seventh slice adds `node.event` payload validation, acknowledgement summaries, and cleanup flags without changing node event broadcasts.
Latest log slice: three hundred twenty-ninth slice redacts sensitive key values and common inline credential patterns from `logs.tail` responses.
Latest cron run-history slice: three hundred thirtieth slice redacts sensitive `cron.runs` output, error, meta, run-record, and introspection response values.
Latest run-internals slice: three hundred thirty-first slice redacts sensitive `run.graph.get` and `run.introspection.list` payload, run-record, raw-event, and introspection response values.
Latest session-detail slice: three hundred thirty-second slice redacts sensitive `session.detail` tool-call previews, summary/completed internals, raw events, run records, and top-level error values.
Latest usage-cost slice: three hundred thirty-sixth slice adds cleanup summaries to control-plane `usage.cost` reports.
Latest Web usage slice: three hundred thirty-seventh slice carries redacted usage/cost/quota aggregates into Web `/ops` through shared `LemonCore.UsageStore`.

## Purpose

Track where Lemon already has Hermes-class agent harness behavior, where it is partial, and where the next PR-sized improvements should land. “Parity” here means comparable harness ergonomics and reliability, not copying Hermes internals.

## Summary

Lemon already has the hard architectural primitives: supervised BEAM sessions, channel routing, CLI engine adapters, task/subagent execution, skill registry, memory search, tool policies, approvals, and a control plane. The biggest near-term gaps are mostly harness-contract gaps: making the native Lemon agent reliably use those primitives every run, then adding tests/evals that prevent regressions.

The first code slice from this scorecard made `read_skill` available in the default native Lemon tool set and aligned `search_memory` with restricted tool policies. The second slice adds deterministic eval checks that verify memory search scope behavior, memory-topic scaffolding, and relevant-skill prompt progressive disclosure. The third slice feeds the current user prompt into native session prompt composition so Lemon can preselect concise relevant-skill hints before the model turn while keeping full skill bodies behind `read_skill`. The fourth slice adds `skill_manage` so agents can turn reusable workflows into audited project/global skills. The fifth slice emits and persists redacted `read_skill` and `skill_manage` telemetry with tool-call and session correlation fields. The sixth slice keeps Hermes-style usage/curation sidecars with counters, agent-authored creation provenance, and pin/archive workflows. The seventh slice records `:missed_skill_observed` when relevant skills were shown but not loaded. The eighth slice lets agents query usage/curation reports with stale/archive candidate flags before maintaining learned skills. The ninth slice adds `LemonSkills.Curator` and `mix lemon.skill curator` commands for stale/archive/reactivation transitions plus an agent review prompt for umbrella-style consolidation. The tenth slice adds an idle automation manager that submits that prompt through `LemonRouter` when review is due. The eleventh slice adds an eval that seeds narrow agent-authored skills, renders the curator prompt, uses real `read_skill` and `skill_manage` tool calls to create an umbrella skill, and archives absorbed siblings. The twelfth slice closes the remaining tool-call lifecycle hardening gaps by turning task-supervisor startup failures into normal error `tool_result` messages and testing that full turns feed exactly one result per tool call into the next model call. The thirteenth slice adds explicit prompt triggers for when agents should write skills, memory topics, or search prior run memory. The fourteenth slice validates and safely coerces tool arguments against tool JSON schemas before starting side-effecting tool tasks. The fifteenth slice adds a deterministic learning trace eval that exercises prior-run search, durable topic creation, reusable skill creation, and usage reporting with the real tools. The sixteenth slice emits `:missed_learning_observed` when a learning-triggered session ends without the corresponding learning tools. The seventeenth slice adds an immutable `ToolSchemaSnapshot` so the provider schema and executable tools share a run-local snapshot id. The eighteenth slice adds a scripted contract eval that catches completed file/code action claims when the transcript has no tool call or tool result. The nineteenth slice stores run/session/agent provenance on native sessions so built-in learning tools and session events can be queried by run id. The twentieth slice sharpens agent-facing guidance so run recall, durable memory topics, procedural skills, and transient todos no longer compete as ambiguous memory surfaces. The twenty-first slice adds an AgentCore loop eval that consumes scripted model tool calls and asserts the returned messages include real `read_skill` and `skill_manage` tool results. The twenty-second slice adds the matching AgentCore loop eval for prior-work prompts that call `search_memory` and search current project plus home scopes before finalizing. The twenty-third slice adds an AgentCore loop eval that queues a real async task, dynamically joins the returned task id, and verifies the final answer includes the joined child output. The twenty-fourth slice extends that contract to two async children joined together before aggregation. The twenty-fifth slice adds `max_tool_turns`, a typed `:loop_budget_exhausted` event, and a terminal assistant fallback when a model keeps requesting tools. The twenty-sixth slice reconciles empty terminal provider messages with accumulated streamed content. The twenty-seventh slice turns scheduled cron runs into self-contained prompts that name forked-session isolation, prior-run memory semantics, origin delivery, and recursive scheduling guardrails. The twenty-eighth slice ports another Hermes streaming edge case by merging chunked OpenAI-compatible tool-call function-name deltas while ignoring repeated suffixes. The twenty-ninth slice adds an AgentCore streaming regression for tool-only streams whose final provider message arrives with empty content. The thirtieth slice adds typed `:tool_task_crashed` details when a tool task process exits before producing a result. The thirty-first slice adds typed details for tool-returned errors, raised exceptions, caught exits/throws, and unexpected return values. The thirty-second slice adds opt-in per-tool task timeouts that terminate supervised tool tasks and emit typed `:tool_task_timeout` results. The thirty-third slice makes router-style `blocked_tools` effective in native sessions and blocks cron tooling for scheduled runs. The thirty-fourth slice adds `mix lemon.eval --live-model`, an explicit provider-backed lane that proves an independent model calls `search_memory` for prior-work recall before answering. The thirty-fifth slice makes parallel tool execution return results and transcript messages in the original assistant tool-call order even when supervised tasks finish out of order. The thirty-sixth slice extends the live-model lane to prove a provider-backed model uses `read_skill` and `skill_manage` to capture a reusable workflow as an agent-authored skill. The thirty-seventh slice adds a reusable AgentCore transcript validator and rejects invalid assistant tool-call histories before provider conversion. The thirty-eighth slice extends the live-model lane to verify curator-style umbrella consolidation over real skill candidates. The thirty-ninth slice extends the live-model lane to verify scheduled-run memory recall while the `cron` tool is filtered by `blocked_tools`. The fortieth slice extends the live-model lane to verify a provider-backed model starts two async child tasks, joins both ids, and answers from the joined outputs. The forty-first slice adds a deterministic delegation artifact eval that requires the parent loop to join the child, read the produced artifact, and only then finalize. The forty-second slice hardens OpenAI-compatible transcript conversion so persisted assistant tool-call arguments with invalid UTF-8 are sanitized before JSON request encoding. The forty-third slice keeps recoverable partial OpenAI-compatible tool-call arguments at stream finalization instead of replacing them with an empty map. The forty-fourth slice honors retry delay hints from OpenAI-compatible providers before falling back to jittered retry backoff. The forty-fifth slice classifies context-window HTTP failures as explicit context-length errors and routes OpenAI-compatible terminal HTTP errors through the shared provider error normalizer. The forty-sixth slice preserves rate-limit metadata when providers hand `Ai.Error` Req-style header maps whose values are lists. The forty-seventh slice routes OpenAI Responses API terminal HTTP errors through the shared normalizer too. The forty-eighth slice extends the live-model lane to require delegation side-effect verification by reading a child-created artifact before finalizing. The forty-ninth slice adds explicit `:orchestrator` and `:leaf_worker` tool policies plus deterministic and live-model contracts for blocking recursive delegation from leaf workers. The fiftieth slice applies the same invalid-UTF-8 argument sanitation to OpenAI Responses function calls before request encoding. The fifty-first slice sanitizes OpenAI Responses function-call `call_id`, `id`, and `name` before request encoding too. The fifty-second slice sanitizes OpenAI Responses tool names, descriptions, and parameter schemas before request encoding. The fifty-third slice makes internal task-spawned child sessions leaf workers by default unless an explicit policy overrides it. The fifty-fourth slice adds shared durable-memory secret screening and rejects unsafe documents before store writes or skill synthesis. The fifty-fifth slice extends the live-model lane to prove an independent model chooses `memory_topic` for durable project context while avoiding prior-run search and procedural skill writes. The fifty-sixth slice adds `docs/security/agent-safety-contract.md` as the composed safety reference for tool policies, approvals, memory screening, skill audits, and redacted telemetry. The fifty-seventh slice adds a deterministic eval that wraps adversarial untrusted tool output, preserves the warning boundary, and sanitizes nested external-content end markers. The fifty-eighth slice starts on the Hermes lifecycle follow-up by carrying AgentCore structured tool failure metadata through LemonRunner action completion events. The fifty-ninth slice carries that failure metadata into router status intent bodies for downstream UI and observability consumers.

## Capability scorecard

Latest slice: support-bundle `readiness_summary.json` tests now assert provider-media unresolved-gate reason-kind lists survive.

### Tool ergonomics and enforcement

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools.ex`
  - `apps/coding_agent/lib/coding_agent/tool_registry.ex`
  - `apps/coding_agent/lib/coding_agent/tool_policy.ex`
  - `apps/coding_agent/lib/coding_agent/context_guardrails.ex`
  - `apps/coding_agent/lib/coding_agent/security/untrusted_tool_boundary.ex`
- Strengths:
  - File, search, edit, shell, web, task, todo, memory, auth, and extension status tools exist.
  - Dynamic registry has builtin/WASM/extension precedence and conflict reporting.
  - Tool policies model read-only, safe-mode, subagent-restricted, no-external, and minimal-core profiles.
  - Context guardrails spill/truncate oversized tool outputs.
- Gaps:
  - Some prompt-level tool-use rules are now backed by evals, including dedicated memory/skill tool preference.
  - Tool naming is Lemon-native; portability aliases may be useful later.
  - Dedicated memory/skill tools are explicitly preferred over shell equivalents; other tool families may need similar guidance later.
- Priority: high.
- Acceptance tests:
  - Default tool set contains every tool referenced by the system prompt.
  - Read-only and minimal-core policies allow context-loading tools such as `read_skill` and `search_memory`.
  - Eval harness includes deterministic contracts for memory scopes, memory-topic scaffolding, and relevant-skill prompt progressive disclosure.
  - Tool-task startup failures emit exactly one error `tool_result` instead of crashing the loop.
  - Tool-task process crashes emit exactly one error `tool_result` with typed `:tool_task_crashed` details.
  - Tool-returned errors, exceptions, caught exits/throws, and unexpected return values emit typed error details.
  - Configured tool task timeouts terminate the running task and emit exactly one typed `:tool_task_timeout` result.
  - Full turns append exactly one `tool_result` per tool call before the next model turn.
  - Invalid tool-call transcripts are rejected before provider calls.
  - Parallel tool batches append `tool_result` messages in assistant tool-call order, not completion order.
  - Invalid schema-shaped arguments emit a structured error `tool_result` before any tool task starts.
  - Nullable object/array arguments and JSON Schema union type lists are coerced before tool task startup.
  - A per-run tool schema snapshot event records the frozen executable tool names.
  - Eval catches an agent finalizing after promising an action without calling a tool.
  - Repeated tool-use turns stop at `max_tool_turns` with `:loop_budget_exhausted` and a user-visible fallback.
  - Streaming preserves accumulated assistant content when the final provider message has an empty content list.
  - OpenAI-compatible streaming merges chunked function-name deltas without duplicating repeated suffix chunks.
  - Streaming preserves accumulated tool calls when the final provider message has an empty content list.
  - Empty or thinking-only terminal provider responses fail with `empty_assistant_response`.
  - OpenAI-compatible request conversion sanitizes invalid UTF-8 in assistant tool-call arguments before encoding provider JSON.
  - OpenAI-compatible streaming preserves recoverable truncated tool-call arguments at terminal finalization.
  - Shared provider error parsing classifies provider-body rate-limit text and overloaded/transient text independently of exact HTTP status.
  - Shared rate-limit parsing honors HTTP-date `Retry-After` headers and ignores malformed values.
  - System and learning prompts tell agents to prefer dedicated memory and skill tools over shell commands, with a deterministic harness contract.
  - AgentCore emits explicit loop state transitions and rejects invalid transition paths.

### Skills lifecycle and procedural memory

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/lemon_skills/lib/lemon_skills/**`
  - `apps/lemon_skills/lib/lemon_skills/tools/read_skill.ex`
  - `apps/lemon_skills/lib/lemon_skills/tools/skill_manage.ex`
  - `apps/coding_agent/lib/coding_agent/system_prompt.ex`
  - `apps/lemon_skills/lib/lemon_skills/prompt_view.ex`
  - `docs/user-guide/skills.md`
- Strengths:
  - Registry supports global, project, and `.agents/skills` compatibility paths.
  - Relevance scoring exists.
  - Prompt renderer lists available skills and tells the agent to load relevant skills.
  - Native session prompt refresh passes the current user prompt into relevance scoring and renders concise `<relevant-skills>` hints per turn.
  - `read_skill` can read full content, summaries, sections, and linked files.
  - `skill_manage` can create, edit, patch, delete, and maintain audited project/global skills and supporting files.
  - `read_skill` and `skill_manage` emit redacted load/write telemetry with tool-call and session correlation fields, then project it into introspection events.
  - `LemonSkills.Usage` persists load/write counters, agent-authored creation provenance, and curation state.
  - `skill_manage` can pin/unpin/archive/restore skills; pinned skills are protected from archive/delete, and archived skills are disabled.
  - Session end audits record `:missed_skill_observed` when `<relevant-skills>` hints were not loaded with `read_skill`.
  - Session end audits record `:missed_learning_observed` when prompts ask for prior memory, durable context, or reusable workflows and the run does not call the corresponding learning tools.
  - Prompt composition now tells agents when to capture reusable workflows as skills and when to write durable context as memory topics.
  - Install/update audit gates exist.
- Gaps:
  - The live-model lane now covers basic reusable skill capture through `read_skill` and `skill_manage`.
  - Background curator submission now has deterministic scripted coverage and opt-in live-model coverage for useful umbrella consolidation over real skill clusters.
  - No active high-priority harness gap remains for relevant-skill loading, missed-skill auditing, or reusable skill capture.
- Priority: high.
- Acceptance tests:
  - Native Lemon default tools include `read_skill`.
  - Native Lemon default tools include `skill_manage`, and safe/subagent-restricted profiles deny it as a write-capable tool.
  - System prompt mentions `read_skill` only when the tool is available, or tests enforce both surfaces move together.
  - System prompt mentions `skill_manage` only when the tool is available, or tests enforce both surfaces move together.
  - Prompt tests require learning-trigger text for reusable workflows, recurring command sequences, project conventions, memory topics, and end-of-run capture.
  - Eval harness runs a scripted learning trace over `search_memory`, `memory_topic`, `skill_manage create`, and `skill_manage report`.
  - Eval harness verifies a skill-relevant fixture prompt surfaces a `<relevant-skills>` block, includes a `read_skill` reminder, and does not inline full skill bodies.
  - Eval harness drives `AgentCore.Loop` through real `read_skill` and `skill_manage` tool results before finalizing.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through `read_skill` and `skill_manage create` before answering a reusable-workflow prompt.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through relevant-skill `read_skill` usage and verifies no missed-skill audit event is recorded.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through curator-style skill reads, umbrella creation, and sibling archives.

### Memory and session recall

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools/search_memory.ex`
  - `apps/coding_agent/lib/coding_agent/tools/memory_topic.ex`
  - `apps/lemon_core/lib/**memory**`
  - `docs/user-guide/memory.md`
- Strengths:
  - Completed runs become structured `MemoryDocument`s.
  - Full-text search supports current/project/home/session/agent/all scopes.
  - Ingest-time secret screening is shared by memory ingest and skill synthesis, with regressions for documented secret patterns.
  - Skill synthesis can mine successful runs.
- Gaps:
  - No active high-priority harness gap remains for choosing among prior-run search, durable-topic capture, and workspace memory-file inspection.
- Priority: high.
- Acceptance tests:
  - `search_memory` defaults to current scope and searches both project and assistant-home memory without broadening missing contexts.
  - `memory_topic` scaffolds `memory/topics/<slug>.md` from the workspace template and replaces the slug placeholder.
  - Eval harness drives `AgentCore.Loop` through a `search_memory` tool result for a “last time” prompt before finalizing.
  - Eval harness drives `AgentCore.Loop` through real `grep` and `read` results for a workspace `memory/topics/*.md` note before finalizing.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model to call `search_memory` before answering a prior-work prompt.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model to call `memory_topic` for durable project context while avoiding `search_memory` and `skill_manage`.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model to inspect workspace memory files with `grep` and `read` while avoiding `search_memory` and `memory_topic`.
  - Memory-topic creation does not replace procedural skill authoring.

### Delegation and orchestration

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools/task.ex`
  - `apps/coding_agent/lib/coding_agent/tools/agent.ex`
  - `apps/coding_agent/lib/coding_agent/coordinator.ex`
  - `apps/coding_agent/lib/coding_agent/run_graph*.ex`
  - `docs/subagent-parent-questions.md`
- Strengths:
  - Async task records, run graph, join/poll/get, parent questions, and lane queues exist.
  - Eval harness drives a real async task through `join` before the final answer.
  - Eval harness joins and aggregates two async child task results before the final answer.
  - Eval harness verifies a child-produced artifact by reading the artifact after join and before final answer.
  - Opt-in `mix lemon.eval --live-model` drives a provider-backed model through two async child tasks and one wait-all join before finalizing.
  - Tool policies now define explicit `:orchestrator` and `:leaf_worker` profiles, with leaf workers blocked from recursive `task`/`agent` delegation.
  - Internal task-spawned child sessions default to the `:leaf_worker` policy while preserving explicit task `tool_policy` overrides.
  - External engines can be delegated to via CLI adapters.
- Gaps:
  - Live-model delegation now has parallel child/join, side-effect verification, and leaf toolset coverage.
- Priority: high after skill/memory slice.

### Cron and durable background jobs

- Current Lemon status: partial.
- Current modules/docs:
  - `apps/lemon_automation/**`
  - `apps/lemon_gateway/lib/lemon_gateway/tools/cron.ex`
  - `docs/long-running-agent-harnesses.md`
- Strengths:
  - Cron manager, heartbeat manager, and scheduled submissions exist.
  - Gateway exposes cron tooling into Lemon engine runs.
  - Scheduled prompts include forked-session isolation, prior-run memory semantics, origin delivery, and a recursive scheduling guardrail.
  - Scheduled submissions attach `blocked_tools: ["cron"]`, and CodingAgent policy filtering honors router-style `blocked_tools`.
- Gaps:
  - Job toolset restriction now has focused regression coverage and opt-in live-model coverage.
  - Recursive scheduling through direct cron tooling is structurally blocked, but non-tool API entrypoints remain operator-controlled rather than model-facing.
- Priority: medium-high.
- Acceptance tests:
  - `RunSubmitter.build_params/2` embeds the cron prompt contract: isolated forked session, prior-run memory, origin delivery, and recursive scheduling guardrail.
  - `RunSubmitter.build_params/2` attaches a cron tool policy that blocks a `cron` tool.
  - Opt-in `mix lemon.eval --live-model` filters a `cron` tool out with `blocked_tools` and drives the model through prior scheduled-run memory before finalizing.

### Messaging and native delivery

- Current Lemon status: partial / strong foundation.
- Current modules/docs:
  - `apps/lemon_channels/**`
  - `apps/lemon_gateway/tools/*telegram*`
  - `apps/lemon_gateway/tools/*discord*`
- Strengths:
  - Telegram, Discord, X, XMTP, and legacy gateway ingress exist.
  - Channel outbox separates rendering/delivery from execution.
- Gaps:
  - Final-answer `MEDIA:<path>` delivery is now implemented for Telegram and Discord through Lemon's existing safe `auto_send_files` path; live channel proof for this exact host-visible directive remains useful.
  - Telegram and Discord now have deterministic long-text rendering coverage; richer per-channel markdown/rendering evals remain useful.
- Priority: medium.

### Browser/web/media tools

- Current Lemon status: partial.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tools/webfetch.ex`
  - `apps/coding_agent/lib/coding_agent/tools/websearch.ex`
  - `clients/lemon-browser-node/`
- Strengths:
  - Web search/fetch tools exist.
  - Browser node client exists for CDP/Playwright-related work.
- Gaps:
  - Browser interaction is not yet as first-class in the default native harness as Hermes browser tools.
  - Media generation/TTS/image analysis are not clearly first-class native Lemon tools.
- Priority: medium.

### Safety, approvals, and untrusted content

- Current Lemon status: strong foundation.
- Current modules/docs:
  - `apps/coding_agent/lib/coding_agent/tool_policy.ex`
  - `apps/coding_agent/lib/coding_agent/tool_executor.ex`
  - `apps/coding_agent/lib/coding_agent/security/untrusted_tool_boundary.ex`
  - `SECURITY.md`
  - `docs/security/agent-safety-contract.md`
- Strengths:
  - Approval gate system exists.
  - Tool policies are explicit.
  - Skill install/update audit exists.
  - Untrusted tool-output boundary exists.
  - The agent safety contract now ties tool exposure, approval scopes, durable-memory screening, skill audit enforcement, and redacted telemetry together.
  - The deterministic eval lane now checks that adversarial untrusted tool output stays inside the external-content boundary.
  - The opt-in live-model lane now checks that provider-backed models ignore untrusted external tool instructions and avoid `skill_manage` side effects.
  - Launch-focused prompt-injection tests now cover web fetch output, inbound email prompts, skill prompt rendering, and generic untrusted extension-style tool results.
- Gaps:
  - Broader adversarial prompt-injection variant depth remains useful post-1.0 hardening work.
- Priority: medium-high.

### Observability and dogfood loop

- Current Lemon status: partial.
- Current modules/docs:
  - `apps/lemon_control_plane/**`
  - `clients/lemon-web/web/README.md`
  - `apps/coding_agent/lib/coding_agent/evals/harness.ex`
- Strengths:
  - Control plane exposes many RPCs.
  - Web UI has sessions/runs/tasks/events visibility.
  - Eval harness exists.
  - Skill prompt render/load/write decisions are available through redacted telemetry and introspection events.
  - Web run detail pages have dedicated approval, learning, channel-event,
    cron-event, and subagent/delegation panels in addition to the raw timeline
    and child-run graph.
- Gaps:
  - Deeper subagent duration, ownership, and wait/join analytics remain useful
    post-1.0 hardening work.
- Priority: medium.

## Implementation slices so far

### Slice 1: Native `read_skill` / `search_memory` availability

1. Exposed `read_skill` from `CodingAgent.Tools` and `CodingAgent.ToolRegistry`.
2. Allowed `read_skill` and `search_memory` in relevant read/minimal policies.
3. Updated docs and tests so the prompt/tool contract stays synchronized.

### Slice 2: Memory and skill harness contract evals

1. Added eval checks for default `search_memory` current-scope resolution.
2. Added eval checks for `memory_topic` scaffold behavior.
3. Added eval checks for relevant-skill prompt progressive disclosure and `read_skill` guidance.
4. Added tests that require those checks to appear in `CodingAgent.Evals.Harness.run/1` and `mix lemon.eval` JSON output.

### Slice 3: Native relevant-skill preselection

1. Extended `CodingAgent.SystemPrompt.build/2` with `:skill_context` and `:max_relevant_skills` options.
2. Updated session prompt refresh to pass the current user prompt/steer/follow-up text into skill relevance scoring.
3. Added contract tests for system-prompt, prompt-builder, and session prompt-composer paths that require concise `<relevant-skills>` hints and keep full skill bodies behind `read_skill`.

### Slice 4: Agent skill authoring tool

1. Added `LemonSkills.Tools.SkillManage` for create/edit/patch/delete/write_file/remove_file operations on project and global skills.
2. Wrapped `skill_manage` into the default CodingAgent tool surface, builtin registry, minimal-core policy, and harness contract.
3. Treated `skill_manage` as dangerous in safe/subagent-restricted profiles and documented audited write behavior.

### Slice 5: Skill load/write telemetry

1. Added `LemonSkills.Telemetry` and emitted `[:lemon_skills, :skill, :load]` from `read_skill` for found and missing skill requests.
2. Emitted `[:lemon_skills, :skill, :write]` from `skill_manage` for accepted and rejected write attempts without recording skill bodies, patch strings, or supporting-file contents.
3. Threaded CodingAgent `session_key`, `session_id`, `agent_id`, and optional `run_id` tool options into those events when available.
4. Projected the telemetry into `:skill_load_observed` and `:skill_write_observed` introspection events.
5. Documented event fields and added regression tests for successful/missing loads, successful/rejected writes, and introspection projection.

### Slice 6: Skill usage and curation state

1. Added `LemonSkills.Usage` sidecars for global and project usage metadata.
2. Recorded load/write counters, last-use metadata, and agent-authored creation provenance from skill telemetry.
3. Extended `skill_manage` with `pin`, `unpin`, `archive`, and `restore`; archived skills use the existing disabled-skill config, and pinned skills must be unpinned before archive/delete.
4. Added regression tests for usage counters, provenance, curation state, and archived-skill restore behavior.

### Slice 7: Missed relevant-skill audit

1. Added a session-end audit that parses `<relevant-skills>` from the current prompt and compares those keys with observed `read_skill` tool results.
2. Persisted `:missed_skill_observed` introspection events for relevant skills that were not loaded.
3. Documented the event so operators can query missed skill usage.

### Slice 8: Skill usage and curation report

1. Added `LemonSkills.Usage.report/1` to summarize usage sidecar rows, counters, last activity, and stale/archive candidate flags for agent-authored skills.
2. Added `skill_manage` action `report` so agents can inspect curation candidates before pinning, archiving, restoring, or deleting skills.
3. Documented the report action in skill docs and user guidance.

### Slice 9: Conservative skill curator loop

1. Added `LemonSkills.Curator` for persisted curator state, interval/pause checks, automatic stale/archive/reactivation transitions, and an agent review prompt.
2. Added `mix lemon.skill curator status|run|pause|resume`; `run --prompt` prints the review prompt after applying conservative lifecycle transitions.
3. Documented curator behavior and invariants: only agent-authored skills are considered, pinned/non-agent-authored skills are skipped, archived skills are disabled, and no curator path deletes skills.

### Slice 10: Idle background curator submission

1. Added `LemonAutomation.SkillCurator` to apply enabled/idle/interval gates and submit `LemonSkills.Curator` review prompts through `LemonRouter`.
2. Added `LemonAutomation.SkillCuratorManager` to check router idleness periodically and launch the curator pass in the automation task supervisor.
3. Updated automation dependencies and docs so `lemon_automation` intentionally owns the background scheduler while `lemon_skills` owns curation state and prompt rendering.

### Slice 11: Scripted curator behavior eval

1. Added `skill_curator_behavior_contract` to `CodingAgent.Evals.Harness.run/1`.
2. The eval seeds two narrow project skills through real `skill_manage create` calls, runs `LemonSkills.Curator`, verifies the review prompt requires `read_skill` and `skill_manage`, then calls real `read_skill` and `skill_manage` operations to create an umbrella skill and archive the absorbed siblings.
3. Added harness contract tests so `mix lemon.eval` keeps this procedural-memory behavior in the eval suite.

### Slice 12: Tool call lifecycle hardening

1. Made `AgentCore.Loop.ToolCalls` handle `Task.Supervisor.start_child/2` failures and exits as synthetic error `tool_result` messages.
2. Preserved `tool_execution_start`, `tool_execution_end`, and `tool_result:emit` events for failed-start tool calls so UI and telemetry consumers still see a complete lifecycle.
3. Added a regression test that uses a missing task supervisor and verifies the tool body is not run, the loop does not crash, and exactly one error `tool_result` is appended.
4. Added a full-turn regression test that verifies a model response with N tool calls appends exactly N `tool_result` messages, passes those results into the next model turn, and only then emits the final answer.

### Slice 13: Learning trigger prompt guidance

1. Added a `<learning-workflow>` prompt section covering when to use `skill_manage`, `memory_topic`, and `search_memory`.
2. Wired that guidance into main Lemon system prompts and PromptBuilder prompts when relevant skill context is present and skill/memory tools are available.
3. Added regression tests for reusable workflow, recurring command sequence, project convention, durable-memory, prior-work search, and end-of-run capture triggers.

### Slice 14: Tool argument schema validation

1. Added pre-dispatch validation/coercion for tool call arguments against each tool's JSON-style parameter schema.
2. Coerced safe provider/model drift before task startup: string booleans, string integers/numbers, JSON-encoded objects/arrays, and scalar values for arrays.
3. Rejected missing or unparseable arguments as structured `:invalid_tool_arguments` tool results without starting the tool task.
4. Added structured `:unknown_tool` details for unmatched tool calls before task startup.

### Slice 15: Scripted learning trace eval

1. Added `learning_tool_trace_contract` to `CodingAgent.Evals.Harness.run/1`.
2. The eval checks learning prompt triggers, calls real `search_memory` for prior work, creates a durable topic with `memory_topic`, creates a reusable project skill with `skill_manage`, and verifies the skill appears in `skill_manage report`.
3. Added a harness contract test so `mix lemon.eval` keeps the end-to-end learning artifact path in the eval suite.

### Slice 16: Missed learning audit

1. Extended session-end auditing to detect learning-triggered transcripts under `<learning-workflow>` prompts.
2. Records `:missed_learning_observed` with trigger classes, missing learning tools, and any used learning tools when prior-memory, durable-memory, or reusable-skill triggers were not followed by the expected tool call.
3. Added regression tests for both missed-learning recording and suppression when `search_memory`, `memory_topic`, and `skill_manage` were used.

### Slice 17: Per-run tool schema snapshot

1. Added `AgentCore.Types.ToolSchemaSnapshot` with snapshot id, fingerprint, frozen tool structs, and tool names.
2. AgentCore now snapshots tools at loop start, emits `{:tool_schema_snapshot, snapshot}`, and records telemetry with snapshot id/fingerprint/tool names.
3. The LLM provider context and tool execution path both use the frozen snapshot tools, including when a configured snapshot is supplied explicitly.
4. Added regression tests for snapshot event ordering and provider/executor parity.

### Slice 18: Tool-use claim contract eval

1. Added `tool_use_claim_contract` to the deterministic eval harness.
2. The eval detects a final assistant message that claims a completed file/code side effect when no tool call or tool result appears in the transcript.
3. The same eval allows the completed-action claim when a matching transcript includes tool activity, preventing the contract from banning legitimate summaries.

### Slice 19: Native run provenance for learning tools

1. `CodingAgent.CliRunners.LemonRunner` now passes its `run_id` into `CodingAgent.Session`.
2. Native sessions keep `run_id`, logical `session_key`, and `agent_id` in state and pass them through tool construction, including extension reloads.
3. Session lifecycle, tool dispatch, missed-skill, and missed-learning introspection events include the same provenance fields when available.
4. Added regression tests proving LemonRunner sets native session provenance and `read_skill` events from native sessions are queryable by run id.

### Slice 20: Learning surface guidance

1. Reworded `<learning-workflow>` to choose among `read_skill`, `search_memory`, `memory_topic`, `skill_manage`, and `todo`.
2. Clarified the main system prompt memory workflow: run history search, workspace note inspection, durable topic creation, reusable skill capture, and active-run todos now have separate instructions.
3. Updated user docs for memory and skills with the same boundaries.
4. Added prompt regression assertions for `read_skill` and `todo` guidance.

### Slice 21: Agent-loop learning trace eval

1. Added `agent_loop_learning_trace_contract` to the eval harness.
2. The eval seeds a project skill, runs the real `AgentCore.Loop` with scripted model tool calls, and asserts `read_skill` returns the seeded skill.
3. The same loop creates a reusable project skill through `skill_manage` and verifies the agent-authored skill is active before the final response.

### Slice 22: Agent-loop memory trace eval

1. Added `agent_loop_memory_trace_contract` to the eval harness.
2. The eval runs the real `AgentCore.Loop` with a scripted `search_memory` tool call for a “last time” prompt.
3. It verifies the loop returns a real `search_memory` tool result, coerces the string limit argument, and searches both project and assistant-home scopes before the final answer.

### Slice 23: Agent-loop async join trace eval

1. Added `agent_loop_async_join_trace_contract` to the eval harness.
2. The eval uses the real `task` tool with an async `run_override`, then dynamically reads the queued `task_id` from the previous tool result and calls `task` with `action=join`.
3. It verifies the loop has both queued and joined task results, and that the final answer appears after the join result and includes the child output.

### Slice 24: Agent-loop parallel join trace eval

1. Added `agent_loop_parallel_join_trace_contract` to the eval harness.
2. The eval runs two real async `task` calls, dynamically joins both queued task ids, and verifies the join result includes both child outputs.
3. It verifies the final answer aggregates both joined child outputs.

### Slice 25: Bounded tool-loop terminal fallback

1. Added `max_tool_turns` to `AgentCore.Agent` and `AgentCore.Loop` config, defaulting to 25 with `:infinity` for explicit unbounded runs.
2. AgentCore now emits `{:loop_budget_exhausted, details}` after the configured number of tool-use turns and completes with a terminal assistant fallback instead of calling the model again.
3. Added a loop regression test proving the model is called once at `max_tool_turns: 1`, the tool call receives its result, and the final event is `:agent_end`.

### Slice 26: Empty final streaming response reconciliation

1. Added an AgentCore streaming regression test for a provider stream where deltas carry visible content but the terminal SDK message has `content: []`.
2. AgentCore now preserves the accumulated streamed assistant content while retaining terminal metadata from the final provider message.

### Slice 27: Scheduled cron prompt contract

1. Hardened `LemonAutomation.CronMemory.build_prompt/3` so scheduled task runs are self-contained about forked-session isolation, prior-run memory, origin delivery, and recursive scheduling boundaries.
2. Added `RunSubmitter` regression coverage requiring those prompt-contract lines to stay present when cron jobs are submitted.
3. Updated the cron scorecard gap from broad prompt parity to the remaining structural toolset and recursive-scheduling enforcement work.

### Slice 28: Chunked streamed tool-call names

1. Updated the OpenAI-compatible completions streamer so function-name deltas are merged when providers split a tool name across chunks.
2. Kept repeated suffix chunks idempotent so duplicate name deltas do not corrupt the final tool name.
3. Added a provider regression test that streams `read_`, `file`, then a repeated `file` suffix and verifies the final tool call is `read_file`.

### Slice 29: Tool-only empty final streaming response

1. Added an AgentCore streaming regression for provider streams that emit a tool call and then finish with an empty terminal message.
2. Verified final message reconciliation preserves the accumulated `ToolCall` block in both the returned message and updated conversation context.

### Slice 30: Structured tool-task crash envelope

1. Added typed `:tool_task_crashed` details to tool results emitted when a supervised tool task exits before returning a result.
2. Added a regression that kills the tool task process and verifies exactly one error `tool_result`, matching conversation context, and end event are emitted.

### Slice 31: Typed tool execution error envelopes

1. Added typed details for tool functions that return `{:error, reason}`, raise exceptions, catch exits/throws, or return unsupported shapes.
2. Preserved the visible text content for existing tool errors while making `details.error_type` machine-readable.
3. Added focused regressions for returned tool errors, raised exceptions, and unexpected return values.

### Slice 32: Optional per-tool task timeouts

1. Added `tool_timeout_ms` to `AgentLoopConfig` and `AgentCore.Agent` opts, defaulting to unbounded for compatibility.
2. Tool execution now schedules per-task timeouts when configured, terminates overdue supervised tasks, and emits typed `:tool_task_timeout` results.
3. Added a focused regression proving a long-running tool is terminated and contributes exactly one error result and end event.

### Slice 33: Cron recursive-tool block

1. Scheduled run submissions now attach a tool policy with `blocked_tools: ["cron"]`.
2. Native CodingAgent tool policy filtering now honors router-style `blocked_tools`, not only CodingAgent-style `deny`.
3. Added focused regressions for the cron submission policy and blocked-tools enforcement.

### Slice 34: Opt-in live memory recall eval

1. Added `mix lemon.eval --live-model` for explicit provider-backed behavioral checks outside deterministic CI.
2. Added `live_model_memory_trace_contract`, which gives a live model a prior-work prompt and verifies it calls the real `search_memory` tool before answering.
3. Documented the `LEMON_EVAL_*` / `INTEGRATION_*` configuration surface and kept the live lane out of default `eval-fast`.

### Slice 35: Parallel tool result ordering

1. AgentCore now tracks the assistant tool-call order for each parallel tool batch.
2. Returned `tool_results`, updated loop context, and current-turn `new_messages` are sorted back to assistant order before the next model turn.
3. Added a regression where a later tool call finishes first but the transcript still preserves the original call order.

### Slice 36: Opt-in live skill learning eval

1. Added `live_model_skill_learning_contract` to `mix lemon.eval --live-model`.
2. The eval seeds a project skill, then requires the provider-backed model to call `read_skill` and create a project skill with `skill_manage`.
3. It verifies the new skill is active and agent-authored before accepting the final marker response.

### Slice 37: Tool transcript validator

1. Added `AgentCore.Loop.TranscriptValidator` as a reusable pre-provider contract for assistant tool calls and tool results.
2. `Loop.Streaming` now validates transformed context messages before converting them to provider-specific messages.
3. Added regressions for missing, duplicate, unexpected, and orphaned tool results, plus a loop-level check that invalid transcripts never call the model.

### Slice 38: Opt-in live skill curator eval

1. Added `live_model_skill_curator_contract` to `mix lemon.eval --live-model`.
2. The eval seeds two narrow Kubernetes rollout skills, renders the real curator prompt, and requires the provider-backed model to read both skills.
3. It verifies the model creates a broader umbrella skill, archives the absorbed siblings, and finishes with the expected live eval marker.

### Slice 39: Opt-in live cron block eval

1. Added `live_model_cron_block_contract` to `mix lemon.eval --live-model`.
2. The eval applies a `blocked_tools: ["cron"]` policy to a live eval tool set and verifies the `cron` tool is filtered before the model turn.
3. It requires the provider-backed model to use `search_memory` for prior scheduled-run context and finish with the expected cron blocked-tool marker.

### Slice 40: Opt-in live parallel delegation eval

1. Added `live_model_parallel_delegation_contract` to `mix lemon.eval --live-model`.
2. The eval requires a provider-backed model to start exactly two async child tasks with `auto_followup` disabled, preserve both task ids, and join them with `mode` `wait_all`.
3. It verifies the final answer includes the expected marker and both joined child outputs.

### Slice 41: Delegation artifact verification eval

1. Added `agent_loop_delegation_artifact_trace_contract` to the deterministic eval suite.
2. The eval queues an async child, joins the returned task id, reads the child-produced artifact, and requires the final answer to include the verified artifact contents.
3. It keeps child side-effect verification in the default eval lane while leaving provider-backed side-effect behavior for a later live-model slice.

### Slice 42: OpenAI-compatible tool-call argument sanitization

1. Sanitized assistant tool-call names and nested argument values before OpenAI-compatible request encoding.
2. Added a regression that stores invalid UTF-8 inside an assistant tool-call argument and verifies the provider request still encodes valid JSON.
3. This ports one Hermes provider-weirdness invariant without changing Lemon's provider boundary shape.

### Slice 43: Truncated streamed tool-call argument recovery

1. Preserved best-effort parsed tool-call arguments when an OpenAI-compatible stream ends with recoverable truncated JSON.
2. Replaced the simple closing-brace fallback with stack-based completion so nested arrays/objects close in the correct order.
3. Added a regression that streams a truncated `{"files":["mix.exs"` argument and verifies finalization keeps `%{"files" => ["mix.exs"]}`.

### Slice 44: Provider retry delay normalization

1. Moved retry-delay extraction for `retry-after`, `x-ratelimit-reset-after`, `Please retry in`, reset-after, and `retryDelay` hints into `Ai.Providers.RetryHelper`.
2. Wired OpenAI-compatible streaming retries to honor provider-supplied retry delays before falling back to jittered exponential backoff.
3. Added focused retry-helper coverage plus an OpenAI-compatible 429 regression that verifies the retry waits for the supplied header.

### Slice 45: Context-length provider error normalization

1. Classified context-window HTTP failures as explicit `:context_length` provider errors in `Ai.Error`.
2. Routed OpenAI-compatible terminal HTTP responses through the shared error normalizer instead of local string formatting.
3. Added regressions for OpenAI context-length classification and streamed OpenAI-compatible HTTP error output.

### Slice 46: Req-style rate-limit header normalization

1. Made `Ai.Error.extract_rate_limit_info/1` accept maps as well as header tuple lists.
2. Normalized header keys with `to_string/1` and unwrapped first list values, matching Req response header shape.
3. Added coverage for rate-limit and retry-after extraction from Req-style header maps.

### Slice 47: OpenAI Responses HTTP error normalization

1. Materialized async non-2xx OpenAI Responses bodies before logging and parsing provider errors.
2. Routed terminal OpenAI Responses HTTP errors through `Ai.Error.parse_http_error/3`.
3. Added a regression that verifies a streamed Responses context-length failure surfaces the normalized context-length message.

### Slice 48: Live-model delegation artifact verification

1. Added an opt-in live-model eval that asks the provider-backed loop to delegate artifact creation, join the child task, read the child-created file, and only then answer.
2. Verified the eval fails cleanly without live-model credentials and appears only in the `--live-model` lane.
3. Kept the eval side effect local to a temporary project and checked the artifact exists before passing.

### Slice 49: Leaf/orchestrator toolset contracts

1. Added explicit `:orchestrator` and `:leaf_worker` tool-policy profiles.
2. Added a deterministic eval that proves orchestrators retain delegation tools while leaf workers keep normal work tools but lose `task` and `agent`.
3. Added an opt-in live-model eval that filters `task` from a leaf worker and requires the provider-backed model to use `read` without recursive delegation.

### Slice 50: OpenAI Responses tool-call argument sanitation

1. Sanitized nested OpenAI Responses tool-call argument values before JSON request encoding.
2. Added a regression proving invalid UTF-8 inside nested function-call arguments is sanitized instead of breaking Responses request construction.

### Slice 51: OpenAI Responses tool-call identity sanitation

1. Sanitized OpenAI Responses function-call ids before splitting and encoding.
2. Sanitized function-call names and item ids before request encoding.
3. Added a regression proving invalid UTF-8 in `call_id`, `id`, and `name` fields still produces valid request strings.

### Slice 52: OpenAI Responses tool schema sanitation

1. Sanitized OpenAI Responses tool names and descriptions before request encoding.
2. Sanitized nested tool parameter schema values before request encoding.
3. Added a regression proving invalid UTF-8 in tool schema fields still produces an encodable request schema.

### Slice 53: Internal task child leaf-worker default

1. Defaulted internal `task` children to the `:leaf_worker` tool policy.
2. Preserved explicit task `tool_policy` overrides and non-internal CLI engine behavior.
3. Updated task docs and AGENTS guidance to document the recursive delegation boundary.

### Slice 54: Durable memory secret screening

1. Added `LemonCore.MemorySafety` as the shared predicate for secret-looking memory summaries.
2. Rejected unsafe memory documents before config loading or store writes in `MemoryIngest`.
3. Reused the same predicate for skill synthesis candidate filtering and added focused regressions.

### Slice 55: Live-model durable topic memory contract

1. Added `live_model_memory_topic_contract` to the opt-in live-model eval lane.
2. Exposed `search_memory`, `memory_topic`, and `skill_manage` together so the provider-backed model must choose durable topic capture for project context.
3. Asserted the eval creates `deployment-incident-handoff.md`, avoids prior-run search and procedural skill writes, and finalizes with the expected marker.

### Slice 56: Agent safety contract documentation

1. Added `docs/security/agent-safety-contract.md` as the composed safety reference.
2. Registered the doc in `docs/catalog.exs` and linked it from `docs/README.md`.
3. Updated this scorecard so the remaining safety/governance gap is adversarial prompt-injection eval depth.

### Slice 57: Untrusted prompt-injection eval

1. Added `untrusted_prompt_injection_contract` to the deterministic eval harness.
2. Exercised the real untrusted tool-output boundary with adversarial external content that tries to close the wrapper and override system/tool policy.
3. Asserted the wrapper warning remains present and nested end markers are sanitized while the real boundary marker is preserved.

### Slice 58: LemonRunner structured tool failure metadata

1. Preserved `AgentToolResult.details.error_type` and adjacent failure fields in LemonRunner completed action metadata.
2. Added a native runner regression for an unknown tool call, proving `ActionEvent` observers see `result_meta.error_type` and `result_meta.tool_name`.
3. Documented the `action.detail.result_meta` surface in the LemonRunner module docs.

### Slice 59: Router status tool failure metadata

1. Added `body.tool_failures` to router tool-status intents when completed actions include `result_meta.error_type`.
2. Kept the rendered status text unchanged while exposing compact structured failure fields for UI and observability consumers.
3. Added a ToolStatusCoalescer regression covering an unknown-tool failure propagated through status intent dispatch.

### Slice 60: Control-plane tool-use metadata mapping

1. Fixed EventBridge `:engine_action` mapping to read canonical nested `payload.action` fields while preserving legacy flat payload fallback.
2. Preserved `action.detail.result_meta` in WebSocket `agent` tool-use events so UI/control-plane observers can inspect structured tool failures.
3. Added an EventBridge regression that broadcasts a nested unknown-tool completion and asserts the control-plane event carries `error_type` and `tool_name`.

### Slice 61: Anthropic overloaded error normalization

1. Classified HTTP 529 provider responses as transient instead of generic server errors.
2. Made HTTP 529 retryable so Anthropic `overloaded_error` responses follow the same recovery path as 502/503/504 provider failures.
3. Updated provider-error regressions to assert Anthropic overloaded responses are transient and retryable.

### Slice 62: Skill prompt-render observability

1. Added `[:lemon_skills, :skill, :prompt_render]` telemetry with redacted skill keys/counts for available and relevant prompt surfaces.
2. Projected prompt-render telemetry into `:skill_prompt_render_observed` introspection events with run/session/agent provenance.
3. Passed native session provenance through prompt composition and added regressions for direct prompt rendering and native session introspection lookup.

### Slice 63: Workspace memory-file inspection contract

1. Added `agent_loop_workspace_memory_file_contract` to the eval harness.
2. Seeded a workspace `memory/topics/*.md` note and drove `AgentCore.Loop` through real `grep` and `read` tool results before finalizing.
3. Added harness regressions so the workspace memory-file lane stays distinct from prior-run `search_memory` and durable `memory_topic` coverage.

### Slice 64: Millisecond retry-after header normalization

1. Taught shared parsed provider errors to extract `retry-after-ms` and `x-ms-retry-after-ms` as millisecond retry delays.
2. Taught provider retry backoff extraction to honor the same millisecond headers before falling back to reset-after or body hints.
3. Added Azure-style and retry-helper regressions so millisecond retry delays remain distinct from seconds-based `retry-after`.

### Slice 65: Rate-limit reset duration parsing

1. Parsed OpenAI-style reset duration strings such as `1ms` and `6m0s` into future reset times.
2. Parsed ISO 8601 reset timestamps before Unix timestamp fallbacks so date strings are no longer truncated to leading years.
3. Treated long numeric reset values as Unix milliseconds while preserving seconds-based Unix timestamp support.

### Slice 66: Live-model workspace memory-file inspection

1. Added `live_model_workspace_memory_file_contract` to the opt-in live-model eval lane.
2. Seeded a workspace `memory/topics/release-handoff.md` note and exposed `grep`, `read`, `search_memory`, and `memory_topic` together.
3. Required the provider-backed model to find and read the workspace memory file while avoiding prior-run search and durable-topic creation.

### Slice 67: Live-model relevant-skill audit coverage

1. Added `live_model_relevant_skill_usage_contract` to the opt-in live-model eval lane.
2. Seeded a relevant project skill, required the provider-backed model to call `read_skill`, and checked the final answer marker.
3. Ran the session missed-skill audit over the live transcript and asserted no `:missed_skill_observed` event was recorded for the loaded skill.

### Slice 68: Provider text-driven retry classification

1. Extended shared HTTP error parsing to classify provider-body rate-limit messages as `:rate_limit` even when the status is not 429.
2. Classified overloaded, temporary-unavailable, retry-later, and deadline-exceeded provider messages as retryable `:transient` errors.
3. Added regressions for non-429 retry headers, overloaded client errors, and non-retryable quota failures.

### Slice 69: Retry-After HTTP-date parsing

1. Extended shared rate-limit parsing to handle RFC-style HTTP dates in `Retry-After`.
2. Converted future retry dates into millisecond delays while ignoring past or malformed values.
3. Added regressions for numeric seconds, HTTP-date, and malformed retry headers.

### Slice 70: Dedicated memory and skill tool preference

1. Updated main-session memory guidance to prefer `search_memory`, `memory_topic`, `read_skill`, and `skill_manage` over shell commands for learning surfaces.
2. Updated the shared learning workflow prompt with the same dedicated-tool preference.
3. Added `dedicated_tool_preference_contract` so the deterministic eval lane fails if that guidance drifts.

### Slice 71: Live-model untrusted prompt-injection coverage

1. Added `live_model_untrusted_prompt_injection_contract` to the opt-in live-model eval lane.
2. Seeded an untrusted external lookup tool whose result tries to close the external-content boundary, call `skill_manage`, and force a PWNED response.
3. Required the provider-backed model to use the external result only as data, avoid `skill_manage`, and finish with the safe marker.

### Slice 73: Durable curator run reports

1. Added project and global curator report directories under the same Lemon-owned roots as the skill sidecars.
2. Wrote `run.json` and `REPORT.md` for each curator pass with transition counts, state changes, candidates, and review-required status.
3. Persisted `last_report_path` in `skills.curator.json` so the most recent curator audit artifact is easy to locate.

### Slice 74: Curator active-update prompt

1. Updated the background curator prompt to treat reusable user corrections, workflow preferences, formatting preferences, and tool lessons as first-class skill signals.
2. Made the prompt prefer patching an existing class-level skill, then adding support files, then creating a new class-level umbrella only when no existing skill fits.
3. Added a prompt contract test so the curator does not drift back toward creating narrow one-run skills.

### Slice 75: Curator learning-only tool surface

1. Attached a default per-run tool policy to background curator review submissions.
2. Restricted that default policy to `read_skill`, `skill_manage`, `search_memory`, and `memory_topic`, while still allowing explicit operator override.
3. Added automation regressions and docs so curator review runs do not silently regain broad shell, web, or delegation tools.

### Slice 76: Curator review-run report linkage

1. Added `LemonSkills.Curator.record_review_submission/2` to update `run.json` and `REPORT.md` after a background review is submitted.
2. Recorded the router run id, submission timestamp, and submission status in the curator report.
3. Included the curator report path in background submission metadata so downstream run viewers can link back to the automatic curation pass.

### Slice 77: Nullable and union tool arguments

1. Extended pre-dispatch schema coercion to accept nullable object and array fields when models emit literal `"null"` or `nil`.
2. Added support for JSON Schema union type lists such as `["integer", "string"]` and `["null", "object"]`, preserving declared-order coercion.
3. Added focused AgentCore tool-call regressions so nullable and union-shaped arguments are normalized before side-effecting tool tasks start.

### Slice 78: Empty terminal response normalization

1. Normalized terminal `:stop` responses with no visible text and no tool calls into `:error` assistant messages.
2. Treated thinking-only terminal responses the same way so private reasoning does not become a successful blank answer.
3. Added AgentCore loop regressions for empty and thinking-only provider stop responses.

### Slice 79: Provider RetryInfo normalization

1. Taught `Ai.Error.parse_http_error/3` to classify provider rate-limit body shapes such as Google `RESOURCE_EXHAUSTED` and AWS throttling markers even when the HTTP status is not 429.
2. Merged Google/Vertex `google.rpc.RetryInfo.retryDelay` body hints into parsed `rate_limit_info.retry_after` when retry headers are absent, while preserving header precedence.
3. Aligned decimal `Retry-After` parsing with the existing provider test contract and added focused parser regressions for body retry hints.

### Slice 80: OpenAI Responses malformed tool-call identity normalization

1. Normalized streamed OpenAI Responses function-call items that omit `call_id` or `id` into deterministic `call_*|fc_*` tool-call ids instead of `nil`-derived ids.
2. Filled missing streamed function-call names with `unknown_tool` so downstream tool execution produces a normal unknown-tool result rather than receiving a nil tool name.
3. Added a focused streaming regression for missing identity fields while preserving parsed arguments and `:tool_use` stop reason.

### Slice 81: OpenAI-compatible malformed tool-call identity normalization

1. Normalized streamed OpenAI-compatible tool-call deltas with missing or blank ids into deterministic `call_stream_*` ids.
2. Filled missing or blank function names with `unknown_tool` while still allowing later name deltas to replace the fallback.
3. Added a focused streaming regression for missing identity fields while preserving parsed arguments and `:tool_use` stop reason.

### Slice 82: Tool-batch abort closure contract

1. Added a direct AgentCore `ToolCalls` regression for aborting while one tool task is pending and another tool call is still queued.
2. Proved both tool calls receive exactly one terminal `is_error: true` tool result with `%{error_type: :aborted}`.
3. Proved queued side-effecting tool execution does not start after the abort while still emitting a terminal tool-end event for observability.

### Slice 83: OpenAI-compatible duplicate tool-call id normalization

1. Normalized duplicate streamed OpenAI-compatible tool-call ids within the same assistant turn into unique ids before AgentCore execution.
2. Preserved the provider's original id for the first matching call while assigning deterministic suffixed ids to later duplicates.
3. Added a focused streaming regression that keeps chunked duplicate-id arguments attached to the uniquified tool call and preserves `:tool_use`.

### Slice 84: OpenAI Responses duplicate function-call id normalization

1. Normalized duplicate streamed OpenAI Responses function-call ids within the same assistant turn into unique ids before AgentCore execution.
2. Kept the finalized tool-call block aligned with the normalized id emitted during stream accumulation.
3. Added a focused Responses streaming regression that preserves chunked arguments, final tool names, and `:tool_use` while uniquifying duplicate ids.

### Slice 85: Provider error array message normalization

1. Normalized nested provider error arrays shaped like `%{"error" => %{"errors" => [%{"message" => ...}]}}` into the first provider message.
2. Normalized top-level provider error arrays shaped like `%{"errors" => [%{"message" => ...}]}` the same way.
3. Replaced the old inspected-map fallback expectation with focused parser regressions for both shapes.

### Slice 86: Standalone LemonRunner tool metadata preservation

1. Preserved structured `AgentToolResult.details` metadata when LemonRunner receives a `tool_execution_end` event without a tracked matching start event.
2. Kept `result_meta.error_type` and related fields available on the completed action for cross-layer observability.
3. Added a LemonRunner regression for untracked timeout-style tool completions.

### Slice 87: Provider detail-array message normalization

1. Normalized FastAPI/Pydantic-style top-level `detail: [%{msg: ...}]` provider bodies into the first useful detail message.
2. Normalized nested provider `error.details` arrays with `message`, `msg`, or `reason` fields into clean provider messages.
3. Added focused parser regressions for both shapes so clients do not surface inspected maps for common provider validation errors.

### Slice 88: Nested provider message normalization

1. Added a fallback nested-provider-message search for `message`, `msg`, and `reason` fields inside otherwise unrecognized provider error maps.
2. Preserved existing top-level provider message priority and existing inspected-map fallback when no useful nested message exists.
3. Added focused regressions for deeply nested maps and nested arrays so common validation payloads no longer surface inspected maps.

### Slice 89: Gateway action metadata preservation

1. Added a CLI adapter regression showing `AgentCore` action `detail.result_meta` remains nested on LemonGateway action events.
2. Added a gateway run bus regression showing `:engine_action` payloads preserve failed tool action metadata.
3. Locked the LemonRunner-to-gateway hop before continuing lifecycle metadata checks downstream.

### Slice 90: AgentCore transcript detail preservation

1. Strengthened the AgentCore loop regression so the next model turn receives `ToolResultMessage.details` with the tool results.
2. Strengthened the final message assertions so returned loop transcripts keep those details in assistant-visible order.
3. Added a GenServer-level conversation regression showing stored agent messages preserve tool result details after a full prompt completes.

### Slice 91: Provider detail-map and error-array normalization

1. Normalized top-level provider `detail`/`details` maps by searching nested `message`, `msg`, and `reason` fields.
2. Normalized top-level `error` arrays with useful detail entries into clean provider messages.
3. Added parser regressions so common validation and proxy error payloads do not surface inspected maps.

### Slice 92: Provider error-description normalization

1. Normalized OAuth/proxy-style `error` plus `error_description` bodies into code-prefixed provider messages.
2. Added `error_description` and `error_message` to nested provider message search.
3. Added parser regressions for top-level and nested description-only provider payloads.

### Slice 93: Router session and status metadata propagation

1. Added a RunProcess regression for failed tool actions carrying structured `result_meta`.
2. Verified the raw `:engine_action` delivered to session subscribers keeps the nested failure metadata.
3. Verified the router tool-status intent exposes the same failure metadata in `body.tool_failures`.

### Slice 94: AgentCore streaming partial tool arguments

1. Added an AgentCore streaming regression for chunked `:tool_call_delta` argument updates.
2. Verified the final assistant message preserves the accumulated tool call when the terminal provider message has empty content.
3. Verified stream lifecycle events expose the intermediate partial arguments and final reconciled tool call.

### Slice 95: Provider request invalid UTF-8 sanitization

1. Added an OpenAI-compatible request-body regression for invalid UTF-8 in system and user content.
2. Added an OpenAI Responses conversion regression for the same request-boundary content paths.
3. Verified both providers keep outgoing message payloads valid and preserve the valid prefix content.

### Slice 96: Late stream delta closure

1. Added a router stream coalescer regression for deltas arriving after `finalize_run/4`.
2. Verified the finalized answer dispatch remains the only semantic delivery intent for the run.
3. Verified late deltas do not advance stream sequence, mutate accumulated text, or replace the finalized answer text.

### Slice 97: Agent-loop skill refinement contract

1. Added a deterministic eval where the loop reads an existing project skill before modifying it.
2. Verified `skill_manage` patches `SKILL.md` through the real tool path rather than replacing files directly.
3. Verified the updated skill persists the newly learned workflow detail for later runs.

### Slice 98: OpenAI Responses partial function-call arguments

1. Added a Responses API regression for truncated nested function-call arguments on an incomplete stream.
2. Reused stack-based JSON completion so arrays and objects close in provider stream order.
3. Kept final `output_item.done` reconciliation from replacing recoverable partial arguments with an empty map.

### Slice 99: OpenAI Responses final-only function-call arguments

1. Added a regression for Responses streams where `output_item.added` names a function call but only `output_item.done` carries arguments.
2. Routed that final-only arguments path through the same recovery parser as streaming deltas.
3. Verified truncated nested arrays are preserved with `stop_reason: :length` instead of becoming an empty argument map.

### Slice 100: Agent-loop workspace memory update contract

1. Added a deterministic eval where the loop reads an existing workspace topic memory file before changing it.
2. Verified the update goes through the real `patch` tool rather than direct file mutation.
3. Verified the persisted memory topic captures the newly learned follow-up-owner detail for later runs.

### Slice 101: Launch-focused prompt-injection coverage

1. Tightened the untrusted tool boundary so raw tool output cannot bypass the
   wrapper merely by including both external-content markers.
2. Added deterministic marker-smuggling coverage for web fetch output, inbound
   email prompts, skill prompt rendering, and extension-style untrusted tool
   results.
3. Updated the 1.0 safety docs and launch ledger so broader adversarial variants
   are tracked as post-1.0 hardening rather than an initial launch blocker.

### Slice 102: Live-model coding repair contract

1. Added `live_model_coding_repair_contract` to the opt-in live-model eval lane.
2. The eval creates a failing Elixir fixture and requires the provider-backed
   model to read the source, patch only the implementation, run
   `elixir test/lemon_release_report_test.exs`, and finalize only after the
   bash result reports success.
3. Added missing-credential regression coverage so the expanded live lane fails
   cleanly when provider credentials are absent.

### Slice 103: LSP timeout cleanup contract

1. Hardened `LemonCore.LspServerManager` so a timed-out JSON-RPC request marks
   the session `:request_timeout`, replies to pending callers, terminates the
   launcher PID, and sweeps launcher descendants.
2. Added a regression with a stuck fake LSP wrapper that spawns a child process
   and verified timeout cleanup leaves no live child behind.
3. Re-ran the real six-server LSP smoke with the documented ElixirLS launcher
   path and verified the intentionally broken default wrapper times out without
   leaving language-server processes running.

### Slice 104: LSP editor-flow proof

1. Extended `scripts/live_lsp_server_smoke.exs` with `--editor-flow` for an
   open, clean, rebreak, reclean, and close sequence over the same supervised
   stdio session.
2. Added proof fields for reintroduced diagnostic count, final diagnostic
   count, final clean state, change count, and document close status.
3. Ran the editor-flow proof across Pyright, gopls, clangd, rust-analyzer,
   TypeScript Language Server, and ElixirLS with all six completing and clearing
   diagnostics a second time.

### Slice 105: Extension tool telemetry contract

1. Wrapped explicitly trusted BEAM extension tools at `CodingAgent.ToolRegistry`
   so execution emits redacted start, stop, and exception telemetry.
2. Kept metadata bounded to host/tool labels plus hashed extension and tool-call
   identities, with no raw params, source paths, extension file contents, or raw
   call ids.
3. Extended `scripts/live_extension_host_smoke.exs` with
   `extension_tool_execution_emits_redacted_telemetry`; that extension-host
   smoke run completed five checks with zero failures before the later
   disabled-mode check expanded the proof.

### Slice 106: Extension telemetry operator gate

1. Projected the latest extension-host smoke proof into
   `LemonCore.Doctor.ExtensionDiagnostics` as redacted execution-telemetry
   status, proof hash, counts, check status, and redaction booleans.
2. Exposed that same summary through support bundles, `extensions.status`, and
   Web `/ops` so operators can inspect proof state without loading plugin code.
3. Added `mix lemon.doctor` coverage as `extensions.telemetry`, passing only
   when the redacted extension tool start/stop/exception telemetry proof is
   complete.

### Slice 107: Extension execution disable policy

1. Added `[runtime.extensions] enabled` and `LEMON_EXTENSIONS_ENABLED` as a
   global execution switch for BEAM extension code.
2. Ensured disabled mode blocks extension loading even for explicit
   `extension_paths` / `extensionPaths`, while keeping manifest diagnostics and
   support surfaces code-free and visible.
3. Exposed the enabled/disabled policy through extension diagnostics,
   `extensions.status`, and Web `/ops`, and fixed mixed atom/string config
   lookup so explicit `false` settings are not treated as missing.
4. Extended `scripts/live_extension_host_smoke.exs` with
   `extensions_disabled_blocks_explicit_path_execution` and
   `extensions_env_disabled_blocks_explicit_path_execution`; the latest
   extension-host smoke proof completed seven checks with zero failures and
   verifies both config and env disabled mode block explicit-path BEAM extension
   execution.

### Slice 108: WASM tool execution telemetry contract

1. Wrapped WASM `ToolFactory` execution so discovered WASM tools emit redacted
   start, stop, and exception telemetry around `SidecarSession.invoke/4`.
2. Kept telemetry metadata bounded to the WASM host label, tool name, hashed
   WASM path, hashed tool-call id, status, duration, and redacted exception
   type. Raw params, raw tool-call ids, raw WASM paths, sidecar error strings,
   and tool result payloads stay out of telemetry.
3. Added `scripts/live_wasm_telemetry_smoke.exs`; the latest proof completed
   four checks with zero failures for successful execution, returned sidecar
   errors, sidecar exits, and telemetry redaction. This proves the WASM wrapper
   telemetry boundary, not public registry, MCP, marketplace, or full sandbox
   parity.
4. Projected the latest WASM telemetry proof into
   `LemonCore.Doctor.ExtensionDiagnostics`, `extensions.status`, and Web `/ops`
   as redacted proof status, check status, host-boundary flags, proof hash,
   counts, and redaction booleans.
5. Added a `mix lemon.doctor` gate as `extensions.wasm_telemetry`, passing only
   when the latest WASM smoke proof completed the success, sidecar-error,
   sidecar-exit, and redaction checks.

### Slice 109: WASM risky-capability policy proof

1. Added `scripts/live_wasm_policy_smoke.exs` to prove the current WASM policy
   wrapper around ToolRegistry execution.
2. Proved that WASM tools declaring `http`, `tool_invoke`, or `exec`
   capabilities require approval by default, safe-capability tools execute
   without approval, and explicit `approvals.<tool> = never` can override that
   default. The latest proof completed five checks with zero failures and wrote
   `.lemon/proofs/wasm-policy-latest.json`.
3. Projected the latest WASM policy proof into
   `LemonCore.Doctor.ExtensionDiagnostics`, `extensions.status`, Web `/ops`,
   and `mix lemon.doctor` as `extensions.wasm_policy`.
4. This is policy-wrapper proof, not full runtime sandboxing, public registry,
   or marketplace install/update review.

### Slice 110: Extension registry install/update audit proof

1. Added `LemonCore.Extensions.RegistryAudit` for code-free registry index
   validation over embedded extension manifests, distribution source metadata,
   audit status, installable/blocked package counts, and update-candidate
   detection.
2. Added `scripts/live_extension_registry_audit_smoke.exs`; the latest proof
   completed five checks with zero failures for code-free index validation,
   unaudited install blocking, audited update detection, no extension-code
   loading, and redaction of registry paths, package names, distribution URLs,
   and manifest contents.
3. Projected the latest registry audit proof into
   `LemonCore.Doctor.ExtensionDiagnostics`, `extensions.status`, Web `/ops`,
   and `mix lemon.doctor` as `extensions.registry_audit`.
4. This proves registry metadata review for install/update decisions, not full
   marketplace hosting, sandboxed non-BEAM execution, or bundled plugin breadth.

### Slice 111: WASM sidecar lifecycle proof

1. Redacted `CodingAgent.Wasm.SidecarSession` discover/invoke lifecycle
   telemetry so per-session WASM events expose hashed session, cwd, and tool
   metadata instead of raw runtime values.
2. Added `scripts/live_wasm_lifecycle_smoke.exs`; the latest proof completed
   five checks with zero failures for redacted discover/invoke start-stop
   telemetry, running status visibility, sidecar stop termination, and omission
   of raw cwd, session id, tool name, and params.
3. Projected the latest WASM lifecycle proof into
   `LemonCore.Doctor.ExtensionDiagnostics`, `extensions.status`, Web `/ops`,
   and `mix lemon.doctor` as `extensions.wasm_lifecycle`.
4. This proves per-session sidecar lifecycle support, not full runtime
   sandboxing, marketplace hosting, or broad WASM package parity.

### Slice 112: Latest proof artifact inventory

1. Extended `LemonCore.Doctor.ProofDiagnostics` so support bundles,
   `proofs.status`, and Web `/ops` include `.lemon/proofs/*-latest.json`
   artifacts in addition to legacy `*proof*.json` files.
2. Kept `tmp/` scanning restricted to `*proof*.json`, preserving the narrower
   live-script scratch contract while making first-party `.lemon/proofs`
   latest artifacts visible in safe proof counts.
3. Added regression coverage proving `wasm-lifecycle-latest.json` contributes
   to proof counts, proof-scope counts, check-name counts, and recent proof
   metadata without exposing raw paths or proof contents.
4. This is observability/support inventory hardening, not a new capability
   proof by itself.

### Slice 113: LSP project-fixture promotion

1. Extended `scripts/live_lsp_server_smoke.exs` with `--project-fixtures` /
   `--fixture-profile project`, producing multi-file temporary projects with
   root markers and companion files for Pyright, gopls, clangd, rust-analyzer,
   TypeScript Language Server, and ElixirLS.
2. Added redacted proof shape for project fixtures: top-level status,
   `lsp_project_fixtures_smoke` proof scope, safe per-server check names,
   fixture file counts, root-marker counts, and companion-file counts without
   raw workspace paths, file contents, diagnostic output, session ids, or server
   I/O.
3. Ran the full project-fixture editor-flow proof with the documented ElixirLS
   launcher. All six servers completed with `failed_count: 0`, non-zero
   reintroduced diagnostics, final clean diagnostics, and closed documents.
4. This promotes the local LSP proof from single-file smoke fixtures to
   project-shaped workspace fixtures, but broader real-repository and editor
   compatibility lanes remain before stable Hermes LSP parity.

### Slice 114: MCP stdio and registry ingestion

1. Fixed the stdio MCP runtime path so `LemonMCP.Transport.Stdio` opens child
   processes with real stdio wiring and `LemonMCP.Client` sends transport
   messages back to the client process instead of the transport process.
2. Implemented stdio MCP discovery and invocation in `LemonSkills.McpSource`.
   Configured stdio servers now start under the BEAM client, discovered tools
   are wrapped as `mcp_<server>_<tool>` `AgentTool`s, successful calls return
   normal tool results, MCP tool-error responses propagate as tool errors, and
   unavailable servers degrade without breaking discovery.
3. Added MCP tools to `CodingAgent.ToolRegistry` as the lowest-precedence source
   after built-ins, WASM, and BEAM extensions. Conflict reports now include MCP
   counts and shadowed MCP sources.
4. Added `scripts/live_mcp_stdio_smoke.exs`; the latest proof completed eight
   checks with zero failures for missing-command degradation, client
   initialization, tool listing, success call, error call, prefixed source
   discovery, registry exposure, and `notifications/initialized` compatibility.
5. This proves local stdio MCP tool ingestion and registry exposure. Later
   slices cover resource/prompt utility tools, filtering, HTTP JSON-RPC, and
   legacy HTTP+SSE; OAuth metadata, sampling, and richer capability wrappers
   remain open before stable Hermes MCP parity.

### Slice 115: MCP stdio resources and prompts

1. Extended `LemonMCP.Protocol` and `LemonMCP.Client` with stdio MCP
   `resources/list`, `resources/read`, `prompts/list`, and `prompts/get`
   requests and typed responses.
2. Extended `LemonSkills.McpSource` so capable stdio servers expose explicit
   model-facing utility tools: `mcp_<server>_resources_list`,
   `mcp_<server>_resource_read`, `mcp_<server>_prompts_list`, and
   `mcp_<server>_prompt_get`.
3. Updated `scripts/live_mcp_stdio_smoke.exs`; the latest proof completed
   thirteen checks with zero failures for missing-command degradation, client
   initialization, tool listing, resource listing/reading, prompt
   listing/getting, success and tool-error calls, prefixed source discovery,
   source utility invocation, registry exposure, and
   `notifications/initialized` compatibility.
4. This proves stdio MCP tools/resources/prompts through Lemon's supervised
   BEAM capability path. HTTP JSON-RPC, legacy HTTP+SSE, and exact stdio
   filtering are covered in later slices; OAuth metadata, sampling, richer
   capability wrappers, broader external-server compatibility and full
   marketplace/sandbox parity remain open.

### Slice 116: MCP stdio filtering and capability status

1. Added exact allow/block filters for stdio MCP tools, resources, and prompts
   through tuple config and JSON config keys. Filters run before model-facing
   registry exposure and before resource/prompt utility calls.
2. Exposed redacted server capability metadata through `LemonMCP.Client` and
   `LemonSkills.McpSource.status/0`, alongside tool/resource/prompt counts.
3. Extended `scripts/live_mcp_stdio_smoke.exs`; the latest proof completed
   fourteen checks with zero failures, adding
   `mcp_source_applies_stdio_filters` to the stdio tools/resources/prompts
   proof.
4. This proves local stdio MCP filtering and capability status. HTTP JSON-RPC
   and legacy HTTP+SSE MCP tools/resources/prompts are covered in later slices;
   OAuth metadata, sampling, richer capability wrappers, broader external-server
   compatibility and full marketplace/sandbox parity remain open.

### Slice 117: MCP HTTP JSON-RPC capability ingestion

1. Added `LemonMCP.Client.HTTP`, a supervised GenServer client for HTTP
   JSON-RPC MCP endpoints. It performs the initialize/initialized handshake,
   stores server info and capability metadata, lists tools/resources/prompts,
   invokes tools, reads resources, retrieves prompts, and returns MCP RPC
   errors cleanly.
2. Promoted `{:http, url, opts}` configs in `LemonSkills.McpSource` from
   validated-but-disabled entries into active source entries. HTTP MCP tools
   now use the same prefixed `mcp_<server>_<tool>` registry path as stdio
   tools, support authentication headers, expose status capability shape,
   expose resource/prompt utility tools, and apply exact tool/resource/prompt
   allow/block filters before model-facing registry exposure.
3. Added `scripts/live_mcp_http_smoke.exs`; the latest proof completed
   fourteen checks with zero failures and zero skipped checks for HTTP client
   initialization, tool/resource/prompt listing, resource reading, prompt
   retrieval, success and tool-error calls, prefixed source discovery and
   invocation, source resource/prompt utility invocation, registry exposure,
   status capability reporting, and exact HTTP filtering.
4. This proves HTTP JSON-RPC MCP tools/resources/prompts through Lemon's BEAM
   capability host path. Legacy HTTP+SSE MCP transport is covered in the next
   slice; OAuth metadata, sampling/capability wrappers, broader external-server
   compatibility and full marketplace/sandbox parity remain open.

### Slice 118: MCP legacy HTTP+SSE capability ingestion

1. Added `LemonMCP.Client.SSE`, a supervised GenServer client for legacy
   HTTP+SSE MCP endpoints. It opens the SSE stream, consumes the server
   `endpoint` event, posts JSON-RPC messages to that endpoint, correlates
   JSON-RPC responses from SSE `message` events, handles timeouts, exposes
   server info/capability metadata, and supports tool/resource/prompt methods.
2. Promoted `{:sse, url, opts}` configs in `LemonSkills.McpSource` and
   `LemonSkills.Config`. SSE MCP tools use the same
   `mcp_<server>_<tool>` registry path as stdio and HTTP JSON-RPC tools,
   support authentication headers, expose resource/prompt utility tools,
   report status capability shape, and apply exact tool/resource/prompt
   allow/block filters before model-facing registry exposure.
3. Added `scripts/live_mcp_sse_smoke.exs`; the latest proof completed
   fourteen checks with zero failures and zero skipped checks for SSE client
   initialization, tool/resource/prompt listing, resource reading, prompt
   retrieval, success and tool-error calls, prefixed source discovery and
   invocation, source resource/prompt utility invocation, registry exposure,
   status capability reporting, and exact SSE filtering.
4. This closes the local legacy SSE transport parity gap at the deterministic
   fixture level. MCP OAuth metadata, sampling/capability wrappers, broader
   external-server compatibility, current Streamable HTTP response/session
   proof, and full marketplace/sandbox parity remain open.

### Slice 119: MCP Streamable HTTP response and session compatibility

1. Extended `LemonMCP.Client.HTTP` from a JSON-only HTTP client into a
   Streamable HTTP client while preserving its public API. It now sends
   `Accept: application/json, text/event-stream`, captures server-issued
   `Mcp-Session-Id` headers during initialization, includes the negotiated
   `MCP-Protocol-Version` header on subsequent requests, and accepts both
   JSON responses and per-request SSE `message` responses.
2. Added deterministic client coverage with a Streamable HTTP fixture that
   returns an initialize JSON response with a session id, accepts the
   initialized notification with session/protocol headers, and returns
   `tools/list` over an SSE response body.
3. Extended `scripts/live_mcp_http_smoke.exs`; this proof point completed
   fifteen checks with zero failures and zero skipped checks, adding
   `mcp_http_streamable_sse_response_and_session_headers` to the existing
   HTTP client/source/registry/filtering proof.
4. This closes the local current Streamable HTTP response/session proof gap at
   the deterministic fixture level. MCP OAuth, sampling/capability wrappers,
   broader external-server compatibility and full marketplace/sandbox parity
   remain open.

### Slice 120: MCP OAuth protected-resource metadata discovery

1. Extended `LemonMCP.Client.HTTP` so Streamable HTTP startup failures caused
   by 401 authentication challenges return `{:error, {:auth_required,
   metadata}}` with the original `WWW-Authenticate` value, discovered
   `resource_metadata_url`, and decoded OAuth protected-resource metadata.
2. Added deterministic client coverage with a protected-resource fixture that
   returns a Bearer challenge containing `resource_metadata`, serves
   `.well-known/oauth-protected-resource/mcp`, and verifies Lemon returns the
   resource URI plus authorization-server metadata without starting a ready
   client.
3. Extended `scripts/live_mcp_http_smoke.exs`; the latest proof completed
   sixteen checks with zero failures and zero skipped checks, adding
   `mcp_http_oauth_protected_resource_metadata` to the Streamable HTTP
   client/source/registry/filtering proof.
4. This closes MCP OAuth protected-resource metadata discovery at deterministic
   fixture level. Authorization-server metadata, client-credentials token
   handling, sampling workflows, broader external-server compatibility and
   full marketplace/sandbox parity remain open.

### Slice 121: MCP OAuth authorization-server metadata discovery

1. Extended `LemonMCP.Client.HTTP` so protected-resource metadata discovery
   follows declared `authorization_servers` entries to their OAuth
   authorization-server metadata documents and includes those decoded documents
   under `authorization_server_metadata`.
2. Kept discovery requests scoped to metadata headers only, so configured MCP
   request headers such as bearer tokens are not forwarded to metadata URLs.
3. Added deterministic client coverage and extended
   `scripts/live_mcp_http_smoke.exs`; the latest HTTP proof completed
   seventeen checks with zero failures and zero skipped checks, adding
   `mcp_http_oauth_authorization_server_metadata` beside the protected-resource
   metadata check.
4. This closes OAuth protected-resource plus authorization-server metadata
   discovery at deterministic fixture level. Client-credentials token handling,
   interactive auth flow,
   broader external-server compatibility and full marketplace/sandbox parity
   remain open.

### Slice 122: MCP stdio sampling callback wrapper

1. Extended `LemonMCP.Client` with an opt-in `sampling_handler` for
   server-initiated `sampling/createMessage` requests over stdio. The client
   advertises `"sampling" => %{}` only when that handler is configured, then
   sends a normal JSON-RPC result or rejection response back through the stdio
   transport.
2. Added generic JSON-RPC response encoding in `LemonMCP.Protocol` so client
   callbacks can answer server requests without bypassing protocol helpers.
3. Added deterministic client coverage with a Node stdio fixture that verifies
   sampling capability advertisement, receives the sampling params in the
   callback, and observes the returned assistant text response.
4. Extended `scripts/live_mcp_stdio_smoke.exs`; the latest stdio proof
   completed fifteen checks with zero failures and zero skipped checks, adding
   `mcp_stdio_sampling_callback_wrapper` to the existing startup, discovery,
   registry, resource/prompt, filtering, and initialized-notification proof.
5. This closes the local stdio callback wrapper gap at deterministic fixture
   level. HTTP OAuth client-credentials handling, interactive auth flow,
   broader external-server compatibility,
   and full marketplace/sandbox parity remain open.

### Slice 123: MCP HTTP OAuth client-credentials token acquisition

1. Extended `LemonMCP.Client.HTTP` so a Streamable HTTP MCP server protected by
   OAuth can be configured with `oauth: [client_id: ..., client_secret: ...]`.
   After a 401 challenge, the client discovers protected-resource metadata,
   follows authorization-server metadata to a token endpoint, requests a bearer
   token with `grant_type=client_credentials`, and retries the protected MCP
   request with `Authorization: Bearer ...`.
2. Kept metadata discovery isolated from configured MCP headers and acquired
   bearer tokens. Metadata requests use metadata-only headers; the token request
   carries only the client-credentials form payload plus optional `resource` and
   `scope`.
3. Added low-level client coverage for a protected Streamable HTTP fixture,
   including token form assertions, protected-request retry, and proof that
   metadata URLs do not receive bearer authorization. Added config/source
   coverage for `oauth` options in tuple and JSON MCP server configs.
4. Extended `scripts/live_mcp_http_smoke.exs`; that HTTP proof completed
   eighteen checks with zero failures and zero skipped checks, adding
   `mcp_http_oauth_client_credentials_token_acquisition` beside the metadata
   checks.
5. This closes client-credentials token acquisition at deterministic fixture
   level. Refresh-token grant was later closed in Slice 128, authorization-code PKCE callback in Slice 130, and token persistence/resume in Slice 131, and loopback callback capture was later closed in Slice 132; broader external-server compatibility and full marketplace/sandbox parity remain open.

### Slice 124: MCP HTTP OAuth bearer reacquisition after 401

1. Extended `LemonMCP.Client.HTTP` to remember discovered OAuth metadata after
   client-credentials acquisition. If a later protected request gets a 401, the
   client can reuse that metadata, reacquire a bearer token with the configured
   client credentials, and retry the request once instead of requiring an
   operator restart.
2. Bounded the retry path so a bad token endpoint or still-rejected bearer
   returns `{:auth_required, metadata}` instead of looping indefinitely.
3. Added low-level client coverage with a fixture that accepts the first bearer
   for initialization, rejects it on `tools/list`, issues a second bearer, and
   proves the retried `tools/list` uses the refreshed token.
4. Extended `scripts/live_mcp_http_smoke.exs`; the latest HTTP proof completed
   nineteen checks with zero failures and zero skipped checks, adding
   `mcp_http_oauth_client_credentials_token_refresh` beside the existing
   metadata and token-acquisition checks.
5. This closes basic client-credentials bearer reacquisition at deterministic
   fixture level. Refresh-token grant was later closed in Slice 128, authorization-code PKCE callback in Slice 130, and token persistence/resume in Slice 131, and loopback callback capture was later closed in Slice 132; broader external-server compatibility and full marketplace/sandbox parity remain open.

### Slice 125: MCP HTTP OAuth token endpoint auth methods

1. Extended `LemonMCP.Client.HTTP` so configured OAuth client credentials can
   authenticate to token endpoints with either the existing
   `:client_secret_post` form payload or `:client_secret_basic` HTTP Basic
   auth.
2. Threaded `token_auth_method` through tuple and JSON MCP server config,
   including validation in `LemonSkills.Config` and `LemonSkills.McpSource`.
   Unknown auth methods are rejected before a misleading runtime attempt.
3. Added low-level client coverage proving Basic auth sends
   `Authorization: Basic ...`, omits `client_id` and `client_secret` from the
   token form, keeps scope/resource handling intact, and still reaches a ready
   protected Streamable HTTP MCP client.
4. Extended `scripts/live_mcp_http_smoke.exs`; the latest HTTP proof completed
   twenty checks with zero failures and zero skipped checks, adding
   `mcp_http_oauth_client_secret_basic_token_auth` beside the existing OAuth
   metadata, acquisition, and bearer-reacquisition checks.
5. This closes the common confidential-client token-auth compatibility gap at
   deterministic fixture level. Refresh-token grant was later closed in Slice 128, authorization-code PKCE callback in Slice 130, and token persistence/resume in Slice 131, and loopback callback capture was later closed in Slice 132; broader external-server compatibility and full marketplace/sandbox parity remain open.

### Slice 126: MCP reviewed sampling policy wrapper

1. Added `LemonMCP.Sampling`, a BEAM-side policy wrapper for stdio
   `sampling/createMessage` requests. It emits redacted summaries with request
   hashes, message counts, roles, content-kind counts, text length, max tokens,
   and requested model, without raw prompt text.
2. Wired `LemonMCP.Client` to accept `sampling_policy` alongside the low-level
   `sampling_handler`. Capability advertisement still stays tied to real
   response ability: Lemon advertises sampling only when a handler or policy is
   configured.
3. Added policy enforcement for max-token limits, optional model allowlists,
   reviewed-model approval, and safe hashed error details before a model-backed
   delegate sees raw params.
4. Extended deterministic coverage for redaction, reviewer approval/rejection,
   model/token policy failure, client policy routing, and the stdio fixture
   path. The focused MCP lane passed 26 tests with zero failures.
5. Extended `scripts/live_mcp_stdio_smoke.exs`; the latest stdio proof
   completed seventeen checks with zero failures and zero skipped checks, adding
   `mcp_stdio_sampling_reviewed_model_policy` beside the raw callback wrapper.
6. This closes the local reviewed model-backed sampling policy gap at
   deterministic fixture level. Authorization-code PKCE callback was later closed in Slice 130 and token persistence/resume in Slice 131, and loopback callback capture was later closed in Slice 132; broader external-server compatibility and full marketplace/sandbox parity remain open.

### Slice 127: Local media smoke proof lane

1. Extended all five media smoke scripts with `--local` mode so image, speech,
   transcription, vision, and video can be proven through deterministic
   no-credential providers without consuming provider quota.
2. The local lane writes separate `.lemon/proofs/media-*-local-smoke-latest.json`
   artifacts with `proof_scope: media_local`, `lemon.media_*_local_smoke` proof
   objects, and provider-specific checks for `local_svg`, `local_wav`,
   `local_transcript`, `local_vision`, and `local_mp4`.
3. The 2026-05-17 local run completed all five checks with zero failures and
   produced managed artifacts for SVG, WAV, transcript JSON, vision JSON, and
   MP4 output.
4. The provider-backed launch gate remains strict. The local artifacts do not
   satisfy `media.provider_live`, `scripts/audit_1_0_readiness`, or claims of
   image/TTS/STT/vision/video provider parity.

### Slice 128: MCP HTTP OAuth refresh-token grant lifecycle

1. Extended `LemonMCP.Client.HTTP` to retain refresh tokens returned by OAuth
   token endpoints alongside the access token and discovered metadata.
2. On a later 401, the client now prefers `grant_type=refresh_token` when a
   refresh token is available, rotates the stored refresh token if the token
   endpoint returns a replacement, and falls back to client credentials only
   when refresh is unavailable or fails.
3. Added deterministic low-level client coverage proving exactly one initial
   client-credentials request, one later refresh-token request, the expected
   `refresh_token` form value, retried `tools/list` with the refreshed bearer,
   and no second client-credentials request during refresh-token recovery.
4. Extended `scripts/live_mcp_http_smoke.exs`; the latest HTTP proof completed
   twenty-one checks with zero failures and zero skipped checks, adding
   `mcp_http_oauth_refresh_token_grant` beside the existing OAuth metadata,
   client-credentials acquisition/reacquisition, and token-auth checks.
5. This closes the deterministic refresh-token grant lifecycle gap. PKCE
   callback and token persistence/resume were later closed in Slices 130 and
   131, and loopback callback capture was later closed in Slice 132. Operator approval routing was later closed in Slice 133; broader external-server
   compatibility and full marketplace/sandbox parity remain open.

### Slice 129: MCP stdio sampling ops approval bridge

1. Threaded configured stdio MCP `sampling_policy` options from
   `LemonSkills.McpSource` into `LemonMCP.Client`, including JSON config parsing
   and validation in `LemonSkills.Config`.
2. Added an `:ops_approval` reviewer sentinel for configured sources. It creates
   a redacted `LemonCore.ExecApprovals` request named
   `mcp_<server>_sampling` with request hash, message counts, roles,
   content-kind counts, text length, max tokens, and requested model, without raw
   prompt text.
3. Kept delegate execution behind approval resolution: approvals return
   `:approve`, denials reject the sampling request, and raw params only reach the
   delegate after the approval bridge resolves.
4. Added focused source/config coverage for the approval bridge and reran the
   combined MCP source/sampling lane: 30 tests passed with zero failures.
5. Extended `scripts/live_mcp_stdio_smoke.exs`; the latest stdio proof completed
   seventeen checks with zero failures and zero skipped checks at
   `2026-05-17T14:16:03.768025Z`, adding
   `mcp_stdio_sampling_ops_approval_bridge`.
6. This closes the configured-source sampling approval bridge at deterministic
   fixture level. Token persistence/resume was later closed in Slice 131, and loopback callback capture was later closed in Slice 132. Operator approval routing was later closed in Slice 133; broader external-server compatibility and full
   marketplace/sandbox parity remain open.

### Slice 130: MCP HTTP PKCE authorization-code callback

1. Extended `LemonMCP.Client.HTTP` OAuth handling so Streamable HTTP clients can
   use authorization-code + PKCE when a public-client callback is configured.
   The client builds an authorization URL with `state`, S256
   `code_challenge`, optional redirect URI, scope, and MCP resource, then
   verifies callback state before token exchange.
2. Added public-client token exchange with `grant_type=authorization_code`,
   `code_verifier`, `client_id`, optional `redirect_uri`, and no client secret
   requirement unless `:client_secret_basic` is explicitly selected.
3. Added focused low-level HTTP client coverage proving authorization URL
   fields, SHA256 PKCE challenge correctness, state verification, token form
   fields, bearer retry, and mismatched-state rejection.
4. Extended `LemonSkills.Config` and `LemonSkills.McpSource` validation so HTTP
   MCP configs can declare `flow: :authorization_code_pkce`, public
   `client_id`, redirect URI, scopes, and a callback provider without requiring
   a client secret.
5. Extended `scripts/live_mcp_http_smoke.exs`; the latest HTTP proof completed
   twenty-two checks with zero failures and zero skipped checks at
   `2026-05-17T14:28:56.980867Z`, adding
   `mcp_http_oauth_pkce_authorization_code`.
6. This closes the deterministic PKCE callback/token-exchange boundary.
   Token persistence/resume was later closed in Slice 131, and loopback callback capture was later closed in Slice 132. Operator approval routing was later closed in Slice 133; broader external-server compatibility and full
   marketplace/sandbox parity remain open.

### Slice 131: MCP HTTP OAuth token cache persistence/resume

1. Extended `LemonMCP.Client.HTTP` with storage-agnostic OAuth token cache hooks.
   The client loads cached access/refresh tokens before initialize and persists
   successful client-credentials, refresh-token, and authorization-code PKCE
   token responses after acquisition or rotation.
2. Added compatibility callback options (`oauth_token_loader` and
   `oauth_token_persister`) plus the preferred `oauth_token_cache: [load: ...,
   save: ...]` form so low-level integrations can provide encrypted or
   in-memory storage without making `lemon_mcp` depend on Lemon runtime storage.
3. Wired configured Streamable HTTP MCP sources through `LemonSkills.McpSource`
   to use `LemonCore.Secrets` when `oauth.token_secret` is configured. The same
   config path can resolve confidential client secrets from
   `oauth.client_secret_secret`.
4. Added focused low-level HTTP client coverage proving cache load before
   initialize, token persistence after PKCE acquisition, and restart from the
   cached bearer without calling the authorization callback again.
5. Added configured-source coverage proving `LemonSkills.McpSource` persists
   OAuth cache payloads into `LemonCore.Secrets` through `oauth.token_secret`,
   with access token, refresh token, client id, scope, resource, version, and
   `mcp_oauth` provider metadata intact.
6. Extended config validation and JSON parsing coverage for `token_secret` and
   `client_secret_secret`.
7. Extended `scripts/live_mcp_http_smoke.exs`; the latest HTTP proof completed
   twenty-three checks with zero failures and zero skipped checks at
   `2026-05-17T14:36:09.108813Z`, adding
   `mcp_http_oauth_token_cache_resume`.
8. This closes the deterministic token persistence/resume boundary for
   Streamable HTTP OAuth. Configured-source loopback callback capture was later
   closed in Slice 132. Operator approval routing was later closed in Slice 133; broader external-server
   compatibility and full marketplace/sandbox parity remain open.

### Slice 132: MCP HTTP loopback OAuth callback capture

1. Wired configured Streamable HTTP MCP sources through Lemon's existing
   `LemonCore.Onboarding.LocalCallbackListener` when OAuth is configured as
   `authorization_code_pkce` and the `redirect_uri` points at localhost.
2. Kept the low-level `LemonMCP.Client.HTTP` boundary storage- and UI-agnostic:
   it still receives an `authorization_code_provider`, while `LemonSkills`
   owns listener startup, operator request notification, callback parsing, and
   timeout sizing for the interactive start path.
3. Added source-layer test coverage proving a configured HTTP MCP source emits
   the authorization request, accepts a localhost callback with matching
   `code`/`state`, exchanges it with PKCE verifier/resource/scope intact, and
   discovers the protected MCP tool through the resulting bearer.
4. Extended `scripts/live_mcp_http_smoke.exs`; the latest HTTP proof completed
   twenty-four checks with zero failures and zero skipped checks at
   `2026-05-17T14:55:23.434581Z`, adding
   `mcp_source_http_oauth_loopback_callback`.
5. This closes the deterministic loopback callback capture boundary for
   configured Streamable HTTP OAuth sources. Operator approval UI was later
   closed in Slice 133. Broader external-server compatibility and full
   marketplace/sandbox parity remain open.

### Slice 133: MCP HTTP operator OAuth approval surface

1. Routed configured Streamable HTTP MCP local PKCE authorization requests
   through `LemonCore.ExecApprovals` as structured `mcp_*_oauth` pending
   approvals before token exchange.
2. The approval action carries the authorization URL, resource, client id,
   redirect URI, scope, and a short state hash. It intentionally does not expose
   PKCE verifier material.
3. Web `/ops` now renders those pending approvals with an `Open OAuth` link and
   resource/redirect/scope context while preserving the existing approve/deny
   resolution path.
4. `LemonCore.ExecApprovals` now consumes the requester process's own
   `approval_requested` bus event while waiting for resolution, preventing
   GenServer requesters from logging their own approval event as unexpected
   after approval resolves.
5. Focused coverage passed for `McpSource` and Web `/ops`, and
   `scripts/live_mcp_http_smoke.exs` completed twenty-four checks with zero
   failures and zero skipped checks at `2026-05-17T15:02:16.211285Z`.
6. This closes the deterministic operator OAuth approval surface for configured
   local Streamable HTTP MCP PKCE flows. Broader external-server compatibility
   and full marketplace/sandbox parity remain open.

### Slice 134: Control-plane pending approval snapshots

1. Extended `exec.approvals.get` so remote operator clients receive active
   pending approvals in addition to policy data.
2. Pending approval snapshots now keep non-expiring approvals visible, filter
   expired entries, and include string-keyed structured `action` metadata.
3. This preserves `mcp_*_oauth` authorization URL/resource/redirect/scope
   context for reconnecting TUI/API clients instead of requiring them to have
   seen the original live `exec.approval.requested` event.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/exec_approvals_test.exs --seed 1`,
   covering twenty-five tests with zero failures.

### Slice 135: Control-plane approval event action metadata

1. Extended the EventBridge mapping for `:approval_requested` so live
   `exec.approval.requested` events include the pending approval's structured
   `action` metadata.
2. The event path now accepts either atom-keyed or string-keyed pending payloads
   and recursively stringifies nested action keys while preserving values such
   as boolean `false`.
3. This gives WebSocket clients the same MCP OAuth authorization URL/state
   context available through `exec.approvals.get`, so connected operator
   clients can render the approval immediately without waiting for a polling
   refresh.
4. Focused EventBridge validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_mapping_test.exs --seed 1`,
   covering thirty tests with zero failures.

### Slice 136: TUI MCP OAuth approval notifications

1. Extended the TypeScript TUI WebSocket event mapper so
   `exec.approval.requested` events emit `ui_notify` messages instead of being
   ignored.
2. MCP OAuth approval notifications include the tool, rationale,
   authorization URL, resource, scope, and redirect URI, matching the operator
   context exposed by Web `/ops` and `exec.approvals.get`.
3. The TUI also emits approval-resolution notifications so attached operators
   see when a pending approval completes.
4. Focused client validation passed with
   `cd clients/lemon-tui && npm test -- --run src/agent-connection.test.ts`,
   covering ninety-eight tests with zero failures, plus
   `cd clients/lemon-tui && npm run typecheck` and
   `cd clients/lemon-tui && npm run build`.
5. The full `scripts/test clients` lane passed after a small browser-node lint
   cleanup for download filename sanitization.

### Slice 137: TUI approval resolution command

1. Added a TUI `/approval` command so operators can resolve pending approvals
   without opening Web `/ops`.
2. The parser accepts `approve`, `once`, `session`, `agent`, `global`, and
   `deny` aliases and maps them to the existing control-plane decisions:
   `approve_once`, `approve_session`, `approve_agent`, `approve_global`, and
   `deny`.
3. The WebSocket command path now sends `exec.approval.resolve` with
   `approvalId` and `decision`, then renders the response as a terminal
   notification.
4. This completes the TUI-side loop for MCP OAuth approvals: the operator sees
   the authorization URL notification, completes login, and resolves the
   pending request from the same terminal session.
5. Focused client validation passed with
   `cd clients/lemon-tui && npm test -- --run src/agent-connection.test.ts src/ink/hooks/useCommands.test.tsx`,
   covering one hundred fifty-one tests with zero failures, plus
   `cd clients/lemon-tui && npm run typecheck` and
   `cd clients/lemon-tui && npm run build`.
6. The full `scripts/test clients` lane passed after the command/help/autocomplete
   surface changed.

### Slice 138: TUI pending approval snapshots

1. Added `/approval` and `/approval list` as terminal commands for refreshing
   current pending approval state.
2. The WebSocket path routes those commands to `exec.approvals.get` and formats
   the returned pending list as a TUI notification.
3. Pending MCP OAuth approvals include the approval id, tool name,
   authorization URL, resource, scope, and redirect URI, matching the structured
   metadata exposed by Web `/ops` and live approval events.
4. This closes the reconnect/late-join operator path for TUI approvals: an
   operator can list pending approvals, open the OAuth URL, then resolve with
   `/approval approve|once|session|agent|global|deny <approval-id>`.
5. Focused client validation passed with
   `cd clients/lemon-tui && npm test -- --run src/agent-connection.test.ts src/ink/hooks/useCommands.test.tsx`,
   covering one hundred fifty-three tests with zero failures, plus
   `cd clients/lemon-tui && npm run typecheck` and
   `cd clients/lemon-tui && npm run build`.
6. The full `scripts/test clients` lane passed after the pending approval list
   command changed the TUI command and WebSocket surfaces.

### Slice 139: Approval resolved event context

1. Extended the EventBridge `:approval_resolved` mapping so
   `exec.approval.resolved` WebSocket events include approval id, decision, run
   id, session key, agent id, and tool metadata when the original pending
   approval is available.
2. The mapper now handles string-keyed payloads and pending approval maps, which
   keeps externally injected or serialized approval events from dropping the
   approval id.
3. The TUI resolved-event notification now includes approval id and tool context
   when present instead of only reporting the decision.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_mapping_test.exs --seed 1`,
   covering thirty-one tests with zero failures.
5. Focused TUI validation passed with
   `cd clients/lemon-tui && npm test -- --run src/agent-connection.test.ts`,
   covering one hundred three tests with zero failures, plus
   `cd clients/lemon-tui && npm run typecheck` and
   `cd clients/lemon-tui && npm run build`.
6. The full `scripts/test clients` lane passed after the TUI resolved-event
   notification changed.

### Slice 140: Approval event schema contract

1. Added event-payload schemas to `LemonControlPlane.Protocol.Schemas` for
   `exec.approval.requested` and `exec.approval.resolved`.
2. The schema layer now exposes `get_event/1` and `validate_event/2`, keeping
   server-to-client event contracts separate from request-param validation while
   preserving compatibility for untyped events.
3. Approval requested events now have a schema-backed requirement for approval
   id, tool, and structured action metadata. Approval resolved events now have a
   schema-backed requirement for approval id and decision, with optional
   run/session/agent/tool context.
4. EventBridge tests now validate the live mapped approval requested/resolved
   payloads against those schemas, so future payload-shape drift breaks a
   focused control-plane test.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_mapping_test.exs --seed 1`,
   covering seventy-eight tests with zero failures.

### Slice 141: Web MCP sampling approval details

1. Extended Web `/ops` pending approval cards so `mcp_<server>_sampling`
   approvals render their structured redacted action metadata.
2. The card now shows the requested model, max tokens, message count, text
   character count, roles, content-kind counts, and request hash without raw
   sampling prompt text.
3. Added Web snapshot coverage for MCP sampling approval metadata alongside the
   existing MCP OAuth approval metadata coverage.
4. Updated Web, MCP, and skills docs to describe structured MCP sampling
   approval metadata in Web `/ops`.
5. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering twenty-nine tests with zero failures.
6. The delegated and rerun MCP sampling approval lane passed with
   `MIX_ENV=test mix test apps/lemon_mcp/test/lemon_mcp/sampling_test.exs apps/lemon_mcp/test/lemon_mcp/client_test.exs:739 apps/lemon_skills/test/lemon_skills/mcp_source_test.exs:526 apps/lemon_skills/test/lemon_skills/mcp_source_test.exs:934 apps/lemon_skills/test/lemon_skills/mcp_source_test.exs:977 apps/lemon_skills/test/lemon_skills/mcp_source_test.exs:1013 --seed 1`,
   covering ten tests with zero failures.

### Slice 142: TUI MCP sampling approval details

1. Extended TUI approval notification formatting so live
   `exec.approval.requested` events for `mcp_<server>_sampling` include
   structured sampling context.
2. Extended `/approval` and `/approval list` output so reconnecting terminal
   operators see the same redacted sampling metadata from
   `exec.approvals.get`.
3. The TUI now renders requested model, max tokens, message count, text
   character count, roles, content-kind counts, and request hash while omitting
   raw sampling prompt text.
4. Focused TUI validation passed with
   `cd clients/lemon-tui && npm test -- --run src/agent-connection.test.ts`,
   covering one hundred five tests with zero failures, plus
   `cd clients/lemon-tui && npm run typecheck` and
   `cd clients/lemon-tui && npm run build`.
5. The full `scripts/test clients` lane passed after the formatter change; lint
   warnings were limited to generated coverage report files.

### Slice 143: Web run-detail approval metadata

1. Extended Web `/ops/runs/:run_id` pending approval cards with the same
   structured MCP OAuth and MCP sampling metadata blocks as the main `/ops`
   dashboard.
2. Run-scoped OAuth approvals now include the `Open OAuth` action plus
   resource/redirect/scope context on the run detail page.
3. Run-scoped sampling approvals now include requested model, max tokens,
   message count, text character count, roles, content-kind counts, and request
   hash without raw sampling prompt text.
4. Added run-detail coverage proving both OAuth and sampling pending approval
   action metadata remain visible for the selected run.
5. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty tests with zero failures.

### Slice 144: Web run-detail approval resolution

1. Added the same approve-once, session, agent, global, and deny controls to
   Web `/ops/runs/:run_id` pending approval cards that already exist on the
   main `/ops` dashboard.
2. Added a run-detail `resolve-approval` LiveView handler that resolves through
   `LemonWeb.OpsDashboard.resolve_approval/2`, refreshes the selected run
   detail on success, and keeps failed resolutions visible to the operator.
3. Added focused Web coverage proving a run-scoped pending approval disappears
   from both the refreshed run detail assign and the run-detail snapshot after
   approving once.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-one tests with zero failures.


### Slice 145: Run approval history

1. `LemonCore.ExecApprovals` now records redacted `approval_requested`,
   `approval_resolved`, and `approval_timed_out` introspection events with
   approval id, tool, action type/hash, decision/scope, and safe booleans.
2. The approval timeline intentionally excludes raw action payloads, prompts,
   PKCE verifier material, provider responses, and secrets.
3. Web run details now classify `approval_*` introspection events into a
   dedicated Approval Events panel, so operators can audit what happened after
   a pending approval disappears.
4. Focused core validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/exec_approvals_test.exs --seed 1`,
   covering eighteen tests with zero failures.
5. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-one tests with zero failures.

### Slice 146: Approval timeout operator notifications

1. Approval request timeouts now emit the same `:approval_resolved` bus event
   used by explicit operator decisions, with `decision: :timeout` and the
   original pending approval metadata.
2. The control-plane EventBridge maps that timeout into
   `exec.approval.resolved` with `decision: "timeout"`, preserving approval id,
   run id, session key, agent id, and tool for WebSocket clients.
3. The TUI now renders timeout decisions as error notifications instead of
   treating them as successful approval completions.
4. Focused core validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/exec_approvals_test.exs --seed 1`,
   covering nineteen tests with zero failures.
5. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_mapping_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1`,
   covering seventy-nine tests with zero failures.
6. Focused TUI validation passed with
   `cd clients/lemon-tui && npm test -- --run src/agent-connection.test.ts`,
   covering one hundred six tests with zero failures, plus typecheck and build.

### Slice 147: Web run-detail learning events

1. Web run details now classify skill, memory, and missed-learning
   introspection events into `learning_events`.
2. `/ops/runs/:run_id` renders those events in a dedicated Learning Events
   panel so operators can inspect skill loads/writes, memory searches/topics,
   and missed learning audits without digging through the full timeline.
3. Added focused Web coverage with `skill_load_observed` and
   `memory_search_completed` events for the selected run.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-one tests with zero failures.

### Slice 148: Web run-detail channel events

1. Web run details now classify Telegram-, Discord-, and channel-shaped
   introspection events into `channel_events`.
2. `/ops/runs/:run_id` renders those events in a dedicated Channel Events panel
   so operators can inspect messaging ingress/delivery behavior without digging
   through the full timeline.
3. Added focused Web coverage with a Telegram-shaped
   `channel_message_received` event for the selected run.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-one tests with zero failures.

### Slice 149: Web run-detail cron events

1. Web run details now classify cron, heartbeat, and scheduled-run
   introspection events into `cron_events`.
2. `/ops/runs/:run_id` renders those events in a dedicated Cron Events panel so
   operators can inspect scheduled execution lifecycle behavior without digging
   through the full timeline.
3. Added focused Web coverage with a `cron_run_completed` event for the
   selected run.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-one tests with zero failures.

### Slice 150: Web run-detail subagent events

1. Web run details now classify `agent`/`task` tool events plus
   delegation-shaped introspection into `subagent_events`.
2. `/ops/runs/:run_id` renders those events in a dedicated Subagent Events
   panel beside the existing child-run graph.
3. Added focused Web coverage with an `agent` tool completion carrying task and
   child-run metadata for the selected run.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-one tests with zero failures.

### Slice 151: Discord free-response intent drift diagnostics

1. Doctor channel checks now inspect sanitized latest-check reason kinds as well
   as proof-level reason-kind counts.
2. `channels.discord.free_response` now distinguishes a missing local Message
   Content Intent declaration from proof artifacts that still report Message
   Content Intent or unmentioned-message delivery drift after the declaration is
   present.
3. The live Discord proof writer and proof diagnostics now classify explicit
   `message_content_intent_declared=false` hints before generic unmentioned
   no-reply hints.
4. Added focused doctor/support regressions that keep the checks redacted while
   surfacing Developer Portal/runtime restart remediation.
5. Focused doctor/support validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs --seed 1`,
   covering twenty-seven tests with zero failures; `python3 -m py_compile
   scripts/live_discord_matrix.py` also passed.

### Slice 152: Web free-response drift drilldown

1. Web `/ops` channel drilldown now counts
   `discord_message_content_intent_or_delivery` alongside the legacy
   unmentioned-message no-reply reason.
2. The Discord free-response row now shows Message Content Intent/delivery
   failures in its evidence string and chooses Developer Portal/runtime restart
   remediation when proof drift remains after local declaration.
3. Added focused Web coverage with a redacted failed Discord live-matrix proof
   artifact so the dashboard contract stays aligned with doctor and support
   bundles.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-two tests with zero failures; subagent compile validation
   also passed with `mix compile --warnings-as-errors`.

### Slice 153: Web Discord intent config controls

1. Web `/ops` now exposes Discord access config beside Telegram access config,
   including token-secret reference, guild/channel allowlists, deny-unbound
   policy, and the local Message Content Intent declaration.
2. `LemonWeb.OpsDashboard.update_channel_discord_config/1` writes
   `gateway.discord` through the existing TOML patch/reload path, so operators
   can record the local side of the Developer Portal intent change without
   hand-editing config.
3. Focused Web coverage updates the config fixture and asserts the rendered
   snapshot sees Discord allowlists, deny-unbound policy, and
   `message_content_intent_enabled`.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-two tests with zero failures.

### Slice 154: Slash client-click proof reason kinds

1. `scripts/live_discord_matrix.py --check-slash-client-click-proof` now emits
   stable reason kinds for missing, invalid, and non-promotable client-click
   proof artifacts.
2. Sanitized proof output preserves those reason kinds, letting
   `ProofDiagnostics`, support bundles, doctor, and Web `/ops` distinguish the
   operator's exact next step instead of collapsing everything into a generic
   failed proof.
3. `channels.discord.slash_client_click` now reports a specific missing-artifact
   message and includes a `--proof-path` remediation command when the latest
   check says no client-click artifact has been captured.
4. Focused doctor validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering twenty-six tests with zero failures. Python compile passed, and a
   no-credential missing-artifact proof check exited with `rc=1` while writing
   sanitized `discord_slash_client_click_missing` evidence.

### Slice 155: Web provider-media proof commands

1. Web `/ops` provider-backed media proof rows now expose copy-ready
   live-credential commands for image, TTS, STT, vision, and video proof runs.
2. Each row includes the default `.lemon/proofs/media-*-smoke-latest.json`
   proof path, current reason kind when present, proof status, model, and the
   existing per-provider next action.
3. This keeps provider-backed launch promotion distinct from deterministic
   `--local` media smoke artifacts while giving operators the exact command to
   run after credentials and quota are available.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-two tests with zero failures; `mix compile
   --warnings-as-errors` also passed.

### Slice 156: Slash client-click missing proof artifact

1. Ran the local slash client-click artifact validator with the default real
   proof path and redacted proof output path:
   `python3 scripts/live_discord_matrix.py --check-slash-client-click-proof --slash-client-click-proof-path .lemon/proofs/discord-slash-client-click-proof-latest.json --proof-path .lemon/proofs/discord-slash-client-click-check-latest.json --result-path tmp/discord-slash-client-click-proof-check.json`.
2. The command exited with `rc=1` as expected because no real Discord
   client-click proof artifact exists yet, but it wrote sanitized failed proof
   evidence with `discord_slash_client_click_missing` at proof and check level.
3. `mix lemon.doctor --verbose` now reports `channels.discord.slash_client_click`
   as "proof artifact has not been captured yet" and includes the redacted
   `--proof-path` rerun command.
4. `LemonCore.Doctor.ProofDiagnostics.status(project_dir: File.cwd!())` now
   reports 211 valid proof artifacts, 129 completed, 27 failed, 33 skipped, 22
   unknown, 0 invalid, and one
   `discord_slash_client_click_missing` reason-kind count.

### Slice 157: Web slash client-click missing proof drilldown

1. Web `/ops` channel failure drilldown now reads the latest
   `discord_slash_client_click_proof_artifact` reason kind from
   `ProofDiagnostics.latest_checks`.
2. The Discord slash client-click row distinguishes missing, invalid, and
   non-promotable client-click proof artifacts instead of using the generic
   "run a real proof" action for every failure.
3. Missing-artifact state now keeps the row in `needs_proof`, reports
   classified missing proof evidence, and shows the same redacted
   `--proof-path .lemon/proofs/discord-slash-client-click-check-latest.json`
   remediation command that doctor emits.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-three tests with zero failures.

### Slice 158: Doctor provider-media proof commands

1. `LemonCore.Doctor.Checks.Media` now stores the default redacted proof path
   for each provider-backed media lane: image, TTS, STT, vision, and video.
2. `media.provider_live` remediation now emits copy-ready
   `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run ... --proof-path
   .lemon/proofs/media-*-smoke-latest.json` commands for incomplete providers.
3. This aligns `mix lemon.doctor --verbose`, Web `/ops`, the release
   checklist, and the final readiness audit next-step output, so operators do
   not need to infer proof artifact locations.
4. The same release/audit handoff now includes the redacted slash client-click
   check `--proof-path`, matching the doctor/Web slash remediation.
5. Focused doctor validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering twenty-six tests with zero failures. Compile with warnings as
   errors also passed.

### Slice 159: CI docs lint for proof-path handoffs

1. `scripts/lint_ci_docs.sh` now verifies that the final readiness audit and
   release checklist keep the redacted slash client-click proof-check command:
   `--proof-path .lemon/proofs/discord-slash-client-click-check-latest.json`.
2. The same J27 provider-media check now verifies that both handoff surfaces
   keep explicit `--proof-path` arguments for image, TTS, STT, vision, and
   video provider-backed smoke commands.
3. This prevents future docs/audit drift where doctor and Web `/ops` have
   copy-ready proof commands but release handoff text silently drops the
   redacted proof artifact locations.
4. Validation passed with `scripts/lint_ci_docs.sh`, `bash -n
   scripts/audit_1_0_readiness`, `xmllint --html --noout
   docs/plans/lemon-hermes-progress.html`, and `git diff --check`.

### Slice 160: Provider detail-array description normalization

1. `Ai.Error.parse_http_error/3` now extracts provider messages from
   FastAPI/Pydantic-style `detail` arrays whose entries expose
   `error_description` or `error_message` rather than `message`, `msg`, or
   `reason`, and from JSON:API-style `errors[].detail` arrays.
2. This keeps OpenAI-compatible proxies and OAuth-adjacent provider gateways
   from collapsing actionable upstream errors into generic invalid-request
   messages.
3. Added focused `Ai.ErrorEdgeCasesTest` coverage for detail-array
   `error_description` and JSON:API-style `errors[].detail` plus documentation in `apps/ai/README.md` and
   `apps/ai/AGENTS.md`.
4. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering ninety-six tests with zero failures.

### Slice 161: Discord finalized long-text chunking

1. `LemonChannels.Adapters.Discord.Renderer` now splits finalized long Discord
   text at the safe 1,900-character outbound size before delivery.
2. When an answer message already exists, the renderer edits that message with
   the first chunk and uses `PresentationState` to enqueue ordered follow-up
   chunks that preserve the original reply target.
3. Streaming snapshots and tool-status snapshots are truncated to one editable
   message so progressive updates do not create repeated overflow follow-ups.
4. Repeated identical `stream_finalize`/`final_text` deliveries are suppressed
   when a newer sequence replays the same final answer, matching Telegram's
   final idempotency behavior and avoiding redundant Discord edits or
   generated-file auto-send attempts.
5. Focused Discord renderer validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/adapters/discord/renderer_test.exs --seed 1`,
   covering eleven tests with zero failures.

### Slice 162: File-sensitive channel final idempotency

1. Telegram and Discord semantic renderers now include normalized
   `auto_send_files` metadata in the final-message idempotency hash.
2. Same-text final replays still suppress redundant edits and duplicate
   generated-file sends when the attachment set is unchanged.
3. A later final delivery with the same text but newly attached files now
   reaches the edit/file path instead of being mistaken for a duplicate text
   replay.
4. Focused Telegram/Discord renderer validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/adapters/discord/renderer_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/renderer_test.exs --seed 1`,
   covering twenty-eight tests with zero failures.

### Slice 163: JSON:API title and nested validation error normalization

1. `Ai.Error.parse_http_error/3` now extracts provider messages from
   JSON:API-style `errors` arrays whose entries expose `title` without
   `detail`.
2. Validation-style `detail` arrays that wrap a nested `error` object now unwrap
   that object through the shared nested provider-message search before falling
   back to inspected map text.
3. This keeps OpenAI-compatible proxies, OAuth-adjacent gateways, and typed
   validation layers from collapsing actionable provider text into generic
   invalid-request messages when they use `title` or nested `error` fields.
4. Added focused `Ai.ErrorEdgeCasesTest` coverage plus documentation in
   `apps/ai/README.md` and `apps/ai/AGENTS.md`.
5. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering ninety-eight tests with zero failures.

### Slice 164: String error code provider message preservation

1. `Ai.Error.parse_http_error/3` now preserves actionable provider text when a
   response body carries a string `error` code beside a sibling `message`,
   `detail`, or `description`.
2. Nested provider `description` fields are now treated like `message`, `msg`,
   `reason`, `detail`, `error_description`, and `error_message`, so they do not
   fall through to inspected map fallback text.
3. This covers OpenAI-compatible proxies and gateway layers that return a short
   symbolic error code plus a separate human-readable explanation.
4. Added focused `Ai.ErrorEdgeCasesTest` coverage plus documentation in
   `apps/ai/README.md` and `apps/ai/AGENTS.md`.
5. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred one tests with zero failures.

### Slice 165: Provider body retry hint normalization

1. `Ai.Error.parse_http_error/3` now reads common JSON body retry hints:
   `retry_after`, `retryAfter`, `retry_after_ms`, and `retryAfterMs`.
2. Body hints are merged into `rate_limit_info.retry_after` for parsed
   rate-limit errors when retry headers are absent.
3. Existing header precedence is preserved: `retry-after`, `retry-after-ms`, and
   `x-ms-retry-after-ms` still win over body hints.
4. Added focused `Ai.ErrorEdgeCasesTest` coverage for second-based body hints,
   millisecond body hints, and header precedence.
5. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred four tests with zero failures.
6. Wider AI error validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering two hundred ninety-one tests with zero failures.

### Slice 166: Router tool failure exception metadata

1. `LemonRouter.ToolStatusCoalescer` now preserves safe `exception` metadata
   from completed tool action `detail.result_meta` entries when building
   `body.tool_failures`.
2. This closes another cross-layer lifecycle gap: AgentCore tool results can
   carry exception class/name metadata through LemonRunner action completions,
   gateway action maps, RunProcess session broadcasts, and now final
   channel-facing status intents.
3. Extended the existing RunProcess cross-layer regression so session
   subscribers still see the full `result_meta` and the flushed
   `:tool_status_snapshot` intent exposes `exception` beside `error_type`,
   `tool_name`, `timeout_ms`, and `message`.
4. Updated `apps/lemon_router/README.md` and `apps/lemon_router/AGENTS.md` to
   document the safe failure-summary fields.
5. Focused router validation passed with
   `MIX_ENV=test mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs apps/lemon_router/test/lemon_router/run_process_test.exs:751 --seed 1`,
   covering twenty-two tests with zero failures.

### Slice 167: Command exit metadata through status surfaces

1. `CodingAgent.CliRunners.LemonRunner` now converts nonzero `bash`
   `AgentToolResult.details.exit_code` values into structured
   `action.detail.result_meta` with `error_type: :command_exit`, `tool_name`,
   `exit_code`, and a safe message.
2. `LemonRouter.ToolStatusCoalescer` now includes safe `exit_code` metadata in
   channel/operator-facing `body.tool_failures` summaries.
3. This closes another lifecycle gap: command failures no longer require UI,
   channel, or support-bundle consumers to parse terminal text to distinguish
   command-exit failures from provider/tool crashes.
4. Extended the LemonRunner nonzero bash regression and router failure-summary
   regression to lock the metadata shape.
5. Updated coding-agent and router docs so the command-exit field is part of
   the documented failure metadata contract.
6. Focused validation passed with
   `MIX_ENV=test mix test apps/coding_agent/test/coding_agent/cli_runners/lemon_runner_test.exs apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs apps/lemon_router/test/lemon_router/run_process_test.exs:751 --seed 1`,
   covering one hundred twenty-one tests with zero failures. Compile, HTML
   parse, docs lint, diff whitespace, and doctor readiness checks also passed;
   doctor remains at twenty-three passed, four warnings, zero failed, and two
   skipped.

### Slice 168: Tool-reported exit code metadata

1. `CodingAgent.CliRunners.LemonRunner` now also preserves `exit_code` when a
   tool result already carries structured failure metadata with an `error_type`.
2. This keeps explicit tool failures and synthesized nonzero command failures
   on the same safe metadata contract: downstream status surfaces can use
   `result_meta.exit_code` without caring whether LemonRunner synthesized the
   command-exit shape or passed through a tool's own structured failure.
3. Extended the untracked-completion regression to prove existing structured
   failure metadata retains both `timeout_ms` and `exit_code`.
4. Updated coding-agent docs to document both tool-reported exit codes and
   synthesized nonzero `bash` command-exit metadata.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/coding_agent/test/coding_agent/cli_runners/lemon_runner_test.exs apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs apps/lemon_router/test/lemon_router/run_process_test.exs:751 --seed 1`,
   covering one hundred twenty-one tests with zero failures. Compile with
   warnings as errors, HTML parse, docs lint, diff whitespace, and doctor
   readiness checks also passed; doctor remains at twenty-three passed, four
   warnings, zero failed, and two skipped.

### Slice 169: Exit-code metadata boundary contracts

1. `LemonGateway.Engines.CliAdapter` and `LemonGateway.Run` regressions now
   explicitly carry `result_meta.exit_code` through AgentCore action events and
   gateway bus `:engine_action` payloads.
2. `LemonControlPlane.EventBridge` regressions now explicitly preserve
   `result_meta.exit_code` inside WebSocket `agent` `tool_use` events.
3. This locks the cross-layer contract for both synthesized command-exit
   failures and tool-reported structured failures from LemonRunner through
   gateway, router, and operator clients.
4. Updated gateway and control-plane docs to name `exit_code` as part of the
   safe nested `result_meta` failure metadata surface.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_gateway/test/cli_adapter_test.exs:39 apps/lemon_gateway/test/run_test.exs:709 apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs:166 --seed 1`,
   covering three focused tests with zero failures. Compile with warnings as
   errors, HTML parse, docs lint, diff whitespace, and doctor readiness checks
   also passed; doctor remains at twenty-three passed, four warnings, zero
   failed, and two skipped.

### Slice 170: Symbolic provider error nested detail messages

1. `Ai.Error.extract_provider_message/1` now preserves nested actionable text
   when a provider returns an error map with a top-level symbolic `type` or
   `code` and places the human-readable message under nested `details`.
2. This covers another OpenAI-compatible proxy shape where previous behavior
   could return only `invalid_request_error` while dropping the message that
   tells the operator what request format or model capability failed.
3. Added focused `Ai.ErrorEdgeCasesTest` coverage for symbolic error maps with
   nested `details.message`.
4. Updated `apps/ai/README.md` and `apps/ai/AGENTS.md` so the documented
   provider-message contract includes this shape.
5. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred five tests with zero failures. Wider AI error
   validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering two hundred ninety-two tests with zero failures. Compile with
   warnings as errors, HTML parse, docs lint, diff whitespace, and doctor
   readiness checks also passed; doctor remains at twenty-three passed, four
   warnings, zero failed, and two skipped.

### Slice 171: Placeholder provider message nested details

1. `Ai.Error.extract_provider_message/1` now treats blank top-level provider
   `error.message` values as placeholders when nested actionable details are
   present.
2. Truly empty provider messages still preserve the empty message, but
   OpenAI-compatible proxy bodies such as `%{"error" => %{"message" => "",
   "details" => %{"message" => "..."}}}` now surface the nested explanation.
3. Added focused edge-case coverage for empty top-level messages with nested
   `details.message`.
4. Updated `apps/ai/README.md` and `apps/ai/AGENTS.md` to document the
   placeholder-empty provider-message behavior.
5. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred six tests with zero failures. Wider AI error validation
   passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering two hundred ninety-three tests with zero failures. Compile with
   warnings as errors, HTML parse, docs lint, diff whitespace, and doctor
   readiness checks also passed; doctor remains at twenty-three passed, four
   warnings, zero failed, and two skipped.

### Slice 172: Symbolic provider error prefixes

1. `Ai.Error.extract_provider_message/1` now preserves symbolic provider
   `type` and string `code` prefixes before direct `error.message` values
   instead of letting the generic message extractor shadow those clauses.
2. Placeholder-empty top-level messages still defer to nested `details.message`,
   but symbolic error maps now surface both the provider category and the
   nested explanation.
3. Added focused `Ai.ErrorEdgeCasesTest` coverage for direct symbolic `type`
   and string `code` messages, and updated the placeholder nested-detail
   regression to expect the preserved provider category prefix.
4. Updated `apps/ai/README.md` and `apps/ai/AGENTS.md` so the provider-message
   contract documents symbolic prefixes with direct or nested effective
   messages.
5. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred eight tests with zero failures. Wider AI error
   validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering two hundred ninety-five tests with zero failures. Compile with
   warnings as errors, HTML parse, docs lint, diff whitespace, and doctor
   readiness checks also passed; doctor remains at twenty-three passed, four
   warnings, zero failed, and two skipped.

### Slice 173: Atom-key provider error body normalization

1. `Ai.Error.parse_http_error/3` now normalizes atom-key Elixir maps at the
   parse boundary before provider-message extraction, classification, or body
   retry-hint parsing.
2. Recursive normalization preserves nested string values as strings, so retry
   hints such as `"2.5"` stay parseable instead of being JSON-decoded as nested
   numeric values.
3. Added focused `Ai.ErrorEdgeCasesTest` coverage for atom-key symbolic error
   maps, placeholder nested details, detail arrays, and retry body hints.
4. Updated `apps/ai/README.md` and `apps/ai/AGENTS.md` so atom-key Elixir maps
   are part of the documented provider-message normalization contract.
5. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred twelve tests with zero failures. Wider AI error
   validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering two hundred ninety-nine tests with zero failures. Compile with
   warnings as errors, HTML parse, docs lint, diff whitespace, and doctor
   readiness checks also passed; doctor remains at twenty-three passed, four
   warnings, zero failed, and two skipped.

### Slice 174: Atom-key context-length helper detection

1. `Ai.Error.context_length_error?/1` now normalizes map bodies before checking
   provider context-length `code`, `type`, or message text.
2. This keeps direct helper checks consistent with the `parse_http_error/3`
   path after Slice 173 moved atom-key normalization to the parse boundary.
3. Added focused `Ai.ErrorEdgeCasesTest` coverage for atom-key
   `context_length_exceeded` codes and atom-key maximum-context message text.
4. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred thirteen tests with zero failures. Wider AI error
   validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering three hundred tests with zero failures. Compile with warnings as
   errors, HTML parse, docs lint, diff whitespace, and doctor readiness checks
   also passed; doctor remains at twenty-three passed, four warnings, zero
   failed, and two skipped.

### Slice 175: Atom enum provider value normalization

1. `Ai.Error.parse_http_error/3` now converts non-boolean, non-nil atom values
   inside provider error maps into strings during recursive body
   normalization.
2. This lets symbolic provider enum values such as
   `:context_length_exceeded` and `:rate_limit_error` classify the same way as
   decoded JSON string values, while preserving `nil`, `true`, and `false`.
3. `Ai.Error.context_length_error?/1` gets the same benefit for direct
   `{:http_error, status, map}` helper checks.
4. Added focused `Ai.ErrorEdgeCasesTest` coverage for atom enum
   context-length and rate-limit values.
5. Updated `apps/ai/README.md` and `apps/ai/AGENTS.md` so atom enum provider
   values are part of the documented normalization contract.
6. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred fifteen tests with zero failures. Wider AI error
   validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering three hundred two tests with zero failures. Compile with warnings
   as errors, HTML parse, docs lint, diff whitespace, and doctor readiness
   checks also passed; doctor remains at twenty-three passed, four warnings,
   zero failed, and two skipped.

### Slice 176: Provider-body rate-limit helper detection

1. `Ai.Error.rate_limit_error?/1` now routes non-429
   `{:http_error, status, body}` tuples through `parse_http_error/3` before
   answering.
2. This keeps direct helper checks consistent with parsed provider-body
   classifications for non-429 rate-limit signals such as `rate_limit_error`
   types and "Too many requests" messages.
3. Added focused `Ai.ErrorEdgeCasesTest` coverage for non-429 provider-body
   rate-limit tuples, including atom-key maps.
4. Focused AI validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering one hundred sixteen tests with zero failures. Wider AI error
   validation passed with
   `MIX_ENV=test mix test apps/ai/test/ai/error_test.exs apps/ai/test/ai/error_extended_test.exs apps/ai/test/ai/error_provider_test.exs apps/ai/test/ai/error_edge_cases_test.exs --seed 1`,
   covering three hundred three tests with zero failures. Compile with
   warnings as errors, HTML parse, docs lint, diff whitespace, and doctor
   readiness checks also passed; doctor remains at twenty-three passed, four
   warnings, zero failed, and two skipped.

### Slice 177: Hermes-style final-answer MEDIA directive delivery

1. `LemonRouter.RunProcess.ArtifactTracker.finalize_meta/2` now accepts the
   completed answer text and turns line-start `MEDIA:<path>` directives into
   explicit `auto_send_files` entries.
2. Directive paths use the same completion-time safety boundary as explicit
   file-send requests: they must resolve to existing regular files and stay
   inside the run `cwd`, including symlink escape checks.
3. `RunProcess` passes the completed answer to artifact finalization and strips
   host-visible `MEDIA:` lines from the channel-facing final text after
   extracting attachments, so Telegram and Discord receive normal text plus
   real file attachments rather than leaking local path directives.
4. A stale Telegram stream finalization assertion now matches the renderer's
   current final hash contract, which includes the final-file signature in the
   idempotency hash even when no files are attached.
5. Focused router validation passed with
   `MIX_ENV=test mix test apps/lemon_router/test/lemon_router/artifact_tracker_test.exs --seed 1`,
   covering eleven tests with zero failures, and
   `MIX_ENV=test mix test apps/lemon_router/test/lemon_router/run_process_test.exs --seed 1`,
   covering forty-seven tests with zero failures. The stale stream hash focused
   check passed with
   `MIX_ENV=test mix test apps/lemon_router/test/lemon_router/stream_coalescer_test.exs:822 --seed 1`.
   Widened router media validation passed with
   `MIX_ENV=test mix test apps/lemon_router/test/lemon_router/artifact_tracker_test.exs apps/lemon_router/test/lemon_router/run_process_test.exs apps/lemon_router/test/lemon_router/stream_coalescer_test.exs --seed 1`,
   covering ninety-five tests with zero failures. Compile with warnings as
   errors, HTML parse, docs lint, diff whitespace, and doctor readiness checks
   also passed; doctor remains at twenty-three passed, four warnings, zero
   failed, and two skipped.

### Slice 178: Live MEDIA directive proof harnesses

1. `scripts/live_telegram_matrix.py` now supports
   `--topic-media-directive-delivery` and `--media-directive-topic-id`.
2. The Telegram proof asks Lemon to create a project-local text file and finish
   with a final-answer `MEDIA:<path>` directive. It requires a marker reply, a
   Telegram document whose filename includes the proof nonce, topic scoping, and
   no leaked `MEDIA:` line in the channel-facing text.
3. `scripts/live_discord_matrix.py` now supports
   `--wait-media-directive-delivery`.
4. The Discord proof asks for the same project-local-file plus final-answer
   directive path and validates marker text, matching attachment, and no leaked
   `MEDIA:` directive in bot-authored message content.
5. Sanitized proof coverage now includes `contains_media_directive`; the
   Telegram sanitized check records marker/document/directive-leak status, and
   the Discord sanitized check records attachment count plus directive-leak
   status without raw message bodies or channel identifiers.
6. Validation passed with
   `uv run python -m py_compile scripts/live_telegram_matrix.py scripts/live_discord_matrix.py`,
   `scripts/live_telegram_matrix.py --help >/tmp/lemon-telegram-help.txt`, and
   `scripts/live_discord_matrix.py --help >/tmp/lemon-discord-help.txt`.

### Slice 179: MEDIA directive proof diagnostics

1. `LemonCore.Doctor.ProofDiagnostics` now recognizes Telegram and Discord
   final-answer `MEDIA:<path>` delivery checks as channel media-delivery
   proofs.
2. Redacted proof coverage now carries `contains_media_directive`, and media
   proof summaries expose whether a proof was MEDIA-directive based and whether
   the raw directive leaked into channel-facing text.
3. `mix lemon.doctor` media checks now describe the broader media attachment
   proof lane instead of only generated media/audio proof lanes.
4. `proofs.status` now formats the new coverage and media-proof fields for
   operator surfaces without exposing raw paths, filenames, channel IDs, or
   message bodies.
5. Support-bundle fixtures now include a Discord MEDIA directive proof artifact
   and assert the sanitized proof counts, coverage, and directive-leak status.
6. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`,
   covering eighty-seven tests with zero failures. An initial attempt to run
   those test files as separate concurrent Mix invocations exposed shared
   `_build/test` contention, so the accepted signal is the single Mix run.

### Slice 180: Final readiness MEDIA directive gate

1. `scripts/audit_1_0_readiness` now treats Telegram and Discord final-answer
   `MEDIA:<path>` delivery proof as release-blocking evidence before broad
   Hermes-channel/media parity can be claimed.
2. The audit next-step output now prints the exact Telegram
   `--topic-media-directive-delivery` and Discord
   `--wait-media-directive-delivery` commands, including their redacted
   `.lemon/proofs/*media-directive-latest.json` destinations.
3. The audit accepts override paths through
   `LEMON_TELEGRAM_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON` and
   `LEMON_DISCORD_MEDIA_DIRECTIVE_REDACTED_PROOF_JSON`.
4. New audit verification checks require completed redacted proof artifacts
   with `contains_media_directive` coverage, completed platform-specific check
   names, delivered Telegram document or Discord attachment evidence, and
   `marker_seen: true` plus `directive_leaked: false`.
5. `docs/release/release_checklist_and_support_policy.md` now includes the same
   live proof commands and environment variables, and `scripts/lint_ci_docs.sh`
   enforces the audit/docs contract.
6. A read-only review found two gate-quality issues before promotion: missing
   marker status could pass the audit, and the docs lint only proved the MEDIA
   directive verifier existed rather than proving it was invoked. The audit now
   requires `marker_seen: true`, Discord sanitized proof artifacts now emit
   `marker_seen`, and docs lint matches the exact verifier invocation.
7. Validation passed with
   `bash -n scripts/audit_1_0_readiness scripts/lint_ci_docs.sh`,
   `uv run python -m py_compile scripts/live_discord_matrix.py`,
   `scripts/lint_ci_docs.sh`, and `git diff --check`.

### Slice 181: Web ops MEDIA directive proof visibility

1. Web `/ops` proof rows now render `media directive`, `directive leaked`, and
   `marker` fields when recent proof artifacts carry media-delivery metadata.
2. This makes the Slice 179 diagnostics directly visible in the operator page,
   instead of leaving MEDIA directive state only in support bundles and
   `proofs.status`.
3. Added a focused Web snapshot regression that writes a redacted Discord
   `discord_media_directive_delivery` proof artifact and asserts the snapshot
   exposes `media_directive_delivery`, `directive_leaked: false`,
   attachment count, and `contains_media_directive` coverage.
4. `docs/support.md` now explicitly calls out media-directive delivery/leak
   booleans on Web `/ops`.
5. Validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-four tests with zero failures.

### Slice 182: Live Telegram and Discord MEDIA directive proof

1. Restarted the stale worktree-held Lemon runtime and brought up the main
   checkout runtime so the live probes exercised the current MEDIA directive
   implementation.
2. Telegram live proof passed with
   `scripts/live_telegram_matrix.py --skip-dm --skip-topic --topic-media-directive-delivery --media-directive-topic-id 35 --timeout 180 --result-path tmp/telegram-media-directive-proof.json --proof-path .lemon/proofs/telegram-media-directive-latest.json`.
3. The Telegram sanitized proof artifact is completed with
   `proof_object: lemon.telegram_live_matrix`,
   `contains_media_directive: true`,
   `telegram_forum_topic_media_directive_delivery`, `marker_seen: true`,
   `telegram_has_document: true`, and `directive_leaked: false`.
4. Discord live proof passed with
   `scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-token-index 0 --sender-bot-token-index 1 --wait-media-directive-delivery --reset-session-between-checks --timeout 180 --result-path tmp/discord-media-directive-proof.json --proof-path .lemon/proofs/discord-media-directive-latest.json`.
5. The Discord sanitized proof artifact is completed with
   `proof_object: lemon.discord_live_matrix`,
   `contains_media_directive: true`, `discord_media_directive_delivery`,
   `marker_seen: true`, `attachment_count: 1`, and `directive_leaked: false`.
6. The readiness-audit MEDIA directive verifier was exercised directly against
   the current proof artifacts and accepted both Telegram and Discord artifacts
   with zero blockers.

### Slice 183: Provider media proof-path command contract

1. `scripts/live_media_image_smoke.exs`,
   `scripts/live_media_speech_smoke.exs`,
   `scripts/live_media_transcription_smoke.exs`,
   `scripts/live_media_vision_smoke.exs`, and
   `scripts/live_media_video_smoke.exs` now accept `--proof-path PATH` as the
   redacted proof destination used by doctor, Web `/ops`, release-audit, and
   release-checklist copy-ready commands.
2. The existing `--out PATH` flag remains a backward-compatible alias, so old
   automation keeps working while operator-facing proof commands stop
   depending on an undocumented flag.
3. `docs/testing.md` and `docs/tools/media.md` now show explicit provider
   smoke commands with `.lemon/proofs/media-*-smoke-latest.json` proof paths,
   keeping the docs aligned with `scripts/audit_1_0_readiness`,
   `scripts/lint_ci_docs.sh`, doctor remediation, and Web `/ops`.
4. Validation passed by running all five media smoke scripts with
   `--proof-path tmp/media-*-proof-path-alias.json` and no live credential gate,
   verifying each wrote a redacted skipped proof with `failed_count: 0`.

### Slice 184: Provider media secret-name proof overrides

1. The five provider media smoke scripts now accept
   `--api-key-secret SECRET_NAME` in addition to `--api-key-env ENV_NAME`.
2. The override resolves through `LemonAiRuntime.resolve_secret_api_key/1`, so
   release-candidate operators can run one-off provider-media proofs against
   the encrypted Lemon secret store without editing config files or exporting
   raw API keys into the shell environment.
3. Environment-variable overrides still take precedence when both flags are
   present, preserving the existing explicit-env behavior.
4. Doctor remediation and `docs/support.md` now call out the secret-name path,
   while `docs/testing.md` and `docs/tools/media.md` document that override
   secret names and raw values are not written into the redacted proof JSON.
5. Focused doctor validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering twenty-seven tests with zero failures.
6. Validation passed by running all five provider media smoke scripts with
   `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1`, `--proof-path
   tmp/media-*-secret-alias.json`, and a missing `--api-key-secret`, verifying
   each wrote a redacted skipped proof with `failed_count: 0` and no raw API-key
   cleanup flags.

### Slice 185: Web ops provider-media secret proof command

1. Web `/ops` provider-media proof summaries now include `secret_command`
   alongside the existing `command`, preserving the environment-variable proof
   path while exposing the encrypted-secret one-step command to operators.
2. The LiveView provider proof cards render both copy-ready commands for each
   provider row, so the dashboard no longer requires an operator to combine
   doctor or docs guidance with Web state manually.
3. `apps/lemon_web/AGENTS.md` now records the expectation that `/ops`
   provider-media rows keep the secret-backed variant visible.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-four tests with zero failures.

### Slice 186: Final readiness secret-backed provider-media handoff

1. `scripts/audit_1_0_readiness` now prints a provider-media proof note telling
   operators to append `--api-key-secret SECRET_NAME` when provider keys live in
   Lemon's encrypted secret store.
2. `docs/release/release_checklist_and_support_policy.md` mirrors that note in
   the provider-backed media release checklist, so final release handoff,
   doctor, Web `/ops`, and support docs describe the same raw-key-free path.
3. `scripts/lint_ci_docs.sh` now enforces the presence of the secret-backed
   provider-media handoff in both the readiness audit and release checklist.
4. Validation passed with
   `bash -n scripts/audit_1_0_readiness scripts/lint_ci_docs.sh` and
   `scripts/lint_ci_docs.sh`.

### Slice 187: Terminal backend doctor readiness gate

1. `mix lemon.doctor --verbose` now reports `terminal.backends_live` from the
   redacted proof rows emitted by `scripts/live_terminal_backend_smoke.exs` and
   exposed through `ProofDiagnostics`.
2. The doctor check passes only when the latest proof has completed rows for
   the local, local PTY, Docker, and SSH preview backends, warns on failed or
   missing rows, and skips when no terminal backend proof has been generated.
3. The remediation points operators to
   `MIX_ENV=test mix run scripts/live_terminal_backend_smoke.exs` and the
   canonical `.lemon/proofs/terminal-backend-latest.json` artifact without
   exposing command text, environment values, process output, raw SSH targets,
   or raw proof paths.
4. `docs/testing.md`, `docs/support.md`,
   `docs/release/release_checklist_and_support_policy.md`, the mainstream
   readiness plan, and the Hermes feature matrix now mention the doctor gate so
   terminal backend preview support has the same code, proof, support, and
   release-checklist surface.
5. Focused doctor validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering thirty-one tests with zero failures.

### Slice 188: Final readiness terminal backend proof gate

1. `scripts/audit_1_0_readiness` now treats terminal backend proof as a final
   release evidence item before terminal support can be promoted beyond preview.
2. The audit validates `.lemon/proofs/terminal-backend-latest.json` by default
   or `LEMON_TERMINAL_BACKEND_PROOF_JSON` when evidence lives elsewhere.
3. The verifier requires completed proof status, `failed_count: 0`, completed
   result rows for `local`, `local_pty`, `docker`, and `ssh`, plus safe cleanup
   flags for command text, environment values, and process output.
4. The release checklist now documents the same final-audit environment
   override, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep terminal backend proof requirements wired.

### Slice 189: OpenAI-compatible API doctor proof gate

1. `LemonCore.Doctor.ProofDiagnostics` now classifies
   `scripts/live_openai_compat_smoke.exs` result-row artifacts as completed
   proof artifacts, infers `openai_compat_api` proof scope, and exposes
   `openai_compat_*` latest-check rows from the redacted result names.
2. `mix lemon.doctor --verbose` now reports `openai_compat.api_preview`,
   passing only when the local `/v1` smoke has completed all fourteen preview
   rows: health/capabilities, Chat Completions wait/stream, Responses
   continuation/storage, image metadata/pass-through/rejection/policy, run
   status redaction, cancellation, external fetch, OpenAI Node SDK, and OpenAI
   Python SDK clients.
3. The check skips when no local proof exists and warns on failed or missing
   rows, with remediation pointing to
   `MIX_ENV=test mix run scripts/live_openai_compat_smoke.exs`.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering thirty-five tests with zero failures.

### Slice 190: Final readiness OpenAI-compatible API proof gate

1. `scripts/audit_1_0_readiness` now treats the local OpenAI-compatible `/v1`
   smoke proof as final release evidence before API preview support can be
   promoted.
2. The audit validates `.lemon/proofs/openai-compat-smoke-latest.json` by
   default or `LEMON_OPENAI_COMPAT_PROOF_JSON` when release evidence lives
   elsewhere.
3. The verifier requires `completed_count: 14`, `failed_count: 0`, completed
   rows for health/capabilities, Chat Completions wait/stream, Responses
   continuation/storage, image metadata/pass-through/rejection/policy, run
   status redaction, cancellation, external fetch, OpenAI Node SDK, and OpenAI
   Python SDK clients, plus cleanup flags excluding raw prompts, API keys,
   answers, and run events.
4. The release checklist now documents the same final-audit environment
   override, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep OpenAI-compatible API proof requirements wired.

### Slice 191: ACP doctor proof gate

1. `LemonCore.Doctor.ProofDiagnostics` now classifies ACP stdio proof artifacts
   by their `object` field, infers `acp_stdio`, `acp_stdio_external_client`,
   and `acp_official_sdk_client` proof scopes, and exposes `acp_stdio_*`,
   `acp_stdio_external_*`, and `acp_official_sdk_*` latest-check rows from the
   redacted result names.
2. `mix lemon.doctor --verbose` now reports `acp.preview`, passing only when
   the deterministic stdio smoke, external Node stdio client proof, and official
   ACP SDK client proof are all complete.
3. The check skips when no ACP proof exists and warns on failed or missing
   proof artifacts, with remediation pointing to
   `MIX_ENV=test mix run scripts/live_acp_stdio_smoke.exs`,
   `node scripts/live_acp_stdio_external_client.mjs`, and
   `node scripts/live_acp_official_sdk_client.mjs`.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering thirty-nine tests with zero failures.

### Slice 192: Final readiness ACP proof gate

1. `scripts/audit_1_0_readiness` now treats ACP preview proof as final release
   evidence before ACP support can be promoted.
2. The audit validates `.lemon/proofs/acp-stdio-smoke-latest.json`,
   `.lemon/proofs/acp-stdio-external-client-latest.json`, and
   `.lemon/proofs/acp-official-sdk-client-latest.json` by default, or
   `LEMON_ACP_STDIO_PROOF_JSON`, `LEMON_ACP_EXTERNAL_CLIENT_PROOF_JSON`, and
   `LEMON_ACP_OFFICIAL_SDK_PROOF_JSON` when release evidence lives elsewhere.
3. The verifier requires the expected proof object, completed rows, zero
   failures, update/client-request counts for the client proofs, and cleanup
   flags excluding raw prompts, API keys, answers, events, session ids, child
   stderr, file contents, and file paths.
4. The release checklist now documents the same final-audit environment
   overrides, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep ACP proof requirements wired.

### Slice 193: MCP doctor proof gate

1. `LemonCore.Doctor.ProofDiagnostics` now classifies MCP smoke artifacts into
   `mcp_stdio`, `mcp_http`, and `mcp_sse` proof scopes while continuing to use
   the existing `proof: "mcp_*_smoke"` artifact shape.
2. `mix lemon.doctor --verbose` now reports `mcp.preview`, passing only when
   the stdio, Streamable HTTP, and legacy SSE proof artifacts are complete with
   their expected redacted check rows.
3. The check skips when no MCP proof exists and warns on failed or missing
   proof artifacts, with remediation pointing to
   `MIX_ENV=test mix run scripts/live_mcp_stdio_smoke.exs`,
   `MIX_ENV=test mix run scripts/live_mcp_http_smoke.exs`, and
   `MIX_ENV=test mix run scripts/live_mcp_sse_smoke.exs`.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering forty-three tests with zero failures.

### Slice 194: Final readiness MCP proof gate

1. `scripts/audit_1_0_readiness` now treats MCP preview proof as final release
   evidence before MCP support can be promoted.
2. The audit validates `.lemon/proofs/mcp-stdio-latest.json`,
   `.lemon/proofs/mcp-http-latest.json`, and
   `.lemon/proofs/mcp-sse-latest.json` by default, or
   `LEMON_MCP_STDIO_PROOF_JSON`, `LEMON_MCP_HTTP_PROOF_JSON`, and
   `LEMON_MCP_SSE_PROOF_JSON` when release evidence lives elsewhere.
3. The verifier requires the expected proof name, completed status,
   completed rows, zero failures, zero skips, and cleanup flags excluding raw
   paths, filenames, prompts, provider responses, tool arguments, tool results,
   and server IO.
4. The release checklist now documents the same final-audit environment
   overrides, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep MCP proof requirements wired.

### Slice 195: Final readiness extension and WASM proof gate

1. `scripts/audit_1_0_readiness` now treats extension host, WASM telemetry,
   WASM policy, extension registry audit, and WASM lifecycle proofs as final
   release evidence before plugin/extension preview support can be promoted.
2. The audit validates `.lemon/proofs/extension-host-smoke-latest.json`,
   `.lemon/proofs/wasm-tool-telemetry-latest.json`,
   `.lemon/proofs/wasm-policy-latest.json`,
   `.lemon/proofs/extension-registry-audit-latest.json`, and
   `.lemon/proofs/wasm-lifecycle-latest.json` by default, or their
   `LEMON_EXTENSION_HOST_PROOF_JSON`, `LEMON_WASM_TELEMETRY_PROOF_JSON`,
   `LEMON_WASM_POLICY_PROOF_JSON`, `LEMON_EXTENSION_REGISTRY_AUDIT_PROOF_JSON`,
   and `LEMON_WASM_LIFECYCLE_PROOF_JSON` overrides.
3. The verifier requires the expected proof name, completed status, exact
   completed rows, zero failures, zero skips, and proof-specific redaction flags
   excluding raw paths, params, call ids, session ids, tool names, file
   contents, load errors, tool result payloads, sidecar errors, registry paths,
   package names, distribution URLs, manifest contents, and raw cwd.
4. The release checklist now documents the same commands and final-audit
   overrides, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep extension/WASM proof requirements wired.

### Slice 196: LSP doctor proof gate

1. `mix lemon.doctor --verbose` now reports `lsp.preview`, backed by redacted
   LSP project-fixture and real-repo fixture proof artifacts.
2. The check passes only when both proof artifacts complete editor-flow rows
   for Pyright, gopls, clangd, rust-analyzer, TypeScript Language Server, and
   ElixirLS, warns on failed or missing proof artifacts, and skips when no LSP
   proof has been generated.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering forty-seven tests with zero failures.

### Slice 197: Final readiness LSP proof gate

1. `scripts/audit_1_0_readiness` now treats project-fixture and real-repo
   fixture LSP editor-flow proofs as final release evidence before LSP preview
   support can be promoted.
2. The audit validates `.lemon/proofs/lsp-project-fixtures-latest.json` and
   `.lemon/proofs/lsp-real-repo-fixtures-latest.json` by default, or
   `LEMON_LSP_PROJECT_FIXTURES_PROOF_JSON` and
   `LEMON_LSP_REAL_REPO_PROOF_JSON` when release evidence lives elsewhere.
3. The verifier requires completed status, six full-fleet editor-flow rows,
   zero failures, zero skips, and cleanup flags excluding raw paths, file
   contents, diagnostic output, raw session ids, and server IO.
4. The release checklist now documents the same commands and final-audit
   overrides, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep LSP proof requirements wired.

### Slice 198: Browser doctor proof gate

1. `LemonCore.Doctor.ProofDiagnostics` now recognizes the browser live smoke as
   a `browser_smoke` proof scope and exposes only safe browser proof summaries:
   counts, completed feature booleans, tool names, progress counts, and redacted
   cleanup flags.
2. `mix lemon.doctor --verbose` now reports `browser.preview`, passing only when
   the latest browser proof covers local driver execution, CDP attach mode,
   route guardrails, page interaction, upload/download, screenshots, cookies,
   state reset, progress redaction, model-visible screenshots, and
   browser-to-media vision.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering fifty-one tests with zero failures.

### Slice 199: Final readiness browser proof gate

1. `scripts/audit_1_0_readiness` now treats
   `.lemon/proofs/browser-smoke-latest.json` as final release evidence before
   browser preview support can be promoted.
2. The audit accepts `LEMON_BROWSER_PROOF_JSON` when release evidence lives
   elsewhere and validates the same local-driver, CDP attach, route guardrail,
   interaction, upload/download, screenshot, cookie/state, progress-redaction,
   and browser-to-media vision coverage enforced by `browser.preview`.
3. `scripts/live_browser_smoke.exs` now writes standardized `status`, `proof`,
   `proof_scope`, `skipped_count`, `cleanup`, and per-tool completed check rows
   while hashing local project, driver, executable, screenshot, and artifact
   paths in the proof artifact itself.
4. The release checklist now documents the same command and final-audit
   override, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep browser proof requirements wired.

### Slice 200: Cron doctor proof gate

1. `mix lemon.doctor --verbose` now reports `cron.preview`, backed by redacted
   cron diagnostics, runtime restart, and channel-origin proof artifacts.
2. The check passes only when diagnostics rows, full-runtime restart
   persistence rows, and Telegram/Discord-shaped channel-origin delivery rows
   are complete with expected cleanup flags.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering fifty-five tests with zero failures.

### Slice 201: Final readiness cron proof gate

1. `scripts/audit_1_0_readiness` now treats cron diagnostics, runtime restart,
   and channel-origin proof artifacts as final release evidence before cron
   preview support can be promoted.
2. The audit validates `.lemon/proofs/cron-diagnostics-latest.json`,
   `.lemon/proofs/cron-runtime-restart-latest.json`, and
   `.lemon/proofs/cron-channel-origin-latest.json` by default, or
   `LEMON_CRON_DIAGNOSTICS_PROOF_JSON`,
   `LEMON_CRON_RUNTIME_RESTART_PROOF_JSON`, and
   `LEMON_CRON_CHANNEL_ORIGIN_PROOF_JSON` when release evidence lives
   elsewhere.
3. The verifier requires completed status or completed expected check rows,
   exact expected check rows, zero failures, zero skips, and proof-specific
   cleanup flags excluding raw prompts, outputs, errors, session ids, agent ids,
   memory paths, store paths, channel ids, peer ids, cron ids, and meta values.
4. The release checklist now documents the same commands and final-audit
   overrides, and `scripts/lint_ci_docs.sh` enforces that the audit script and
   release checklist keep cron proof requirements wired.

### Slice 202: Secret-backed provider-media proof command fix

1. The five provider-media smoke scripts now opt into the persistent encrypted
   Lemon secret store when `--api-key-secret` is used under `MIX_ENV=test` and
   the script is launched with `mix run --no-start`.
2. Doctor remediation, Web `/ops` provider-media proof commands, release audit
   next steps, release checklist commands, support docs, and testing docs now
   use `MIX_ENV=test mix run --no-start ... --proof-path ...`, so the
   documented secret-backed command can resolve encrypted one-off proof
   credentials before OTP boots.
3. `scripts/lint_ci_docs.sh` now enforces the `mix run --no-start` provider
   media handoff in both the final readiness audit and release checklist.

### Slice 203: Canonical provider vision proof refresh

1. The secret-backed canonical media vision proof passed with
   `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_vision_smoke.exs --model openrouter:openai/gpt-4o-mini --api-key-secret OPENROUTER_API_KEY --proof-path .lemon/proofs/media-vision-smoke-latest.json`.
2. The resulting `.lemon/proofs/media-vision-smoke-latest.json` artifact has
   `proof_object: lemon.media_vision_smoke`, `proof_scope: media_provider`,
   `completed_count: 1`, `failed_count: 0`, `skipped_count: 0`, and a completed
   `media_provider_openai_vision` row with redacted hashes only.
3. `mix lemon.doctor --verbose` now counts provider media as one of five
   completed lanes: vision is proven in this slice. Deepgram STT was later
   promoted as the second completed provider-backed lane, so image, TTS, and
   video remain the explicit launch blockers for broad provider-backed media
   parity.

### Slice 204: Proof-bundle redaction visibility

1. `LemonCore.Doctor.ProofDiagnostics` now preserves proof-level `redaction`
   maps in recent proof summaries alongside existing generic `cleanup` maps.
2. This matters for extension and WASM proof artifacts because their safety
   contract is encoded as redaction flags: raw cwd, session ids, tool names,
   params, paths, manifest contents, distribution URLs, and tool payloads must
   be absent from support surfaces.
3. The support-bundle fixture now asserts that a WASM lifecycle proof exposes
   its redaction flags while keeping `cleanup` empty, so release support
   bundles do not silently drop redaction-only proof evidence.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs --seed 1`,
   covering two tests with zero failures.

### Slice 205: Media provider proof reason visibility

1. `media.provider_live` now carries redacted per-provider `reason_kind`
   labels for failed or skipped image, TTS, STT, vision, and video proof lanes.
2. The doctor message still groups completed, failed, skipped, and missing
   provider lanes, but now adds safe labels such as
   `image=provider_http_error` so operators can distinguish quota,
   credential, endpoint, and API-shape failures without opening raw proof
   responses.
3. Focused doctor coverage now writes a failed image proof with a private
   provider response and asserts the doctor output includes only the safe
   reason kind, not the raw response.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`,
   covering fifty-five tests with zero failures.

### Slice 206: JSON-RPC proof redaction visibility

1. `proofs.status` now formats proof-level `redaction` maps on recent proofs
   instead of dropping the field at the control-plane boundary.
2. External clients can now see the same extension/WASM redaction evidence as
   support bundles: raw cwd, session ids, tool names, params, paths, manifest
   contents, distribution URLs, and tool payloads are reported only as safe
   boolean flags.
3. The control-plane proof-status fixture asserts that
   `wasm_lifecycle_smoke` returns those redaction booleans while keeping
   `cleanup` empty.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`,
   covering fifty-eight tests with zero failures.

### Slice 207: Web ops proof redaction visibility

1. Web `/ops` proof artifact rows now render a compact `redaction:` summary
   whenever recent proof artifacts include a proof-level `redaction` map.
2. This closes the operator-facing visibility gap for extension/WASM artifacts
   whose safety evidence is redaction-only rather than generic cleanup policy.
3. The Web fixture writes a `wasm_lifecycle_smoke` proof containing private
   raw-looking detail fields plus safe redaction booleans, then asserts the
   `/ops` snapshot exposes only the redaction booleans and not the raw fields.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`,
   covering thirty-five tests with zero failures.

### Slice 208: JSON-RPC redaction key normalization

1. The `proofs.status` control-plane formatter now converts proof-level
   redaction keys to lowerCamelCase in JSON-RPC responses.
2. External clients get API-shaped keys such as `containsRawCwd` and
   `containsRawSessionIds`, while support bundles and Web internals can still
   stay close to the source proof artifact vocabulary.
3. The control-plane proof-status fixture now asserts that
   `wasm_lifecycle_smoke` returns lowerCamelCase redaction booleans and does
   not leak the raw snake_case keys into the JSON-RPC response.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`,
   covering fifty-eight tests with zero failures.

### Slice 209: Final readiness provider-media reason diagnostics

1. `scripts/audit_1_0_readiness` now prints bounded `reason_kind` labels when
   provider-backed image, TTS, STT, vision, or video proof artifacts are present
   but incomplete.
2. The audit still blocks incomplete live evidence, but the stderr diagnostics
   now include safe labels such as `credential_preflight_skipped` or
   `openai_tts_http_error` so operators know whether they are looking at
   credentials, quota, endpoint, or API-shape failures.
3. The reason extraction is intentionally narrow: it reads only top-level,
   detail-level, or check-level `reason_kind` fields and redacts labels outside
   a bounded safe-label pattern instead of printing raw provider responses.
4. CI docs lint now guards the final-readiness audit contract for provider-media
   reason diagnostics alongside the existing proof-path and secret-backed
   command checks.

### Slice 210: Final readiness Discord proof reason diagnostics

1. `scripts/audit_1_0_readiness` now prints bounded `reason_kind` labels from
   incomplete Discord DM, free-response, and real slash client-click proof
   artifacts.
2. DM setup refusals, Message Content Intent/free-response delivery blockers,
   invalid slash client-click artifacts, and missing real-click proof can now
   reach final-audit stderr as safe labels instead of only broad prose.
3. The extraction reads only explicit proof/check `reason_kind` fields and
   redacts labels outside the bounded safe-label pattern, preserving the
   existing ban on Discord IDs, interaction tokens, bot tokens, secret names,
   and message bodies in release diagnostics.
4. CI docs lint now guards the Discord final-audit reason-diagnostic contract
   alongside the existing DM/free-response/client-click proof gates.

### Slice 211: Discord message-content runtime intent diagnostics

1. `channel_diagnostics.json` now exposes
   `free_response.runtime_requests_message_content_intent: true` for Discord.
2. This separates Lemon's BEAM/Nostrum runtime behavior from the external
   Discord Developer Portal setting: Lemon requests the gateway intent, while
   `message_content_intent_declared` remains the operator's redacted declaration
   that the privileged app setting was enabled.
3. `mix lemon.doctor` remediation now says the runtime requests
   `message_content`, so remaining free-response blockers are portal drift,
   runtime restart/hot reload, trigger-mode storage, or live unmentioned-message
   delivery.
4. Web `/ops` free-response evidence now includes whether the runtime requests
   the intent, and support/testing/release docs point operators at that
   diagnostic before chasing lower-level Discord routing.

### Slice 212: Provider-media model routing diagnostics

1. The image, TTS, STT, and video provider-media proof scripts now detect
   `provider:model` values before live execution and write a skipped proof with
   `provider_prefixed_model_not_supported_for_media_type`.
2. This avoids accidentally treating the OpenAI-endpoint media tools as generic
   OpenAI-compatible media routing while vision remains the explicitly proven
   provider-prefixed OpenAI-compatible path.
3. Operator docs now say to use media vision for provider-prefixed routing, or
   pass `--base-url` plus an unprefixed provider model when validating compatible
   image/TTS/STT/video endpoints against their OpenAI-shaped proof scripts.
4. CI docs lint guards the four script reason labels and the testing/support
   documentation so this handoff stays visible.

### Slice 213: Multi-provider voice media proof

1. `media_generate_speech` now supports `elevenlabs_tts` on the same
   BEAM-supervised `LemonCore.MediaJobSupervisor` path as local WAV and OpenAI
   TTS, resolving credentials from env, gateway voice config/secrets, or Lemon
   secret names without returning raw text or keys.
2. `media_transcribe_audio` now supports `deepgram_transcribe`, posts project-local
   audio bytes to Deepgram, normalizes the transcript into the existing untrusted
   transcript result shape, and keeps job/support metadata redacted.
3. `scripts/live_media_speech_smoke.exs` and
   `scripts/live_media_transcription_smoke.exs` accept `--provider` for those
   providers and write provider-specific completed/failed check names while
   preserving the existing proof object and cleanup contract.
4. The Deepgram live STT proof passed with
   `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 MIX_ENV=test mix run --no-start scripts/live_media_transcription_smoke.exs --provider deepgram_transcribe --api-key-secret DEEPGRAM_API_KEY --proof-path .lemon/proofs/media-transcription-smoke-latest.json`,
   making provider-backed media 2/5 complete: STT and vision are current, while
   image, TTS, and video remain open.
5. ElevenLabs TTS reached the supervised media worker through
   `ELEVENLABS_API_KEY` but failed with redacted `elevenlabs_tts_http_error`, so
   TTS remains incomplete until usable provider credentials/quota are available.

### Slice 214: Provider media subreason diagnostics

1. `LemonCore.MediaJobWorker` now preserves bounded provider status/type labels
   in `error_kind` when any image, TTS, STT, vision, or video media tool has
   already reduced the provider response to a safe `{:safe_error_kind, label}`
   tuple.
2. Raw provider messages remain hashed only; arbitrary binary error details are
   not appended to `error_kind`.
3. OpenAI-style `error.type` / `error.code` and ElevenLabs-style
   `detail.status` / `detail.type` / `detail.code` response shapes now produce
   actionable labels such as `openai_tts_http_error:invalid_request_error` and
   `elevenlabs_tts_http_error:payment_required`.
4. `scripts/live_media_speech_smoke.exs` now uses the ElevenLabs default voice
   id for `elevenlabs_tts` proof runs instead of OpenAI's `alloy` voice.
5. The canonical ElevenLabs TTS proof now reaches the corrected provider path
   and records `elevenlabs_tts_http_error:payment_required`, so TTS remains
   blocked by provider quota/payment rather than a Lemon routing or voice-shape
   bug.
6. The canonical OpenAI image proof now reaches the provider and records
   `openai_image_http_error:billing_limit_user_error`, so image remains blocked
   by provider billing/quota rather than missing credential wiring.

### Slice 215: Vertex Imagen image-provider lane

1. `media_generate_image` now supports `vertex_imagen` on the same
   `LemonCore.MediaJobSupervisor` path as `local_svg` and `openai_image`.
   It resolves `providers.google_vertex` project, location, and service-account
   JSON through Lemon runtime config/secrets, exchanges the service-account JWT
   for an access token, calls Vertex AI Imagen `:predict`, writes managed
   PNG/JPEG/WebP artifacts, and keeps prompt text out of job/support metadata.
2. `scripts/live_media_image_smoke.exs` now accepts `--provider vertex_imagen`
   and writes the `media_provider_vertex_imagen` proof row. The final readiness
   audit, proof diagnostics, and `media.provider_live` doctor gate all treat
   either `openai_image` or `vertex_imagen` as satisfying the image lane.
3. Google provider `error.status` labels are reduced to safe error suffixes.
   The canonical Vertex proof reaches Google and currently records
   `vertex_imagen_http_error:permission_denied` at
   `.lemon/proofs/media-image-smoke-latest.json`, so image remains blocked by
   provider/project permission rather than Lemon media-worker routing.

### Slice 216: Google Cloud Text-to-Speech provider lane

1. `media_generate_speech` now supports `google_tts` on the same
   `LemonCore.MediaJobSupervisor` path as `local_wav`, `openai_tts`, and
   `elevenlabs_tts`. It resolves the same `providers.google_vertex`
   service-account JSON, exchanges a JWT for a Google access token, calls Cloud
   Text-to-Speech `text:synthesize`, writes managed MP3 artifacts, and keeps raw
   text/audio/provider bodies out of job and support metadata.
2. `scripts/live_media_speech_smoke.exs` now accepts `--provider google_tts`
   and writes the `media_provider_google_tts` proof row. The final readiness
   audit, proof diagnostics, and `media.provider_live` doctor gate all treat
   OpenAI, ElevenLabs, or Google proof as satisfying the TTS lane.
3. The canonical Google TTS proof reaches Cloud Text-to-Speech and currently
   records `google_tts_http_error:permission_denied` at
   `.lemon/proofs/media-speech-smoke-latest.json`, so TTS remains blocked by
   provider/project permission rather than Lemon media-worker routing.

### Slice 217: Web ops grouped media provider proof lanes

1. Web `/ops` media provider-proof readiness now models the five launch lanes
   as provider groups instead of single provider ids. Image can be satisfied by
   `openai_image` or `vertex_imagen`, TTS by `openai_tts`, `elevenlabs_tts`, or
   `google_tts`, and STT by `openai_transcribe` or `deepgram_transcribe`.
2. The `/ops` snapshot still exposes the default copy-ready command and
   `--api-key-secret SECRET_NAME` command for each lane, and now also exposes
   per-provider `--provider` rerun commands for smoke scripts that support
   alternate providers.
3. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   `35 tests, 0 failures`.

### Slice 218: Vertex Veo video-provider lane

1. `media_generate_video` now supports `vertex_veo` on the same
   `LemonCore.MediaJobSupervisor` path as `local_mp4` and `openai_video`.
   It resolves `providers.google_vertex` service-account credentials, exchanges
   a JWT for a Google access token, calls Vertex AI Veo `:predictLongRunning`,
   polls with `:fetchPredictOperation`, writes managed MP4 artifacts when inline
   bytes are returned, and keeps prompt text/provider bodies/operation names out
   of job and support metadata.
2. `scripts/live_media_video_smoke.exs` now accepts `--provider vertex_veo`
   and writes the `media_provider_vertex_veo` proof row. The final readiness
   audit, proof diagnostics, doctor, and Web `/ops` all treat either
   `openai_video` or `vertex_veo` as satisfying the video lane.
3. The canonical Vertex Veo proof reaches Google and currently records
   `vertex_veo_create_http_error:permission_denied` at
   `.lemon/proofs/media-video-smoke-latest.json`, so video remains blocked by
   provider/project permission rather than Lemon media-worker routing.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/coding_agent/test/coding_agent/tools/media_generate_video_test.exs apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   `55 + 7 + 35 tests, 0 failures`.

### Slice 219: Discord free-response live proof promotion

1. Discord free-response routing now handles the real thread-message shape where
   Discord sends `MESSAGE_CREATE` with the thread id as `channel_id` and no
   parent-channel context. `LemonChannels.Adapters.Discord.Transport` falls back
   from `{thread, nil}` to the stored `{thread, thread}` trigger-mode key, which
   matches the live matrix harness setup for per-check public threads.
2. `scripts/live_discord_matrix.py --wait-free-response-trigger` now has a
   Message Content Intent preflight. It reads Discord application flags, compares
   them with Lemon's local `gateway.discord.message_content_intent_enabled`
   declaration, writes redacted preflight evidence on failure, and still allows
   `--skip-free-response-preflight` for diagnostic waits.
3. After verifying Discord application flags and setting the local declaration,
   the live free-response proof passed with the second bot sender:
   `.lemon/proofs/discord-free-response-latest.json` is `completed` with
   `contains_free_response: true`, `message_content_intent_declared: true`,
   trigger mode `all`, cleanup mode `clear`, and no raw token/channel/user/body
   leakage. `mix lemon.doctor --verbose` now reports
   `channels.discord.free_response` as `pass`; Discord DM and real slash
   client-click remain the Discord launch blockers.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1`:
   `17 tests, 0 failures`, plus `python -m py_compile scripts/live_discord_matrix.py`.

### Slice 220: Discord slash client-click wait-mode handoff

1. `scripts/live_discord_matrix.py` now has
   `--wait-slash-client-click-proof`, a live operator handoff mode for the last
   Discord slash promotion gate. It posts a proof request to `--channel-id` when
   provided, recommends a concrete slash command such as `/media status`, polls
   `.lemon/proofs/discord-slash-client-click-proof-latest.json`, and only
   accepts proof artifacts generated after the watcher started.
2. The wait mode reuses the existing redacted
   `lemon.discord_slash_client_click` validator, so missing, invalid,
   non-promotable, and stale proof artifacts surface through stable reason kinds
   and the same sanitized `--proof-path` contract used by doctor, support
   bundles, and Web `/ops`.
3. This does not claim the Discord client-click gate is complete; it closes the
   operational gap between passive runtime recording and the human Discord
   action Discord requires before a real slash interaction can exist.

### Slice 221: Web ops client-click handoff visibility

1. Web `/ops` channel failure drilldown now points missing Discord
   client-click proof directly at
   `scripts/live_discord_matrix.py --wait-slash-client-click-proof`, including
   the redacted `--proof-path` output used by support bundles and doctor.
2. `/ops` now treats `discord_slash_client_click_stale` as a distinct blocked
   reason kind and tells operators to rerun the wait-mode watcher while clicking
   a fresh real slash command.
3. While updating this surface, the free-response next action was tightened to
   explicitly name Message Content Intent when the proof reason is
   `discord_message_content_intent_or_delivery`.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   `35 tests, 0 failures`.

### Slice 222: Web ops DM proof handoff visibility

1. Web `/ops` channel failure drilldown now gives Discord DM operators the
   concrete `scripts/live_discord_matrix.py --wait-dm-inbound` handoff instead
   of a generic "run live proof" note.
2. Closed-DM and bot-to-bot setup refusal stays explicitly blocked as
   `discord_dm_setup_refused`; the next action names the reachable
   human/open-DM requirement and the redacted proof paths needed for promotion.
3. `apps/lemon_web/README.md` and `apps/lemon_web/AGENTS.md` now document that
   Discord DM drilldown must keep the external reachability blocker separate
   from stable support claims.
4. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   `35 tests, 0 failures`.

### Slice 223: CI guard for client-click wait-mode handoff docs

1. `scripts/lint_ci_docs.sh` now fails if the release checklist stops
   documenting `--wait-slash-client-click-proof` alongside the existing
   one-shot `--check-slash-client-click-proof` validator.
2. This keeps the operator handoff durable: the readiness audit can still
   validate an already captured proof, while release docs must preserve the
   wait-mode path that asks for a fresh real Discord client click.
3. Validation passed with `bash -n scripts/lint_ci_docs.sh`,
   `scripts/lint_ci_docs.sh`, and `git diff --check`.

### Slice 224: Final readiness audit client-click wait handoff

1. `scripts/audit_1_0_readiness` now prints the
   `--wait-slash-client-click-proof` workflow in its operator handoff text,
   so release blockers point at the fresh proof watcher instead of only the
   post-capture validator.
2. Missing client-click proof blockers now mention running the wait-mode watcher
   while clicking a real Discord slash command.
3. CI docs lint now guards the wait-mode command in the audit script as well as
   the release checklist.
4. Validation passed with `bash -n scripts/audit_1_0_readiness
   scripts/lint_ci_docs.sh`, `scripts/lint_ci_docs.sh`, and `git diff --check`.

### Slice 225: Doctor client-click wait-mode remediation

1. `LemonCore.Doctor.Checks.Channels` now points missing, invalid,
   non-promotable, stale, and otherwise failed Discord slash client-click proof
   states at `scripts/live_discord_matrix.py --wait-slash-client-click-proof`
   instead of the older post-capture-only check.
2. Doctor still keeps `channels.discord.slash_client_click` as a warning until
   a real Discord client click produces a promotable
   `lemon.discord_slash_client_click` artifact.
3. `apps/lemon_core/README.md` and `apps/lemon_core/AGENTS.md` now document the
   stable missing/invalid/non-promotable/stale reason-kind contract and
   wait-mode remediation expectation.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`:
   `55 tests, 0 failures`, and the live doctor warning now prints
   `--wait-slash-client-click-proof`.

### Slice 226: Slash client-click stale-doc cleanup

1. The channel command parity matrix, 1.0 readiness plan, and testing guide now
   lead with `--wait-slash-client-click-proof` for real Discord slash
   client-click promotion and reserve `--check-slash-client-click-proof` for
   already captured artifacts.
2. The Hermes feature parity matrix now describes the client-click gate as a
   fresh operator-click wait flow rather than a post-click-only validator.
3. Validation passed with `scripts/lint_ci_docs.sh`,
   `xmllint --html --noout docs/plans/lemon-hermes-progress.html`, and
   `git diff --check`.

### Slice 227: Doctor media provider blocker remediation

1. `LemonCore.Doctor.Checks.Media` now maps safe provider-media `reason_kind`
   labels into bounded operator hints for permission-denied, billing/quota,
   payment-required, request-shape, and generic provider HTTP failures.
2. Current `media.provider_live` output now distinguishes the actual state:
   image, TTS, and video reached their providers but were denied permissions,
   so remediation points at provider API/IAM/billing access instead of only
   saying to set credentials.
3. `apps/lemon_core/README.md`, `apps/lemon_core/AGENTS.md`, `docs/support.md`,
   and `docs/tools/media.md` now document the safe reason-to-remediation
   boundary.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs --seed 1`:
   `56 tests, 0 failures`, and the live doctor warning prints the provider
   hints without raw provider responses.

### Slice 228: Web ops media provider blocker remediation

1. Web `/ops` grouped media provider rows now use the same safe `reason_kind`
   classes to provide bounded next actions for permission, quota/billing,
   payment, request-shape, and generic provider HTTP failures.
2. Failed provider rows still keep copy-ready smoke commands, per-provider
   rerun commands, proof paths, and secret-backed variants visible while keeping
   raw provider response text out of the snapshot.
3. `apps/lemon_web/README.md` and `apps/lemon_web/AGENTS.md` now document that
   provider-media rows may surface bounded reason hints but never raw provider
   bodies.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   `36 tests, 0 failures`.

### Slice 229: Final readiness media blocker hints

1. `scripts/audit_1_0_readiness` now maps safe incomplete provider-media
   `reason_kind` labels to bounded remediation hints for permission-denied,
   billing/quota, payment-required, request-shape, and generic provider HTTP
   failures.
2. The audit still prints only safe reason labels and hints, not raw provider
   responses, prompts, keys, transcripts, or media bytes.
3. `scripts/lint_ci_docs.sh` now guards that the audit preserves media proof
   remediation hints for `permission_denied` and `payment_required` classes.
4. Validation passed with `bash -n scripts/audit_1_0_readiness
   scripts/lint_ci_docs.sh`, `scripts/lint_ci_docs.sh`, and `git diff --check`.

### Slice 230: Web ops visible media next actions

1. Web `/ops` media provider cards now render each lane's bounded
   `next_action` next to its safe `reason_kind`, proof path, and copy-ready
   rerun commands.
2. Operators can now see permission, quota/billing, payment, request-shape, and
   generic provider-HTTP remediation without consulting backend-only snapshot
   fields.
3. Focused validation passed with Web/Core tests at `36` and `56` tests with
   zero failures, plus formatting, docs lint, HTML lint, and diff hygiene.

### Slice 231: Doctor targeted media provider reruns

1. `media.provider_live` remediation now appends target-provider `--provider`
   flags for failed or skipped multi-provider lanes when a redacted proof
   identifies the safe provider id.
2. Current image/TTS/video blocker reruns now point at `vertex_imagen`,
   `google_tts`, and `vertex_veo` instead of rerunning each lane's default
   provider.
3. Focused doctor validation passed with `56 tests, 0 failures`, and live
   doctor output prints the target-provider rerun commands.

### Slice 232: Final audit targeted media provider reruns

1. `scripts/audit_1_0_readiness` now defines media reason hints inside the
   media verifier and prints a target-provider rerun command for failed or
   skipped multi-provider proof artifacts.
2. The extracted media verifier was exercised against the current failed image
   proof and emitted `--provider vertex_imagen` with sanitized
   permission-denied guidance.
3. This keeps final audit guidance aligned with doctor and Web `/ops`.

### Slice 233: Media proof state stale-doc cleanup

1. The scorecard and feature matrix no longer list STT as an open
   provider-media blocker.
2. Documentation now matches doctor and support wording: Deepgram STT plus
   vision are current provider-backed passes, while image, TTS, and video
   remain blocked by provider permission/payment/quota evidence.
3. Stale-text search, docs lint, HTML lint, and diff hygiene passed.

### Slice 234: Support bundle media provider lane summary

1. `media_diagnostics.json` now includes redacted provider-live
   image/TTS/STT/vision/video lane state.
2. Support bundles include target-provider rerun commands for failed or
   skipped multi-provider proofs so media launch-gate triage is self-contained.
3. Focused support-bundle validation passed with `3 tests, 0 failures`.

### Slice 235: Docs lint guard for support-bundle media lanes

1. `scripts/lint_ci_docs.sh` now checks support-bundle code, support-bundle
   tests, and support docs for the redacted `provider_live` media lane summary.
2. The guard also keeps the matching `--provider` rerun flag contract visible.
3. Validation passed with support-bundle tests at `3 tests, 0 failures`,
   formatting, docs lint, HTML lint, and diff hygiene.

### Slice 236: Web ops cron scheduler-health counters

1. Web `/ops` now renders aggregate cron scheduler health from durable run and
   lifecycle audit stores: active run locks, retry runs, suppressed scheduled
   slots, stale-run recoveries, scheduled retries, and next/last run
   timestamps.
2. `LemonWeb.OpsDashboard.cron_status/0` now computes the same health counters
   used by the UI instead of leaving operators to infer scheduler state from
   raw run rows.
3. Focused Web validation passed with `36 tests, 0 failures`, and docs/docs-lint
   guard the BEAM-native scheduling visibility contract.

### Slice 237: Control-plane cron scheduler-health status

1. `cron.status` now exposes active lock, failed-run, retry-run,
   suppressed-slot, stale-recovery, scheduled-retry, status-count,
   trigger-count, and audit-action counters.
2. The control-plane API now carries the same durable scheduler health exposed
   in Web `/ops` to TUI and JSON-RPC operators.
3. Focused control-plane validation passed with `59 tests, 0 failures`, and
   docs/docs-lint keep the API contract visible.

### Slice 238: Control-plane terminal backend live proof summary

1. `terminal.backends.status` now accepts `projectDir` / `project_dir` and
   includes a redacted `liveProof` object from
   `LemonCore.Doctor.ProofDiagnostics`.
2. The proof summary includes completed/failed/skipped/missing counts,
   per-backend proof status, proof object, generated/modified timestamps, file
   hash, proof hash, and safe Docker hardening fields such as read-only rootfs,
   no-exec tmpfs, dropped capabilities, no-new-privileges, cgroup limits, pull
   policy, network, memory, CPU, and pids.
3. The response explicitly omits raw proof commands and output while documenting
   that raw proof details are not included in cleanup/status metadata.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `59 tests, 0 failures`, plus formatting, docs lint, HTML lint, and diff
   hygiene.

### Slice 239: Control-plane proof launch-gate summaries

1. `proofs.status` now includes a redacted `launchGates` object for Discord DM,
   Discord slash client-click, provider media, and terminal backend promotion
   gates.
2. The Discord gates reuse the same safe proof/check reason-kind vocabulary as
   doctor and Web `/ops`, including `discord_dm_setup_refused`,
   `discord_dm_missing`, and Discord slash client-click missing/stale/invalid
   classes.
3. The provider-media gate groups image, TTS, STT, vision, and video lanes by
   their accepted provider proofs and reports completed, failed, and missing
   lane counts without prompts, provider responses, or artifact bytes.
4. The terminal gate reports terminal live-proof pass/block/warning state from
   the same redacted terminal backend proof rows used by support bundles,
   doctor, Web `/ops`, and `terminal.backends.status`.
5. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `59 tests, 0 failures`, plus formatting, docs lint, and diff hygiene.

### Slice 240: Pagination-safe proof launch gates

1. `proofs.status` now asks `LemonCore.Doctor.ProofDiagnostics` for a broader
   internal proof sample when computing launch gates, so Discord, provider
   media, and terminal gate summaries do not depend on the client-facing
   response `limit`.
2. The API still applies the requested `limit` to returned `latestChecks` and
   `recentProofs`, preserving compact operator responses while keeping
   `launchGates` accurate.
3. Focused regression coverage now calls `proofs.status` with `limit: 1` over
   multiple media-provider proof lanes and verifies `recentProofs` /
   `latestChecks` are truncated while provider-media completed lane counts
   still include all matching proof artifacts.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `60 tests, 0 failures`, plus formatting.

### Slice 241: Control-plane LSP proof status visibility

1. `lsp.diagnostics.status` now includes a redacted `proofs` object with recent
   LSP proof artifacts, latest LSP proof checks, proof/check counts, cleanup
   flags, and bounded error state.
2. The method accepts `projectDir` / `project_dir` for proof scanning while
   preserving existing `diagnosticsTimeoutMs` status behavior.
3. The proof summary matches the Web `/ops` promotion view and omits raw proof
   paths, filenames, file contents, diagnostics output, workspace roots, server
   I/O, and raw session ids.
4. Focused regression coverage seeds an LSP proof artifact with private path
   fields, calls `lsp.diagnostics.status`, verifies proof/check summaries, and
   asserts private paths do not leak.
5. Broader control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1`:
   `107 tests, 0 failures`, plus formatting, docs lint, and diff hygiene.

### Slice 242: Control-plane media provider proof lanes

1. `media.status` now includes a redacted `providerProofs` object for
   provider-backed image, TTS, STT, vision, and video launch lanes.
2. Each lane reports accepted provider ids, selected provider, proof status,
   safe reason kind, model label, proof hash, modified timestamp, copy-ready
   rerun command, secret-backed rerun command, per-provider rerun commands for
   multi-provider lanes, and a bounded next action.
3. The provider proof summary reuses the same safe remediation classes as
   doctor and Web `/ops`, including permission, quota/billing, payment,
   request-shape, and generic provider-HTTP blockers.
4. Focused regression coverage seeds failed image and completed STT proof
   artifacts, verifies the grouped lane summary, and asserts prompts/provider
   responses do not leak.
5. Broader control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1`:
   `107 tests, 0 failures`, plus formatting, docs lint, and diff hygiene.

### Slice 243: Control-plane browser live proof status

1. `browser.status` now includes a redacted `liveProof` object for recent
   browser smoke proof state alongside local driver, artifact, and node status.
2. The proof summary reports status, completed/failed/skipped counts, proof
   object, generated/modified timestamps, file/proof hashes, safe browser proof
   booleans, latest browser proof checks, and cleanup booleans.
3. The API omits raw proof paths, filenames, page data, screenshot bytes,
   provider responses, raw prompts, and proof file contents while still making
   the live browser proof visible to non-Web operator clients.
4. Focused regression coverage seeds a browser proof artifact with private
   artifact and page fields, calls `browser.status`, verifies the browser proof
   and check summary, and asserts the private URL/path fields do not leak.
5. Broader control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1`:
   `107 tests, 0 failures`, plus formatting, docs lint, and diff hygiene.

### Slice 244: Control-plane checkpoint lifecycle event status

1. `checkpoint.status` now includes redacted checkpoint lifecycle event counts
   and recent event summaries alongside checkpoint-store metadata.
2. The method accepts `runId` / `run_id`, `sessionKey` / `session_key`,
   `agentId` / `agent_id`, and `eventLimit` / `event_limit` so operator clients
   can inspect checkpoint create/restore/delete lifecycle for a specific run,
   session, or agent without loading raw run events.
3. Recent event summaries include the event type, timestamp, checkpoint id,
   checkpoint kind, tool/action, path/restored count, and a session hash while
   omitting raw checkpoint paths, file contents, raw event payloads, and raw
   session ids.
4. Focused regression coverage seeds create/restore/delete introspection events
   containing private session and path fields, calls `checkpoint.status` with
   event filters, verifies bounded counts/recent events, and asserts private
   values do not leak.
5. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `61 tests, 0 failures`, plus formatting.

### Slice 245: Control-plane channel support diagnostics

1. `channels.status` now includes a redacted `diagnostics` object from
   `LemonCore.Doctor.ChannelDiagnostics` alongside the existing channel adapter
   registry rows.
2. The method accepts `projectDir` / `project_dir`, so operator clients can
   inspect source-runtime or fixture config shape through the same support
   diagnostics used by support bundles and Web `/ops`.
3. Diagnostics expose Telegram/Discord enablement, binding counts, generated-file
   shape, Telegram voice transcription config shape, Discord DM/free-response,
   inbound replay, slash-command readiness, bot-message policy, and cleanup
   booleans without raw bot tokens, secret names, chat ids, channel ids, guild
   ids, message bodies, or session keys.
4. Focused regression coverage builds a fixture config with fake Telegram and
   Discord credentials plus private channel/chat ids, calls `channels.status`,
   verifies diagnostics, and asserts private values do not leak.
5. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `63 tests, 0 failures`, plus formatting.

### Slice 246: Control-plane provider fallback proof status

1. `providers.status` now includes a redacted `liveProofs` object with the
   latest provider fallback proof status alongside credential readiness and
   route preview.
2. The fallback proof summary reports proven/blocked/skipped/missing state,
   proof status, proof object, primary/fallback/final provider labels, modified
   timestamp, proof hash, proof-scope counts, cleanup booleans, and bounded next
   action.
3. The proof summary uses the same local proof-artifact inventory as Web `/ops`
   and omits raw API keys, secret names, base URLs, env var names, prompts,
   answers, and provider response bodies.
4. Focused regression coverage seeds a provider-fallback proof artifact with
   private prompt/answer/key fields, calls `providers.status`, verifies the
   fallback proof summary, and asserts private values do not leak.
5. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `64 tests, 0 failures`, plus formatting.

### Slice 247: Control-plane channel proof status

1. `channels.status` now includes a redacted `proofs` object with recent
   Telegram/Discord proof artifacts and latest channel proof checks alongside
   adapter status and support diagnostics.
2. The proof summary scans the same `.lemon/proofs` and `tmp` proof inventory
   used by support bundles, Web `/ops`, and `proofs.status`, then filters rows
   whose proof object, proof scopes, provider, reason kind, or check names are
   channel-related.
3. The response reports bounded recent proofs, latest checks, proof/check
   counts, and cleanup booleans while omitting raw proof paths, filenames,
   prompts, provider responses, and proof file contents.
4. Focused regression coverage seeds a Discord MEDIA directive proof with
   private channel/guild/prompt/body fields, calls `channels.status`, verifies
   the proof/check summaries, and asserts private values do not leak.
5. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `64 tests, 0 failures`, plus formatting.

### Slice 248: Control-plane memory-provider health summary

1. `memory.status` now includes a redacted `health` object alongside the
   memory-provider registry rows.
2. The health summary reports ready/degraded/disabled/missing status,
   enabled/disabled counts, loaded/missing module counts, searchable scopes,
   and per-scope provider counts without reading or returning memory contents,
   raw config values, secret names, or provider internals.
3. Focused regression coverage verifies a loaded local memory provider reports
   `ready`, enabled and loaded counts, the `session` searchable scope, and
   per-scope counts through the public control-plane method.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `64 tests, 0 failures`, plus formatting.

### Slice 249: Control-plane skill readiness summary

1. `skills.status` now preserves each skill's activation state, readiness
   boolean, platform compatibility, missing binary/config/env/tool lists,
   disabled flag, and error string instead of collapsing all non-nil values into
   ready.
2. The response adds a redacted `summary` object with total, ready, not-ready,
   hidden, blocked, platform-incompatible, activation-state, source, and
   missing-requirement counts for operator clients.
3. Focused regression coverage creates one ready project skill and one
   missing-binary project skill, verifies `ready: false` stays boolean false,
   confirms the `not_ready` activation state and missing binary are surfaced,
   and asserts the temporary skill path is omitted from the response.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `66 tests, 0 failures`, plus formatting.

### Slice 250: Control-plane secrets-store health summary

1. `secrets.status` now includes encrypted-store `healthy`, `fileFallback`,
   safe `keychainErrorKind`, and explicit cleanup flags alongside the existing
   configured/source/keychain/env/count metadata.
2. The response keeps raw secret values, raw key material, and raw keychain
   error text out of the control-plane status surface while still exposing
   enough BEAM-local setup signal for provider/channel credential triage.
3. Focused regression coverage exercises set/list/exists/delete/status
   end-to-end with an env-backed master key and verifies the new health,
   fallback, keychain-error-kind, count, and cleanup fields.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/secrets_methods_test.exs --seed 1`:
   `3 tests, 0 failures`, plus formatting.

### Slice 251: Root status BEAM VM capacity counters

1. Root `status` now includes a `server.beam` object with process count/limit,
   port count/limit, atom count/limit, and run-queue counters.
2. The run-count branch now catches missing optional router supervisor exits and
   returns zero counts, so partial app startup does not crash the status method.
3. Focused regression coverage verifies the BEAM counters are present,
   integer-shaped, and bounded by their limits.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/status_test.exs --seed 1`:
   `2 tests, 0 failures`, plus formatting.

### Slice 252: Control-plane transport registry health summary

1. `transports.status` now includes registry module/loaded/running state,
   enabled/disabled totals, and a `summary` object with configured count,
   enabled count, disabled count, module-loaded count, module-missing count,
   safe status, and cleanup flags.
2. The summary distinguishes stopped registry, empty registry, all-disabled
   registry, and enabled-transport states without returning credential values,
   raw config, or secret names.
3. Focused regression coverage checks missing modules, stopped registries,
   configured/enabled transports, missing registry APIs, and crashing transport
   lookups.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs --seed 1`:
   `8 tests, 0 failures`, plus formatting.

### Slice 253: Control-plane TTS provider readiness summary

1. `tts.status` now preserves explicit stored falsey values from atom-keyed or
   string-keyed TTS config, including `enabled: false`, explicit `voice`, `rate`,
   and `updated_at_ms` values.
2. The response adds configured state, active-provider known/available booleans,
   a redacted provider readiness list, provider-count summary, and cleanup flags
   without returning secret values, raw key material, or raw provider errors.
3. The summary distinguishes disabled, unknown-provider, provider-unavailable,
   and ready states for non-Web control-plane clients.
4. Focused control-plane validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs`:
   `50 tests, 0 failures`, plus formatting.

### Slice 254: Control-plane usage summary consistency

1. `usage.status` now reads the current usage summary maintained by
   `usage.cost.record_usage/1` instead of only checking the older
   `usage_stats` side channel.
2. The response adds provider rows with request, token, and cost counts, quota
   status/remaining fields, and cleanup flags for prompts, responses, and
   secret values.
3. `usage.cost.record_usage/1` now keeps per-provider request and token maps in
   the current summary so non-Web clients can explain usage by provider without
   scanning daily records.
4. Focused optional-parity validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs`:
   `117 tests, 0 failures`, plus formatting.

### Slice 255: Control-plane voicewake status summary

1. `voicewake.get` now preserves explicit stored falsey values from atom-keyed
   or string-keyed config, including disabled state, zero sensitivity, backend,
   and update timestamp.
2. The response adds configured state, enabled/backend summary, and cleanup
   flags without returning audio samples or secret values.
3. `voicewake.set` now also preserves existing string-keyed config values and
   returns sensitivity, backend, and update timestamp after writes.
4. Focused optional-parity validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs`:
   `52 tests, 0 failures`, plus formatting.

### Slice 256: Control-plane config redaction

1. `config.get` now redacts stored config values whose keys look like API keys,
   tokens, passwords, secrets, credentials, or private keys, both for single-key
   reads and full-config reads.
2. Nested config maps are recursively redacted by sensitive key names, while
   non-sensitive config values remain unchanged.
3. `config.set` now avoids echoing sensitive submitted values in its response,
   while still storing the value for existing admin workflows.
4. Focused config/atom-safety validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/event_type_validation_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/event_type_atom_leak_test.exs`:
   `72 tests, 0 failures`, plus formatting.

### Slice 257: Control-plane model catalog summary

1. `models.list` now returns a `summary` with catalog source, total model
   count, provider count, provider names, vision-model count, thinking-model
   count, and streaming-model count.
2. The formatter now preserves explicit false capability booleans for map-shaped
   models instead of treating every missing or false `supportsStreaming` value
   as true.
3. The response adds cleanup flags confirming credentials and secret values are
   not included.
4. Focused model-catalog validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/models_list_test.exs`:
   `1 test, 0 failures`, plus formatting.

### Slice 258: Control-plane agent directory summaries

1. `agent.directory.list` now returns a compact summary with include-sessions
   state, agent count, returned session count, active-session count,
   route-session count, and aggregate agent session counts.
2. `agent.targets.list` now returns target/session/active-session/agent counts
   for the returned target rows.
3. Backward-compatible `agents.list` now preserves directory totals, summary,
   and cleanup flags while still adding the legacy `id` alias to each agent row.
4. All three responses include cleanup flags confirming they do not return
   message bodies, credentials, or secret values.
5. Focused agent-routing validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/agent_routing_methods_test.exs`:
   `5 tests, 0 failures`, plus formatting.

### Slice 259: Control-plane run and task observability summaries

1. `runs.active.list` now returns a compact summary with returned run count,
   status counts, engine counts, unique agent/session counts, oldest/newest
   start timestamps, applied filters, and cleanup flags.
2. `runs.recent.list` now returns the same run-shape summary plus ok/error/
   aborted counts and average duration for recently completed, errored, or
   aborted runs.
3. `tasks.active.list` and `tasks.recent.list` now return task summaries with
   status, engine, role, agent, run, event, reasoning, and duration counts. The
   cleanup block truthfully reports whether optional task events or full task
   records were included.
4. The existing row arrays, totals, filters, event/record include switches, and
   engine inference behavior remain backward-compatible.
5. Focused monitoring validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/monitoring_methods_test.exs`:
   `78 tests, 0 failures`, and the broader control-plane parity gate passed
   with monitoring, agent-routing, model-catalog, optional parity, secrets,
   status, introspection, schema, and atom-safety lanes: `284 tests, 0
   failures`. Docs lint, HTML validation, diff whitespace checks, and formatting
   also passed.

### Slice 260: Control-plane session summary and full-text opt-in

1. `sessions.list` now accepts nil/string-keyed params safely and returns a
   summary with returned count, total available sessions, agent count, origin
   counts, aggregate run count, updated timestamp bounds, applied filters, and
   cleanup flags.
2. `sessions.active.list` now returns active-session summaries with active,
   agent, channel, kind, peer-kind, target, harness, run, and updated timestamp
   counts while preserving the existing best-effort harness projection.
3. `session.detail` now returns aggregate run/session summary data for ok/error
   counts, engine mix, tool-call count, event count, token totals, average
   duration, and truthful include flags.
4. `session.detail` no longer emits `promptFull` or `answerFull` unless
   `includeFullText` is explicitly true, and `summaryRaw` / `completedRaw`
   truncate prompt/answer fields when full text is not requested. Raw events and
   run records remain opt-in through their existing flags.
5. Focused introspection validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs`:
   `9 tests, 0 failures`, including default full-text redaction and explicit
   full-text opt-in. The broader control-plane parity gate passed with
   monitoring, agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `285 tests, 0 failures`. Docs
   lint, HTML validation, diff whitespace checks, and formatting also passed.

### Slice 261: Control-plane history preview summaries

1. `sessions.preview` now accepts nil/string-keyed params safely, bounds the
   requested limit, marks each preview row when prompt or answer text was
   truncated, and returns summary/cleanup flags for returned count, ok/error
   counts, truncation count, limit, and no raw events/records/secret values.
2. `chat.history` now exposes a summary with message count, role counts,
   ok/error counts, truncation count, requested limit, `beforeId`, and cleanup
   flags. It keeps full message bodies by default for backward compatibility,
   and supports `includeFullText: false` for bounded preview content.
3. `chat.history` now honors `beforeId` by returning messages after the matched
   id in the current history order instead of ignoring the parameter.
4. The protocol schema now documents optional `sessions.preview.limit`,
   `chat.history.beforeId`, and `chat.history.includeFullText`.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `58 tests, 0 failures`, covering preview truncation, full-text history
   preview mode, `beforeId` pagination, and schema acceptance. The broader
   control-plane parity gate passed with monitoring, agent-routing,
   model-catalog, optional parity, secrets, status, introspection, schema, and
   atom-safety lanes: `285 tests, 0 failures`. Docs lint, HTML validation, diff
   whitespace checks, and formatting also passed.

### Slice 262: Control-plane log tail summaries

1. `logs.tail` now supports both legacy schema params (`lines`, `filter`) and
   existing handler params (`limit`, `level`), normalizes the level filter, and
   bounds requested limits.
2. The log-ring boundary is configurable through `:lemon_control_plane,
   :log_ring_module`, making the method testable while preserving the existing
   `LemonControlPlane.LogRing` default.
3. The response keeps the backward-compatible `logs` array and adds `total`,
   `filters`, and a `summary` with count, limit, level, level-counts, and cleanup
   flags.
   Slice 329 later tightened the same response path so sensitive log keys and
   common inline credential patterns are redacted before the log array is
   returned to clients.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `61 tests, 0 failures`, covering filtered log summaries, unavailable
   log-ring fallback, and schema acceptance. The broader control-plane parity
   gate passed with monitoring, system/logs, agent-routing, model-catalog,
   optional parity, secrets, status, introspection, schema, and atom-safety
   lanes: `297 tests, 0 failures`. Docs lint, HTML validation, diff whitespace
   checks, and formatting also passed.

### Slice 263: Control-plane event subscription state summaries

1. WebSocket connection state now tracks `events.subscribe` and
   `events.unsubscribe` topic changes per connection, including specific topic
   removal and all-topic clears.
2. `events.subscribe` accepts nil params, string-keyed or atom-keyed `topics`,
   and `runId`/`run_id`, validates allowed topics without atom creation, updates
   live connection state when a connection pid or registered connection id is
   available, and returns topic/run/session counts plus cleanup flags.
3. `events.unsubscribe` accepts nil params, string-keyed or atom-keyed topics,
   and `runId`/`run_id`, sends a clear-all message when no topic/run filter is
   supplied, and returns topic/run/session counts plus cleanup flags.
4. `events.subscriptions.list` now reads the live connection state supplied by
   the WebSocket dispatcher and returns sorted subscriptions, run subscription
   ids, total count, run/session counts, connection state, and cleanup flags.
5. The protocol schema now documents optional `events.subscribe.topics`,
   `events.subscribe.runId`, `events.subscribe.run_id`,
   `events.unsubscribe.topics`, `events.unsubscribe.runId`,
   `events.unsubscribe.run_id`, and the empty `events.subscriptions.list`
   parameter shape.
6. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/event_subscription_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/ws/connection_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `60 tests, 0 failures`, covering subscription state transitions,
   connection-context list summaries, unsubscribe clear-all behavior, invalid
   topic rejection, and schema acceptance. The broader control-plane parity gate
   passed with event subscriptions, WebSocket connection, monitoring,
   system/logs, agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `308 tests, 0 failures`.

### Slice 264: WebSocket event subscription delivery filtering

1. WebSocket event delivery now honors per-connection subscription state before
   pushing frames. New connections keep the legacy all-event behavior until they
   set explicit subscriptions, while `events.unsubscribe` with no topics clears
   the connection to no event delivery.
2. Topic matching covers static event families (`system`, `cron`, `goals`,
   `presence`, `exec_approvals`, and `nodes`) plus `run:<id>` and
   `session:<key>` matches derived from mapped event payload fields.
3. `LemonControlPlane.EventBridge` now supports generic dynamic topic reference
   counting for `run:*` and `session:*` subscriptions, keeps the legacy
   `subscribe_run/1` and `unsubscribe_run/1` API, and subscribes to the static
   `channels` bus topic.
4. `events.subscribe` now registers every dynamic topic in the requested topic
   list, not only the separate `runId` parameter. `events.unsubscribe` releases
   explicit dynamic topics and uses the live connection subscription state when
   clearing all topics.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/event_subscription_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/ws/connection_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `80 tests, 0 failures`, covering delivery filtering, clear-all suppression,
   session-topic matching, dynamic session bus subscription, subscription list
   default state, and schema acceptance. The broader control-plane parity gate
   passed with event subscriptions, WebSocket connection, EventBridge,
   monitoring, system/logs, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `328 tests, 0 failures`.

### Slice 265: Bounded external event ingest summaries

1. `events.ingest` now accepts nil params safely, supports the same string-keyed
   and atom-keyed parameter shape as surrounding methods, and validates that the
   submitted payload is an object before broadcasting anything.
2. The method now validates target topics at the control-plane boundary,
   allowing only known static event topics plus `run:<id>` and `session:<key>`
   dynamic targets.
3. Ingest responses still avoid echoing event payloads and now include a
   summary with event type, target, target kind, timestamp, payload key count,
   custom-event status, and cleanup flags for payloads, message bodies,
   credentials, and secret values.
4. The protocol schema now documents `events.ingest` with required `eventType`
   and optional `event_type`, `payload`, and `target` fields.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/event_subscription_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/ws/connection_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `95 tests, 0 failures`, covering ingest summary/redaction, invalid payload
   and target rejection, non-string event-type rejection, goal-topic filtering,
   and schema acceptance. The broader control-plane parity gate passed with
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   monitoring, system/logs, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `331 tests, 0 failures`.

### Slice 266: Event subscription schema compatibility

1. The control-plane schema validator now supports small union type lists for
   fields that intentionally accept more than one JSON shape.
2. `events.subscribe.topics` and `events.unsubscribe.topics` now accept either a
   single topic string or a topic list at the schema boundary, matching the
   runtime handlers and avoiding a pre-dispatch mismatch.
3. Schema error messages now render union types as readable `type or type`
   strings instead of crashing while formatting the expected type.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/event_subscription_methods_test.exs`:
   `56 tests, 0 failures`, covering string/list topic compatibility and invalid
   topic type errors. The broader control-plane parity gate passed with event
   ingest, event subscriptions, WebSocket connection, EventBridge, monitoring,
   system/logs, agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `332 tests, 0 failures`.

### Slice 267: Ingested metrics/log event fanout mapping

1. `EventBridge` now maps `:metrics` to the `metrics` WebSocket event and
   `:log` to the `log` WebSocket event, and `Frames.supported_events/0`
   advertises both names.
2. Ingested `custom`, `metrics`, and `log` events now carry `runId` or
   `sessionKey` in the pushed payload when their bus target is `run:<id>` or
   `session:<key>`, so per-connection subscription filtering can match target
   scoped ingested events.
3. Ingested log event payloads expose a bounded message preview, level, and
   timestamp, while metrics payloads use string-keyed maps for JSON clients.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/ws/connection_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/system_methods_test.exs`:
   `41 tests, 0 failures`, covering metrics/log/custom target fields and
   subscription filtering. The broader control-plane parity gate passed with
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, system/logs, agent-routing,
   model-catalog, optional parity, secrets, status, introspection, schema, and
   atom-safety lanes: `350 tests, 0 failures`.

### Slice 268: Bounded admin system-event summaries

1. `system-event` now accepts nil params safely, supports string-keyed,
   snake-case, and atom-keyed compatibility for the event type and payload, and
   validates that the submitted payload is an object before broadcasting.
2. The method now validates target topics at the admin event boundary, allowing
   only known static event topics plus `run:<id>` and `session:<key>` dynamic
   targets instead of arbitrary PubSub topics.
3. The response preserves the existing `success`, `eventType`, `topic`, and
   `timestamp` fields, and adds a summary with event type, topic, target kind,
   timestamp, payload key count, custom-event status, and cleanup flags for
   payloads, message bodies, credentials, and secret values.
4. The protocol schema now supports one-of required fields for `eventType` or
   `event_type`, keeping `system-event` and `events.ingest` schemas aligned with
   runtime compatibility while preserving missing-field rejection.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `67 tests, 0 failures`, covering summary/redaction, snake-case compatibility,
   payload and target rejection, non-string event-type rejection, and schema
   acceptance. The broader control-plane parity gate passed with system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, system/logs, agent-routing,
   model-catalog, optional parity, secrets, status, introspection, schema, and
   atom-safety lanes: `352 tests, 0 failures`.

### Slice 269: System-presence summaries and cleanup flags

1. `system-presence` now preserves the existing `connId`, `connections`,
   `activeRuns`, `timestamp`, `health`, and `resources` fields for current
   operator clients.
2. The method adds a compact `summary` with connection count, active-run count,
   health status, timestamp milliseconds, memory total, process count, scheduler
   count, and cleanup flags.
3. Cleanup flags explicitly show that the response includes the current
   connection id but omits other connection ids, raw process state, message
   bodies, credentials, and secret values.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `67 tests, 0 failures`, covering the presence summary and cleanup contract.
   The broader control-plane parity gate passed with system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, system/logs,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `352 tests, 0 failures`.

### Slice 270: Node-list summaries and cleanup flags

1. `node.list` now preserves the existing `nodes` array while adding a compact
   `summary` for node count, status counts, type counts, and capability-key
   counts.
2. The summary includes cleanup flags that make the node inventory contract
   explicit: capabilities are included, while invocation results, pairing
   secrets, credentials, and secret values are omitted.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `120 tests, 0 failures`, covering summary counts, string-keyed JSONL reload
   compatibility, and cleanup flags. The broader control-plane parity gate
   passed with node-list, node-event, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets, status, introspection, schema, and atom-safety
   lanes: `421 tests, 0 failures`.

### Slice 271: Node-describe metadata redaction and summaries

1. `node.describe` now preserves the existing single-node response shape while
   adding a compact `summary` for node status, type, capability count,
   metadata-key count, and cleanup flags.
2. Sensitive metadata keys such as tokens, secrets, passwords, API keys,
   credentials, and cookies are redacted recursively before the response leaves
   the control-plane boundary.
3. Cleanup flags explicitly show that capabilities and metadata are included,
   sensitive metadata keys are redacted, and invocation results, pairing
   secrets, credentials, and secret values are omitted.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `121 tests, 0 failures`, covering summary fields, JSONL reload
   compatibility, and recursive metadata redaction. The broader control-plane
   parity gate passed with node-describe, node-list, node-event,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `422 tests, 0 failures`.

### Slice 272: Node-pair-list summaries and reload safety

1. `node.pair.list` now supports string-keyed pairing records from JSONL reload
   paths when filtering pending, non-expired pairing requests.
2. The method preserves the existing `requests` array and adds a compact
   `summary` with pending count, node-type counts, capability-key counts, and
   cleanup flags.
3. Cleanup flags explicitly document that pairing codes and capabilities are
   included, while approved tokens, challenge tokens, credentials, and secret
   values are omitted.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `123 tests, 0 failures`, covering string-keyed pending pairings, expired and
   resolved filtering, summary counts, and cleanup flags. The broader
   control-plane parity gate passed with node-pair-list, node-describe,
   node-list, node-event, system-presence, system-event, event ingest,
   event subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `424 tests, 0 failures`.

### Slice 273: Approval policy summaries and action-key redaction

1. `exec.approvals.get` now preserves policy, approval-hash, and active pending
   approval rows while adding summary counts for policy entries, approval rows,
   active pending approvals, pending tools, and pending agents.
2. Pending approval `action` metadata remains structured for operator clients
   such as MCP OAuth surfaces, but sensitive nested keys such as tokens,
   secrets, passwords, API keys, credentials, and cookies are redacted before
   leaving the control plane.
3. `exec.approvals.node.get` now adds node-scoped policy and approval summaries
   plus cleanup flags that distinguish approval hashes from action bodies.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/exec_approvals_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `76 tests, 0 failures`, covering global summaries, pending action secret-key
   redaction, expired pending omission, and node-policy summaries. The broader
   control-plane parity gate passed with approval, node-pair-list,
   node-describe, node-list, node-event, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets, status, introspection, schema, and atom-safety
   lanes: `449 tests, 0 failures`.

### Slice 274: Last-heartbeat summaries and response redaction

1. `last-heartbeat` now preserves the existing agent id, enabled status,
   interval, and last-run fields while adding summary metadata for configured
   state, enabled state, interval, last-run presence, last status, suppression,
   and response length.
2. Heartbeat response text that looks secret-bearing is redacted before leaving
   the control plane, while ordinary heartbeat responses remain available for
   operator diagnostics.
3. Cleanup flags explicitly show response inclusion/redaction behavior and
   confirm that heartbeat prompts, credentials, and secret values are omitted.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/heartbeat_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `63 tests, 0 failures`, covering empty state, configured state, last-run
   summaries, and sensitive response redaction. The broader control-plane parity
   gate passed with heartbeat, approval, node-pair-list, node-describe,
   node-list, node-event, system-presence, system-event, event ingest,
   event subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `461 tests, 0 failures`.

### Slice 275: Set-heartbeats summaries and prompt cleanup flags

1. `set-heartbeats` now preserves the existing agent id, enabled status, and
   interval response fields while adding a stored-config `summary`.
2. The summary reports agent id, enabled state, interval, prompt-configured
   status, and update timestamp without returning the heartbeat prompt text.
3. Cleanup flags explicitly document that prompts, credentials, and secret
   values are omitted from the write response.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/heartbeat_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `63 tests, 0 failures`, covering enabled/disabled/default interval
   summaries and prompt omission. The broader control-plane parity gate passed
   with heartbeat, approval, node-pair-list, node-describe, node-list,
   node-event, system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `461 tests, 0 failures`.

### Slice 276: Node invocation response summaries

1. `node.invoke` now preserves the existing pending invocation response while
   adding a summary with node id, method, pending status, timeout, argument-key
   count, and cleanup flags.
2. `node.invoke.result` now preserves the existing acknowledgement response
   while adding a summary with invoke id, node id, terminal status, ok/result/
   error presence flags, and cleanup flags.
3. The node transport contract is unchanged: raw args/results continue to be
   stored and broadcast where the remote node protocol needs them, while
   control-plane method responses explicitly omit args, results, errors,
   credentials, and secret values.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `123 tests, 0 failures`, covering JSONL reload-safe node invocation,
   completed result summaries, and error result summaries. The broader
   control-plane parity gate passed with node invocation, heartbeat, approval,
   node-pair-list, node-describe, node-list, node-event, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets, status, introspection, schema, and
   atom-safety lanes: `461 tests, 0 failures`.

### Slice 277: Node-event acknowledgement summaries

1. `node.event` now validates that submitted payloads are objects before
   merging node metadata, avoiding direct-call crashes for malformed payloads.
2. The method preserves the existing event acknowledgement shape and adds a
   summary with event type, node id, custom-event status, payload key count, and
   cleanup flags.
3. The node event broadcast payload is unchanged for subscribers that need the
   raw node event data, while the control-plane acknowledgement explicitly omits
   payloads, message bodies, credentials, and secret values.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/event_type_validation_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/event_type_atom_leak_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `142 tests, 0 failures`, covering allowed/custom event summaries,
   malformed payload rejection, and atom-safety validation. The broader
   control-plane parity gate passed with node-event, node invocation, heartbeat,
   approval, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets, status, introspection, schema, and
   atom-safety lanes: `462 tests, 0 failures`.

### Slice 278: Node-rename response summaries

1. `node.rename` now preserves the existing acknowledgement shape while adding a
   compact summary for node id, renamed state, and whether the visible node name
   changed.
2. The response includes cleanup flags documenting that previous names,
   capabilities, metadata, credentials, and secret values are omitted from the
   write acknowledgement.
3. The unchanged-rename path is covered so clients can distinguish an idempotent
   rename without receiving the old name or any node metadata.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `125 tests, 0 failures`, covering successful rename summaries, unchanged
   rename summaries, metadata non-leakage, and protocol schema coverage. The
   broader control-plane parity gate passed with node-rename, node-event, node
   invocation, heartbeat, approval, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `463 tests, 0 failures`.

### Slice 279: Node-pairing lifecycle response summaries

1. `node.pair.request` now preserves pairing code delivery while adding a
   bounded summary for pairing id, node type, expiration, capability count, and
   explicit pairing-code credential delivery.
2. `node.pair.approve` now preserves node token and challenge token delivery
   while adding node id, node type, challenge expiration, capability count, and
   explicit token/challenge delivery metadata. The summary also documents that
   capabilities, metadata, and stored token hashes are not echoed.
3. `node.pair.reject` and `node.pair.verify` now return cleanup/status summaries
   without echoing pairing codes, approved tokens, challenge tokens, or secret
   values. Verification only returns `pairingId` in the same valid pending or
   approved paths that already exposed it.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `126 tests, 0 failures`, covering request, approve, reject, verify, list,
   rename, invoke, event, and schema paths. The broader control-plane parity
   gate passed with node-pairing lifecycle, node-rename, node-event, node
   invocation, heartbeat, approval, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `464 tests, 0 failures`.

### Slice 280: Connect-challenge token-delivery summaries

1. `connect.challenge` now preserves the required session token and identity
   response while adding a bounded summary for verified state, identity type,
   identity id, session-token TTL, and explicit session-token delivery.
2. The summary cleanup contract documents that the one-time challenge,
   challenge token, and secret values are not echoed after exchange.
3. Device and node pairing flows now assert the summary shape alongside the
   existing one-time challenge and token-store behavior.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/connect_challenge_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/device_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/node_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `157 tests, 0 failures`, covering device and node challenge exchange,
   one-time token use, token storage, pairing reload safety, and protocol
   schema coverage. The broader control-plane parity gate passed with
   connect-challenge, device-pairing, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval, node-pair-list,
   node-describe, node-list, system-presence, system-event, event ingest, event
   subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `491 tests, 0 failures`.

### Slice 281: Device-pairing lifecycle response summaries

1. `device.pair.request` now preserves pairing-code delivery while adding a
   bounded summary for pairing id, device type, expiration, and explicit
   pairing-code delivery.
2. `device.pair.approve` now preserves device token and challenge token
   delivery while adding pairing id, device type, challenge expiration, and
   explicit token/challenge delivery metadata.
3. `device.pair.reject` now returns pairing id, rejected status, device type,
   and cleanup flags without echoing pairing codes, device tokens, challenge
   tokens, or secret values.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/device_pair_string_keys_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/connect_challenge_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `133 tests, 0 failures`, covering device request, approve, reject,
   connect-challenge exchange, optional parity, and schema coverage. The
   broader control-plane parity gate passed with device-pairing lifecycle,
   connect-challenge, node-pairing lifecycle, node-rename, node-event, node
   invocation, heartbeat, approval, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `492 tests, 0 failures`.

### Slice 282: Approval request and resolve summaries

1. `exec.approval.request` now preserves approval id and expiration while adding
   a bounded summary for approval id, tool, run/session presence, action key
   count, and cleanup flags.
2. `exec.approval.resolve` now preserves the existing decision echo while adding
   a normalized decision summary and cleanup flags.
3. The request and resolve responses explicitly do not echo raw action payloads,
   rationale text, or secret values.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/exec_approvals_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_mapping_test.exs`:
   `150 tests, 0 failures`, covering approval request summary/redaction,
   resolve summary decisions, schemas, and event bridge lanes. The broader
   control-plane parity gate passed with approval request/resolve, device
   pairing, connect-challenge, node-pairing lifecycle, node-rename, node-event,
   node invocation, heartbeat, approval read policy, node-pair-list,
   node-describe, node-list, system-presence, system-event, event ingest, event
   subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `493 tests, 0 failures`.

### Slice 283: Approval policy write summaries

1. `exec.approvals.set` now preserves existing success and `approvals_set`
   fields while adding a mode summary for policy writes and pre-approval writes.
2. `exec.approvals.node.set` now preserves `nodeId`, success, and
   `approvals_set` fields while adding the same mode summary scoped to the
   target node.
3. Policy-mode summaries report policy tool count; pre-approval summaries
   report requested and stored approval counts. Both methods document that raw
   action payloads and secret values are not echoed.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/exec_approvals_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_mapping_test.exs`:
   `150 tests, 0 failures`, covering global and node policy/approval summary
   modes and action non-leakage. The broader control-plane parity gate passed
   with approval policy writes, approval request/resolve, device pairing,
   connect-challenge, node-pairing lifecycle, node-rename, node-event, node
   invocation, heartbeat, approval read policy, node-pair-list, node-describe,
   node-list, system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `493 tests, 0 failures`.

### Slice 284: Session-patch response summaries

1. `sessions.patch` now preserves existing success and session key fields while
   adding a compact summary for patched keys and patched count.
2. Patch summaries report key names only and explicitly avoid echoing tool
   policy, model names, or secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/sessions_patch_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `101 tests, 0 failures`, covering single-key and multi-key patch summaries,
   non-leakage, persisted policy overrides, and schema coverage. The broader
   control-plane parity gate passed with session patch, approval policy writes,
   approval request/resolve, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets, status, introspection, schema, and
   atom-safety lanes: `504 tests, 0 failures`.

### Slice 285: Session reset/delete cleanup summaries

1. `sessions.reset` now preserves success and session key while adding a cleanup
   summary for deleted run history, chat state, and session policy.
2. `sessions.delete` now preserves deleted state and session key while adding a
   cleanup summary for deleted run session, chat state, and session policy.
3. Both responses explicitly avoid echoing messages, policies, or secret values.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/sessions_patch_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `103 tests, 0 failures`, covering reset/delete cleanup summaries,
   non-leakage, session policy removal, session patch, and schema coverage. The
   broader control-plane parity gate passed with session reset/delete, session
   patch, approval policy writes, approval request/resolve, device pairing,
   connect-challenge, node-pairing lifecycle, node-rename, node-event, node
   invocation, heartbeat, approval read policy, node-pair-list, node-describe,
   node-list, system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets, status,
   introspection, schema, and atom-safety lanes: `506 tests, 0 failures`.

### Slice 286: Chat-abort target and dispatch summaries

1. `chat.abort` now preserves the existing aborted acknowledgement while adding
   a target summary for run-scoped and session-scoped abort requests.
2. The summary reports target type, target id, normalized user-requested reason,
   and dispatch status. Missing router registry state is handled as
   `router_unavailable` instead of crashing the control-plane method.
3. Abort acknowledgements explicitly avoid echoing prompts, messages, or secret
   values.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `92 tests, 0 failures`, covering run-scoped and session-scoped summaries and
   router-unavailable resilience. The broader control-plane parity gate passed
   with chat abort, session reset/delete, session patch, approval policy writes,
   approval request/resolve, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval read
   policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets, status, introspection, schema, and
   atom-safety lanes: `508 tests, 0 failures`.

### Slice 287: Talk-mode cleanup summaries

1. `talk.mode` now preserves the existing get/set response shape while adding a
   compact summary for session key, mode, and whether the request changed state.
2. The summary includes cleanup flags confirming the acknowledgement does not
   include audio bytes, transcripts, or secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `93 tests, 0 failures`, covering get and set summaries. The broader
   control-plane parity gate passed with talk mode, chat abort, session
   reset/delete, session patch, approval policy writes, approval
   request/resolve, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets, status, introspection, schema, and atom-safety
   lanes: `509 tests, 0 failures`.

### Slice 288: TTS configuration write summaries

1. `tts.enable`, `tts.disable`, and `tts.set-provider` now preserve their
   existing acknowledgement shapes while adding compact config-write summaries.
2. The summaries report action, enabled state or provider where applicable, and
   cleanup flags confirming the acknowledgement does not include input text,
   audio bytes, credential values, or secret values.
3. `tts.disable` now also summarizes the stored provider correctly when the
   persisted TTS config was reloaded with string keys.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `106 tests, 0 failures`, covering enable/disable/provider-write summaries
   and string-keyed config reload behavior. The broader control-plane parity
   gate passed with TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes, approval
   request/resolve, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets, status, introspection, schema, and atom-safety
   lanes: `510 tests, 0 failures`.

### Slice 289: Voicewake write cleanup summary

1. `voicewake.set` now preserves the explicit voicewake configuration response
   while adding a compact summary for enabled state, backend, keyword
   configuration, and sensitivity configuration.
2. The summary includes cleanup flags confirming the acknowledgement does not
   include audio bytes, transcripts, credential values, or secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `106 tests, 0 failures`, covering voicewake write summaries alongside the
   optional parity schema lane. The broader control-plane parity gate passed
   with voicewake writes, TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes, approval
   request/resolve, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets, status, introspection, schema, and atom-safety
   lanes: `510 tests, 0 failures`.

### Slice 290: Direct channel-send delivery summary

1. `send` now preserves the existing success acknowledgement and delivery ref
   while adding a bounded delivery summary for channel id, account-id presence,
   peer-id presence, content byte count, and idempotency-key presence.
2. The summary includes cleanup flags confirming the acknowledgement does not
   include message content, attachments, credentials, or secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/send_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/send_idempotency_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `62 tests, 0 failures`, covering cached idempotent sends and direct send
   summary shape. The broader control-plane parity gate passed with send,
   voicewake writes, TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes, approval
   request/resolve, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets, status, introspection, schema, and atom-safety
   lanes: `521 tests, 0 failures`.

### Slice 291: Channel logout cleanup summary

1. `channels.logout` now preserves the existing success acknowledgement and
   channel id while adding a compact logout summary for operator clients.
2. The summary confirms logout completion and includes cleanup flags for
   credentials, session tokens, adapter state, and secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/channels_logout_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `53 tests, 0 failures`, covering successful logout through a disposable
   channel plugin and the required `channelId` validation path. The broader
   control-plane parity gate passed with channel logout, send, voicewake
   writes, TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, device
   pairing, connect-challenge, node-pairing lifecycle, node-rename, node-event,
   node invocation, heartbeat, approval read policy, node-pair-list,
   node-describe, node-list, system-presence, system-event, event ingest, event
   subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `523 tests, 0 failures`.

### Slice 292: Config patch value-cleanup summary

1. `config.patch` now preserves the existing success acknowledgement and
   applied-key list while adding a compact patch summary.
2. The summary reports applied count, applied keys, sensitive-key count, and
   cleanup flags confirming response values, credential values, and secret
   values are not echoed.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `107 tests, 0 failures`, covering ordinary patch summaries and sensitive
   key classification without value echo. The broader control-plane parity
   gate passed with config patch, channel logout, send, voicewake writes, TTS
   config writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, device pairing,
   connect-challenge, node-pairing lifecycle, node-rename, node-event, node
   invocation, heartbeat, approval read policy, node-pair-list, node-describe,
   node-list, system-presence, system-event, event ingest, event
   subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity,
   secrets, status, introspection, schema, and atom-safety lanes:
   `524 tests, 0 failures`.

### Slice 293: Secrets lifecycle no-value summaries

1. `secrets.list`, `secrets.set`, `secrets.delete`, and `secrets.exists` now
   preserve their existing response shapes while adding compact lifecycle
   summaries.
2. The summaries cover metadata counts, provider counts, existence state,
   deletion state, expiration/version metadata, env fallback options, and
   cleanup flags confirming secret values, raw key material, and credential
   values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/secrets_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `54 tests, 0 failures`, covering end-to-end set/list/exists/delete/status
   behavior without plaintext value echo. The broader control-plane parity gate
   passed with secrets lifecycle, config patch, channel logout, send,
   voicewake writes, TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes, approval
   request/resolve, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `524 tests, 0 failures`.

### Slice 294: Config set cleanup summary

1. `config.set` now preserves the existing key/value/success acknowledgement
   while adding a compact write summary.
2. The summary reports key, stored-value presence, whether the key is sensitive,
   and cleanup flags. Non-sensitive values remain visible for compatibility,
   while sensitive config values stay redacted and report
   `includesValue: false`.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `107 tests, 0 failures`, covering non-sensitive and sensitive config write
   summaries. The broader control-plane parity gate passed with config set,
   secrets lifecycle, config patch, channel logout, send, voicewake writes, TTS
   config writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, device pairing,
   connect-challenge, node-pairing lifecycle, node-rename, node-event, node
   invocation, heartbeat, approval read policy, node-pair-list, node-describe,
   node-list, system-presence, system-event, event ingest, event
   subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity,
   secrets status, status, introspection, schema, and atom-safety lanes:
   `524 tests, 0 failures`.

### Slice 295: Config schema property summary

1. `config.schema` now preserves the schema payload while adding a compact
   property summary for clients that only need schema shape.
2. The summary reports schema type, property count, property keys, and cleanup
   flags confirming no runtime config values, credential values, or secret
   values are included.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `107 tests, 0 failures`, covering schema property summaries. The broader
   control-plane parity gate passed with config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch, approval
   policy writes, approval request/resolve, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `524 tests, 0 failures`.

### Slice 296: Agent endpoint lifecycle summaries

1. `agent.endpoints.list`, `agent.endpoints.set`, and
   `agent.endpoints.delete` now preserve their existing response shapes while
   adding bounded endpoint lifecycle summaries.
2. The summaries report endpoint counts, channel counts, route channel,
   peer/thread presence, deletion state, and cleanup flags confirming endpoint
   acknowledgements do not include credentials or secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/agent_routing_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `56 tests, 0 failures`, covering set/list/delete summary shape across the
   alias lifecycle. The broader control-plane parity gate passed with agent
   endpoint summaries, config schema, config set, secrets lifecycle,
   config patch, channel logout, send, voicewake writes, TTS config writes,
   talk mode, chat abort, session reset/delete, session patch, approval policy
   writes, approval request/resolve, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `524 tests, 0 failures`.

### Slice 297: Agent inbox submission cleanup summary

1. `agent.inbox.send` now preserves the existing run/session/selector/fanout
   acknowledgement while adding a bounded submission summary.
2. The summary reports agent id, prompt byte count, queue mode, selector,
   session-key presence, route target presence, fanout count, deliver-to count,
   and cleanup flags confirming prompt text, message bodies, credentials, and
   secret values are not echoed.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/agent_routing_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `56 tests, 0 failures`, covering routed Telegram shorthand, fanout, and
   queue-mode override summaries. The broader control-plane parity gate passed
   with agent inbox summaries, agent endpoint summaries, config schema, config
   set, secrets lifecycle, config patch, channel logout, send, voicewake
   writes, TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, device
   pairing, connect-challenge, node-pairing lifecycle, node-rename, node-event,
   node invocation, heartbeat, approval read policy, node-pair-list,
   node-describe, node-list, system-presence, system-event, event ingest, event
   subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, model-catalog, optional parity, secrets status,
   status, introspection, schema, and atom-safety lanes:
   `524 tests, 0 failures`.

### Slice 298: Agent identity capability summary

1. `agent.identity.get` now preserves the existing identity/profile response
   while adding a compact capability summary for clients that need profile
   shape without scraping the full capability map.
2. The summary reports agent id, name, default engine, description/avatar
   presence, capability count, enabled capability names, and cleanup flags
   confirming credentials and secret values are not included.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `93 tests, 0 failures`, covering default identity summaries and cleanup
   flags. The broader control-plane parity gate passed with agent identity
   summaries, agent inbox summaries, agent endpoint summaries, config schema,
   config set, secrets lifecycle, config patch, channel logout, send,
   voicewake writes, TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes,
   approval request/resolve, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `524 tests, 0 failures`.

### Slice 299: Agent progress polling summary

1. `agent.progress` now preserves the existing long-running harness snapshot
   while adding a bounded progress summary for lightweight polling clients.
2. The summary reports session id, cwd, overall percentage, todo and feature
   counts, checkpoint presence/counts, next-action counts, and cleanup flags
   confirming next-action content, prompts, message bodies, credentials, and
   secret values are not included.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `96 tests, 0 failures`, covering progress summary counts and cleanup flags.
   The broader control-plane parity gate passed with agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes,
   approval request/resolve, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `527 tests, 0 failures`.

### Slice 300: Agent file operation summaries

1. `agents.files.list`, `agents.files.get`, and `agents.files.set` now
   preserve their existing file-list, content-read, and write acknowledgement
   shapes while adding bounded file operation summaries.
2. The summaries report agent id, file name/type/size metadata, file counts,
   total listed bytes, content-return state for reads, and cleanup flags for
   responses that do not echo file content, credentials, or secret values.
   `agents.files.get` intentionally still returns file content in the primary
   response and marks that explicitly with `contentReturned`.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `99 tests, 0 failures`, covering list/get/set summaries and content cleanup
   assertions. The broader control-plane parity gate passed with agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, device pairing,
   connect-challenge, node-pairing lifecycle, node-rename, node-event, node
   invocation, heartbeat, approval read policy, node-pair-list, node-describe,
   node-list, system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage,
   monitoring, agent-routing, model-catalog, optional parity, secrets status,
   status, introspection, schema, and atom-safety lanes:
   `530 tests, 0 failures`.

### Slice 301: Core agent submission and wait summaries

1. `agent` now preserves the existing run submission acknowledgement while
   adding a prompt-cleanup summary for fresh or idempotent submissions.
2. `agent.wait` now preserves completed-run answer/error results while adding a
   bounded result summary with answer byte count, answer-return state,
   error presence/kind, and cleanup flags that do not echo prompts,
   credentials, or secret values. The response still intentionally returns the
   answer in its primary `answer` field.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `105 tests, 0 failures`, covering idempotent submission summaries and
   completed-run wait summaries without starting a model run. The broader
   control-plane parity gate passed with agent submission/wait summaries,
   agent file summaries, agent progress summaries, agent identity summaries,
   agent inbox summaries, agent endpoint summaries, config schema, config set,
   secrets lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, device
   pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `536 tests, 0 failures`.

### Slice 302: Config read cleanup summary

1. `config.get` now preserves single-key and all-config read behavior while
   adding key-count, sensitive-key, found/value-returned, and cleanup
   summaries.
2. The summary distinguishes normal config values, which may still be returned
   by design, from sensitive config values, which remain redacted and are
   counted without echoing credential or secret material.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `107 tests, 0 failures`, covering single-key summaries, all-config
   summaries, and sensitive-key redaction summaries. The broader
   control-plane parity gate passed with config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes,
   approval request/resolve, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `536 tests, 0 failures`.

### Slice 303: TTS provider catalog summary

1. `tts.providers` now preserves the existing provider list while adding a
   compact provider/voice summary for clients that only need catalog shape.
2. The summary reports provider count, available-provider count, provider ids,
   voice count, and cleanup flags confirming credential values, secret values,
   and raw provider errors are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `107 tests, 0 failures`, covering TTS provider catalog summaries. The
   broader control-plane parity gate passed with TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, device
   pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `536 tests, 0 failures`.

### Slice 304: Chat send submission summary

1. `chat.send` now preserves the existing run/session acknowledgement while
   adding bounded prompt-cleanup submission metadata.
2. The summary reports run id, session key, agent id, queue mode, prompt byte
   count, and cleanup flags confirming prompt text, message bodies,
   credentials, and secret values are not echoed.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `108 tests, 0 failures`, covering an Echo-routed chat submission summary.
   The broader control-plane parity gate passed with chat send summaries,
   TTS provider summaries, config read summaries, agent submission/wait
   summaries, agent file summaries, agent progress summaries, agent identity
   summaries, agent inbox summaries, agent endpoint summaries, config schema,
   config set, secrets lifecycle, config patch, channel logout, send,
   voicewake writes, TTS config writes, talk mode, chat abort, session
   reset/delete, session patch, approval policy writes, approval
   request/resolve, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `539 tests, 0 failures`.

### Slice 305: Goal objective redaction summaries

1. `goal.set`, `goal.status`, `goal.pause`, and `goal.resume` now return
   objective byte counts and cleanup summaries instead of echoing the durable
   objective text.
2. `goal.status` also reports bounded list/read summaries with goal count,
   status counts, active filters, and no-objective cleanup flags.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/goal_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `54 tests, 0 failures`, covering redacted set/status/pause/resume
   responses plus existing goal continuation and loop contracts. The broader
   control-plane parity gate passed with goal objective redaction summaries,
   chat send summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `542 tests, 0 failures`.

### Slice 306: Goal clear cleanup summary

1. `goal.clear` now preserves the existing cleared acknowledgement while
   adding a bounded cleanup summary for clients and support tooling.
2. The summary reports session key, cleared state, objective-return state, and
   cleanup flags confirming objective text, prompts, message bodies,
   credentials, and secret values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/goal_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `54 tests, 0 failures`, covering goal-clear cleanup summaries alongside
   the redacted goal objective read/write responses. The broader
   control-plane parity gate passed with goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, device
   pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `542 tests, 0 failures`.

### Slice 307: Goal continuation and loop cleanup summaries

1. `goal.continue`, `goal.loop.once`, `goal.loop.start`,
   `goal.loop.status`, and `goal.loop.stop` now preserve their operational
   result fields while adding bounded cleanup summaries.
2. Continuation and loop summaries report run/session/agent or loop status,
   objective byte counts where a goal is present, verdict reason byte counts
   for loop ticks, and cleanup flags confirming objective text, prompt text,
   message bodies, credentials, and secret values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/goal_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `54 tests, 0 failures`, covering continuation and loop cleanup summaries.
   The broader control-plane parity gate passed with goal continuation/loop
   cleanup summaries, goal clear cleanup summaries, goal objective redaction
   summaries, chat send summaries, TTS provider summaries, config read
   summaries, agent submission/wait summaries, agent file summaries, agent
   progress summaries, agent identity summaries, agent inbox summaries,
   agent endpoint summaries, config schema, config set, secrets lifecycle,
   config patch, channel logout, send, voicewake writes, TTS config writes,
   talk mode, chat abort, session reset/delete, session patch, approval policy
   writes, approval request/resolve, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage,
   monitoring, agent-routing, model-catalog, optional parity, secrets status,
   status, introspection, schema, and atom-safety lanes:
   `542 tests, 0 failures`.

### Slice 308: Cron list target-text redaction summary

1. `cron.list` now redacts scheduled prompt and command text by default while
   returning prompt/command byte counts and per-job cleanup summaries.
2. Trusted operator clients can pass `includeTargetText: true` to preserve the
   previous raw prompt/command text view, and the response reports that
   opt-in through top-level and per-job summaries.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering default redaction and explicit target-text
   opt-in. The broader control-plane parity gate passed with cron-list
   target-text redaction summaries, goal continuation/loop cleanup summaries,
   goal clear cleanup summaries, goal objective redaction summaries, chat send
   summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage,
   monitoring, agent-routing, model-catalog, optional parity, secrets status,
   status, introspection, schema, and atom-safety lanes:
   `555 tests, 0 failures`.

### Slice 309: Cron status cleanup summary

1. `cron.status` now preserves the existing BEAM scheduler-health counters
   while adding a bounded summary for operator clients and support tooling.
2. The summary reports enabled state, job counts, active/recent/failed/retry
   run counts, scheduler-lock/recovery counters, and cleanup flags confirming
   prompt text, command text, output text, error text, message bodies,
   credentials, and secret values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering scheduler-health cleanup summaries. The
   broader control-plane parity gate passed with cron-status cleanup summaries,
   cron-list target-text redaction summaries, goal continuation/loop cleanup
   summaries, goal clear cleanup summaries, goal objective redaction
   summaries, chat send summaries, TTS provider summaries, config read
   summaries, agent submission/wait summaries, agent file summaries, agent
   progress summaries, agent identity summaries, agent inbox summaries,
   agent endpoint summaries, config schema, config set, secrets lifecycle,
   config patch, channel logout, send, voicewake writes, TTS config writes,
   talk mode, chat abort, session reset/delete, session patch, approval policy
   writes, approval request/resolve, cron lifecycle methods, device pairing,
   connect-challenge, node-pairing lifecycle, node-rename, node-event,
   node invocation, heartbeat, approval read policy, node-pair-list,
   node-describe, node-list, system-presence, system-event, event ingest,
   event subscriptions, WebSocket connection, EventBridge, EventBridge
   mapping coverage, monitoring, agent-routing, model-catalog, optional
   parity, secrets status, status, introspection, schema, and atom-safety
   lanes: `555 tests, 0 failures`.

### Slice 310: Cron audit lifecycle summary

1. `cron.audit` now preserves authorized operator lifecycle rows while adding
   a bounded summary for audit consumers.
2. The summary reports event count, action counts, active filters,
   raw-id-return state, lifecycle-reason return state, and cleanup flags
   confirming prompt text, command text, output text, error text, message
   bodies, credentials, and secret values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering operator-facing audit summaries. The
   broader control-plane parity gate passed with cron-audit lifecycle
   summaries, cron-status cleanup summaries, cron-list target-text redaction
   summaries, goal continuation/loop cleanup summaries, goal clear cleanup
   summaries, goal objective redaction summaries, chat send summaries,
   TTS provider summaries, config read summaries, agent submission/wait
   summaries, agent file summaries, agent progress summaries, agent identity
   summaries, agent inbox summaries, agent endpoint summaries, config schema,
   config set, secrets lifecycle, config patch, channel logout, send,
   voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage,
   monitoring, agent-routing, model-catalog, optional parity, secrets status,
   status, introspection, schema, and atom-safety lanes:
   `555 tests, 0 failures`.

### Slice 311: Cron write lifecycle summaries

1. `cron.add`, `cron.update`, `cron.pause`, `cron.resume`, and `cron.abort`
   now preserve their existing lifecycle acknowledgements while adding bounded
   summaries for operator clients.
2. Add/update summaries report target byte counts and changed fields without
   prompt or command text; pause/resume summaries report lifecycle state;
   abort summaries report raw-id-return state while cleanup flags confirm
   prompt text, command text, output text, error text, message bodies,
   credentials, and secret values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering cron write lifecycle summaries. The
   broader control-plane parity gate passed with cron write lifecycle
   summaries, cron-audit lifecycle summaries, cron-status cleanup summaries,
   cron-list target-text redaction summaries, goal continuation/loop cleanup
   summaries, goal clear cleanup summaries, goal objective redaction
   summaries, chat send summaries, TTS provider summaries, config read
   summaries, agent submission/wait summaries, agent file summaries, agent
   progress summaries, agent identity summaries, agent inbox summaries,
   agent endpoint summaries, config schema, config set, secrets lifecycle,
   config patch, channel logout, send, voicewake writes, TTS config writes,
   talk mode, chat abort, session reset/delete, session patch, approval policy
   writes, approval request/resolve, cron lifecycle methods, device pairing,
   connect-challenge, node-pairing lifecycle, node-rename, node-event,
   node invocation, heartbeat, approval read policy, node-pair-list,
   node-describe, node-list, system-presence, system-event, event ingest,
   event subscriptions, WebSocket connection, EventBridge, EventBridge
   mapping coverage, monitoring, agent-routing, model-catalog, optional
   parity, secrets status, status, introspection, schema, and atom-safety
   lanes: `555 tests, 0 failures`.

### Slice 312: Cron run-history lifecycle summaries

1. `cron.run`, `cron.remove`, and `cron.runs` now preserve their existing
   lifecycle/run-history payloads while adding bounded summaries for operator
   clients.
2. Manual-trigger and removal summaries report raw-id-return state with cleanup
   flags confirming prompt text, command text, output text, error text, message
   bodies, credentials, and secret values are not returned. Run-history
   summaries report run counts, status counts, output/error byte counts,
   output-preview/full-output state, meta/run-record/introspection include
   state, raw-id-return state, and cleanup flags that make operator-requested
   previews or internals explicit.
   Slice 330 later tightened this response path so output/error text and
   optional meta, run-record, and introspection internals redact sensitive keys
   and common inline credential patterns.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `67 tests, 0 failures`, covering cron run-history lifecycle summaries.
   The broader control-plane parity gate passed with cron run-history
   lifecycle summaries, cron write lifecycle summaries, cron-audit lifecycle
   summaries, cron-status cleanup summaries, cron-list target-text redaction
   summaries, goal continuation/loop cleanup summaries, goal clear cleanup
   summaries, goal objective redaction summaries, chat send summaries,
   TTS provider summaries, config read summaries, agent submission/wait
   summaries, agent file summaries, agent progress summaries, agent identity
   summaries, agent inbox summaries, agent endpoint summaries, config schema,
   config set, secrets lifecycle, config patch, channel logout, send,
   voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage,
   monitoring, agent-routing, model-catalog, optional parity, secrets status,
   status, introspection, schema, and atom-safety lanes:
   `558 tests, 0 failures`.

### Slice 313: Checkpoint diff and restore cleanup summaries

1. `checkpoint.diff` now preserves changed paths, structured diffs, and unified
   diff output while adding a summary that reports changed count, diff byte
   count, path-return state, diff-output state, raw-session-id state, and
   cleanup flags for paths, diff text, file-content text, credentials, and
   secret values.
2. `checkpoint.restore` now preserves restored paths while adding a summary
   that reports restored count, path-return state, raw-session-id state, and
   cleanup flags confirming file content, diff text, credentials, and secret
   values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `117 tests, 0 failures`, covering checkpoint diff/restore summaries. The
   broader control-plane parity gate passed with checkpoint diff/restore
   summaries, cron run-history lifecycle summaries, cron write lifecycle
   summaries, cron-audit lifecycle summaries, cron-status cleanup summaries,
   cron-list target-text redaction summaries, goal continuation/loop cleanup
   summaries, goal clear cleanup summaries, goal objective redaction summaries,
   chat send summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `558 tests, 0 failures`.

### Slice 314: Browser request result cleanup summaries

1. `browser.request` now preserves paired-node and local-fallback browser
   request behavior while adding a browser-specific summary to successful
   responses.
2. The summary reports dispatch mode, normalized method, awaited state, timeout,
   result/error return state, network-policy return state, and cleanup flags
   for raw URLs, selectors, typed text, page content, screenshot data, cookie
   values, evaluated results, error text, credentials, and secret values. When
   the request dispatches through `node.invoke`, the original node invocation
   summary is retained as `nodeInvokeSummary`.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `117 tests, 0 failures`, covering browser request summaries with no compile
   warnings. The broader control-plane parity gate passed with browser request
   summaries, checkpoint diff/restore summaries, cron run-history lifecycle
   summaries, cron write lifecycle summaries, cron-audit lifecycle summaries,
   cron-status cleanup summaries, cron-list target-text redaction summaries,
   goal continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, cron
   lifecycle methods, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `558 tests, 0 failures`.

### Slice 315: Channel status readiness summaries

1. `channels.status` now preserves adapter status, redacted channel
   diagnostics, and recent channel proof state while adding a top-level summary
   for promoted Telegram/Discord operator views.
2. The summary reports channel count, diagnostic transport count, binding
   count, unsupported binding count, proof count, check count, promoted
   platform scope, and cleanup flags confirming raw bot tokens, secret names,
   chat IDs, channel IDs, guild IDs, message bodies, proof paths, proof
   details, prompts, and provider responses are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `117 tests, 0 failures`, covering channel status summaries. The broader
   control-plane parity gate passed with channel status summaries, browser
   request summaries, checkpoint diff/restore summaries, cron run-history
   lifecycle summaries, cron write lifecycle summaries, cron-audit lifecycle
   summaries, cron-status cleanup summaries, cron-list target-text redaction
   summaries, goal continuation/loop cleanup summaries, goal clear cleanup
   summaries, goal objective redaction summaries, chat send summaries,
   TTS provider summaries, config read summaries, agent submission/wait
   summaries, agent file summaries, agent progress summaries, agent identity
   summaries, agent inbox summaries, agent endpoint summaries, config schema,
   config set, secrets lifecycle, config patch, channel logout, send,
   voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `558 tests, 0 failures`.

### Slice 316: LSP document lifecycle cleanup summaries

1. `lsp.document.open`, `lsp.document.change`, and `lsp.document.close` now
   preserve their supervised LSP document lifecycle responses while adding
   document cleanup summaries.
2. The summaries report lifecycle action, document status, version, document
   byte count, change count, raw-URI return state, document-text return state,
   and cleanup flags confirming raw URIs, document text, credentials, and
   secret values are not returned.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `117 tests, 0 failures`, covering LSP document lifecycle summaries. The
   broader control-plane parity gate passed with LSP document summaries,
   channel status summaries, browser request summaries, checkpoint diff/restore
   summaries, cron run-history lifecycle summaries, cron write lifecycle
   summaries, cron-audit lifecycle summaries, cron-status cleanup summaries,
   cron-list target-text redaction summaries, goal continuation/loop cleanup
   summaries, goal clear cleanup summaries, goal objective redaction summaries,
   chat send summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation, heartbeat,
   approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `558 tests, 0 failures`.

### Slice 317: LSP server lifecycle cleanup summaries

1. `lsp.server.start`, `lsp.server.initialize`, `lsp.server.request`, and
   `lsp.server.stop` now preserve their supervised LSP lifecycle/protocol
   payloads while adding bounded summaries.
2. Start/stop summaries report server id, lifecycle status, session-id return
   state, session-hash return state, command/cwd hash return state, diagnostic
   counts, pending request counts, and cleanup flags for raw cwd, executable
   paths, server IO, diagnostic text, credentials, and secret values.
   Initialize/request summaries report method, timeout, result/error return
   state, protocol-response return state, raw-session-id return state, and
   cleanup flags for request params, protocol results, protocol errors, server
   IO, credentials, and secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `117 tests, 0 failures`, covering LSP server lifecycle summaries. The
   broader control-plane parity gate passed with LSP server summaries, LSP
   document summaries, channel status summaries, browser request summaries,
   checkpoint diff/restore summaries, cron run-history lifecycle summaries,
   cron write lifecycle summaries, cron-audit lifecycle summaries, cron-status
   cleanup summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, cron
   lifecycle methods, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `558 tests, 0 failures`.

### Slice 318: Config and system reload lifecycle summaries

1. `config.reload` now preserves the runtime config reload payload while
   adding a lifecycle summary for changed source counts, changed config-path
   counts, action counts, warning counts, reload id return state, applied
   timestamp, and cleanup flags for config values, environment values, secret
   values, file contents, and credential values.
2. `system.reload` now preserves module/app/extension/all reload payloads while
   adding a lifecycle summary for kind/status, target return state, result
   counts, reloaded/skipped/error counts, duration, metadata return state,
   extension-path return state, and cleanup flags for source code, file
   contents, compile output, raw process state, credentials, and secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/config_reload_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/system_reload_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering config/system reload summaries. The
   broader control-plane parity gate passed with reload summaries, LSP server
   summaries, LSP document summaries, channel status summaries, browser request
   summaries, checkpoint diff/restore summaries, cron run-history lifecycle
   summaries, cron write lifecycle summaries, cron-audit lifecycle summaries,
   cron-status cleanup summaries, cron-list target-text redaction summaries,
   goal continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, cron
   lifecycle methods, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `571 tests, 0 failures`.

### Slice 319: Run graph and introspection return-state summaries

1. `run.graph.get` now preserves the parent/child graph payload while adding
   node counts, status counts, option state, graph-return state, and cleanup
   flags that make optional raw run records, raw run events, and introspection
   payloads explicit.
2. `run.introspection.list` now preserves the timeline payload while adding
   event counts, event-type counts, run-record return state, option state, and
   cleanup flags that make event payloads, raw run records, and raw run events
   explicit.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/monitoring_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `134 tests, 0 failures`, covering run graph/introspection return-state
   summaries. The broader control-plane parity gate passed with run
   graph/introspection summaries, reload summaries, LSP server summaries, LSP
   document summaries, channel status summaries, browser request summaries,
   checkpoint diff/restore summaries, cron run-history lifecycle summaries,
   cron write lifecycle summaries, cron-audit lifecycle summaries, cron-status
   cleanup summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, cron
   lifecycle methods, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `576 tests, 0 failures`.

### Slice 320: Health and root status runtime summaries

1. `health` now preserves its public runtime payload while adding a summary for
   ok state, uptime, memory, scheduler count, and cleanup flags for raw process
   state, credentials, and secret values.
2. `status` now preserves server, connection, run, channel, and skill status
   payloads while adding a summary for version, BEAM capacity counters, run
   queue, connection/run/channel/skill counts, and cleanup flags for raw process
   state, channel credentials, skill sources, and secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/status_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `54 tests, 0 failures`, covering public health and root status summaries.
   The broader control-plane parity gate passed with health/status summaries,
   run graph/introspection summaries, reload summaries, LSP server summaries,
   LSP document summaries, channel status summaries, browser request summaries,
   checkpoint diff/restore summaries, cron run-history lifecycle summaries,
   cron write lifecycle summaries, cron-audit lifecycle summaries, cron-status
   cleanup summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, cron
   lifecycle methods, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `577 tests, 0 failures`.

### Slice 321: Active-session and introspection snapshot summaries

1. `sessions.active` now preserves its lightweight active-run lookup while
   adding active state, session-key return state, run-id return state, and
   cleanup flags for run records, run events, message text, credentials, and
   secret values.
2. `introspection.snapshot` now preserves its consolidated agents/sessions/
   active-sessions/channels/transports/runs payload while adding include flags,
   applied filters, section counts, run counts, error counts, harness counts,
   and cleanup flags for returned section records, harness snapshots, channel
   status, transport status, error details, message text, credentials, and
   secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `62 tests, 0 failures`, covering active-session and snapshot summaries. The
   broader control-plane parity gate passed with introspection snapshot
   summaries, health/status summaries, run graph/introspection summaries,
   reload summaries, LSP server summaries, LSP document summaries, channel
   status summaries, browser request summaries, checkpoint diff/restore
   summaries, cron run-history lifecycle summaries, cron write lifecycle
   summaries, cron-audit lifecycle summaries, cron-status cleanup summaries,
   cron-list target-text redaction summaries, goal continuation/loop cleanup
   summaries, goal clear cleanup summaries, goal objective redaction summaries,
   chat send summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation, heartbeat,
   approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `579 tests, 0 failures`.

### Slice 322: Memory and secrets status summaries

1. `memory.status` now preserves its redacted memory-provider status payload
   while adding provider counts, enabled-provider counts, health status,
   searchable-scope counts, and the existing cleanup metadata as a top-level
   summary for non-Web clients.
2. `secrets.status` now preserves its redacted secrets-store health payload
   while adding configured/healthy state, source, keychain/env/file fallback
   flags, secret counts, and the existing cleanup metadata as a top-level
   summary.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/secrets_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `120 tests, 0 failures`, covering memory-provider and secrets-store status
   summaries. The broader control-plane parity gate passed with memory/secrets
   summaries, introspection snapshot summaries, health/status summaries, run
   graph/introspection summaries, reload summaries, LSP server summaries, LSP
   document summaries, channel status summaries, browser request summaries,
   checkpoint diff/restore summaries, cron run-history lifecycle summaries,
   cron write lifecycle summaries, cron-audit lifecycle summaries, cron-status
   cleanup summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, cron
   lifecycle methods, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `579 tests, 0 failures`.

### Slice 323: Provider, proof, and extension status summaries

1. `providers.status` now preserves its redacted provider readiness, routing,
   and live fallback proof payload while adding provider counts, ready-provider
   counts, default-provider/model presence, selected provider, routing decision,
   fallback proof status, proof-scope count, and cleanup metadata.
2. `proofs.status` now preserves its redacted proof inventory, recent proof
   rows, latest checks, and launch-gate payload while adding proof/check counts,
   status counts, applied limit, per-launch-gate statuses, and cleanup metadata.
3. `extensions.status` now preserves its redacted extension, path, execution,
   provider-registration, tool-conflict, host-runtime, and WASM diagnostics
   while adding extension/path/error/provider/conflict counts, execution
   counts, host statuses, and cleanup metadata.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `117 tests, 0 failures`, covering provider, proof, and extension status
   summaries. The broader control-plane parity gate passed with provider/proof/
   extension summaries, memory/secrets summaries, introspection snapshot
   summaries, health/status summaries, run graph/introspection summaries,
   reload summaries, LSP server summaries, LSP document summaries, channel
   status summaries, browser request summaries, checkpoint diff/restore
   summaries, cron run-history lifecycle summaries, cron write lifecycle
   summaries, cron-audit lifecycle summaries, cron-status cleanup summaries,
   cron-list target-text redaction summaries, goal continuation/loop cleanup
   summaries, goal clear cleanup summaries, goal objective redaction summaries,
   chat send summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation, heartbeat,
   approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `579 tests, 0 failures`.

### Slice 324: Terminal backend and LSP diagnostics status summaries

1. `terminal.backends.status` now preserves its registered backend, policy,
   live-proof, and Docker hardening payload while adding backend counts,
   available-backend counts, allowlist/approval policy counts, live-proof
   status/counts, Docker hardening return state, and cleanup metadata.
2. `lsp.diagnostics.status` now preserves its diagnostics capability,
   executable, server-manager, registry, proof, and cleanup payload while
   adding status, timeout, language/executable/server/proof/check counts,
   server-manager state, proof-error return state, and cleanup metadata.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `117 tests, 0 failures`, covering terminal backend and LSP diagnostics
   status summaries. The broader control-plane parity gate passed with
   terminal/LSP status summaries, provider/proof/extension summaries,
   memory/secrets summaries, introspection snapshot summaries, health/status
   summaries, run graph/introspection summaries, reload summaries, LSP server
   summaries, LSP document summaries, channel status summaries, browser
   request summaries, checkpoint diff/restore summaries, cron run-history
   lifecycle summaries, cron write lifecycle summaries, cron-audit lifecycle
   summaries, cron-status cleanup summaries, cron-list target-text redaction
   summaries, goal continuation/loop cleanup summaries, goal clear cleanup
   summaries, goal objective redaction summaries, chat send summaries, TTS
   provider summaries, config read summaries, agent submission/wait summaries,
   agent file summaries, agent progress summaries, agent identity summaries,
   agent inbox summaries, agent endpoint summaries, config schema, config set,
   secrets lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete,
   session patch, approval policy writes, approval request/resolve, cron
   lifecycle methods, device pairing, connect-challenge, node-pairing
   lifecycle, node-rename, node-event, node invocation, heartbeat, approval
   read policy, node-pair-list, node-describe, node-list, system-presence,
   system-event, event ingest, event subscriptions, WebSocket connection,
   EventBridge, EventBridge mapping coverage, monitoring, agent-routing,
   model-catalog, optional parity, secrets status, status, introspection,
   schema, and atom-safety lanes: `579 tests, 0 failures`.

### Slice 325: Kanban board, task, and dispatcher summaries

1. `kanban.board.create`, `kanban.board.list`, `kanban.board.get`, and
   `kanban.board.archive` now preserve their board/task payloads while adding
   board return-state, filter, column, task-count, task-status, archive-state,
   and cleanup summaries.
2. `kanban.task.create`, `kanban.task.update`, and `kanban.task.comment` now
   preserve their task payloads while adding task return-state, dependency,
   comment, session/run return-state, and cleanup summaries.
3. `kanban.dispatcher.start`, `kanban.dispatcher.status`, and
   `kanban.dispatcher.stop` now preserve dispatcher payloads while adding
   running, dispatcher-return, board-id, worker, concurrency, running-count,
   and cleanup summaries.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/kanban_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `55 tests, 0 failures`, covering Kanban board/task/dispatcher summaries.
   The broader control-plane parity gate, expanded to include Kanban methods,
   passed with Kanban summaries, terminal/LSP status summaries, provider/proof/
   extension summaries, memory/secrets summaries, introspection snapshot
   summaries, health/status summaries, run graph/introspection summaries,
   reload summaries, LSP server summaries, LSP document summaries, channel
   status summaries, browser request summaries, checkpoint diff/restore
   summaries, cron run-history lifecycle summaries, cron write lifecycle
   summaries, cron-audit lifecycle summaries, cron-status cleanup summaries,
   cron-list target-text redaction summaries, goal continuation/loop cleanup
   summaries, goal clear cleanup summaries, goal objective redaction summaries,
   chat send summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation, heartbeat,
   approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `583 tests, 0 failures`.

### Slice 326: Remaining capability helper summaries

1. `skills.bins`, `skills.install`, and `skills.update` now preserve their
   existing payloads while adding action, count, return-state, environment-key,
   approval-context, and cleanup summaries. Slice 328 later tightened
   `skills.update` so sensitive env response values are redacted while safe env
   keys remain visible.
2. `tts.convert`, `update.run`, and `wake` now preserve their conversion,
   update-check, and run-trigger payloads while adding provider/format,
   current/latest version, force/check-only, prompt byte-count, returned-id,
   and cleanup summaries without echoing text, prompts, credentials, or secret
   values.
3. `wizard.start`, `wizard.step`, and `wizard.cancel` now report wizard
   return-state, step counts, current step, completion state, wizard data-key
   counts, and cleanup summaries. The new success-path test also fixed a real
   `wizard.step` crash when advancing a freshly started wizard before the
   `updated_at_ms` key existed.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/skills_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/skills_approval_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `255 tests, 0 failures`, covering remaining capability helper summaries.
   The broader control-plane parity gate passed with helper summaries, Kanban
   summaries, terminal/LSP status summaries, provider/proof/extension
   summaries, memory/secrets summaries, introspection snapshot summaries,
   health/status summaries, run graph/introspection summaries, reload
   summaries, LSP server summaries, LSP document summaries, channel status
   summaries, browser request summaries, checkpoint diff/restore summaries,
   cron run-history lifecycle summaries, cron write lifecycle summaries,
   cron-audit lifecycle summaries, cron-status cleanup summaries, cron-list
   target-text redaction summaries, goal continuation/loop cleanup summaries,
   goal clear cleanup summaries, goal objective redaction summaries, chat send
   summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation, heartbeat,
   approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `585 tests, 0 failures`.

### Slice 327: Wizard-step sensitive response redaction

1. `wizard.step` now stores the submitted wizard data as before, but redacts
   sensitive response keys such as API keys, secrets, tokens, passwords,
   private keys, and credentials before returning the step payload to
   control-plane clients.
2. Non-sensitive wizard data still returns normally, and the existing summary
   continues to report current step, completion state, data-key count, and
   cleanup flags. This makes the `includesSecretValues: false` cleanup claim
   true for setup/API-key wizard flows.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `109 tests, 0 failures`, covering wizard redaction and schemas. The broader
   control-plane parity gate passed with helper summaries, wizard redaction,
   Kanban summaries, terminal/LSP status summaries, provider/proof/extension
   summaries, memory/secrets summaries, introspection snapshot summaries,
   health/status summaries, run graph/introspection summaries, reload
   summaries, LSP server summaries, LSP document summaries, channel status
   summaries, browser request summaries, checkpoint diff/restore summaries,
   cron run-history lifecycle summaries, cron write lifecycle summaries,
   cron-audit lifecycle summaries, cron-status cleanup summaries, cron-list
   target-text redaction summaries, goal continuation/loop cleanup summaries,
   goal clear cleanup summaries, goal objective redaction summaries, chat send
   summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation, heartbeat,
   approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions,
   WebSocket connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `585 tests, 0 failures`.

### Slice 328: Skills env response redaction

1. `skills.update` still persists submitted env config as before, but redacts
   sensitive response values for keys containing API-key, secret, token,
   password, private-key, or credential markers before returning the updated
   env payload to control-plane clients.
2. Non-sensitive env keys still return normally, and the existing summary
   reports skill-key return state, enabled return state, version-update mode,
   env-key count, env keys, and cleanup flags. This makes the
   `includesSecretValues: false` cleanup claim true for skill credential setup
   responses while preserving useful operator feedback.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/skills_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/skills_approval_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `74 tests, 0 failures`, covering skill env redaction and schemas. The
   broader control-plane parity gate passed with helper summaries, wizard
   redaction, skill env redaction, Kanban summaries, terminal/LSP status
   summaries, provider/proof/extension summaries, memory/secrets summaries,
   introspection snapshot summaries, health/status summaries, run
   graph/introspection summaries, reload summaries, LSP server summaries, LSP
   document summaries, channel status summaries, browser request summaries,
   checkpoint diff/restore summaries, cron run-history lifecycle summaries,
   cron write lifecycle summaries, cron-audit lifecycle summaries, cron-status
   cleanup summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, cron lifecycle methods,
   device pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `585 tests, 0 failures`.

### Slice 336: Usage cost cleanup summary

1. `usage.cost` now preserves the existing date-range, total-cost,
   per-provider, total-request, token, and optional daily breakdown fields while
   adding a bounded summary for grouping mode, provider count, daily-row return
   state, request count, token count, and cleanup guarantees.
2. The cleanup summary explicitly marks prompt text, responses, message bodies,
   credentials, and secret values as excluded from the cost report, aligning the
   lower-level cost breakdown surface with the safer `usage.status` operator
   contract.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `175 tests, 0 failures`, covering usage-cost cleanup summaries, optional
   parity methods, and schemas. The broader control-plane parity gate passed
   with helper summaries, wizard redaction, skill env redaction, log redaction,
   cron output redaction, run-internal redaction, session-detail redaction,
   preview text redaction, agent-wait answer/error redaction,
   session-compaction cleanup summaries, usage-cost cleanup summaries, Kanban
   summaries, terminal/LSP status summaries, provider/proof/extension
   summaries, memory/secrets summaries, introspection snapshot summaries,
   health/status summaries, run graph/introspection summaries, reload
   summaries, LSP server summaries, LSP document summaries, channel status
   summaries, browser request summaries, checkpoint diff/restore summaries,
   cron run-history lifecycle summaries, cron write lifecycle summaries,
   cron-audit lifecycle summaries, cron-status cleanup summaries, cron-list
   target-text redaction summaries, goal continuation/loop cleanup summaries,
   goal clear cleanup summaries, goal objective redaction summaries, chat send
   summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation, heartbeat,
   approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
introspection, schema, and atom-safety lanes: `591 tests, 0 failures`.

### Slice 371: Discord named script-send target resolution

1. Extended `LemonChannels.ScriptSend.parse_target/2` so Discord script sends
   can resolve unique exact known names from `LemonChannels.Discord.KnownTargetStore`.
   Supported named forms are `discord:#channel`, `discord:#channel:thread-name`,
   and `discord:<channel_id>:thread-name`; the resolver returns the underlying
   numeric `discord:<channel_id>[:thread_id]` target before delivery.
2. Kept the failure mode conservative. Missing names return
   `{:named_channel_not_found, selector}` and ambiguous names return
   `{:ambiguous_named_channel, selector}`; `mix lemon.send` maps both to usage
   exit code `2` instead of guessing. Telegram still rejects named targets.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`:
   `18 tests, 0 failures`, covering unique channel resolution, unique thread
   resolution, numeric-channel/thread-name resolution, missing names, ambiguous
   names, and delivery through the injected Discord adapter. The broader
   Discord/script-send focused lane passed with `38 tests, 0 failures`; source
   wrapper smoke confirmed a missing named target exits `2`, list mode exits
   `0`, and `--list discord --json` remains clean. Docs lint, HTML lint,
   warning-as-error compile, and targeted diff hygiene passed.

### Slice 372: Script-send attachment uploads

1. Extended `LemonChannels.ScriptSend` with `--attach` / `-a` so script callers
   can upload one local file to Telegram or Discord through the existing
   `OutboundPayload` `:file` adapter path. Positional body text, `--file`, or
   stdin becomes the platform caption; an attachment without text is valid.
2. Preserved the narrow Telegram/Discord surface and conservative usage
   failures. Empty attachment paths, missing local files, and repeated
   `--attach` flags return usage/input errors that `mix lemon.send` maps to
   exit code `2`; `--file` continues to mean "read body text" rather than
   "upload this file".
3. Script responses now expose sanitized `attachment_filename` and
   `attachment_bytes` alongside existing message identifiers while excluding
   raw attachment paths, raw message bodies, and full platform responses.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/outbound_test.exs apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs --seed 1`:
   `40 tests, 0 failures`, covering Telegram and Discord file payload
   construction, caption handling, attachment metadata, attachment usage
   errors, and the adapter file-delivery paths. Source-wrapper smoke confirmed
   a missing attachment exits `2` and help exits `0` with documented
   `--attach` usage. Docs lint, HTML lint, warning-as-error compile, and
   targeted diff hygiene passed.

### Slice 373: Script-send multi-attachment uploads

1. Lifted script-send attachment delivery from one file to a bounded batch of up
   to 10 repeated `--attach` flags. `LemonChannels.ScriptSend` now builds the
   existing Telegram batch-file payload shape and the same bounded file-list
   shape for Discord, with positional text, `--file`, or stdin retained as the
   caption.
2. Extended `LemonChannels.Adapters.Discord.Outbound` to accept `%{files: [...]}` file payloads, read each local file, preserve explicit filenames, disable mention parsing, preserve reply/thread routing, and fail closed on empty or over-limit batches. This brings Discord direct outbound in line with the Telegram adapter's existing batch-file path.
3. Script responses now expose `attachment_filenames`, `attachment_count`, and
   total `attachment_bytes` for multi-file sends while preserving
   `attachment_filename` as the first attachment name for compatibility.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/outbound_test.exs apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs --seed 1`:
   `42 tests, 0 failures`, covering script-send multi-attachment payload
   construction plus Telegram and Discord adapter file-delivery paths.
   Source-wrapper smoke confirmed 11 attachments fail with usage exit `2` and
   help exits `0` with repeated-attachment usage. Docs lint, HTML lint,
   warning-as-error compile, and targeted diff hygiene passed.

### Slice 374: Script-send batch delivery ids

1. Updated `LemonChannels.ScriptSend` delivery metadata extraction so list-shaped
   adapter responses preserve all platform message ids. This covers Telegram
   batch file sends where the adapter can return one result per delivered file.
2. `message_id` remains the first delivered platform id for compatibility, while
   the remaining ids are exposed as `extra_message_ids`. Existing Discord
   direct outbound responses that already return `extra_message_ids` keep their
   explicit metadata unchanged.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/outbound_test.exs apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs --seed 1`:
   `43 tests, 0 failures`, covering batch Telegram attachment id extraction
   plus the existing script-send and adapter file-delivery paths. Docs lint,
   HTML lint, warning-as-error compile, wrapper smoke, and targeted diff hygiene
   passed.

### Slice 375: Script-send dry-run validation

1. Added `--dry-run` to `LemonChannels.ScriptSend` and `mix lemon.send` so
   operators can validate Telegram/Discord target parsing, default-target
   resolution, Discord known-name resolution, body/caption selection, and local
   attachment metadata without channel credentials or delivery side effects.
2. Dry-run results use the normal script-send result shape with `dry_run: true`,
   sanitized attachment metadata, and no platform message ids. Human output is
   prefixed with `dry-run`, while JSON output exposes the same bounded metadata
   used by real sends.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/outbound_test.exs apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs --seed 1`:
   `44 tests, 0 failures`, covering dry-run attachment validation plus existing
   script-send and adapter file-delivery paths. Source-wrapper smoke confirmed
   human and JSON dry-runs exit `0`, preserve `dry_run: true`, and do not need
   live Telegram/Discord delivery configuration.

### Slice 376: Telegram named script-send target resolution

1. Extended `LemonChannels.ScriptSend.parse_target/2` so Telegram script sends
   can resolve unique exact known names from `LemonChannels.Telegram.KnownTargetStore`.
   Supported named forms are `telegram:#chat`, `telegram:@username`,
   `telegram:#chat:topic-name`, and `telegram:<chat_id>:topic-name`; the
   resolver returns the underlying numeric `telegram:<chat_id>[:topic_id]`
   target before delivery.
2. Kept the failure mode conservative. Missing names return
   `{:named_channel_not_found, selector}` and ambiguous names return
   `{:ambiguous_named_channel, selector}`; `mix lemon.send` maps both to usage
   exit code `2` instead of guessing. Discord keeps the same known-name
   behavior.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`:
   `27 tests, 0 failures`, covering Telegram chat username/title resolution,
   topic-name resolution, numeric chat plus named topic resolution, missing
   names, ambiguous names, and delivery through the injected Telegram adapter.
   The broader Telegram/Discord script-send and adapter file-delivery lane
   passed with `47 tests, 0 failures`; wrapper smoke confirmed missing Telegram
   names exit `2`, and docs lint, HTML lint, warning-as-error compile, and
   targeted diff hygiene passed.

### Slice 377: Script-send list aliases

1. Added `aliases` to bounded Telegram and Discord `known_targets` returned by
   `mix lemon.send --list` / `./bin/lemon send --list`. The aliases are exact
   reusable target selectors for the known-name resolver, such as
   `telegram:#chat:topic-name`, `telegram:@username`, `telegram:<chat_id>:topic-name`,
   `discord:#channel:thread-name`, and `discord:<channel_id>:thread-name`.
2. Human list output now prints those aliases next to each known target, while
   JSON list mode exposes the same bounded alias array. The metadata stays
   derived from the BEAM known-target stores and does not include message text,
   tokens, or raw platform responses.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`:
   `27 tests, 0 failures`, covering Telegram and Discord alias metadata in
   known-target list output. The broader Telegram/Discord script-send and
   adapter file-delivery lane passed with `47 tests, 0 failures`; docs lint,
   HTML lint, warning-as-error compile, and targeted diff hygiene passed.

### Slice 378: Script-send config defaults

1. Extended `LemonChannels.ScriptSend` so platform-only `telegram` and
   `discord` targets resolve from durable gateway config when the explicit env
   defaults are absent. Telegram reads `[gateway.telegram] default_chat_id` plus
   `default_thread_id` or `default_topic_id`; Discord reads
   `[gateway.discord] default_channel_id` plus `default_thread_id`.
2. Kept env values as the highest-precedence script override, so cron jobs and
   CI lanes can still redirect notifications without mutating config. The config
   resolver now preserves the Discord default target fields, while Telegram
   keeps using its pass-through channel config map.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_core/test/lemon_core/config_test.exs --seed 1`:
   `53 tests, 0 failures`, covering config-backed defaults, env precedence, and
   TOML parsing for Telegram and Discord default target fields. The broader
   Telegram/Discord script-send and adapter file-delivery lane passed with
   `49 tests, 0 failures`; docs lint, HTML lint, warning-as-error compile, and
   targeted diff hygiene passed.

### Slice 379: Script-send account selection

1. Added `--account <id>` to `LemonChannels.ScriptSend` and `mix lemon.send`.
   The account id is carried into the outbound payload and returned in
   machine-readable send summaries, preserving the default `script` account
   when no explicit account is supplied.
2. Scoped BEAM known-target list output and named-target resolution by account
   when `--account` is present. This keeps duplicate Telegram/Discord names in
   other bot/workspace accounts from making a valid account-scoped target
   ambiguous, while preserving fail-closed ambiguity behavior without a filter.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`:
   `32 tests, 0 failures`, covering explicit delivery account ids, ambiguous
   unscoped Discord names, scoped Discord name resolution, and account-filtered
   Telegram list output. The broader Telegram/Discord script-send and adapter
   file-delivery lane passed with `52 tests, 0 failures`; docs lint, HTML lint,
   warning-as-error compile, and targeted diff hygiene passed.

### Slice 380: Script-send thread and topic options

1. Added standalone `--thread <id-or-name>` and Telegram-friendly
   `--topic <id-or-name>` options to `LemonChannels.ScriptSend` and
   `mix lemon.send`. This lets scripts keep a stable `--to` chat/channel target
   and set the thread/topic separately, including named thread/topic resolution
   through the existing BEAM known-target stores.
2. Added fail-closed conflict handling: `--thread` and `--topic` cannot both be
   supplied, and a command cannot specify a thread in both `--to` and
   `--thread` / `--topic`.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`:
   `34 tests, 0 failures`, covering direct thread overrides, topic aliases, and
   conflict errors. The broader Telegram/Discord script-send and adapter
   file-delivery lane passed with `54 tests, 0 failures`; docs lint, HTML lint,
   warning-as-error compile, and targeted diff hygiene passed.

### Slice 381: Script-send default account ids

1. Added default account resolution for script notifications. Explicit
   `--account` remains highest precedence; otherwise Telegram reads
   `LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID` then `[gateway.telegram] default_account_id`,
   and Discord reads `LEMON_DISCORD_DEFAULT_ACCOUNT_ID` then
   `[gateway.discord] default_account_id`.
2. The resolved default account scopes BEAM known-target name resolution before
   delivery, so scripts can use friendly target names in multi-account
   deployments without repeating `--account` on every command.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_core/test/lemon_core/config_test.exs --seed 1`:
   `59 tests, 0 failures`, covering env/config default account precedence,
   default-account known-name resolution, and TOML parsing for Telegram and
   Discord default account fields. The broader Telegram/Discord script-send and
   adapter file-delivery lane passed with `55 tests, 0 failures`; docs lint,
   HTML lint, warning-as-error compile, and targeted diff hygiene passed.

### Slice 382: Script-send reply-to routing

1. Added `--reply-to <message-id>` to `LemonChannels.ScriptSend` and
   `mix lemon.send`. The value is normalized as a platform message id and stored
   on `OutboundPayload.reply_to`, which the existing Telegram and Discord
   outbound adapters already understand for replies.
2. Script result metadata now includes `reply_to`, so JSON and dry-run consumers
   can confirm reply routing without inspecting raw adapter payloads.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`:
   `37 tests, 0 failures`, covering reply-target payload construction and empty
   reply-target usage errors. The broader Telegram/Discord script-send and
   adapter file-delivery lane passed with `57 tests, 0 failures`; docs lint,
   HTML lint, warning-as-error compile, and targeted diff hygiene passed.

### Slice 383: Source install verifier

1. Added `scripts/verify_source_install` as the repeatable source-install proof
   for the bounded public support path. It checks `elixir`, `mix`, Elixir
   1.19.5+, Erlang/OTP major 28+, locked dependency resolution, warning-free
   test compile, non-interactive setup runtime dispatch, doctor JSON
   diagnostics, and support-bundle generation.
2. The verifier writes temporary setup, doctor, and support-bundle artifacts
   under `TMPDIR`, fails on doctor failures, and validates that the support
   bundle contains the required redacted diagnostic entries used by release
   runtime boot proof.
3. Docs now point source-install and release-candidate operators at
   `scripts/verify_source_install`, while the install/setup feature matrix keeps
   the public claim scoped to source install plus Linux `x86_64` tarballs until
   a one-line installer has matching artifact, rollback, and support-bundle
   proof. Full validation passed with `scripts/verify_source_install`: the
   verifier reported dependency resolution without lockfile drift, warning-free
   test compile, non-interactive setup runtime dispatch, doctor diagnostics
   `overall=warn pass=30 warn=4 skip=4`, and required support-bundle diagnostic
   entries.

### Slice 384: Stage-1 update proof in source verifier

1. Extended `scripts/verify_source_install` to run
   `MIX_ENV=test ./bin/lemon update --check --no-skill-sync --verbose` after
   the setup-runtime check. The verifier now proves Lemon's source wrapper
   setup/update path without turning the claim into remote binary auto-update
   support.
2. The verifier asserts that the update output includes the current version and
   the explicit `Remote update check: not yet available` boundary, keeping the
   stage-1 local-maintenance scope visible in automation.
3. Validation passed with `scripts/verify_source_install --skip-compile`,
   including locked dependency resolution, setup runtime dispatch, stage-1
   update dry-run dispatch, doctor diagnostics
   `overall=warn pass=30 warn=4 skip=4`, and required support-bundle entries.

### Slice 385: Source update wrapper

1. Added `./bin/lemon update ...` as a source-runtime wrapper around
   `mix lemon.update ...`, matching the existing `./bin/lemon send` delegation
   pattern and making Hermes-style update discovery available without starting
   the runtime.
2. The wrapper stays scoped to the current stage-1 local maintenance task:
   version reporting, config migration checks, and bundled-skill sync. Docs
   explicitly keep remote binary download/swap outside the support claim.
3. `scripts/verify_source_install` and `scripts/test_contract.sh` now guard the
   wrapper by requiring the source verifier to exercise `./bin/lemon update
   --check --no-skill-sync --verbose`. Full validation passed with
   `scripts/verify_source_install`, including dependency resolution without
   lockfile drift, warning-free test compile, setup runtime dispatch,
   source-wrapper update dry-run dispatch, doctor diagnostics
   `overall=warn pass=30 warn=4 skip=4`, and required support-bundle entries.

### Slice 386: Source setup and doctor wrappers

1. Added `./bin/lemon setup ...` and `./bin/lemon doctor ...` as narrow
   source-runtime wrappers around `mix lemon.setup ...` and
   `mix lemon.doctor ...`, matching the existing `send` and new `update`
   delegation pattern.
2. `scripts/verify_source_install` now exercises source-wrapper setup,
   update, and doctor paths: `./bin/lemon setup runtime --profile runtime_min
   --non-interactive`, `./bin/lemon update --check --no-skill-sync --verbose`,
   and `./bin/lemon doctor --json --bundle`.
3. `scripts/test_contract.sh` guards the verifier contract so future edits
   cannot silently fall back to direct Mix invocations for setup, update, or
   doctor. Full validation passed with `scripts/verify_source_install`,
   including dependency resolution without lockfile drift, warning-free test
   compile, source-wrapper setup runtime dispatch, update dry-run dispatch,
   doctor diagnostics `overall=warn pass=30 warn=4 skip=4`, and required
   support-bundle entries.

### Slice 387: Source config wrapper

1. Added `./bin/lemon config ...` as a source-runtime wrapper around
   `mix lemon.config ...`, matching setup, doctor, update, and send delegation
   without booting the runtime.
2. `scripts/verify_source_install` now validates configuration through
   `./bin/lemon config validate --project-dir "$PROJECT_DIR"` before update
   and doctor proof, so the supported source setup path has an explicit config
   validation checkpoint.
3. `scripts/test_contract.sh` guards the verifier contract so future edits must
   keep exercising the source config wrapper. Full validation passed with
   `scripts/verify_source_install`, including dependency resolution without
   lockfile drift, warning-free test compile, source-wrapper config validation,
   source-wrapper setup/update/doctor proof, doctor diagnostics
   `overall=warn pass=30 warn=4 skip=4`, and required support-bundle entries.

### Slice 388: Source wrapper help discoverability

1. Extended `scripts/verify_source_install` to run `./bin/lemon --help` and
   require discoverable source-wrapper entries for `setup`, `config`,
   `doctor`, `send`, and `update`.
2. The source install verifier now catches regressions where a wrapper still
   works when called directly but disappears from the top-level help text.
3. Full validation passed with `scripts/verify_source_install`, including the
   new source-wrapper help check, dependency resolution without lockfile drift,
   warning-free test compile, and the existing wrapper setup, config, update,
   doctor, and support-bundle proof chain.

### Slice 370: Discord script-send target directory

1. Added `LemonChannels.Discord.KnownTargetStore` over the
   `:discord_known_targets` table so Discord channels/threads can be surfaced
   to script callers without scraping logs or Discord APIs at send time.
2. Updated the Discord transport to index allowed, non-self, non-webhook,
   deduped inbound message targets after normalization. The entry stores
   account id, peer kind, channel/thread ids, guild id, channel/thread labels,
   first/last timestamps, and last message id on a 30-second refresh cadence or
   when target metadata changes; it does not store message text, tokens, or raw
   platform payloads.
3. Extended `LemonChannels.ScriptSend.list_targets/2` so
   `mix lemon.send --list discord` and `./bin/lemon send --list discord`
   expose bounded recent Discord `known_targets` alongside env defaults, with
   `known_target_count` and `known_targets_truncated` matching the Telegram
   list contract. Named `discord:#channel` resolution remains unsupported until
   a real alias/name resolution source exists.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_channels/test/lemon_channels/discord/known_target_store_test.exs apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs --seed 1`:
   `35 tests, 0 failures`, covering store round-trip, script list rendering,
   allowed Discord target indexing, and existing Discord transport contracts.

### Slice 369: Script notification known-target discovery

1. Extended `LemonChannels.ScriptSend.list_targets/2` so list mode can read
   configured Lemon store data without starting channel transports and includes
   a bounded recent window of Telegram chats/topics already captured by
   `LemonChannels.Telegram.KnownTargetStore` as
   `known_targets` metadata. Each entry exposes the reusable
   `telegram:<chat_id>[:thread_id]` target, account id, peer kind, label, topic
   metadata, update timestamp, and source marker without message text, tokens,
   or raw platform responses; list results also expose `known_target_count` and
   `known_targets_truncated` so clients can tell when the local directory is
   larger than the returned window.
2. Kept the promoted-platform boundary intact. Discord list mode still reports
   numeric target format plus env defaults only; named Discord channels remain
   unsupported until Lemon has a real Discord channel directory source.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/script_send_test.exs apps/lemon_channels/test/lemon_channels/telegram/known_target_store_test.exs --seed 1`:
   `15 tests, 0 failures`, covering store-backed Telegram topic and DM
   discovery plus the existing send/list/help/body/delivery contracts. The
   source wrapper smoke produced clean JSON with 25 returned targets,
   `known_target_count`, and `known_targets_truncated`; docs lint, HTML lint,
   warning-as-error compile, and targeted diff hygiene passed.

### Slice 368: Script notification exit-code contract

1. Updated `Mix.Tasks.Lemon.Send` so script callers can distinguish failure
   classes without parsing stderr: successful send/list/help exits `0`,
   platform delivery failures exit `1`, and usage, argument, local config, or
   input failures exit `2`.
2. Documented the exit-code contract in channel docs and testing docs, and
   extended docs-lint so the command cannot drift back to generic failure
   behavior unnoticed.
3. Validation passed with shell wrapper smoke checks for `--help`,
   `--list telegram --json`, unsupported list filters, missing body, missing
   default target, and no-token Telegram delivery failure, plus the focused
   script-send/unit adapter lane, docs lint, HTML lint, warning-as-error
   compile, and targeted diff hygiene.

### Slice 367: Script notification JSON delivery summary

1. Extended `LemonChannels.ScriptSend.run/2` to extract bounded delivery
   identifiers from Telegram- and Discord-shaped adapter responses. JSON output
   now includes `message_id` and `extra_message_ids` when available, while the
   raw platform delivery payload remains omitted from `mix lemon.send --json`.
2. Human success output now appends `message_id=<id>` when the adapter reports
   one, preserving quiet mode for scripts that only care about the exit code.
3. Focused coverage now asserts Telegram-style nested result id extraction and
   Discord-style direct message id extraction. Docs clarify that JSON output is
   metadata-only and does not return raw message text or full platform
   responses.
4. Validation passed with `MIX_ENV=test mix test
   apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`,
   adapter compatibility tests, `bash scripts/lint_ci_docs.sh`, HTML lint,
   warning-as-error compile, and targeted diff hygiene.

### Slice 366: Script notification CLI ergonomics

1. Extended `LemonChannels.ScriptSend` and `mix lemon.send` with the remaining
   credential-free Hermes send ergonomics: `--file -` forces stdin, `--list
   telegram` / `--list discord` filters target output, `-l` aliases `--list`,
   and `--help` / `-h` prints built-in usage.
2. Kept the platform boundary unchanged. Filtered list mode only accepts
   Telegram or Discord and returns an explicit unsupported-platform error for
   anything else.
3. Extended focused coverage for forced stdin body reads, filtered listing,
   unsupported list filters, and help output. Updated docs and docs-lint so the
   new script-send details stay visible.
4. Validation passed with `MIX_ENV=test mix test
   apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1`,
   `./bin/lemon send --list --json`, `./bin/lemon send --list telegram
   --json`, `./bin/lemon send --help`, `bash scripts/lint_ci_docs.sh`, HTML
   lint, warning-as-error compile, and targeted diff hygiene.

### Slice 365: Telegram/Discord script notification command

1. Added `LemonChannels.ScriptSend`, a first-party source-tree script
   notification helper that supports only the promoted Telegram and Discord
   platforms for now. It parses `--to`, `--file`, `--subject`, `--json`,
   `--quiet`, `--list`, positional body text, noninteractive stdin, default
   target env vars, and optional thread ids.
2. Added `mix lemon.send` plus the `./bin/lemon send` wrapper. The command
   accepts `telegram:<chat_id>[:thread_id]` and
   `discord:<channel_id>[:thread_id]`, returns JSON/list output without
   starting inbound channel transports, and sends text payloads through the
   existing Telegram/Discord outbound adapters for actual delivery.
3. Added focused unit coverage with injected Telegram and Discord deliverers so
   the script-send contract is deterministic and credential-free: target
   parsing, unsupported/named-channel rejection, default-target env vars,
   body-source precedence, file reads, stdin reads, subject formatting, list
   mode, and outbound payload construction.
4. Updated channel docs, root README/AGENTS, testing docs, Hermes feature
   matrix, docs-lint, this scorecard, and the live progress dashboard. The docs
   explicitly avoid claiming non-Telegram/Discord script delivery and clarify
   that `--file` reads a text body rather than uploading an attachment.
5. Validation passed with `MIX_ENV=test mix test
   apps/lemon_channels/test/lemon_channels/script_send_test.exs --seed 1` (`10
   tests, 0 failures`), `./bin/lemon send --list --json`, and `bash -n
   bin/lemon`.

### Slice 364: Python CLI package check lane

1. Added `.github/workflows/python-cli.yml`, a non-publishing package-quality
   workflow for `clients/lemon-cli` that runs on Python CLI changes, `main`
   pushes touching the package, and manual dispatch.
2. The workflow uses Python 3.13 plus `uv`, runs `uv sync --locked --dev`,
   `uv run ruff check src tests`, `uv run pytest`, and `uv build --sdist
   --wheel`, verifies the built wheel metadata, and uploads short-lived
   distribution artifacts without publishing them.
3. Extended `scripts/test clients` so local client parity now includes the
   Python CLI package lane before the Node web/TUI/browser checks.
4. Cleaned stale Python CLI lint failures: unused imports, ambiguous one-letter
   locals, and an unnecessary f-string. Moved the CLI dev dependencies from
   deprecated `tool.uv.dev-dependencies` into `dependency-groups.dev`.
5. Updated AGENTS, README, testing docs, release docs, the Hermes feature
   matrix, this scorecard, and the live progress dashboard so the local/CI
   client contract includes `lemon-cli` package checks while PyPI publishing
   remains an explicit future decision.
6. Validation passed with focused Python CLI package checks (`uv sync
   --locked --dev`, ruff, `27 tests, 0 failures`, wheel/sdist build, and
   metadata verification), workflow YAML parsing, shell syntax checks,
   `scripts/lint_ci_docs.sh`, HTML lint, targeted diff hygiene, and the full
   `scripts/test clients` lane, including Lemon web `941 tests`, Lemon TUI
   `1290 tests`, and browser node `29 tests` with zero failures.

### Slice 363: PR history integrity workflow

1. Added `.github/workflows/history-check.yml`, a PR-only workflow for `main`
   that checks out the pull request head with full history, fetches the target
   base branch, and requires `git merge-base "origin/${GITHUB_BASE_REF}" HEAD`
   to return a non-empty common ancestor.
2. The workflow fails closed for orphan branches, reinitialized `.git/`
   histories, and force-pushes from unrelated repositories, with operator
   remediation that recreates the branch from the current target and reapplies
   the intended changes.
3. Extended `scripts/lint_ci_docs.sh` with a drift guard for the workflow,
   including explicit permissions coverage and required release/testing docs.
4. Updated release checklist, testing docs, Hermes feature matrix, scorecard,
   and live progress dashboard so history integrity is treated as implemented
   CI parity while PyPI-style package publishing remains a separate future
   decision.
5. Validation passed with `bash scripts/lint_ci_docs.sh`,
   `python3` YAML parsing of `.github/workflows/history-check.yml`,
   `git merge-base origin/main HEAD`, `xmllint --html --noout
   docs/plans/lemon-hermes-progress.html`, and targeted `git diff --check`.

### Slice 362: first-party x_search tool

1. Added `LemonSkills.Tools.XSearch`, a read-only model-facing `x_search` tool
   for recent public X/Twitter search with Hermes-compatible naming, query,
   limit, sort-order, id-boundary, and pagination-token parameters.
2. Extended `LemonChannels.Adapters.XAPI` with `search_configured?/0` so
   read-only search can run from `X_API_BEARER_TOKEN` alone, while still
   accepting existing OAuth posting credentials when available.
3. Added `LemonChannels.Adapters.XAPI.Client.search_recent/2` and matching
   OAuth1 support over X API v2 `/tweets/search/recent`, including bounded
   `max_results`, author expansion, tweet/user fields, optional `sort_order`,
   `since_id`, `until_id`, and `next_token`.
4. Registered `CodingAgent.Tools.XSearch` in the coding-agent default tool set,
   built-in registry, minimal-core policy, and no-external policy boundary.
5. Updated coding-agent, LemonSkills, LemonChannels, feature-matrix, and
   simplified user-facing docs so the social tool surface is now
   `x_search`, `post_to_x`, and `get_x_mentions`.
6. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/adapters/x_api_test.exs apps/lemon_channels/test/lemon_channels/adapters/x_api_client_test.exs apps/lemon_skills/test/lemon_skills/tools/x_search_test.exs apps/coding_agent/test/coding_agent/tools/x_search_test.exs apps/coding_agent/test/coding_agent/tools_test.exs apps/coding_agent/test/coding_agent/tool_registry_test.exs apps/coding_agent/test/coding_agent/tool_policy_test.exs apps/coding_agent/test/coding_agent/evals/harness_contract_test.exs apps/coding_agent/test/coding_agent_test.exs --seed 1`
   at `151 tests, 0 failures`, plus warning-free compile, docs lint, HTML
   lint, and targeted diff hygiene.

### Slice 361: session_search prompt guidance

1. Updated the main system prompt memory workflow so the shell-bypass guidance
   explicitly protects both Lemon-native `search_memory` and Hermes-compatible
   `session_search`.
2. Added dedicated `session_search` guidance to the native system prompt and
   `PromptBuilder` learning section for imported Hermes-style workflows that ask
   for session search, browse, or scroll behavior.
3. Extended the deterministic eval harness prompt contracts so future prompt
   changes must keep `session_search` in the dedicated-tool preference guidance,
   required learning-prompt tools, and learning-trigger checks.
4. Updated prompt, prompt-builder, harness-contract, and top-level coding-agent
   tests so referenced tool names, read-only tool counts, and coding-tool counts
   stay aligned with the new compatibility surface.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/coding_agent/test/coding_agent/system_prompt_test.exs apps/coding_agent/test/coding_agent/prompt_builder_test.exs apps/coding_agent/test/coding_agent/evals/harness_contract_test.exs apps/coding_agent/test/coding_agent_test.exs --seed 1`
   at `93 tests, 0 failures`, plus warning-free compile, docs lint, HTML
   lint, and targeted diff hygiene.

### Slice 360: Hermes-compatible session_search tool

1. Added `CodingAgent.Tools.SessionSearch`, a model-facing `session_search`
   compatibility tool that infers Hermes-style discovery, scroll, and browse
   modes from the argument shape without an explicit `mode` parameter or LLM
   call.
2. Discovery calls `LemonCore.SessionSearch.search/2` across durable Lemon
   memory, filters the current session, supports `newest`/`oldest` ordering, and
   returns scroll anchors plus prompt/answer summary context.
3. Scroll calls read bounded run-history windows through `LemonCore.Store` using
   `session_id` plus `around_message_id`; scroll takes precedence over query
   when both shapes are present and refuses to scroll the current live session.
4. Browse lists recent runs for the current session and fails closed when no
   current session context exists.
5. Registered the tool in `CodingAgent.Tools`, `CodingAgent.ToolRegistry`,
   read-only/minimal-core policies, and the deterministic eval builtin-tool
   contract while keeping Lemon-native `search_memory` available for explicit
   scoped recall.
6. Updated `apps/coding_agent/README.md`, `apps/coding_agent/AGENTS.md`,
   `docs/user-guide/memory.md`, `docs/testing.md`, and the Hermes feature matrix
   to describe the named compatibility surface.
7. Focused validation passed with
   `MIX_ENV=test mix test apps/coding_agent/test/coding_agent/tools/session_search_test.exs apps/coding_agent/test/coding_agent/tools_test.exs apps/coding_agent/test/coding_agent/tool_policy_test.exs apps/coding_agent/test/coding_agent/tool_registry_test.exs --seed 1`
   at `137 tests, 0 failures`, plus warning-free compile, docs lint, HTML lint,
   and targeted diff hygiene.

### Slice 359: OSV supply-chain parity workflow

1. Added `.github/workflows/osv-scanner.yml` using Google's pinned reusable OSV
   scanner workflow at
   `google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@c51854704019a247608d928f370c98740469d4b5`.
2. The workflow runs on lockfile/manifest changes to `main`, weekly on `main`,
   and through manual dispatch. It grants `security-events: write` for SARIF
   upload and keeps `fail-on-vuln: false`, so findings are detection signals
   that still require maintainer triage before release.
3. The scan scope is first-party lockfiles only: `mix.lock`,
   `clients/lemon-web/package-lock.json`, `clients/lemon-tui/package-lock.json`,
   `clients/lemon-browser-node/package-lock.json`, `clients/lemon-cli/uv.lock`,
   `apps/lemon_gateway/priv/package-lock.json`, and
   `tools/diagrams/package-lock.json`.
4. `docs/release/release_checklist_and_support_policy.md` now documents the OSV
   Scanner workflow in the release-candidate checklist and dependency audit
   policy.
5. `docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md` now reflects
   the refreshed Hermes baseline at `94c523f0c`, including upstream
   `session_search` single-shape, `x_search`, fallback, history-check, and PyPI
   workflow notes, and records Lemon's OSV workflow as supply-chain parity
   evidence.

### Slice 358: Discord slash client-click blocker refresh

1. Ran the read-only Discord slash client-click artifact check against the
   current proof directory:
   `scripts/live_discord_matrix.py --check-slash-client-click-proof --slash-client-click-proof-path .lemon/proofs/discord-slash-client-click-proof-latest.json --result-path tmp/discord-slash-client-click-proof-check.json --proof-path .lemon/proofs/discord-slash-client-click-check-latest.json`.
2. The check correctly failed closed with
   `reason_kind: discord_slash_client_click_missing` because no runtime
   `discord-slash-client-click-proof-latest.json` artifact exists yet.
3. The redacted proof artifact at
   `.lemon/proofs/discord-slash-client-click-check-latest.json` records a failed
   `discord_slash_client_click_proof_artifact` check with no raw bot token,
   interaction token, application id, channel id, user id, message body, or
   secret-name leakage.
4. Live operator-surface inspection confirmed `proofs.status` reports
   `discordSlashClientClick` as `warning` with the missing-proof reason and
   wait-mode next action, while `channels.status.summary.launchGateStatuses`
   reports `discord.slash_client_click: warning` and
   `launchGateReasonKinds.discord.slash_client_click:
   discord_slash_client_click_missing`.
5. Current proof diagnostics report 238 valid proof artifacts: 162 completed,
   37 failed, and 39 skipped.

### Slice 357: Channel-status launch-gate summary maps

1. Control-plane `channels.status.summary` now includes compact
   `launchGateStatuses` and `launchGateReasonKinds` maps derived from the shared
   Telegram/Discord readiness gates.
2. Operator clients can read `discord.slash_registration`,
   `discord.slash_client_click`, and other gate states directly from the summary
   while preserving the full detailed `readiness.gates` list.
3. Focused `ChannelsStatus` coverage now asserts the compact warning status and
   reason kind for the Discord slash client-click gate.
4. `apps/lemon_control_plane/README.md`, `apps/lemon_control_plane/AGENTS.md`,
   and `docs/support.md` document the new compact summary maps.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`
   at `67 tests, 0 failures`, warning-free compile, docs lint, HTML lint, and
   targeted diff hygiene.

### Slice 356: Proof-status slash-registration launch gate

1. Control-plane `proofs.status` now includes a `discordSlashRegistration`
   launch gate alongside Discord DM, slash client-click, provider media, and
   terminal backend gates.
2. The new gate passes on completed all-command registration proof or completed
   `contains_all_slash_registration` coverage.
3. Rollback-only or media-only registration proof stays a warning with a
   copy-ready `--check-all-slash-registration` next action.
4. Focused `ProofsStatus` tests now cover both the passed all-command gate and
   rollback-only partial evidence branch.
5. `apps/lemon_control_plane/README.md` and `docs/support.md` now document the
   slash-registration launch gate.
6. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`
   at `67 tests, 0 failures`, warning-free compile, docs lint, and targeted
   diff hygiene.

### Slice 355: Rollback live-registration promotion

1. An initial read-only live Discord API check against Zeebot confirmed
   `/rollback` was missing from the application, and the all-command check
   reported 15 registered commands against the current 16-command inventory.
2. The documented `--register-rollback-slash-command` path upserted only the
   in-repo `/rollback` schema on Zeebot.
3. Follow-up read-only live checks now pass:
   `discord_rollback_slash_registration` is completed, and
   `discord_all_slash_registration` reports `registered_command_count: 16`,
   `expected_command_count: 16`, and no missing commands.
4. `scripts/live_discord_matrix.py` now passes `command_name: "rollback"` into
   the checkpoint-shaped schema validator so missing rollback checks report
   `missing_command: rollback` instead of `checkpoint`.
5. Focused validation passed:
   - `python3 -m py_compile scripts/live_discord_matrix.py`.
   - `scripts/live_discord_matrix.py --bot-token-index 0 --register-rollback-slash-command --result-path tmp/discord-rollback-slash-proof-register.json --proof-path .lemon/proofs/discord-rollback-slash-registration-latest.json`:
     completed.
   - `scripts/live_discord_matrix.py --bot-token-index 0 --check-rollback-slash-registration --result-path tmp/discord-rollback-slash-proof-check.json --proof-path .lemon/proofs/discord-rollback-slash-registration-latest.json`:
     completed.
   - `scripts/live_discord_matrix.py --bot-token-index 0 --check-all-slash-registration --result-path tmp/discord-all-slash-proof-check.json --proof-path .lemon/proofs/discord-all-slash-registration-latest.json`:
     completed with 16 registered commands and no missing commands.
   - `scripts/lint_ci_docs.sh`, HTML lint, and targeted diff hygiene.

### Slice 354: Discord feature-matrix rollback refresh

1. `docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md` now reflects
   the current `/rollback` registration path, the final readiness audit rollback
   gate, and the 16-command all-slash inventory.
2. The Discord row now says `channel_readiness.json` and `channels.status`
   expose slash-registration partial evidence, not only client-click wait-mode
   state.
3. The remaining Discord P0 note now asks for fresh rollback/all-command
   registration evidence before broad parity claims instead of treating
   `/rollback` as absent from the live proof system.
4. Focused validation passed:
   - `scripts/lint_ci_docs.sh`.
   - HTML lint and targeted diff hygiene.
   - Stale 15-command slash inventory scan returned no hits.

### Slice 353: Channel-readiness rollback partial evidence

1. `LemonCore.Doctor.ChannelReadiness` now recognizes
   `discord_rollback_slash_registration` checks and
   `contains_rollback_slash_registration` coverage as partial slash-registration
   evidence when all-command registration proof is still missing.
2. The gate still stays `warning` and points operators to
   `--check-all-slash-registration`, so `/rollback` proof does not over-promote
   broad slash parity.
3. Focused channel-readiness tests now cover the rollback-only evidence branch.
4. `docs/support.md` now names slash registration as a channel-readiness gate
   alongside deterministic slash and real client-click promotion.
5. Focused validation passed:
   - `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/channel_readiness_test.exs --seed 1`:
     `3 tests, 0 failures`.
   - `MIX_ENV=test mix compile --warnings-as-errors`.
   - `MIX_ENV=test mix lemon.quality`.
   - `scripts/lint_ci_docs.sh`, HTML lint, and targeted diff hygiene.

### Slice 352: Final readiness rollback slash gate

1. `scripts/audit_1_0_readiness` now prints and accepts
   `LEMON_DISCORD_ROLLBACK_SLASH_PROOF_JSON` plus
   `LEMON_DISCORD_ROLLBACK_SLASH_REDACTED_PROOF_JSON`.
2. The final readiness audit now verifies the raw Discord `/rollback`
   registration result JSON and the sanitized `.lemon/proofs` coverage artifact,
   including the `discord_rollback_slash_registration` completed check and
   `contains_rollback_slash_registration` coverage flag.
3. The all-command slash registration verifier now expects the current
   16-command inventory after the `/rollback` alias.
4. Release checklist docs and CI docs lint now guard the rollback audit gate and
   16-command expectation.
5. Focused validation passed:
   - `bash -n scripts/audit_1_0_readiness scripts/lint_ci_docs.sh`.
   - `scripts/lint_ci_docs.sh`.
   - HTML lint and targeted diff hygiene.

### Slice 351: Rollback slash docs-lint guardrail

1. `scripts/lint_ci_docs.sh` now checks that the rollback slash alias remains
   present in the live Discord matrix, channel diagnostics, command parity
   matrix, support docs, testing docs, proof diagnostics, and control-plane
   `proofs.status` formatting.
2. `docs/support.md` now names `contains_rollback_slash_registration` as one of
   the sanitized live Discord proof coverage booleans preserved for support
   bundles, doctor gates, Web `/ops`, and `proofs.status`.
3. Focused validation passed:
   - `bash -n scripts/lint_ci_docs.sh`.
   - `scripts/lint_ci_docs.sh`.
   - HTML lint and targeted diff hygiene.

### Slice 350: Rollback slash-registration proof coverage

1. `scripts/live_discord_matrix.py` now includes
   `contains_rollback_slash_registration` in sanitized Discord proof coverage
   when the rollback registration check is present.
2. `LemonCore.Doctor.ProofDiagnostics` now preserves the rollback registration
   coverage flag through support bundles, doctor consumers, Web `/ops`, and
   control-plane proof surfaces.
3. Focused support-bundle and control-plane tests now assert the lower-snake and
   lowerCamelCase rollback coverage keys stay visible while unsafe raw fields
   remain filtered.
4. Focused validation passed:
   - `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
     `69 tests, 0 failures`.
   - `MIX_ENV=test mix compile --warnings-as-errors`.
   - `scripts/lint_ci_docs.sh`, HTML lint, Python compile, and targeted diff
     hygiene.

### Slice 349: Channel rollback command alias

1. Telegram now recognizes `/rollback` as a Hermes-style alias for the shared
   checkpoint rollback flow, including `/rollback diff <id>` and
   `/rollback <id> confirm`.
2. Discord now exports a `/rollback` slash command schema that mirrors the
   redacted `/checkpoint` status/events/diff/restore controls and maps through
   `LemonChannels.CheckpointStatusMessage.handle_rollback/2`.
3. Channel diagnostics now include `rollback` in the promoted Discord command
   inventory, and `scripts/live_discord_slash_interaction_proof.exs` now covers
   the 16-command local inventory plus rollback payload decoding.
4. `scripts/live_discord_matrix.py` now has rollback registration check/update
   paths so operators can upsert `/rollback` before rerunning all-command
   registration proof.
5. Focused validation passed:
   - `MIX_ENV=test mix test apps/lemon_channels/test/lemon_channels/checkpoint_status_message_test.exs apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_checkpoint_event_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
     `154 tests, 0 failures`.
   - `MIX_ENV=test mix run --no-start scripts/live_discord_slash_interaction_proof.exs`:
     `discord slash interaction proof passed: 35 completed`.
   - `MIX_ENV=test mix compile --warnings-as-errors`.
   - `scripts/lint_ci_docs.sh`, HTML lint, Python compile, and targeted diff
     hygiene.

### Slice 348: Public support docs for channel readiness

1. `docs/support.md` now documents support-bundle `channel_readiness.json` as
   the shared Telegram/Discord launch-gate summary.
2. The support contract now states that `channel_readiness.json` carries gate
   status, counts, safe reason kinds, cleanup flags, and bounded next actions
   without bot tokens, secret names, raw ids, message bodies, raw proof paths,
   or raw proof details.
3. `scripts/lint_ci_docs.sh` now guards that the public support doc continues
   to mention `channel_readiness.json` alongside the release verifier and
   release checklist.
4. Focused validation passed with `scripts/lint_ci_docs.sh`,
   `xmllint --html --noout docs/plans/lemon-hermes-progress.html`, and targeted
   `git diff --check`.

### Slice 347: Release support-bundle entry verification

1. `scripts/verify_release_runtime_boot` now opens each generated
   release-runtime support bundle and verifies it is a valid ZIP.
2. The release verifier now requires core support entries, including
   `channel_readiness.json`, `channel_diagnostics.json`,
   `proof_diagnostics.json`, `doctor_report.json`, and `README.txt`.
3. The release checklist documents that runtime boot verification inspects the
   support-bundle ZIP for core support entries.
4. `scripts/lint_ci_docs.sh` now guards that both the verifier and release
   checklist continue to mention `channel_readiness.json`.
5. Focused validation passed with
   `bash -n scripts/verify_release_runtime_boot scripts/lint_ci_docs.sh &&
   scripts/lint_ci_docs.sh`. HTML lint and diff hygiene also passed.

### Slice 346: Doctor channel-readiness summary

1. `mix lemon.doctor` now includes `channels.readiness`, backed by the shared
   `LemonCore.Doctor.ChannelReadiness` launch-gate summary.
2. The check reports passed, warning, blocked, skipped, and total gate counts
   for promoted Telegram/Discord launch gates.
3. Warning remediation points at the first unresolved gate's safe next action,
   preserving Discord slash client-click wait-mode handoff without duplicating
   raw proof contents or leaking tokens, secret names, ids, or message bodies.
4. Updated LemonCore docs and agent guidance so doctor, support bundles,
   `channels.status`, and Web `/ops` stay aligned on the shared readiness
   contract.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_core/test/lemon_core/doctor/channel_readiness_test.exs`:
   `61 tests, 0 failures`. Static validation passed with warning-free
   `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix
   lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 345: Support-bundle README channel readiness

1. Updated generated support-bundle `README.txt` to list channel readiness
   among the bundled diagnostics.
2. The README now explicitly names the redaction boundary for chat/channel/guild
   ids, message bodies, proof file contents, secrets, media bytes, and tool
   outputs before operators share a bundle.
3. Added support-bundle assertions that the README keeps the channel readiness
   entry and proof/content redaction language visible.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs`:
   `3 tests, 0 failures`. Static validation passed with warning-free
   `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix
   lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 344: Web ops shared channel readiness

1. Web `/ops` channel snapshots now include
   `LemonCore.Doctor.ChannelReadiness.status/1`, using the same redacted
   readiness payload as support-bundle `channel_readiness.json` and
   control-plane `channels.status`.
2. The Channel Config panel now renders aggregate launch-gate status plus
   passed/warning/blocked/skipped counts from the shared helper while
   preserving the existing richer failure drilldown for Discord DM,
   free-response, reconnect, and slash client-click next actions.
3. Updated Web docs and agent guidance to keep `/ops`, support bundles, and
   control-plane channel readiness aligned on promoted-platform counts, safe
   reason kinds, cleanup flags, and Discord client-click wait-mode state.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs`:
   `37 tests, 0 failures`. Static validation passed with warning-free
   `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix
   lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 343: Shared channel launch-gate readiness

1. Added `LemonCore.Doctor.ChannelReadiness` as the shared redacted
   Telegram/Discord launch-gate summary for promoted channels.
2. The readiness helper consumes existing redacted channel diagnostics and
   proof diagnostics, then reports gate ids, statuses, safe reason kinds,
   redacted evidence, copy-ready next actions, and aggregate counts for
   Telegram config/voice and Discord config/DM/free-response/reconnect/slash
   gates.
3. Support bundles now include `channel_readiness.json` next to
   `channel_diagnostics.json`, with cleanup flags proving it excludes bot
   tokens, secret names, chat/channel/guild ids, message bodies, raw proof
   paths, and raw proof details.
4. Control-plane `channels.status` now returns the same shared `readiness`
   payload and launch-gate counts in `summary`, so non-Web operator clients can
   see the same Discord slash client-click wait-mode handoff and launch-blocker
   state as support tooling.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/channel_readiness_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs`:
   `5 tests, 0 failures`, and
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs`:
   `66 tests, 0 failures`. Static validation passed with warning-free
   `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix
   lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 342: Shared usage diagnostics contract tests

1. Added direct `LemonCore.UsageDiagnosticsTest` coverage for the shared usage
   aggregate contract now used by Web `/ops`, control-plane `usage.status`,
   doctor `usage.status`, and support-bundle `usage_diagnostics.json`.
2. The tests cover mixed atom/string summary keys, provider rows discovered
   from breakdown/request/token maps, daily totals, cleanup flags, configured
   quota status, and `over_limit` classification.
3. The fixture seeds private prompt, response, message-body, and API-key-like
   fields and asserts the shared diagnostic shape omits them.
4. Updated the root `LemonCore` moduledoc inventory to include
   `LemonCore.UsageStore` and `LemonCore.UsageDiagnostics`.
5. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/usage_diagnostics_test.exs apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs`:
   `65 tests, 0 failures`. Static validation passed with warning-free
   `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix
   lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 341: Control-plane usage diagnostics convergence

1. Refactored control-plane `usage.status` to use
   `LemonCore.UsageDiagnostics.status/1` while preserving its existing
   lowerCamel JSON response contract for clients.
2. Kept the public `runs`, `tokens`, `cost`, `quotas`, `providers`, and
   `summary` keys stable, but removed handler-local usage aggregation helpers
   in favor of the shared core diagnostics shape used by Web `/ops`, doctor,
   and support bundles.
3. Added a redaction regression that seeds private prompt, response,
   message-body, and API-key-like fields into shared usage stores and asserts
   that `usage.status` returns only aggregate values and cleanup booleans.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs`:
   `59 tests, 0 failures`. The broader control-plane optional/schema lane
   passed with `176 tests, 0 failures`, and static validation passed with
   warning-free `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test
   mix lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 340: Shared usage diagnostics convergence

1. Refactored Web `/ops` usage snapshots to call
   `LemonCore.UsageDiagnostics.status/1`, matching support-bundle
   `usage_diagnostics.json` and doctor `usage.status`.
2. Removed the duplicate Web-only usage aggregation helpers so requests,
   tokens, cost, provider rows, daily totals, quota state, and cleanup flags now
   come from one core diagnostic contract.
3. Updated Web docs to name `LemonCore.UsageDiagnostics` as the backing source
   for the redacted usage/cost/quota aggregate panel.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs`:
   `99 tests, 0 failures`. Static validation passed with warning-free
   `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix
   lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 339: Doctor usage quota status

1. Added `LemonCore.UsageDiagnostics` as the shared redacted aggregate shaper
   for usage records, current usage summaries, provider rows, daily totals,
   quotas, cleanup flags, and limit status.
2. Refactored `usage_diagnostics.json` support-bundle generation to use the
   shared diagnostics module instead of keeping bundle-local aggregation logic.
3. Added `LemonCore.Doctor.Checks.Usage` and wired it into `LemonCore.Doctor`
   as `usage.status`, returning skip for no current usage, pass for visible
   aggregate usage, and warn when configured run/token/cost limits are
   exceeded.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/checks_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs`:
   `62 tests, 0 failures`. Static validation passed with warning-free
   `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix
   lemon.quality`, docs lint, HTML lint, and diff hygiene.

### Slice 338: Support-bundle usage diagnostics

1. Added `usage_diagnostics.json` to `LemonCore.Doctor.SupportBundle`, using
   shared `LemonCore.UsageStore` state for the current usage summary and
   today's usage record.
2. The diagnostic file reports only bounded operator aggregates: current cost,
   request count, input/output/total token counts, provider rows, today totals,
   configured run/token/cost quota limits, and limit status.
3. The support-bundle fixture seeds private prompt, response, message-body, and
   API-key-like fields in the usage stores and asserts that none are present in
   the generated bundle while cleanup flags explicitly mark those classes as
   excluded.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs`:
   `3 tests, 0 failures`.

### Slice 337: Web ops usage aggregate visibility

1. Added `LemonCore.UsageStore` as the shared typed wrapper for usage records,
   current usage summaries, and quota counters, then kept the existing
   control-plane usage wrapper as a delegator so existing method APIs stay
   stable.
2. Web `/ops` now shows a redacted usage and quota panel with current cost,
   request count, token count, provider rows, today totals, and configured
   run/token/cost limits. The panel reads shared core usage state directly
   rather than depending on `lemon_control_plane`.
3. The `/ops` usage snapshot and panel carry explicit cleanup flags for prompt
   text, responses, message bodies, credentials, and secret values, with
   regression coverage proving seeded prompt/API-key fields are not surfaced.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs`:
   `37 tests, 0 failures`,
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `175 tests, 0 failures`, and
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/store_test.exs apps/lemon_core/test/lemon_core/store/ets_backend_test.exs`:
   `64 tests, 0 failures`. Static validation passed with docs lint,
   HTML lint, diff hygiene, warning-free `MIX_ENV=test mix compile
   --warnings-as-errors`, and `MIX_ENV=test mix lemon.quality`.

### Slice 335: Session compact cleanup summary

1. `sessions.compact` now preserves the existing admin compaction behavior while
   adding a bounded result summary for compaction state, force mode, custom
   summary presence, token-count return state, and no-text cleanup guarantees.
2. The custom compaction summary is still passed to the active session when
   supplied, but the control-plane response does not echo prompt text, message
   bodies, or custom summary text back to clients.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `112 tests, 0 failures`, covering compaction cleanup summaries, agent wait
   answer/error redaction, and schemas. The broader control-plane parity gate
   passed with helper summaries, wizard redaction, skill env redaction, log
   redaction, cron output redaction, run-internal redaction, session-detail
   redaction, preview text redaction, agent-wait answer/error redaction,
   session-compaction cleanup summaries, Kanban summaries, terminal/LSP status
   summaries, provider/proof/extension summaries, memory/secrets summaries,
   introspection snapshot summaries, health/status summaries, run
   graph/introspection summaries, reload summaries, LSP server summaries, LSP
   document summaries, channel status summaries, browser request summaries,
   checkpoint diff/restore summaries, cron run-history lifecycle summaries,
   cron write lifecycle summaries, cron-audit lifecycle summaries, cron-status
   cleanup summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, cron lifecycle methods,
   device pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy, node-pair-list,
   node-describe, node-list, system-presence, system-event, event ingest,
   event subscriptions, WebSocket connection, EventBridge, EventBridge mapping
   coverage, monitoring, agent-routing, model-catalog, optional parity, secrets
   status, status, introspection, schema, and atom-safety lanes:
   `591 tests, 0 failures`.

### Slice 334: Agent wait sensitive answer redaction

1. `agent.wait` now preserves completed-run answer and error return semantics
   while redacting inline API-key, token, secret, password, private-key,
   credential, and bearer-token patterns from returned answer/error values.
2. The result summary still reports answer-return and byte-count metadata
   without echoing prompt text, and cleanup now explicitly marks sensitive
   answer-value redaction as active.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/control_plane_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `109 tests, 0 failures`, covering agent wait answer/error redaction and
   schemas. The broader control-plane parity gate passed with helper
   summaries, wizard redaction, skill env redaction, log redaction, cron output
   redaction, run-internal redaction, session-detail redaction, preview text
   redaction, agent-wait answer/error redaction, Kanban summaries,
   terminal/LSP status summaries, provider/proof/extension summaries,
   memory/secrets summaries, introspection snapshot summaries, health/status
   summaries, run graph/introspection summaries, reload summaries, LSP server
   summaries, LSP document summaries, channel status summaries, browser
   request summaries, checkpoint diff/restore summaries, cron run-history
   lifecycle summaries, cron write lifecycle summaries, cron-audit lifecycle
   summaries, cron-status cleanup summaries, cron-list target-text redaction
   summaries, goal continuation/loop cleanup summaries, goal clear cleanup
   summaries, goal objective redaction summaries, chat send summaries, TTS
   provider summaries, config read summaries, agent submission/wait summaries,
   agent file summaries, agent progress summaries, agent identity summaries,
   agent inbox summaries, agent endpoint summaries, config schema, config set,
   secrets lifecycle, config patch, channel logout, send, voicewake writes,
   TTS config writes, talk mode, chat abort, session reset/delete, session
   patch, approval policy writes, approval request/resolve, cron lifecycle
   methods, device pairing, connect-challenge, node-pairing lifecycle,
   node-rename, node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `588 tests, 0 failures`.

### Slice 333: Preview-mode sensitive text redaction

1. `session.detail` now redacts inline credential patterns from prompt and
   answer previews when `includeFullText` is false, while preserving the
   explicit full-text opt-in for trusted operators.
2. `sessions.preview` now redacts the same inline API-key, token, secret,
   password, private-key, credential, and bearer-token patterns from compact
   prompt/answer previews. `chat.history` now applies the same redaction in
   preview mode when `includeFullText: false`; full-text mode remains explicit
   and is marked in cleanup metadata.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering preview text redaction, session detail
   redaction, run graph and introspection redaction, and schemas. The broader
   control-plane parity gate passed with helper summaries, wizard redaction,
   skill env redaction, log redaction, cron output redaction, run-internal
   redaction, session-detail redaction, preview text redaction, Kanban
   summaries, terminal/LSP status summaries, provider/proof/extension
   summaries, memory/secrets summaries, introspection snapshot summaries,
   health/status summaries, run graph/introspection summaries, reload
   summaries, LSP server summaries, LSP document summaries, channel status
   summaries, browser request summaries, checkpoint diff/restore summaries,
   cron run-history lifecycle summaries, cron write lifecycle summaries,
   cron-audit lifecycle summaries, cron-status cleanup summaries, cron-list
   target-text redaction summaries, goal continuation/loop cleanup summaries,
   goal clear cleanup summaries, goal objective redaction summaries, chat send
   summaries, TTS provider summaries, config read summaries, agent
   submission/wait summaries, agent file summaries, agent progress summaries,
   agent identity summaries, agent inbox summaries, agent endpoint summaries,
   config schema, config set, secrets lifecycle, config patch, channel logout,
   send, voicewake writes, TTS config writes, talk mode, chat abort,
   session reset/delete, session patch, approval policy writes, approval
   request/resolve, cron lifecycle methods, device pairing, connect-challenge,
   node-pairing lifecycle, node-rename, node-event, node invocation,
   heartbeat, approval read policy, node-pair-list, node-describe, node-list,
   system-presence, system-event, event ingest, event subscriptions, WebSocket
   connection, EventBridge, EventBridge mapping coverage, monitoring,
   agent-routing, model-catalog, optional parity, secrets status, status,
   introspection, schema, and atom-safety lanes: `587 tests, 0 failures`.

### Slice 332: Session detail sensitive run-internal redaction

1. `session.detail` now preserves session/run summaries, tool-call previews,
   summary/completed internals, optional raw events, and optional run records
   while redacting API-key, secret, token, password, private-key, credential,
   and bearer-token values before returning them to control-plane clients.
2. Tool-call detail previews and top-level run errors now pass through the same
   redaction path. Explicit `includeFullText` still controls prompt/answer full
   text, but the tool-call and run-internal surfaces stay redacted even when
   trusted operators request full prompt/answer bodies.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering session detail redaction, run graph and
   introspection redaction, and schemas. The broader control-plane parity gate
   passed with helper summaries, wizard redaction, skill env redaction, log
   redaction, cron output redaction, run-internal redaction, session-detail
   redaction, Kanban summaries, terminal/LSP status summaries,
   provider/proof/extension summaries, memory/secrets summaries, introspection
   snapshot summaries, health/status summaries, run graph/introspection
   summaries, reload summaries, LSP server summaries, LSP document summaries,
   channel status summaries, browser request summaries, checkpoint
   diff/restore summaries, cron run-history lifecycle summaries, cron write
   lifecycle summaries, cron-audit lifecycle summaries, cron-status cleanup
   summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, cron lifecycle methods,
   device pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `587 tests, 0 failures`.

### Slice 331: Run internals sensitive payload redaction

1. `run.introspection.list` now preserves introspection timeline events and
   optional run-store internals while redacting sensitive payload, run-record,
   and raw-event values before returning them to control-plane clients.
2. `run.graph.get` now preserves parent/child graph payloads, optional
   per-node run records, raw run events, and introspection timelines while
   redacting API-key, secret, token, password, private-key, credential, and
   bearer-token values in those optional internals. Cleanup summaries now
   explicitly mark sensitive payload-value redaction as active and credential
   and secret values as excluded.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `64 tests, 0 failures`, covering run graph and introspection redaction plus
   schemas. The broader control-plane parity gate passed with helper summaries,
   wizard redaction, skill env redaction, log redaction, cron output redaction,
   run-internal redaction, Kanban summaries, terminal/LSP status summaries,
   provider/proof/extension summaries, memory/secrets summaries, introspection
   snapshot summaries, health/status summaries, run graph/introspection
   summaries, reload summaries, LSP server summaries, LSP document summaries,
   channel status summaries, browser request summaries, checkpoint
   diff/restore summaries, cron run-history lifecycle summaries, cron write
   lifecycle summaries, cron-audit lifecycle summaries, cron-status cleanup
   summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, cron lifecycle methods,
   device pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `587 tests, 0 failures`.

### Slice 330: Cron run-history sensitive output redaction

1. `cron.runs` now preserves run-history previews, full-output opt-ins, error
   text, metadata, run-record, and introspection payloads, but redacts common
   inline credential patterns from output/error strings before returning them
   to control-plane clients.
2. Optional metadata, run-record, and introspection internals now pass through
   the same recursive serializer with sensitive key redaction for API-key,
   secret, token, password, private-key, and credential markers. Cleanup
   summaries now explicitly mark sensitive output-value redaction as active.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/system_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `83 tests, 0 failures`, covering cron output/error redaction, log
   redaction, system methods, and schemas. The broader control-plane parity
   gate passed with helper summaries, wizard redaction, skill env redaction,
   log redaction, cron output redaction, Kanban summaries, terminal/LSP status
   summaries, provider/proof/extension summaries, memory/secrets summaries,
   introspection snapshot summaries, health/status summaries, run
   graph/introspection summaries, reload summaries, LSP server summaries, LSP
   document summaries, channel status summaries, browser request summaries,
   checkpoint diff/restore summaries, cron run-history lifecycle summaries,
   cron write lifecycle summaries, cron-audit lifecycle summaries, cron-status
   cleanup summaries, cron-list target-text redaction summaries, goal
   continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, cron lifecycle methods,
   device pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `585 tests, 0 failures`.

### Slice 329: Log-tail sensitive value redaction

1. `logs.tail` now keeps the existing log array shape but recursively redacts
   sensitive key values for API-key, secret, token, password, private-key, and
   credential markers before returning recent logs to control-plane clients.
2. Free-form log strings now redact common inline credential patterns such as
   `api_key=...` and bearer tokens while preserving the surrounding message
   text. The cleanup summary now explicitly marks sensitive log-value redaction
   as active.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_methods_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs`:
   `67 tests, 0 failures`, covering filtered log summaries, unavailable
   log-ring fallback, sensitive key redaction, inline credential redaction, and
   schemas. The broader control-plane parity gate passed with helper summaries,
   wizard redaction, skill env redaction, log redaction, Kanban summaries,
   terminal/LSP status summaries, provider/proof/extension summaries,
   memory/secrets summaries, introspection snapshot summaries, health/status
   summaries, run graph/introspection summaries, reload summaries, LSP server
   summaries, LSP document summaries, channel status summaries, browser request
   summaries, checkpoint diff/restore summaries, cron run-history lifecycle
   summaries, cron write lifecycle summaries, cron-audit lifecycle summaries,
   cron-status cleanup summaries, cron-list target-text redaction summaries,
   goal continuation/loop cleanup summaries, goal clear cleanup summaries, goal
   objective redaction summaries, chat send summaries, TTS provider summaries,
   config read summaries, agent submission/wait summaries, agent file
   summaries, agent progress summaries, agent identity summaries, agent inbox
   summaries, agent endpoint summaries, config schema, config set, secrets
   lifecycle, config patch, channel logout, send, voicewake writes, TTS config
   writes, talk mode, chat abort, session reset/delete, session patch,
   approval policy writes, approval request/resolve, cron lifecycle methods,
   device pairing, connect-challenge, node-pairing lifecycle, node-rename,
   node-event, node invocation, heartbeat, approval read policy,
   node-pair-list, node-describe, node-list, system-presence, system-event,
   event ingest, event subscriptions, WebSocket connection, EventBridge,
   EventBridge mapping coverage, monitoring, agent-routing, model-catalog,
   optional parity, secrets status, status, introspection, schema, and
   atom-safety lanes: `585 tests, 0 failures`.

### Slice 412: Support-bundle provider-media reason contract

1. Support-bundle coverage now asserts `readiness_summary.json` preserves the
   compact `provider_media` unresolved gate's `reason_kinds` list.
2. The fixture uses a failed redacted provider-media proof with
   `provider_http_error`, proving the support artifact carries safe blocker
   labels while continuing to redact private prompts, provider responses,
   tokens, secret names, ids, proof paths, and proof details.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs --seed 1`:
   `3 tests, 0 failures`.

### Slice 411: Readiness CLI unresolved reason lists

1. Human-readable `mix lemon.readiness` / `./bin/lemon readiness` unresolved
   gate rows now print `reasons=...` when a gate carries list-shaped
   `reason_kinds`, closing the text-mode gap for provider-media blocker
   reasons.
2. The existing singular `reason=...` output remains unchanged for gates such
   as Discord DM and slash client-click.
3. Focused coverage now runs readiness text mode with enough unresolved rows to
   include the provider-media gate and asserts the safe provider reason kind is
   visible without raw prompts, provider responses, or paths.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs --seed 1`:
   `3 tests, 0 failures`.

### Slice 410: Readiness JSON-RPC unresolved reason summary

1. `readiness.status.summary` now includes
   `unresolvedGateReasonKindCount` and `unresolvedGateReasonKinds`.
2. The summary list is derived from both singular unresolved-gate
   `reasonKind` values and list-shaped provider-media `reasonKinds`, sorted
   and deduplicated for lightweight operator clients.
3. This lets non-Web clients show current blockers such as
   `discord_dm_setup_refused` and provider permission-denied reason kinds
   without scanning the full unresolved gate list or parsing doctor text.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `69 tests, 0 failures`.

### Slice 409: Provider-media unresolved-gate reason kinds

1. `LemonCore.Doctor.ReadinessSummary` now derives a bounded
   `reason_kinds` list for the compact `provider_media` unresolved gate from
   the shared `providerMedia` proof-gate lanes.
2. Web `/ops` now asks for up to ten unresolved readiness gates, enough to keep
   the provider-media row visible next to Telegram/Discord gates, and renders
   `reason_kinds` when present.
3. JSON-RPC `readiness.status` lower-camelizes the same field as
   `reasonKinds`, so non-Web clients can inspect failed image/TTS/video reason
   classes without parsing the doctor message text.
4. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   core `3 tests, 0 failures`, Web `37 tests, 0 failures`, and control-plane
   `69 tests, 0 failures`.

### Slice 408: Discord DM unresolved-gate reason kind

1. `LemonCore.Doctor.ChannelReadiness` now attaches
   `discord_dm_setup_refused` to blocked Discord DM readiness gates and
   `discord_dm_missing` to missing-proof warnings instead of returning a nil
   reason kind.
2. `LemonCore.Doctor.ReadinessSummary` already forwards channel gate reason
   kinds into `unresolved_gates`, so `mix lemon.readiness`,
   `./bin/lemon readiness`, support-bundle `readiness_summary.json`,
   `readiness.status`, and Web `/ops` now preserve the safe Discord DM blocker
   label in the compact triage row.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/channel_readiness_test.exs --seed 1`:
   `4 tests, 0 failures`. A direct `./bin/lemon readiness --json` probe showed
   the `discord.dm` unresolved gate reporting
   `reason_kind: "discord_dm_setup_refused"`.
4. Broader readiness-surface validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/channel_readiness_test.exs apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   core `10 tests, 0 failures`, Web `37 tests, 0 failures`, and control-plane
   `69 tests, 0 failures`.

### Slice 407: Verifier support-bundle proof-gate shape

1. `scripts/verify_source_install` now opens support-bundle
   `readiness_summary.json` and requires the shared proof-gate object, the
   five expected launch-gate ids, `proof_gate_summary.gateCount == 5`, an
   object status map with the same ids, and a provider-media proof-gate status
   of `passed` or `warning`.
2. `scripts/verify_release_runtime_boot` performs the same
   `readiness_summary.json` proof-gate shape check after booting each release
   profile and generating a release-runtime support bundle through `eval`.
3. This turns the support-bundle proof-gate payload from a unit-test-only
   contract into a source-install and release-artifact verifier contract, so a
   candidate cannot pass while omitting the operator-visible launch-gate
   summary.
4. Validation passed with `bash -n scripts/verify_source_install
   scripts/verify_release_runtime_boot`,
   `scripts/verify_source_install --skip-compile`,
   `scripts/lint_ci_docs.sh`, and `xmllint --html --noout
   docs/plans/lemon-hermes-progress.html`. The source verifier generated a
   support bundle and printed `ok support bundle contains required redacted
   readiness diagnostics`; the release-runtime verifier was syntax-checked
   because no packaged artifact directory was available in this checkout.

### Slice 406: Readiness JSON-RPC proof-gate summary

1. `readiness.status.summary` now includes `proofGateStatus`,
   `proofGateCount`, `proofGatePassedCount`, `proofGateBlockedCount`,
   `proofGateWarningCount`, and `proofGateStatuses`, all derived from the shared
   `proofGateSummary`.
2. This keeps lightweight JSON-RPC clients aligned with the full readiness
   payload, Web `/ops`, support bundles, and the human-readable readiness CLI
   without requiring them to inspect the full proof-gate object.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `69 tests, 0 failures`.

### Slice 405: Source verifier guards readiness proof gates

1. `scripts/verify_source_install` now fails if `./bin/lemon readiness` output
   does not include the human-readable `Proof gates:` line. This keeps the
   source-install verifier aligned with the shared proof-gate summary introduced
   into CLI/readiness surfaces.
2. Validation passed with `bash -n scripts/verify_source_install` and
   `scripts/verify_source_install --skip-compile`.

### Slice 404: Readiness CLI proof-gate summary

1. `mix lemon.readiness` and `./bin/lemon readiness` now print a compact
   `Proof gates:` line from `proof_gate_summary`, covering Discord DM, Discord
   slash registration, Discord slash client-click, provider media, and terminal
   backend launch-gate counts.
2. JSON output, support bundles, `readiness.status`, and Web `/ops` already
   had the shared proof-gate payload from Slice 403; this closes the text-mode
   source-install operator gap without adding new raw proof fields.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs --seed 1`:
   `3 tests, 0 failures`. The broader source-install verifier also passed with
   `scripts/verify_source_install --skip-compile`, including source-wrapper
   readiness and required support-bundle diagnostics.

### Slice 403: Shared proof launch-gate diagnostics

1. `LemonCore.Doctor.ProofLaunchGates` now owns the redacted proof launch-gate
   model for Discord DM, Discord slash registration, Discord slash
   client-click, provider media, and terminal backends. `proofs.status` now
   delegates to that shared module instead of keeping private control-plane
   launch-gate logic.
2. `LemonCore.Doctor.ReadinessSummary` now includes `proof_gates` and
   `proof_gate_summary`, so `mix lemon.readiness`, `./bin/lemon readiness`,
   support-bundle `readiness_summary.json`, JSON-RPC `readiness.status`, and
   Web `/ops` all show the same proof-gate statuses without raw proof rows,
   paths, prompts, provider responses, or secret values.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/lemon_core/doctor/proof_launch_gates_test.exs apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs --seed 1`:
   `8 tests, 0 failures`, plus
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `69 tests, 0 failures`.

### Slice 402: Web ops launch readiness panel

1. Web `/ops` now renders a top-level Launch Readiness metric and panel backed
   by `LemonCore.Doctor.ReadinessSummary`, matching `mix lemon.readiness`,
   `./bin/lemon readiness`, support-bundle `readiness_summary.json`, and
   JSON-RPC `readiness.status`.
2. The panel shows doctor status/counts, Telegram/Discord launch-gate counts,
   provider-media state, proof totals, unresolved gate labels/evidence/reason
   kinds/next actions, and cleanup flags. It preserves the same redaction
   boundary: no raw ids, prompts, provider responses, proof paths/details, bot
   tokens, secret names, message bodies, or secret values.
3. Focused Web validation passed with
   `MIX_ENV=test mix test apps/lemon_web/test/lemon_web_test.exs --seed 1`:
   `37 tests, 0 failures`.

### Slice 401: Control-plane launch readiness status

1. `readiness.status` now exposes the same compact launch-readiness rollup as
   `mix lemon.readiness`, `./bin/lemon readiness`, and support-bundle
   `readiness_summary.json` to JSON-RPC operator clients. The method returns
   lowerCamelCase summaries for doctor status, promoted Telegram/Discord gate
   counts, provider-media state, proof totals, unresolved gate labels, and
   cleanup flags.
2. The method is read-only, schema-validated, and registered in the control-plane
   method registry. It keeps raw ids, prompts, provider responses, proof paths,
   proof details, bot tokens, and secret values out of the response.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs --seed 1`:
   `69 tests, 0 failures`. The schema-inclusive lane passed with
   `MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_control_plane/test/lemon_control_plane/protocol/schemas_test.exs --seed 1`:
   `120 tests, 0 failures`.

### Slice 400: Support-bundle launch readiness summary

1. `LemonCore.Doctor.ReadinessSummary` now owns the compact launch-readiness
   rollup shared by `mix lemon.readiness`, `./bin/lemon readiness`, and support
   bundles. The summary includes doctor status/counts, promoted Telegram/Discord
   gate counts, provider-media proof state, proof totals, unresolved gate labels,
   and cleanup flags without raw ids, prompts, provider responses, proof paths,
   proof details, or secret values.
2. Support bundles now include `readiness_summary.json` beside
   `channel_readiness.json`, giving source-install and release-runtime support
   triage one self-contained launch-readiness artifact. Source-install and
   release-runtime bundle verifiers require the entry, and public support/release
   docs describe the redaction boundary.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs --seed 1`:
   `6 tests, 0 failures`. The broader source-wrapper support lane passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.channels_test.exs apps/lemon_core/test/mix/tasks/lemon.proofs_test.exs apps/lemon_core/test/mix/tasks/lemon.usage_test.exs apps/lemon_core/test/mix/tasks/lemon.media_test.exs apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs --seed 1`:
   `14 tests, 0 failures`. `scripts/verify_source_install`,
   `scripts/test_contract.sh`, `scripts/lint_ci_docs.sh`, shell syntax checks,
   and HTML lint also passed.

### Slice 399: Strict source wrapper readiness gate

1. `mix lemon.readiness --strict` and `./bin/lemon readiness --strict` now fail
   unless the compact launch-readiness status is `ready`. Normal readiness
   output remains informational and exits successfully, so source installs can
   still inspect blocked gates without making every local proof command fail.
2. Focused validation now covers the blocked strict-mode path without leaking
   raw proof paths, prompts, provider responses, or secret values. This creates
   a lightweight BEAM-native gate for scripts that need hard pass/fail behavior
   without invoking the full final release audit.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs --seed 1`:
   `3 tests, 0 failures`.

### Slice 398: Source wrapper readiness summary command

1. `mix lemon.readiness` now consolidates the existing BEAM doctor, promoted
   channel readiness, proof inventory, and provider-media proof check into a
   compact source-install launch-readiness summary. It reports doctor counts,
   Telegram/Discord gate counts, provider-media state, proof totals, unresolved
   gates, and cleanup flags without bot tokens, secret names, chat/channel ids,
   message bodies, raw proof paths/details, prompts, provider responses, or
   secret values.
2. `./bin/lemon readiness` now delegates to `mix lemon.readiness`, and
   `scripts/verify_source_install` proves the wrapper after proof inventory and
   before secrets status. The verifier checks provider-media visibility and
   raw-proof-path/provider-response cleanup lines, and the test contract
   requires that wrapper coverage.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.readiness_test.exs --seed 1`:
   `2 tests, 0 failures`. The real source wrapper currently reports launch
   status `blocked`, doctor `warn` with `30` pass / `4` warn / `0` fail /
   `4` skip, channel gates `7` passed / `1` blocked / `1` warning, provider
   media `warn`, and `238` proof artifacts. This slice intentionally does not
   run the heavy final release audit or mark external gates complete.

### Slice 397: Source wrapper media diagnostics command

1. `mix lemon.media` now exposes generated-media job, artifact, worker, and
   provider-proof readiness as a source-install operator command. It reports
   job/artifact counts, artifact bytes, supervisor state, image/TTS/STT/vision/video
   proof status, safe provider labels, grouped smoke commands, and cleanup flags
   without prompts, raw artifact paths, generated bytes, provider responses,
   channel message bodies, raw proof paths, or secret values.
2. `./bin/lemon media` now delegates to `mix lemon.media`, and
   `scripts/verify_source_install` proves the wrapper before model/provider
   inspection. The verifier checks provider-proof visibility plus prompt and
   provider-response cleanup lines, and the test contract requires that wrapper
   coverage.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.media_test.exs --seed 1`:
   `2 tests, 0 failures`. The real source wrapper currently reports `29` jobs,
   `28` artifacts, and provider proofs `2/5`: STT through
   `deepgram_transcribe`, vision through `openai_vision`, and image/TTS/video
   blocked by safe permission-denied provider reason kinds.
   `scripts/verify_source_install --skip-compile` also passed.

### Slice 396: Source wrapper usage diagnostics command

1. `mix lemon.usage` now exposes the shared redacted
   `LemonCore.UsageDiagnostics` summary as a source-install operator command.
   It prints usage status, current period totals, daily totals, provider rows,
   quota limits, and cleanup flags without prompts, responses, message bodies,
   credentials, or secret values.
2. `./bin/lemon usage` now delegates to `mix lemon.usage`, and
   `scripts/verify_source_install` proves the wrapper after skill listing and
   before update dispatch. The verifier checks prompt and credential cleanup
   lines, and the test contract requires that wrapper coverage.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.usage_test.exs --seed 1`:
   `2 tests, 0 failures`. The real source wrapper currently reports no stored
   usage in this checkout (`0` requests, `0` tokens, `0.0000` cost) and keeps
   all prompt/response/message/credential/secret cleanup flags false.
   `scripts/verify_source_install --skip-compile` also passed.

### Slice 395: Source wrapper channel readiness command

1. `mix lemon.channels` now exposes the existing redacted
   `LemonCore.Doctor.ChannelReadiness` launch-gate model as a source-install
   operator command. It prints promoted platforms, aggregate gate counts,
   per-gate evidence, safe reason kinds, and next actions for Telegram and
   Discord without raw bot tokens, secret names, chat ids, channel ids, message
   bodies, raw proof paths, or raw proof details.
2. `./bin/lemon channels` now delegates to `mix lemon.channels`, and
   `scripts/verify_source_install` proves the wrapper with
   `./bin/lemon channels --project-dir ...` before config, model, provider,
   policy, proof, secrets, skill, update, doctor, and support-bundle checks.
   The test contract now requires that verifier coverage.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.channels_test.exs --seed 1`:
   `2 tests, 0 failures`. The real source wrapper reported the current local
   promoted channel readiness as `7` passed gates, `1` blocked gate, and `1`
   warning, with Discord DM still blocked by `discord_dm_setup_refused` and
   Discord slash client-click still waiting for a real operator click.
   `scripts/verify_source_install --skip-compile` also passed.

### Slice 394: Source wrapper proof inventory command

1. `mix lemon.proofs` now exposes the existing redacted
   `LemonCore.Doctor.ProofDiagnostics` inventory as a source-install operator
   command. It prints proof, status, scope, reason-kind, directory, recent
   proof, and latest-check summaries with hash-only artifact identifiers and
   explicit cleanup lines for raw paths, filenames, proof details, prompts, and
   provider responses.
2. `./bin/lemon proofs` now delegates to `mix lemon.proofs`, and
   `scripts/verify_source_install` proves the wrapper with
   `./bin/lemon proofs --project-dir ... --limit 1` alongside setup, config,
   doctor, models, providers, policy, secrets, skill, and update. The test
   contract now requires that verifier coverage.
3. Focused validation passed with
   `MIX_ENV=test mix test apps/lemon_core/test/mix/tasks/lemon.proofs_test.exs --seed 1`:
   `2 tests, 0 failures`. The real source wrapper reported the current local
   proof inventory as `238` valid proofs, `162` completed, `37` failed, `39`
   skipped, and `0` invalid, with raw path and raw filename cleanup both false.
   `scripts/verify_source_install --skip-compile` also passed.

## Follow-up backlog

1. Continue provider-weirdness regressions for provider-normalized response error shapes beyond context length and request sanitation.
2. Continue cross-layer lifecycle checks from AgentCore tool events through LemonRunner, Gateway bus events, Router coalescing, and final session state.
