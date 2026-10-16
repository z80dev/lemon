# LemonComputerUse contributor guide

`lemon_computer_use` lets Lemon agents operate native apps through LCU. LCU and
the original runtime own computer-use behavior; this app is transport,
approval routing and lifecycle. See [README](README.md) and the
[tool reference](../../docs/tools/computer-use.md).

## Boundaries

- Dependencies are `lemon_core`, `lemon_agent`, `lemon_ai`. Tools and the
  prompt section register through the platform registries; `coding_agent` must
  not name this app.
- Use LCU's shared client (`<lcu-root>/adapters/client.mjs`) from the bridge.
  Do not reimplement the MCP session, approval deadlines or the agent-host
  guard, and do not expose host-only tools (`turn_ended`,
  `js_add_node_module_dir`) to the model.
- Opt-in only. Disabled, start no process and register nothing.

## Invariants

- One bridge, one in-flight operation: an approval request belongs to the call
  in flight and must name its session/turn when the runtime supplies them.
- Real identities: session = Lemon session id, turn = run id. Never reuse an
  ended turn id; end turns on `:run_completed` or session exit.
- Approvals go through `ExecApprovals` and fail closed: errors, unknown scopes,
  malformed requests cancel. Only native-app and exact http(s) website-origin
  requests are answered. Lemon's own apps and local Lemon origins are declined.
  Never write LCU's always-allowed store.
- Approvals ask with `expires_in_ms: :infinity`; the owner ending is their expiry.
  `ExecApprovals` expires a pending approval when its run or session ends (no
  grace window), so add neither a clock deadline nor a separate owner-end cleanup.
- The bridge gets a minimal environment (no provider credentials or `LEMON_*`)
  and the account's real home. Results are forwarded unchanged and untrusted.
- A bridge crash fails in-flight calls as possibly applied; never retry them.

## Verification

From the umbrella root: `scripts/test path apps/lemon_computer_use/test`
(fake bridge in `test/support`, needs `node`). The live Calculator smoke needs
LCU and the ChatGPT app: add `--include computer_use_live`. The Chrome smoke
(`--include computer_use_chrome_live`) also needs the ChatGPT extension
connected; it opens and closes one tab on a local page.
