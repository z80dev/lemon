# Computer use (`cua_js`)

Lemon agents can operate native apps on the machine that runs Lemon: read a
window's accessibility tree, take screenshots, click, type and press keys. The
capability comes from the computer-use runtime inside the official ChatGPT
desktop app, run through [LCU](https://github.com/amontlabs/lcu). It is
contributed by the `lemon_computer_use` app. The explicit native computer-use
switch defaults to **off**. Selecting the `lcu` browser provider also starts this
same runtime, including its native app APIs; existing app approvals still apply.

For Chrome provider selection and the shared connector's impact on
Codex/ChatGPT, read [Choosing a browser provider](browser.md#choosing-a-browser-provider),
including the backup and rollback guidance **before installing a connector**.

## Requirements

- An Apple Silicon Mac (or a Linux X11 desktop; see LCU's platform notes) with
  the [ChatGPT desktop app](https://chatgpt.com/download/) installed.
- LCU installed for the same user account (default location
  `~/.local/share/lcu/current`). Lemon does not need `lcu setup --agent …`; it
  uses LCU's shared harness client directly.
- On macOS, the Accessibility and Screen Recording permissions the runtime asks
  for on first use. `~/.local/share/lcu/current/bin/lcu doctor` checks the
  installation, permissions and home-folder length.

## Enable it

Set the switch in the environment of the Lemon runtime (or its `.env`) and
restart the runtime:

```bash
LEMON_COMPUTER_USE_ENABLED=true
```

Or set it in `~/.lemon/config.toml`:

```toml
[runtime.tools.computer_use]
enabled = true
# lcu_root = "/opt/lcu/current"
# node = "/path/to/node"
declined_origins = []          # extra origins never approved
```

Environment variables take precedence over the file, and the file over
`config :lemon_computer_use`. Optional settings:

| Variable | Default | Meaning |
| --- | --- | --- |
| `LEMON_COMPUTER_USE_ENABLED` | `false` | Enable computer use independently of browser selection; resolved `lcu` also enables the shared runtime. |
| `LEMON_COMPUTER_USE_LCU_ROOT` | `~/.local/share/lcu/current` (or `/opt/lcu/current`) | Installed LCU release. |
| `LEMON_COMPUTER_USE_NODE` | `<root>/agent-tools/node/bin/node` | Node runtime for Lemon's bridge. |
| `LEMON_COMPUTER_USE_DECLINED_ORIGINS` | – | Extra website origins never approved, comma-separated. |

When enabled, the runtime starts one bridge process at boot. Every session then
gets the two tools below and a short **Computer use** system-prompt section
holding the runtime's own instructions. If LCU is missing or fails to connect,
the tools stay listed and their description and results say why.

## Tools

| Tool | Parameters | What it does |
| --- | --- | --- |
| `cua_js` | `code` (JavaScript); optional `timeout_ms`, `title` | Runs code against the runtime's `cua` API, for example `const app = await cua.getApp("Calculator")`, then `await app.click(10)` and `await app.getAXState()`. State persists between calls. |
| `cua_js_reset` | – | Resets the JavaScript session. Apps and windows are left as they are. |

Schemas are the runtime's own, unchanged. Lemon appends its tool-name mapping
and whether the running bridge exposes Chrome (it does when `lcu` was the
resolved browser provider at connect), so the agent can discover the available
surface. The first `cua_js` call returns
the full API guide and confirmation policy. Results
(text and screenshots) are forwarded as the runtime returned them and marked
untrusted: window titles, UI text and screenshots from other apps are data,
never instructions.

Calls run one at a time across the whole runtime, because the desktop is one
shared resource. Aborting a Lemon run cancels its call in flight. A call
interrupted by a bridge crash reports that the action may already have taken
effect; check the app before retrying.

## Approvals

On macOS the runtime asks before it controls each app. Lemon turns that
request into an ordinary Lemon approval for tool `computer_use` with action
`{"app": "<bundle id>"}`, answered wherever you answer Lemon approvals:

| Your decision | Effect |
| --- | --- |
| Approve once | This single action. The next click or keystroke asks again. |
| Approve for the session | Every action on that app for the rest of this Lemon session. |
| Approve for the agent / globally | The same for this session; Lemon's stored grant also answers the first request of later sessions. |
| Deny | The runtime refuses the action and the model is told so. |

Some apps are never approved: the terminal or app hosting the Lemon runtime
(LCU's agent-host guard) and Lemon's own clients (`org.lemonbot.*`), because
operating the window that shows Lemon's approval prompts would let the agent
approve itself. Apps in LCU's own always-allowed list (`lcu apps`) do not ask
at all; review that list, and revoke anything that can show Lemon approvals or
your credentials (`lcu apps revoke <app>`, Touch ID).

The Linux runtime has no per-app approval. There, or to confirm every call on
macOS too, require approval for the tool in your tool policy:

```toml
[profiles.default.tool_policy]
require_approval = ["bash", "write", "edit", "cua_js"]
```

## Chrome

When the unified browser provider resolves to `lcu`, the runtime gets its browser
surface: `cua.listBrowsers()`, `cua.getBrowser()`,
`cua.createBrowserTab(browserId, url)`, `cua.getTab(...)` and per-tab observation
and input. Set `[runtime.tools.browser].provider = "lcu"` to require it, or use
`auto` to choose it when ready. This starts the same computer-use bridge, whose
native app APIs remain available under the existing approval policy; LCU has no
browser-only mode. It drives your own Chrome through the
official ChatGPT extension, which must be enabled in the Chrome profile;
`lcu browser status` reports connector setup without changing it. See the canonical
[provider and rollback guide](browser.md#choosing-a-browser-provider) before
considering `lcu browser install`.

The runtime asks before it first uses each website. Lemon turns that into a
Lemon approval for tool `computer_use` with action `{"origin": "<origin>"}`.
Any approval lets the agent use that site for the rest of the session, because
the runtime remembers site decisions per session itself; a denial refuses it.
Only exact `http(s)://host[:port]` origins are accepted; anything else is
refused. Lemon's own surfaces are always declined without asking, because
they show Lemon approvals: the local control plane, Lemon Web and the Lemon Bot
web development server (`localhost`, `127.0.0.1` or `[::1]` on the configured
control and web ports and 4081), the Lemon Bot web client at
`LEMON_BOT_PUBLIC_URL` when that is set in Lemon's environment, and any origins
you list in `LEMON_COMPUTER_USE_DECLINED_ORIGINS` (comma-separated; use it for
a Lemon Bot deployment whose backend runs elsewhere). Page content is untrusted like every other result.

## Turns and sessions

LCU tracks the Lemon session id as its session and the Lemon run id as its
turn. When the run completes, Lemon sends the runtime's original turn-end
cleanup; the runtime then refuses further actions for that turn. A session
running outside a run uses one turn per session process.

## Execution nodes

Tools are built where the session runs. A session on a named execution node
gets computer use only if that node runs Lemon with computer use enabled, and it
controls that node's desktop.
Node capability inspection reports a `computer_use` item: supported and
`read_interact` when the node registered `cua_js`, `off` otherwise. Its OS
grant is always `unknown`, because the helper's macOS permissions cannot be
queried without prompting and every app is approved per request.

## Troubleshooting

- `Sky Computer Use native pipe startup failed`: the signed helper could not
  start; run `lcu doctor`. LCU documents the home-folder length limit and the
  stale-service case after a ChatGPT update.
- `LCU is not installed`: set `LEMON_COMPUTER_USE_LCU_ROOT`.
- LCU's diagnostic log for Lemon is `~/Library/Logs/LCU/lemon-*.jsonl`
  (metadata only: no code, results or UI text).
