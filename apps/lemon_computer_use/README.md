# lemon_computer_use

Native app control for Lemon agents through [LCU](https://github.com/amontlabs/lcu),
which runs the computer-use runtime shipped in the ChatGPT desktop app as a
stdio MCP server. Opt-in (`LEMON_COMPUTER_USE_ENABLED=true`).

- `LemonComputerUse.Server` — supervises the Node bridge (`priv/lcu_bridge.mjs`,
  built on LCU's shared harness client), serializes calls, routes approvals and
  ends LCU turns when Lemon runs complete. `LemonCore.Rpc.Client` owns JSON-line
  framing, in-flight requests and caller monitoring. Its handshake deadline
  closes stalled connections; tool calls and owner-bound approvals remain
  unbounded by a host request timer. Cancellation is message-driven and holds
  the desktop until the bridge acknowledges the cancelled operation. Bridge
  loss fails active and queued work without replaying possibly applied actions.
- `LemonComputerUse.Tools.Js` / `Tools.JsReset` — the `cua_js` and
  `cua_js_reset` agent tools, registered through `LemonAgent.ToolRegistry`.
- `LemonComputerUse.ContextContributor` — the runtime's instructions as a
  system-prompt section, registered through `LemonAgent.ContextRegistry`.
- `LemonComputerUse.Approval` — native-app and website-origin approval requests as
  `LemonCore.ExecApprovals` requests. Lemon's own native apps and loopback origins
  on the configured control-plane/web ports are declined without asking; tests
  derive these origins from runtime configuration rather than assuming defaults.
- `LemonComputerUse.Config` / `Env` — settings.

The supervised server owns its catalog and session-turn nonce in ETS. The
nonce is published before the server accepts calls, so concurrent first tool
calls share a session-turn identity. A bridge disconnect clears the catalog;
owner death removes the whole table. A restarted owner publishes a fresh nonce
and reconnects for a new catalog. Readers never create tables, and missing
ownership reports unavailable rather than inventing a session turn.

See the [tool reference](../../docs/tools/computer-use.md).
