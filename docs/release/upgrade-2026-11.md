# Upgrade from 2026.11.1 or earlier

These notes cover the November lifecycle and security changes after 2026.11.1.
Read them before upgrading an existing LAN, remote-worker or manually supervised
installation. For the actual preview-confirm update and rollback commands, use
[Update Lemon](../user-guide/updates.md); keep a [backup](../user-guide/backups.md)
of user state before changing versions.

## Breaking: listeners are local by default

The controller (`4040`), node gateway (`4044`), LemonWeb (`4080`) and Lemon Bot
(`4100`) default to `127.0.0.1`. The optional simulation UI (`4090`) and launcher
Erlang distribution/epmd defaults are also loopback. Existing clients connecting
directly over a LAN or another host may stop reaching Lemon after restart.
Same-machine browser and CLI use does not need a wider bind.

Choose the smallest exposure you need:

- **Remote execution machine:** keep the controller private. Use Tailscale Serve,
  a TLS reverse proxy or the managed reverse SSH route to the **node-only gateway
  on 4044**, never 4040. Follow [Add a Bot machine](../user-guide/attaching-a-bot-machine.md).
- **Browser over SSH:** keep the Bot backend on loopback and use
  `lemon-bot open --headless`; follow the printed tunnel instructions and private
  one-use, five-minute link. See [headless setup](../getting-started/lemon-bot.md#headless-or-ssh-server).
- **Deliberate LAN/operator deployment:** configure only the necessary literal
  bind addresses and restart the affected service. The
  [listener configuration reference](../config.md#listener-exposure-breaking-default-change)
  lists `LEMON_CONTROL_PLANE_BIND_IP`, `LEMON_WEB_BIND_IP`,
  `LEMON_CONTROL_PLANE_NODE_BIND_IP` and the separate Bot backend settings.
  Main and web non-loopback binds require an operator token; protect browser
  login with TLS. Binding a socket does not configure encryption or a firewall.

Non-loopback main-controller traffic is limited to `/ws` and `/healthz` by
default. Remote OpenAI-compatible/ACP HTTP access needs explicit
`LEMON_CONTROL_PLANE_REMOTE_HTTP` opt-in and dedicated API tokens. OpenAI/ACP
also require bearer authentication locally (falling back to the operator token);
A2A requires peer authentication. Do not restore tokenless access to make a proxy
work. See the [security model](../security/threat-model.md#listener-exposure).

A pre-upgrade epmd process can retain its old wildcard bind until stopped; the
configuration reference explains inspection and remediation. Workers also check
that credential-bearing loopback connections, including SSH-tunneled MCP, reach
a listener owned by the same OS user. Run the worker and tunnel under the same
account; deliberate cross-user exceptions are described in the
[same-user guard](../security/threat-model.md#same-user-loopback-ownership).

## Breaking: stop workers before the controller

Managed updates and rollbacks now stop previously running local workers **before**
restarting the controller. They wait for controller readiness, restart those
workers, then restart the previously running Lemon Bot backend. Stopped units
stay stopped. An installer-managed Bot backend updates in lockstep with the
runtime; remote workers are never silently updated.

Custom supervisors must follow the same ordering. Do not restart only the
controller while old worker sessions remain connected. Update each remote host
explicitly, keep service commands pointed at stable launchers rather than a
version directory, and inspect the result:

```bash
lemon service status --json
lemon node status --name YOUR_NODE --json
```

The [update guide](../user-guide/updates.md#service-update-order-breaking-change)
owns the transaction, failure and rollback details. In particular, a service
restart failure does not necessarily undo an already committed version selection.

## Worker state: one-time isolation migration

Named workers no longer share the controller's DETS files. Each worker uses a
private `~/.lemon/nodes/state/<name-hash>/` directory, with cross-VM ownership
checks to prevent concurrent writers. Stop old workers before the first start
with the new layout; do not point multiple runtimes at a shared state directory.

On the controller's first default-layout boot, Lemon backs up the legacy
`tasks.dets`, `parent_questions.dets`, `run_graph.dets` and `processes.dets` files
that exist into `backups/dets-layout-v1-<timestamp>/` under the agent state
directory, rebuilds them, and writes `.dets-layout-v1` only after success.
An incomplete repair is reported and retried on a later boot. Do not delete the
backup or marker as a routine upgrade step, and do not copy controller DETS files
into worker directories. This is a state-layout repair, not a user-data wipe.

## Node sessions now renew while connected

Execution-node session credentials use a sliding seven-day lifetime: contact
renews the current session; seven days without contact can expire it. Expired,
revoked or superseded credentials cannot be revived by a heartbeat. A worker with
missing or rejected credentials parks for enrollment/reauthorization instead of
crash-looping; a controller outage retries reconnecting.

Use the local `lemon node status` command above to distinguish these states.
Repair or re-enroll through the machine connection flow when credentials are
rejected; repeated controller restarts are not a credential repair.

## Lemon Bot now installs services

`lemon-bot` / `lemon-bot up` is a resumable bootstrap, not just a foreground web
server: for **This machine**, it configures the runtime, installs controller and
backend services, creates the local owner without a password form, enrolls a
supervised worker and opens a signed-in browser. Rerunning resumes setup.

Use the [canonical Lemon Bot guide](../getting-started/lemon-bot.md) rather than
adding another hand-written background process. Service persistence is reported,
not assumed: macOS launchd services persist at login; Linux user services depend
on the session/linger configuration. See [service setup](../user-guide/setup.md).

## Source builds require the new toolchain

Upgrade to **Elixir 1.20.5 and Erlang/OTP 29.1.2** before building this source
checkout (previously Elixir 1.19.5 / OTP 28.5). Packaged runtime users do not need
to install those development toolchains. Follow the source-update dependency
steps in the [update guide](../user-guide/updates.md#source-checkouts-and-other-layouts).

## Mac app requirements and permissions

The Mac app targets **macOS 14 or later**. Its release-pinned setup is designed
to install the matching runtime/backend without developer tools; source app
builds require the Apple build tools described in the
[Apple client README](../../products/lemon_bot/apple/README.md).

No signed DMG is published yet. Release DMG publication is gated on signing and
notarization credentials; an unsigned preview artifact is not a signed release.
Development/ad-hoc builds can re-prompt for Keychain access after every rebuild;
signed releases retain a stable identity.

Use **This Mac** to connect locally or **Add a machine** for SSH setup. Review
local machine permissions after upgrading: the embedded **Lemon Bot Worker**
helper supplies the TCC identity instead of a version-specific runtime process.
Its grants apply to Bots and subprocesses, not to one chat, and it is not a
sandbox. See [macOS permissions](../security/agent-safety-contract.md#macos-permissions).
