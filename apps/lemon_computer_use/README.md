# lemon_computer_use

Native app control for Lemon agents through [LCU](https://github.com/amontlabs/lcu),
which runs the computer-use runtime shipped in the ChatGPT desktop app as a
stdio MCP server. Opt-in (`LEMON_COMPUTER_USE_ENABLED=true`).

- `LemonComputerUse.Server` — supervises the Node bridge (`priv/lcu_bridge.mjs`,
  built on LCU's shared harness client), serializes calls, routes approvals and
  ends LCU turns when Lemon runs complete.
- `LemonComputerUse.Tools.Js` / `Tools.JsReset` — the `cua_js` and
  `cua_js_reset` agent tools, registered through `LemonAgent.ToolRegistry`.
- `LemonComputerUse.ContextContributor` — the runtime's instructions as a
  system-prompt section, registered through `LemonAgent.ContextRegistry`.
- `LemonComputerUse.Approval` — native-app and website-origin approval requests as
  `LemonCore.ExecApprovals` requests. Lemon's own native apps and loopback origins
  on the configured control-plane/web ports are declined without asking; tests
  derive these origins from runtime configuration rather than assuming defaults.
- `LemonComputerUse.Config` / `Env` — settings.

See the [tool reference](../../docs/tools/computer-use.md).
