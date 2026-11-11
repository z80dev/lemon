# Lemon Bot in 3 minutes

Get to one useful answer from a Bot using a real tool. Three minutes is a guide,
not a download or provider-sign-in guarantee. Choose **A** for the native Mac
app, **B** for a browser on your computer or an SSH server, or **C** to add another
execution machine to an existing workspace. Lemon Bot's browser app is separate
from the coding dashboard opened by `lemon web`.

## Before you start

- **Mac:** macOS 14 or newer on Apple Silicon. The packaged Mac app needs no
  Xcode, Command Line Tools or separately installed Python.
- **Linux:** x86_64 or ARM64 with **glibc 2.39+** (not an Alpine/musl binary).
- **Terminal installation:** `curl`, `tar` and working `python3`; on macOS,
  `xcode-select --install` supplies Python. This is an installer prerequisite,
  not a prerequisite for opening the packaged Mac app. Linux workers also use
  Python 3.9+ for file and terminal tools; macOS runtime artifacts bundle it.
- A model-provider account, API key, or configured local model server. Existing
  credentials are offered first; copying another CLI's login or saving a shell
  key requires your choice. Credentials belong on the machine that runs the Bot.
- Bots act as your OS account. Bots on the same machine share its files, tools
  and logins; a Bot persona or working folder is **not a sandbox**.

## A. Mac app

**Distribution status:** the DMG build/sign/notarize pipeline exists, but without
Developer ID and notary credentials it produces only an **unsigned CI preview**,
not a notarized GitHub Release download. Use [path B](#b-terminal-and-browser)
for a published Terminal installation today, or the
[Apple source-build guide](https://github.com/z80dev/lemon/blob/main/products/lemon_bot/apple/README.md#generate-build-and-launch)
for development (Xcode 27.2 also works). Do not treat an unsigned preview as a
signed production release.

With a packaged app available:

1. Move **Lemon Bot.app** to `/Applications` or `~/Applications`, then open it.
2. Choose **Set up Lemon Bot on this Mac**. The app installs missing, pinned
   runtime/backend components, starts user services, signs in using this Mac's
   private local key, and connects this Mac as an execution machine. There is no
   owner form or invite-code copy/paste for this local path.
3. Choose **Create a Bot**. In its model step, connect a model on the selected
   Mac, or explicitly skip for now. A skipped model leaves a reminder: the Bot
   cannot reply until you connect one. See [Model readiness](#model-readiness).
4. Keep the prefilled **Lemon** name and the sole online machine, or change them.
   Keep **Standard** access for this first tool task and read the consent beside
   the create button. **Chat only** deliberately leaves local tools off.
5. Open the Bot's chat and follow [Your first tool task](#your-first-tool-task).

Setup does not request blanket macOS privacy permissions. A later protected-file
or desktop-control task may need permission on the execution Mac; use the app's
Permissions controls when that task needs it.

## B. Terminal and browser

### Same computer

Run in an interactive terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --profile bot
```

The **`bot`** preset installs a full runtime and the Bot backend at the same
manifest version, without the TUI by default. **`lemon_bot`** is a different,
backend-only profile, not the complete setup. On a terminal the installer hands
off to `lemon-bot`; if it only prints a next step, run that absolute path:

```bash
"$HOME/.local/bin/lemon-bot"
```

This is `lemon-bot` even if the current shell has not picked up the new PATH.
It checks the runtime, offers model setup (or **Skip — set it up in the browser**),
installs controller/backend/worker user services, creates the local owner and
enrolls this computer. It then opens your browser already signed in and exits;
you do not keep a backend terminal open when services are available.

The browser shows **Create your first Bot**. Choose **Create a Bot**, finish or
skip the selected machine's model step, keep **Standard** access, review the
shared-account consent and create it. The only online machine is preselected.
Then try [Your first tool task](#your-first-tool-task).

The local-owner notice explains that this workspace is unlocked by your OS
login. Adding an email/password in **Settings → Account** is optional for this
local flow; add one if you want password sign-in from another device. Never copy
the local-access key or controller operator token into a browser.

### Headless or SSH server

Run the same installer and `"$HOME/.local/bin/lemon-bot"` in your SSH terminal on
the server. SSH is detected: instead of launching a remote browser, the command
prints a private one-use sign-in link and a tunnel command. On your own computer,
open another terminal and run the **printed** command, for example:

```bash
ssh -N -L 4100:127.0.0.1:4100 me@server
```

Keep that SSH connection open while using the browser. Open the printed
`http://127.0.0.1:4100/#lemonbot-signin=…` link on your computer within **five
minutes**. Do not paste it into chat, logs or a shared terminal. Port 4100 must be
free locally; use the actual port printed for your installation. The backend
stays on loopback; no public login listener is needed. After redemption you see
**Signed in.** in the server terminal and the Bot app in the browser.

For a new link to an already-running backend, run **on the server**:

```bash
"$HOME/.local/bin/lemon-bot" open --headless
```

This requires a controlling terminal; it does not print the secret to redirected
stdout. Desktop browser handoffs expire after 60 seconds and use a private local
file instead of exposing the key or ticket in browser-launch arguments.

### What keeps running

- **macOS:** LaunchAgents start at **login, not boot**. A GUI login is required
  for managed setup; headless SSH alone is not a replacement for it.
- **Linux:** user systemd services survive logout and start at boot only with
  **linger** enabled. Setup offers it; otherwise it reports session-only
  persistence. If policy requires an administrator, use the printed command,
  such as `sudo loginctl enable-linger "$USER"`, on that Linux host.
- **No usable service manager:** setup reports manual mode, not persistence.
  Processes will not automatically return after reboot/logout; use
  `lemon service repair` after restarting, or provide your own supervisor.

Inspect or repair the installation with `lemon service status --json` and
`lemon service repair`. A service being installed is not proof a worker is
online: an expired/revoked credential needs reauthorization. See the
[CLI service reference](../user-guide/cli.md#user-services).

## C. Add a second machine

The destination needs the supported platform and Terminal-installer prerequisites
above, its own OS account and its own model setup. No controller credentials are
bulk-copied to it.

### Web: one join command

1. Choose **Connect a computer**, enter a friendly name, and leave purpose,
   labels and the 15-minute invite lifetime under **Advanced** unless needed.
2. The page checks the advertised endpoint before issuing an invite. For a
   second host it needs a reachable authenticated **`wss://` node gateway**;
   loopback **This computer** means the controller host, not your browser.
   Follow [Prepare the controller](../user-guide/attaching-a-bot-machine.md#prepare-the-controller)
   to expose the node-only port 4044 through TLS, not the operator port 4040.
   Also configure a reachable HTTPS `LEMON_BOT_PUBLIC_URL` for the product
   backend's MCP/attachments (normally proxied to 4100); the node endpoint alone
   is not sufficient.
3. Copy the exact generated command to a terminal on the destination. Enter its
   separate one-use code at the hidden prompt. The version-pinned script installs
   a compatible worker and a user service, then exits when online. It reports
   whether persistence is login, boot, session-only or none. For an intentionally
   foreground worker, append `--foreground` to the generated script invocation
   and keep that terminal open.
4. When the page shows **Online — Create a Bot here**, choose it. Connect a model
   on that destination (or run `lemon setup model` there), then create the Bot
   and try the first tool task. A socket being online alone does not mean a model
   is configured.

Never replace the generated URL or invent a version pin. If enrollment may have
succeeded but no result returned, do not reuse the code: use **Reconnect** to
obtain a bound repair invitation.

### Mac: Add a machine over SSH

In **Machines → Add a machine**, enter `me@studio` in **SSH address** and choose **Add a
machine**. Passwordless SSH must already work **from the controller host**, which
may not be the Mac displaying the app. The backend must have a local controller,
a working node gateway and runtime launcher. Changed SSH host keys require manual
identity verification; new hosts use SSH trust-on-first-use.

The checklist shows **Connect over SSH → Open a secure link → Get an invite →
Install Lemon → Check it works**. For a loopback-only advertised controller,
the backend maintains a reverse SSH tunnel independently of the Mac UI, forwarding
the node gateway and, if needed, product backend to destination loopback ports.
With a routable advertised endpoint, it uses that direct route instead. It
installs/enrolls the worker without forwarding the main operator listener.
When online, choose **Create a Bot here**
and connect the destination's model. The controller host must remain awake and
its tunnel service running. See [SSH setup and recovery](../user-guide/attaching-a-bot-machine.md#add-a-machine-over-ssh).

## Model readiness

**Verified** means a non-generating check passed; no chat message was sent.
**Saved** means a credential resolves but a quick check was unavailable,
unreachable or inconclusive: the first real message is still the proof.
Missing, expired or rejected credentials require action. Imports and shell-key
saves need explicit consent; Lemon keeps its own copy of a Codex CLI login and
does not modify `~/.codex/auth.json`.

Use **Connect a model** on the selected machine, **Settings → Providers**, or
`lemon setup model` on that host. For a non-interactive report use
`lemon setup model --json`; add `--offline` to avoid provider requests.
See [Set up Lemon](../user-guide/setup.md#provider-auth-and-model) for providers
and headless configuration.

## Your first tool task

Choose the hostname/OS/free-space starter task, or send:

```text
What's this computer's hostname and OS version? Use a terminal command, without reading personal files.
```

**Standard** requests Terminal and Files read/write, and Browser read-only where
supported. Machine limits and workspace policy still apply. It does not grant
blanket permission to run commands without review.

Read the concrete command in the approval card, then choose **Allow once**.
Where policy permits, **Allow Terminal for this chat** remembers Terminal approval
for that conversation; it is not permission for every Bot or future chat. Resolved
cards show the decision instead of leaving active Allow/Deny buttons. A reply
containing the command's output is the success check—not just an online badge.

For offline or reauthorization states, use **Machines → Reconnect**; the Mac
app's host-repair controls can recover its own host. For update and removal,
follow [Update, roll back, and uninstall](../user-guide/updates.md).

## Optional: another browser or iPhone

For access without an SSH forward, configure a reachable HTTPS product origin
(`LEMON_BOT_PUBLIC_URL`), typically Tailscale Serve to the Bot backend's port
4100. This is separate from exposing the node gateway for execution machines.
Use the owner's email/password or configured SSO to sign in from another browser;
network/tailnet access alone is not sign-in authority.

If an operator is deliberately bootstrapping an unconfigured remote workspace
instead of using local sign-in, `lemon-bot setup` verifies its configured tailnet
HTTPS origin and privately prints a five-minute owner setup proof. Use that proof
in the owner form. It does not start services or connect a model, and cannot
re-bootstrap an existing owner. `lemon-bot setup --print-origin` is read-only.

For an iPhone, first verify **Connect iPhone → Check connection readiness** on
the signed-in desktop. Create a fresh QR/link, scan or paste it in the phone app,
review the destination and request connection. Compare the phone's device name
and six-digit code with the desktop before approving that exact request. Wait
for the phone to finish connecting, not merely for desktop approval. The phone
gets its own revocable product session; it is not another execution machine.
Revoke it in **Settings → Account → Devices/Sessions**. The desktop backend and
host must remain available even when the desktop UI is closed.

For terminal-assisted pairing and its HTTPS prerequisites, see
[`lemon connect iphone`](../user-guide/cli.md#connect-an-iphone-to-lemon-bot).
