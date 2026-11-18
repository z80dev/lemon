# Computer use (`cua_js`)

Lemon agents can operate native apps on the machine that runs Lemon: read a
window's accessibility tree, take screenshots, click, type and press keys. The
capability comes from the computer-use runtime inside the official ChatGPT
desktop app, run through [LCU](https://github.com/amontlabs/lcu). It is
contributed by the `lemon_computer_use` app. It is **off** unless you set the
explicit switch (`LEMON_COMPUTER_USE_ENABLED` or
`[runtime.tools.computer_use] enabled = true`). That switch is the only thing
that grants native app control: the browser provider is a separate, independent
setting, and selecting or auto-resolving `lcu` never enables computer use. The
switch is read once at boot; restart Lemon after changing it.

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
  These computer-use permissions belong to the ChatGPT helper, not Lemon Bot Worker.

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
declined_origins = []          # extra origins never approved (list remote/foreground Lemon Bot URLs here)
lasting_grant_apps = []        # apps whose approvals may outlast one action (default: none)
```

Environment variables take precedence over the file, and the file over
`config :lemon_computer_use`. Optional settings:

| Variable | Default | Meaning |
| --- | --- | --- |
| `LEMON_COMPUTER_USE_ENABLED` | `false` | The only switch that enables computer use (native app control, and the Chrome surface when the browser provider resolves to `lcu`). Read once at boot. |
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
`{"app": "<bundle id>"}`, answered wherever you answer Lemon approvals.

Every app is **once-only by default**: whatever you choose, an approval
covers one action, the next click or keystroke asks again, and Lemon stores no
session, agent or global grant for it (the request is made `once_only`, so even
an existing wildcard grant for `computer_use` does not answer it). Any app can
show Lemon approvals — a browser with the Lemon Bot web client, a chat app, a
terminal — so lasting grants are your explicit choice: list the bundle ids in
`[runtime.tools.computer_use] lasting_grant_apps` (case-insensitive, empty by
default). For those apps only:

| Your decision | Effect |
| --- | --- |
| Approve once | This single action. The next click or keystroke asks again. |
| Approve for the session | Every action on that app for the rest of this Lemon session. |
| Approve for the agent / globally | The same for this session; Lemon's stored grant also answers the first request of later sessions. |
| Deny | The runtime refuses the action and the model is told so. |

A computer-use approval has no time limit, but it does not outlive its owner:
when the run or session that asked ends, Lemon expires the pending approval at
once (no grace window) and treats it as denied. The Telegram, Discord and TUI
prompts are edited to say it expired because the run ended, and answering it
later is refused as expired rather than granting control of an app.

Some apps are never approved: the terminal or app hosting the Lemon runtime
(LCU's agent-host guard) and Lemon's own clients (`org.lemonbot.*`), because
operating the window that shows Lemon's approval prompts would let the agent
approve itself. Never list an app that can show Lemon approvals in
`lasting_grant_apps`. Apps in
LCU's own always-allowed list (`lcu apps`) do not ask
at all; review that list, and revoke anything that can show Lemon approvals or
your credentials (`lcu apps revoke <app>`, Touch ID).

The Linux runtime has no per-app approval. There, or to confirm every call on
macOS too, require approval for the tool in your tool policy:

```toml
[profiles.default.tool_policy]
require_approval = ["bash", "write", "edit", "cua_js"]
```

## Chrome

When computer use is enabled and the unified browser provider resolves to `lcu`,
the runtime also gets its browser
surface: `cua.listBrowsers()`, `cua.getBrowser()`,
`cua.createBrowserTab(browserId, url)`, `cua.getTab(...)` and per-tab observation
and input. The two switches are independent: `[runtime.tools.browser].provider`
only chooses whether that bridge also exposes Chrome; it never starts the bridge
or grants native app control. Without the computer-use switch there is no LCU
Chrome surface. LCU has no browser-only mode, so enabling computer use for
Chrome also exposes native app APIs under the existing approval policy. It drives your own Chrome through the
official ChatGPT extension, which must be enabled in the Chrome profile;
`lcu browser status` reports connector setup without changing it. See the canonical
[provider and rollback guide](browser.md#choosing-a-browser-provider) before
considering `lcu browser install`.

The runtime asks before it first uses each website. Lemon turns that into a
Lemon approval for tool `computer_use` with action `{"origin": "<origin>"}`.
Website approvals are once-only in Lemon: no stored or wildcard grant answers
them and no decision stores one, so every new LCU session asks again. LCU
cannot scope a site approval to a single action, though: **an approved site
stays usable for the rest of that LCU session**, because the runtime remembers
site decisions per session itself; a denial refuses it.
The web clients of the channels Lemon delivers approvals to are always
declined: Telegram (`telegram.org` and subdomains such as `web.telegram.org`,
`t.me`), Discord (`discord.com`, `ptb.`/`canary.discord.com`,
`discordapp.com`), Slack (`slack.com` and workspaces), WhatsApp
(`whatsapp.com`), XMTP clients (`xmtp.chat`, `converse.xyz`) and common
webmail for the email channel (`mail.google.com`, Outlook, Yahoo, Fastmail,
Proton). Add any other client that shows Lemon approvals (a generic or
self-hosted channel UI) to `declined_origins`.
Only exact `http(s)://host[:port]` origins are accepted; anything else is
refused. Local and Lemon-owned origins are always declined without asking,
because they can show Lemon approvals: every local origin on any port
(`localhost`, `*.localhost`, any `127.0.0.0/8`, `[::1]`, link-local,
IPv4-mapped and unspecified addresses in any spelling, and any address of this
machine's network interfaces — Lemon's control plane, Lemon Web, Lemon Bot on
4100 or its `LEMON_BOT_PORT`, and SSH tunnels to a remote Lemon Bot all live
there). A hostname is resolved first and declined when any address it resolves
to is local, or when resolution does not answer within two seconds. DNS can
change after this check (DNS rebinding), so it narrows that risk rather than
closing it. Also declined: `LEMON_BOT_PUBLIC_URL` from Lemon's own environment
and from any installed Lemon Bot backend service unit, and every origin in
`[runtime.tools.computer_use] declined_origins` or
`LEMON_COMPUTER_USE_DECLINED_ORIGINS` (comma-separated). Lemon does not learn a
Lemon Bot's public URL from a foreground (`lemon-bot` run by hand) or remote
deployment: **list that URL in `declined_origins`**. Use Lemon's own browser
provider, not LCU, for local development sites. Page content is untrusted like
every other result.

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
