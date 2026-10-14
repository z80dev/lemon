# Attaching a bot machine

A bot machine is a named Lemon execution node on a host you control. It joins an
existing controller; it is not a new controller, virtual machine, or desktop
sandbox. You keep normal SSH, terminal, and filesystem access. Bots assigned to
the same machine share its OS account, files, and browser logins.

## Prepare the controller

Keep the controller operator token on the controller or trusted application
backend. Do **not** send it to a machine owner or put it in an attachment command.
The backend authenticates to the control plane's `/ws` as an operator and needs
`operator.pairing` to issue invitations.

Set the controller's advertised endpoint before issuing invites:

```bash
export LEMON_CONTROL_PLANE_PUBLIC_WS_URL='wss://controller.example/ws'
```

This setting generates join commands; it does not configure TLS or expose a
listener. Arrange TLS termination and routing to the existing control plane
separately. An Elixir deployment can instead set
`:lemon_control_plane, :public_ws_url`. Without either setting, the command uses
`ws://127.0.0.1:<control-plane-port>/ws`, suitable only for a machine on the same
host. Off-loopback invite commands require `wss://`; URLs must not contain user
credentials, query credentials, or fragments.

### Select a compatible destination runtime

Configure runtime selection **on the controller before issuing an invitation**.
The generated command never trusts an arbitrary `lemon` on the destination's
`PATH` and never defaults to the latest published release.

- **Same-host source development:** for a loopback controller URL (`localhost`,
  `127.0.0.1`, or `::1`), the default is the controller's actual source checkout,
  derived from its compile-time source directory when `bin/lemon` and `mix.exs`
  are present there. This uses that checkout's `bin/lemon`, not an older installed
  release. Start the controller from the integrated checkout that implements the
  required bot runtime features.
- **Remote or explicitly selected source:** provision a compatible checkout on
  the destination yourself, then set `LEMON_NODE_SOURCE_CHECKOUT` to its absolute
  **destination-local** path. The Elixir setting is
  `:lemon_control_plane, :node_source_checkout`. The path need not exist on the
  controller, but `mix.exs` and executable `bin/lemon` must exist at that path on
  the destination. This explicit source setting takes priority over all other
  selection. The command does not clone a branch, build a VM, or provision that
  checkout.
- **Published or private packaged build:** select an exact operator-supported
  version **and** an HTTPS release repository base URL. Set
  `LEMON_NODE_INSTALL_VERSION` and `LEMON_NODE_INSTALL_BASE_URL`, or the Elixir
  settings `:node_install_version` and `:node_install_base_url` under
  `:lemon_control_plane`. The base URL is the repository prefix used by
  `install.sh`, which fetches
  `<base>/releases/download/v<version>/manifest.json` and its artifacts. These
  settings are passed to the installer as `LEMON_VERSION` and
  `LEMON_INSTALL_BASE_URL`; those original environment names are also accepted
  on the controller as fallbacks. App settings take precedence over environment
  settings, and the `LEMON_NODE_*` aliases take precedence over the originals.
  Do not put credentials in the base URL.

For example, to use an already-provisioned remote checkout:

```bash
export LEMON_NODE_SOURCE_CHECKOUT='/srv/lemon'
```

There is no assumed supported published version: a version string, including a
version equal to the controller's, does not prove that a build supports the bot
APIs. When a version pin is configured, the selected binary's actual `lemon
version` must match it, **and** its feature gate must pass. Remote invitations
without a destination source checkout or both packaged-build settings return
`INVALID_REQUEST`:
`Configure a destination source checkout or an explicit node install version and HTTPS base URL`.
An invalid source path setting returns
`Configure an absolute destination node source checkout`; an invalid version
setting returns `Configure an exact node install version`.

Compatibility is an API contract, not merely a matching version:

| Component | Required contract |
| --- | --- |
| Controller | `node.pair.invite`, `node.pair.invite.revoke`, and exact `nodes.list` enrollment/repair reconciliation with durable node IDs and `enrollmentInviteId`. |
| Destination CLI | `node capabilities --json --require-bot` must exit zero only for a complete bot runtime; `node join --invite-code` must use restricted enrollment and persist destination-local credentials. |
| Pinned destination build | `version` must report the configured exact pin; it must still pass the capability gate. |
| Repair flow | Controller-bound repair invitation and generation-checked challenge exchange retain the durable node ID; the destination runs the returned code-only command unchanged. |

Use [node files and secrets](node-files-and-secrets.md) for the destination
capability and credential-proof contracts. Capability readiness does not claim
that model-provider credentials are configured.

## Issue an invitation

On the already-authenticated operator WebSocket, request:

```json
{"type":"req","id":"invite-1","method":"node.pair.invite","params":{"nodeName":"studio-mac","purpose":"lemon_bot","labels":{"location":"studio","platform":"mac"},"expiresInMs":900000}}
```

The success payload contains:

- `inviteId`: invitation identifier;
- `inviteCode`: short-lived enrollment credential;
- `joinCommand`: the complete copy-paste command;
- `expiresAtMs`: expiry as Unix milliseconds;
- a bounded summary with no operator credentials.

`purpose` defaults to `lemon_bot`, `labels` to an empty object, and `expiresInMs`
to 15 minutes. Expiry must be between 1 ms and 24 hours. Names and purposes are
nonempty strings of at most 64 UTF-8 bytes and are trimmed. Labels are an explicit
string-to-string object with at most 32 keys: each key is nonempty (not only
whitespace) and at most 64 UTF-8 bytes, and each value is at most 256 UTF-8 bytes.
Empty values are allowed. Label strings are preserved exactly; string-list labels
are not accepted. Control characters are rejected. The invitation's exact
trimmed node name, purpose, and labels are controller-bound, not chosen later by
the joining host. A durable name already in use cannot become a second machine.

Treat `inviteCode` and `joinCommand` as secrets until used or expired. Do not put
them in logs, public issues, telemetry, or transcripts. Only the issuing RPC
returns the code; the controller stores its digest rather than its plaintext.

To cancel a pending, unused invitation, use the same operator pairing authority:

```json
{"type":"req","id":"revoke-invite-1","method":"node.pair.invite.revoke","params":{"inviteId":"INVITE_ID"}}
```

Success is `{"inviteId":"INVITE_ID","revoked":true}`. An absent, consumed,
previously revoked, or expired invitation returns `NOT_FOUND`. Revocation races
atomically with enrollment and never unpairs a node or revokes its established
session. A revoked code cannot authenticate or be used by an enrollment
connection that was already open.

## Run the command on the destination

Copy the returned `joinCommand` to a terminal on the machine being attached.
Source commands select the provisioned checkout's `bin/lemon`. Packaged commands
select `$HOME/.lemon/versions/<configured-version>/bin/lemon`, never `PATH` or
the mutable `versions/current` symlink. If that pinned executable is absent, the
command fetches the existing
[HTTPS installer](https://raw.githubusercontent.com/z80dev/lemon/main/install.sh)
and runs it with explicit `LEMON_VERSION` and `LEMON_INSTALL_BASE_URL` plus the
POSIX flags `--skip-setup --no-modify-path`. Review the installer before executing
remote code when required by your policy. It requires `curl`, `tar`, and `python3`
on a supported macOS/Linux host; source checkouts require their normal development
dependencies. See [installation](../install.md).

Every route runs the **selected actual CLI**:

```bash
"$lemon_bin" node capabilities --json --require-bot >/dev/null
```

Only after this exits zero does the command execute `node join`. Missing or old
capability commands, incomplete features, a missing source checkout, an installer
failure, or a version mismatch stop before enrollment with a redacted message;
there is no fallback to another executable. No controller operator token or
provider credential appears in the command, and this gate does not run provider
setup.

The underlying join invocation is:

```bash
lemon node join --name studio-mac \
  --controller wss://controller.example/ws \
  --invite-code 'THE_RETURNED_INVITE_CODE'
```

In a source checkout, use `./bin/lemon` instead. `--invite-code` implies `--pair`
and cannot be combined with operator/session token flags, `--node-id`, or
`--repair`. For repair, only the issuing operator supplies the durable `nodeId`
in the invitation request; the destination receives the code, not recovery
credentials or a caller-selected identity.

The credential authenticates a restricted **enrollment** connection. It can only
request enrollment for its bound name and exchange the challenge produced by
that enrollment. It grants no operator scope, inventory access, invocation
access, general mutation authority, or general event stream. The pairing request
presents the same `inviteCode` and is automatically approved. The normal
one-time challenge exchange issues a node session token, while the pairing
response delivers node recovery material to the worker. The worker saves them
privately and reconnects as an enrolled node. No manual approval is needed.

An invite is consumed atomically once: concurrent requests cannot create two
nodes or replay it. Expired, revoked, and stale-generation codes and wrong names
fail closed; a wrong-name attempt does not consume a valid invite. If an
enrollment response is lost after consumption, do not retry the old command
indefinitely. Have the controller owner inspect `nodes.list` and issue a bound
repair invitation for any identity already created. Issue a new unbound invite
only for a genuinely new identity/name.

The worker prints `Execution node online (NODE_ID)` and stays in the foreground.
Keep it running, or supervise this foreground command with your OS service
manager. Configure model-provider credentials **on the destination** with
`lemon setup` or `lemon model --provider ...`; the noninteractive installer does
not copy credentials from the controller or run provider setup.

## Working directory and host-access roots

Start from an existing destination-local project directory, or add `--cwd` to
the join invocation. The default is the caller's launch directory. File RPCs use
the destination OS user's home as the allowed root by default. To permit a
project outside home, configure roots on the destination:

```bash
lemon node join --name studio-mac \
  --controller wss://controller.example/ws \
  --invite-code 'THE_RETURNED_INVITE_CODE' \
  --cwd /srv/bots/project \
  --allowed-root /srv/bots --allowed-root "$HOME"
```

`--allowed-root` is repeatable. Explicit roots **extend** the home default, so
home remains permitted. These flags become destination-local
worker policy; callers cannot override them through file/shell RPC arguments.
File RPC paths and shell opening working directories must resolve within allowed
roots. A PTY is still a full shell running as the destination user: root checks
are not an OS sandbox and do not restrict commands to those directories. Use a
dedicated OS account/container and tool policy for stronger isolation. Enrollment
itself does not isolate bots on the same host.

## Files, secrets, and terminal access

The trusted backend uses the durable `nodeId` for `node.host.info`, file RPCs,
and encrypted secret management. File and secret operations require
`operator.admin`; host information requires `operator.read`.
See [node files and secrets](node-files-and-secrets.md) for chunked transfer
shapes, path policy and exact deletion confirmation. Secret listings return
names only; configure the destination's encrypted master key before setting
secrets. Values are never returned or logged.

For a real terminal, keep the opening operator connection alive:

```json
{"type":"req","id":"terminal-1","method":"node.shell.open","params":{"nodeId":"NODE_ID","cols":80,"rows":24}}
```

The success payload is `{"shellId":"SHELL_ID"}`. Use `node.shell.input`
with `{"shellId":"SHELL_ID","dataBase64":"BASE64_BYTES"}`,
`node.shell.resize` with `{"shellId":"SHELL_ID","cols":100,"rows":40}`,
and `node.shell.close` with `{"shellId":"SHELL_ID"}`. All require admin scope.
Only that opening connection receives `node.shell.output` payloads
`{"shellId":"SHELL_ID","dataBase64":"BASE64_BYTES","seq":1}` and terminal
`node.shell.exit` payloads `{"shellId":"SHELL_ID","code":0}`; another connection
cannot operate the shell.

The worker requires `python3` to allocate a real PTY, not a pipe-backed shell.
It runs the destination user's shell with worker-local cwd. Output streams in
16 KiB chunks with acknowledgement backpressure. Terminals cap output at 32 MiB
and lifetime at one hour; disconnects, node replacement, slow consumers, explicit
close and timeouts clean up the PTY and its process group. There are at most
eight terminals per opening connection and 64 globally.


## Inventory, reconnect, and recovery

The trusted backend calls `nodes.list` with operator read authority. Each durable
node row includes `id`, `name`, `purpose`, `labels`, `enrollmentInviteId`,
online/offline status, last seen timestamps, capability names, and session
credential state. `enrollmentInviteId` is the exact consumed invitation ID that
enrolled or most recently repaired this durable node, or null for legacy nodes.
Use it to reconcile a pending attachment with the invitation you issued, not a
timestamp or name-only inference. Store the
controller-issued durable node ID as the machine identity; do not use the
WebSocket connection ID. Ordinary pre-invite nodes report a null purpose and an
empty labels object unless their durable metadata already has them.

Supply optional `name` or `nodeId` parameters for an exact inventory lookup.
If both are supplied, both must match the same durable record. These filters are
applied before the 200-node and 50-pending-pairing response limits.
`summary.truncated` is true if either matching collection exceeded its limit.
Do not interpret a missing row in a truncated response as offline or absent:
repeat the read with the exact durable ID or name. A store query failure returns
`UNAVAILABLE`, not an empty inventory.

For later starts, **remove `--invite-code`** and reuse the stored credential:

```bash
lemon node join --name studio-mac --controller wss://controller.example/ws \
  --cwd /srv/bots/project --allowed-root /srv/bots --allowed-root "$HOME"
```

Credential files are mode 0600 in a mode 0700 directory, keyed by durable node ID
and bound to the exact controller URL. Node sessions last seven days. Renewal
uses the existing operator-authorized `--pair` flow with the locally stored
recovery credential, retaining the same durable node identity and metadata:

```bash
LEMON_NODE_OPERATOR_TOKEN='CONTROLLER_OPERATOR_TOKEN' lemon node join \
  --name studio-mac --controller wss://controller.example/ws --pair
```

Only the controller owner should execute that privileged recovery flow; prefer a
secure environment handoff rather than placing the token in shell history. A
legacy node without recovery material can use explicit `--pair --repair
--node-id EXISTING_NODE_ID` with operator authority. Alternatively, the trusted
backend can authorize repair without sending that operator credential to the
destination:

```json
{"type":"req","id":"repair-invite-1","method":"node.pair.invite","params":{"nodeName":"studio-mac","nodeId":"EXISTING_NODE_ID","expiresInMs":900000}}
```

The `nodeName` must match that ID's durable name. Run the returned `joinCommand`
unchanged; do not add `--node-id` or `--repair`. This invitation binds the existing
identity, recovery-credential hash, and current session generation. It cannot
silently create a replacement identity if the node disappears or its credentials
change. A missing ID returns `NOT_FOUND`; a mismatched durable name returns
`CONFLICT`; expired, revoked, consumed, or stale codes fail authentication.

Auto-approved repair returns the same challenge shape and the **same durable
node ID**, rotates recovery material, and replaces the session through the normal
challenge exchange. The worker privately saves the replacement credentials and
reconnects under that ID. Old sessions are invalidated and live sockets replaced.
Purpose and label metadata are retained when omitted from the repair invitation;
the issuing operator may explicitly supply replacement purpose or label metadata.
After session rotation, revocation, or another repair, issue a fresh bound invite
rather than reusing one from an older generation. Revoking an unused repair
invitation leaves the existing node and its credentials unchanged.

To detach, the trusted backend calls `nodes.revoke` with `nodeId` and an exact
`confirmName`. This invalidates sessions and disconnects live sockets while
retaining the durable identity for deliberate operator recovery.

## Inspect resources and capabilities

`node.host.info {"nodeId":"NODE_ID"}` measures the destination's hostname, OS,
CPU, memory, disk, uptime, Lemon version, cwd and user. Supported macOS/Linux
snapshots contain measured values; missing or failed measurement returns an
explicit `UNAVAILABLE` error instead of invented zeroes or null metrics.

`node.capabilities.get {"nodeId":"NODE_ID"}` requires operator read access and
returns `{nodeId,os,measuredAtMs,stale,items}`. Every item has:

- `id`, `name`, `category` (`files`, `shell`, `browser`, `connector`, `os_app`);
- `supported`: whether the inspected machinery is present;
- `configuredLevel`: `off`, `read_only`, or `read_interact`;
- `osGrant`: `granted`, `denied`, `not_required`, or `unknown`;
- `tools`: actual registered runtime tool names, not inferred method grants;
- a bounded `reason`, `measuredAtMs`, and `stale`.

File inspection checks worker-root access using the destination account's OS
permission checks, including ACLs. Terminal inspection checks the actual shell
and Python installation. Browser inspection uses its owning backend's status
and the built-in tool catalog; it does not launch a browser.

On macOS, installed Peekaboo's passive `permissions status --json` reports
Accessibility, Screen Recording and Event Synthesizing for its selected
execution actor ([command contract](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/permissions.md)).
A missing CLI is **absent**, a failed/unrecognized inspection is **unknown**, and only a measured negative
grant is **denied**. Full Disk Access has no supported nonprompting query and
is reported unknown. On Linux, X11 automation requires installed `xdotool` and
an observed authenticated display connection; an unavailable display is not
misrepresented as an explicit OS denial. No inspection takes a screenshot or
prompts for access.

Connector tools and provider permissions are profile/session-scoped; machine
inspection does not invent grants by enumerating advertised RPC names. Desktop
CLIs are reached through the real `bash` tool, not fictitious registered tool
names. These are destination measurements, **not per-bot authorization**.
Restricting a bot requires its actual runtime tool policy; broad shell access
is not an OS sandbox and can execute installed desktop CLIs.

Machine dispatch resolves only exact durable IDs. A different node whose
display name happens to equal another node's ID cannot receive that machine's
files, secrets, terminals or inspection requests, including when the intended
machine is offline.
