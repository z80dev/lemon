# Lemon 1.0 Interface Proof Pack

Status: release-candidate proof pack, complete for initial 1.0 interface scope

Last reviewed: 2026-05-11

## Summary

This proof pack records the current evidence for the three primary Lemon 1.0
interfaces named in the readiness plan:

- TUI for local development
- Web UI for observability and operations
- Telegram for remote chat access

The current result is stronger than a surface audit but not yet a full live
product proof. TUI has a green client test lane, source-runtime transcripts for
the deterministic echo path, rendered tool failure, and real cancellable-run
abort path, plus release-readiness fixes landed during this pass. Web now has
focused LiveView/controller tests and a browser-level source-runtime proof for
session submission, `/ops`, run detail, custom-port boot, and support-bundle
download. Telegram has focused
adapter/router tests for formatting, delivery state, progress, cancellation,
session keys, and channel-native control behavior, plus live bot proof for
command handling, progress messages, bare `/cancel`, and approval-button
resolution. A live invalid session-model proof now also verifies that common
configuration failures return a concise Telegram failure instead of a BEAM stack
trace.

Post-1.0 unless launch positioning expands:

- lower-priority Web config panels outside defaults, providers, channels, cron,
  skills, approvals, run inspection, runtime health, and support bundles

## Commands Run

### TUI

From `clients/lemon-tui`:

```bash
npm run typecheck
npm test
```

Result:

- `tsc --noEmit` passed.
- Vitest passed: 59 test files, 1,255 tests.

Focused checks after fixes:

```bash
npm test -- src/ink/components/SelectOverlay.test.tsx
npm test -- src/ink/components/MessageList.test.tsx src/ink/components/SelectOverlay.test.tsx src/state.test.ts
npm test -- src/agent-connection.test.ts
npm test -- src/ink/components/InputEditor.test.tsx
npm test -- src/ink/AppLayout.test.tsx src/ink/components/InputEditor.test.tsx src/ink/App.test.tsx
```

Result:

- Select overlay regression test passed: 14 tests.
- Message list, select overlay, and state focused tests passed: 3 files, 79
  tests.
- Agent connection regression tests passed: 91 tests.
- Input editor regression tests passed: 19 tests.
- App layout, input editor, and app focused tests passed: 3 files, 21 tests.

### Telegram and Router

From the repo root:

```bash
mix test \
  apps/lemon_channels/test/lemon_channels/telegram/markdown_test.exs \
  apps/lemon_channels/test/lemon_channels/telegram/delivery_test.exs \
  apps/lemon_channels/test/lemon_channels/telegram/state_store_test.exs \
  apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs \
  apps/lemon_router/test/lemon_router/session_key_test.exs
```

Result:

- `lemon_channels`: 67 tests, 0 failures.
- `lemon_router`: 41 tests, 0 failures.

Focused markdown/media boundary rerun:

```bash
mix test \
  apps/lemon_channels/test/lemon_channels/telegram/markdown_test.exs \
  apps/lemon_channels/test/lemon_channels/adapters/telegram/outbound_test.exs \
  apps/lemon_gateway/test/tools/telegram_send_image_test.exs
```

Result:

- `lemon_channels`: 75 tests, 0 failures.
- `lemon_gateway`: 5 tests, 0 failures.

Focused live-cancel regression after the Telegram product proof found that bare
`/cancel` did not abort active runs unless the command replied to a progress
message:

```bash
mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_cancel_test.exs
```

Result:

- `lemon_channels`: 18 tests, 0 failures.

### Web

Previously run in this launch batch:

```bash
mix test apps/lemon_web/test/lemon_web_test.exs
```

Result:

- 11 tests, 0 failures.

After the Web endpoint, LiveView asset, operations dashboard, and cron control
fixes:

```bash
mix test apps/lemon_web/test/lemon_web_test.exs
```

Result:

- 16 tests, 0 failures.

Browser proof commands:

```bash
mix phx.server
npx agent-browser open http://127.0.0.1:4080/
npx agent-browser fill @e2 "use echo then click-proof-2026-05-11"
npx agent-browser click @e3
npx agent-browser open http://127.0.0.1:4080/ops
npx agent-browser open http://127.0.0.1:4080/ops/runs/run_d38e47d6-96ac-4ce8-907a-4a7b0039a20f
curl -fsS -D /tmp/lemon-web-proof-downloads/headers.txt \
  -o /tmp/lemon-web-proof-downloads/support-bundle.zip \
  http://127.0.0.1:4080/ops/support-bundle
```

Result:

- `LemonWeb.Endpoint` bound with `Bandit.PhoenixAdapter` at
  `127.0.0.1:4080`.
- Browser form submission rendered `Run started (echo).`
- Browser session rendered `Echo: use echo then click-proof-2026-05-11`.
- `/ops` rendered runtime/router/provider state, recent runs, observed
  activity, runtime metadata, cron schedules, cron create/edit/delete/run controls, skill
  provenance/status, install/update controls, enable/disable controls, channel
  transport config enable/disable controls, live channel runtime status and
  disconnect/reconnect controls, and support bundle controls.
- `/ops/runs/run_d38e47d6-96ac-4ce8-907a-4a7b0039a20f` rendered timeline,
  event counts, run graph, failures, approvals, and support bundle controls.
- `/ops/support-bundle` returned HTTP 200 with `content-type: application/zip`
  and attachment filename `lemon-web-support-bundle-1.zip`.
- Browser console and page errors were empty after the successful click proof.
- Screenshots were captured at
  `docs/assets/launch/web-session-proof-2026-05-11.png` and
  `docs/assets/launch/web-ops-proof-2026-05-11.png`.

Unified runtime custom-port proof:

```bash
LEMON_STORE_PATH="$(mktemp -d)" LEMON_LOG_LEVEL=warning \
  ./bin/lemon --no-distribution \
  --port 45240 \
  --web-port 45280 \
  --sim-port 45290

curl -fsS http://127.0.0.1:45280/healthz
```

Result:

- `LemonWeb.Endpoint` bound with `Bandit.PhoenixAdapter` at
  `127.0.0.1:45280`.
- Web `/healthz` returned `ok`.
- Sim UI also bound to the requested `127.0.0.1:45290` port.

## TUI Evidence

The TUI suite proves the core local client contracts:

- runtime connection and event parsing
- prompt submission and session state handling
- config, dotenv, theme, and git-context behavior
- message rendering for user, assistant, and tool-result messages
- streaming/event hooks
- tool panels, execution bars, tool hints, and result formatting
- settings, help, stats, search, editor, input, confirm, and select overlays
- cancellation command handling through the command layer and busy-state
  double-press shortcuts
- formatter behavior for bash, edit, find, grep, patch, process, read, task,
  todo, web, and write tool outputs

Five release-readiness defects were fixed while proving the lane:

- `SelectOverlay` could visibly move selection with ArrowDown but submit the
  previous option when Enter followed quickly. The input handler now tracks the
  selected row synchronously.
- Assistant message IDs were timestamp-derived, which could produce duplicate
  React keys when messages arrived in the same millisecond. Assistant
  normalization now uses the monotonic message ID allocator while preserving the
  in-flight streaming ID across updates.
- The TUI could stay on `connecting...` after the WebSocket handshake because
  the ready message from `connection.start()` was not applied before the first
  render.
- Control-plane `tool_use` events were dropped by the TUI WebSocket adapter, so
  source-runtime tool failures could disappear from the local UI.
- The modeline advertised `Esc×2: abort`, but the busy input editor did not pass
  Escape or Ctrl+C through to `connection.abort()`.
- The initial busy-state abort arm used a short timer window that was brittle
  under streaming terminal repaint load. The AppLayout-level abort gate now
  arms on the first Escape/Ctrl+C during a busy run and aborts on the next
  matching key before resetting when the run goes idle.

Current launch classification:

- TUI has credible automated client coverage for the daily-use path.
- TUI now has source-runtime transcripts for deterministic echo and a rendered
  tool failure.
- TUI now has source-runtime proof for `Esc×2` abort against a real cancellable
  run.

## Web Evidence

The focused Web tests cover the new operations support surface:

- `/ops` dashboard route renders.
- runtime/router health summary renders.
- provider and secrets status summary renders.
- active sessions and recent runs render.
- pending approvals can be surfaced and resolved.
- observed cron, skill, channel, memory, and log activity renders from
  introspection.
- cron schedule and recent cron failure summaries render.
- skill store health renders.
- channel transport enablement and configured binding summaries render.
- support-bundle download route returns a zip.
- `/ops/runs/:run_id` renders timeline events, tool events, failures, nested
  run graph/subagent lineage, direct child references, event counts, run-scoped
  pending approvals, and support-bundle commands.

The product-smoke workflow also verifies packaged-runtime HTTP/Web health for
the release profile:

- packaged runtime boots
- control-plane `/healthz` works
- Web `/healthz` works for `lemon_runtime_full`
- deterministic echo agent run completes through the control-plane protocol

Live browser proof found and fixed three launch blockers:

- `LemonWeb.Endpoint` was missing the Bandit adapter and `mix phx.server`
  attempted to start unavailable `Plug.Cowboy`.
- `app.js` imported Phoenix JS from a jsDelivr URL that returned 404, so
  LiveView did not connect.
- `SessionLive` crashed on raw `:coalesced_output` maps after successful echo
  runs.
- `bin/lemon --web-port` configured the Web port but did not enable the Web
  endpoint server in source runtime boot, so custom Web ports never bound.

Current launch classification:

- Web has automated supportability coverage, packaged-runtime health proof,
  source-runtime browser proof for session submission, `/ops`, run detail,
  custom-port boot, support-bundle download, cron create/edit/delete/run
  controls plus skill install/update/enable/disable controls and an initial
  channel config/runtime slice for gateway transport enablement, gateway
  defaults, Telegram token-secret/allowlist settings, configured binding
  create/edit/delete controls, runtime metadata, default
  provider/model/thinking/engine editing, provider secret-reference editing, and
  configured adapters.
- Lower-priority Web config panels outside the initial support surface are
  post-1.0 unless Lemon is marketed as a full admin console at launch.

## Telegram Evidence

The focused Telegram and router tests prove Telegram-adjacent launch behavior
without using live bot credentials:

- Telegram markdown rendering behavior
- Telegram media/file delivery behavior through outbound and tool tests
- Telegram delivery behavior
- Telegram state store behavior
- session key construction for channel sessions
- coalesced tool status progress behavior
- inline cancel callback data generation
- status message fallback behavior
- message edit/finalization behavior for progress updates

The interface supportability audit also verifies the available Telegram controls
from code:

- `/cancel`
- `/new`
- `/resume`
- `/model`
- `/thinking`
- `/reload`
- `/trigger`
- `/cwd`
- `/topic`
- `/file`
- inline cancel controls for tool status snapshots
- watchdog keep-waiting and stop-run controls
- execution approval buttons for once, deny, session, agent, and global
  decisions

Current launch classification:

- Telegram has credible adapter/router coverage for formatting, state,
  progress, cancellation, and approval plumbing.
- Telegram has source-runtime live bot proof for the core remote path,
  approval resolution, cancellation, and concise config-error rendering.
- Telegram markdown/media behavior is now documented as a text-first 1.0
  support boundary in `docs/support.md`.

## Remaining Proof Required

### TUI Live Proof

Run against a real runtime on 2026-05-11:

```bash
./bin/lemon --no-distribution --port 45340 --web-port 45380 --sim-port 45390
node clients/lemon-tui/dist/cli.js \
  --ws-url ws://127.0.0.1:45340/ws \
  --ws-session-key agent:default:tui-proof \
  --ws-agent-id default \
  --cwd /home/z80/dev/lemon
```

Transcript:

```text
Lemon anthropic:claude-sonnet-4-20250514
cwd     ~/dev/lemon
model   anthropic:claude-sonnet-4-20250514
sessions 1 active

You:
use echo then tui-proof-2026-05-11

Processing...

Assistant:
Echo: use echo then tui-proof-2026-05-11
```

Evidence captured:

- startup connected to the active source runtime over the control-plane
  WebSocket
- cwd/repo context was visible
- a prompt started a run
- the busy/processing state appeared
- the deterministic echo response rendered in the transcript
- the first-ready render bug was fixed so the TUI no longer remains on
  `connecting...` after the WebSocket handshake

Tool-failure proof against the same source runtime used a distributed
source-runtime node and a synthetic `:engine_action` event bridged through
`LemonControlPlane.EventBridge`:

```text
┌─ tools (1) ───────────────────────────────────────────────────────────────┐
│ ✗ missing_tool_for_runner (0.0s) error                                    │
│   {"command":"missing_tool_for_runner"}                                   │
│   result: Tool missing_tool_for_runner not found                          │
└───────────────────────────────────────────────────────────────────────────┘
Ctrl+O to hide tool output
```

Evidence captured:

- `EventBridge` converted a runtime `:engine_action` event into a WebSocket
  `agent` event with `payload.type == "tool_use"`.
- The TUI WebSocket adapter mapped the event into `tool_execution_start` and
  `tool_execution_end` messages.
- A failed tool call rendered in the TUI tool panel with args, result, status,
  and the standard tool-output hint.

Abort shortcut proof status:

- Regression tests now prove busy-state double Escape calls the AppLayout-level
  TUI abort path, and InputEditor component tests still cover its standalone
  double Escape/double Ctrl+C abort behavior.
- WebSocket adapter tests prove `connection.abort()` sends `chat.abort` with
  the active session key and the last known run id.
- A live terminal proof with a synthetic `run_started` event was inconclusive:
  the terminal stayed busy because there was no real running `RunProcess` to
  terminate and no completion event to clear the synthetic busy state. Do not
  use synthetic busy state as product proof.
- A live source-runtime proof on 2026-05-11 used a temporary cancellable runtime
  module that streamed `proof tick N` through a real `RunProcess`; pressing
  Escape twice sent `chat.abort`, stopped the run, rang the completion bell, and
  returned the TUI to the idle prompt.

Still missing for deeper TUI proof:

- a follow-up prompt after cancellation

### Web Browser Proof

Current source-runtime browser proof exists for the echo happy path. Before
stable 1.0, repeat it against the release artifact and, if provider credentials
are available, one live-model run.

Run against a real runtime:

```bash
./bin/lemon
```

Evidence captured on 2026-05-11:

- `/healthz` returns ok
- `/` loads
- a session page accepts a prompt
- echo output appears
- `/ops` shows the active/recent run
- `/ops/runs/:run_id` shows timeline/tool/failure details
- `/ops/support-bundle` downloads a redacted zip

### Telegram Live Proof

Run against a configured bot:

```bash
./bin/lemon
```

Evidence captured on 2026-05-11:

- `./bin/lemon-gateway --no-distribution` started the source Telegram runtime
  with the configured bot token secret and resolved `zeebot_lemon_bot` via
  `getMe`.
- `/cwd` from the allowed direct chat returned the expected chat-scoped working
  directory guidance.
- `use echo then telegram-live-proof-2026-05-11-1778541841` traversed live
  Telegram inbound, created a Lemon run, rendered a `working · lemon` tool
  status message, and finalized back into Telegram with the proof marker.
- A live long-running command initially exposed a launch bug: bare `/cancel`
  did not abort the active session unless it replied to a progress message.
- After the fix, `telegram-cancel-fixed-proof-2026-05-11-1778542127` started a
  `sleep 60` command, rendered progress, accepted bare `/cancel`, emitted
  `Cancelling current run...`, aborted `run_3a2a7a04-9d4e-4bea-8a10-36fb865b74ba`,
  and finalized with `Run failed: user_requested` instead of waiting for sleep
  completion.
- `telegram-approval-proof-2026-05-11-1778542579` injected a real
  `LemonCore.ExecApprovals.request/1` approval into the running source gateway,
  rendered a Telegram inline keyboard with `Approve once`, `Deny`, `Session`,
  `Agent`, and `Global`, accepted a live `Approve once` Telegram button click,
  edited the Telegram message to `Approval: approve once`, and left
  `LemonCore.ExecApprovalStore.list_pending/0` empty on the runtime node.
- `telegram-config-error-proof-2026-05-11-1778542850` used a session-scoped
  invalid model override and exposed a supportability bug: Telegram returned
  `Run failed:` followed by the raw `{:gateway_run_down, ...}` stack tuple.
- After fixing `LemonRouter.RunProcess.RetryHandler.format_run_error/1` and
  `LemonGateway.Renderers.Basic`, `telegram-config-error-fixed-proof-2026-05-11-1778543058`
  repeated the same invalid-model path and rendered
  `Run failed: unknown model "definitely-missing-model-..."` with no stack
  frames in the Telegram message.

Still missing for deeper Telegram proof:

- broader live media proof if Telegram is later marketed as a rich-media
  interface instead of a text-first remote chat interface

## Launch Checklist Impact

This proof pack closes G11 for the initial 1.0 interface scope.

Done enough for release candidate:

- TUI automated client lane passes.
- TUI source-runtime deterministic echo proof passes.
- TUI source-runtime tool-failure rendering proof passes.
- TUI source-runtime cancellation proof against a real cancellable run passes.
- Web operations supportability tests pass.
- Web source-runtime browser proof passes for the deterministic echo path.
- Telegram/router deterministic coverage passes for launch-relevant controls.
- Telegram source-runtime live proof passes for `/cwd`, progress rendering, a
  prompt round trip, bare `/cancel` on a real active run, and approval-button
  resolution.
- Telegram source-runtime live proof passes for a session-scoped invalid-model
  config error, with concise failure text and no stack-frame leak.
- Telegram markdown/media support boundaries are documented for 1.0 as
  text-first rendering plus bounded file/image delivery.
- Product smoke verifies packaged runtime and Web health.

Still outside the stable 1.0 support boundary:

- broader Web admin/config panels beyond defaults, providers, channels, cron,
  skills, approvals, run inspection, runtime health, and support bundles
- richer Telegram media generation, analysis, TTS, and GitHub-identical
  markdown rendering remain outside the stable 1.0 support boundary
