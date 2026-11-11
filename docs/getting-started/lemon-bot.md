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

**Build from source today:** no signed DMG is published yet. Follow the
[Apple source-build guide](https://github.com/z80dev/lemon/blob/main/products/lemon_bot/apple/README.md#generate-build-and-launch)
to build and launch the app. For a published Terminal installation instead, use
[path B](#b-terminal-and-browser).

1. Install the runtime/backend using [path B](#b-terminal-and-browser) if they
   are not already installed, then open your source-built **Lemon Bot** app.
2. In **This Mac**, choose **Connect**. It starts Lemon Bot if needed and signs
   you in with this Mac's private local key: no owner form or setup-code
   copy/paste. A packaged app with pinned installation assets can instead show
   **Set up Lemon Bot on this Mac** when components are missing; this is not a
   signed download available today.
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

Ad-hoc-signed development builds can ask for Keychain access again after each
rebuild. Signed releases won't have this rebuild-specific prompt.

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

Follow the terminal prompts:

1. At **Which Lemon should Lemon Bot use?**, choose **This machine**.
2. In **Connect a model**, use the detected Codex CLI login if offered (confirm
   copying it into Lemon), choose a provider, or choose
   **Skip — set it up in the browser**.
3. Pick a model. Lemon performs a live, non-generating readiness check; it does
   not send a chat message.
4. Setup installs controller/backend/worker user services, creates the owner
   without a form, and enrolls this computer as a supervised worker. On macOS,
   persistence is **login**, not boot.

The browser opens already signed in. On a Mac the notice is **Unlocked by your
Mac login**. At **Create your first Bot**, choose **Create a Bot** and enter a
name; the only online machine is preselected. Keep **Standard** access
(Terminal + Files; asks before commands), or choose **Chat only** to leave tools
off. If you skipped model setup, connect it here before expecting a reply.
Then try [Your first tool task](#your-first-tool-task).

You do not keep the setup terminal open. If interrupted, resume with
`lemon-bot up`; to reopen an existing workspace signed in, use `lemon-bot open`.
Adding an email/password in **Settings → Account** is optional for this local
flow. Never copy the local-access key or controller operator token into a browser.

All default listeners bind `127.0.0.1`: controller **4040**, node-only gateway
**4044**, coding web dashboard **4080**, and Lemon Bot **4100**.

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

Read the concrete command in the approval card, then choose **Allow once**,
**Allow Terminal for this chat**, or **Deny**. The chat allowance remembers
Terminal approval for this conversation, not every Bot or future chat. Use
**Stop allowing** on its chip to revoke it. Resolved cards show the decision
instead of active buttons. A reply containing the command's output is the
success check—not just an online badge.

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
