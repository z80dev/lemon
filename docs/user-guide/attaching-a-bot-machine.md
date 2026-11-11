# Attaching a bot machine

A bot machine is a named Lemon execution node on a host you control. It joins an
existing controller; it is not a new controller, virtual machine, or desktop
sandbox. You keep normal SSH, terminal, and filesystem access. Bots assigned to
the same machine share its OS account, files, and browser logins.

## Add a machine over SSH

For a loopback-only controller, the backend on the controller host can maintain
a reverse SSH link to the destination using your own SSH account and keys.
Passwordless `ssh me@studio` must work from **the controller host**, which is not
necessarily the Mac or browser you are using. A changed host key is never accepted
automatically; verify the destination identity and update your known-hosts entry
before reconnecting. New hosts use SSH's trust-on-first-use policy.

The link forwards only the authenticated node gateway (normally 4044) and, when
needed, the Lemon Bot backend (normally 4100), never the main control-plane port
4040. Destination listeners bind `127.0.0.1`. The destination product port must be
free; unrelated listeners are never stopped. A stale same-user sshd session that
holds a requested forwarding port is terminated before opening the new link.
Use a trusted OS account: other users with access to that account can read its
worker credentials.

For manual tunnel administration on the controller host:

```bash
lemon service install tunnel --name studio --ssh me@studio \
  --node-port 4044 --gateway-port 4044 --product-port 4100 --backend-port 4100 \
  --wait 15 --json
lemon service status tunnel --name studio --json
lemon service repair tunnel --name studio --json
lemon service uninstall tunnel --name studio --json
```

This only establishes the transport; enrollment must use an invitation bound to
`ws://127.0.0.1:4044/ws` on the destination. Choose another `--node-port` if needed;
keep that exact URL for subsequent worker connections.

The supervisor restarts network failures and dropped SSH sessions. Authentication
failures, changed host keys and refused remote forwarding stop retries and appear
as `ssh_auth_failed`, `host_key_changed` or `forward_refused`; fix the cause, then
repair the tunnel service. Keys available only through an interactive SSH agent
may need loading again after login. The service passes only an allowlisted
environment to SSH, never Lemon tokens.

`lemon tunnel run` is the shell-only foreground implementation used by the service.
It writes private, atomically replaced state to
`~/.lemon/run/service/tunnel-<name>.json`. It reports online after SSH survives five
seconds; network errors exit 75 for the supervisor to restart, while terminal
failures exit 0. The link works only while the controller host is awake and its
tunnel service is running.

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
listener. Route a TLS proxy (for example Tailscale Serve) to the **node gateway
at `http://127.0.0.1:4044`**, never the main port 4040. The gateway serves only
`GET /ws` for authenticated node/enrollment roles and `GET /healthz`; it cannot
authenticate operators or expose OpenAI/ACP. Its bind/port are configurable via
`LEMON_CONTROL_PLANE_NODE_BIND_IP` and `LEMON_CONTROL_PLANE_NODE_PORT`.
An occupied or disabled (`0`) gateway port requires fixing before forwarding.

Keep operator access local. A trusted remote backend needing operator `/ws`
must use a separate TLS, path-limited proxy to **4040 `/ws` only** and authenticate
with the operator token. Do not forward the whole main listener. Main and web
listeners now bind loopback by default; LAN binds require explicit opt-in and
operator authentication. Never enable tokenless loopback compatibility behind
either proxy.

An Elixir deployment can instead set `:lemon_control_plane, :public_ws_url`.
Without either setting, the command uses
`ws://127.0.0.1:<control-plane-port>/ws`, suitable only for a machine on the same
host. Off-loopback invite commands require `wss://`; URLs must not contain user
credentials, query credentials, or fragments.

In Lemon Bot on the web, **Connect a computer** asks for one friendly name. Its
machine ID is derived from that name (lowercase ASCII letters, digits, dots,
underscores and dashes; leading punctuation removed; at most 64 characters;
`lemon-host` if nothing remains). Use a distinct name for each computer.
Purpose, labels and the default 15-minute invite lifetime are under **Advanced**.
The page checks the controller's actual advertised endpoint before issuing an
invite. A loopback-only controller offers **This computer**, meaning the computer
running the controller—not necessarily your browser. Other computers require
the reachable `wss://` endpoint above (for example, TLS over your Tailscale network).
The preview classifies the configured endpoint; it does not probe the destination
network or prove remote reachability. No operator token or controller address is
returned by the preview.

Run the copied command and enter its separate one-use code on the destination.
The page observes enrollment live and, once verified online, offers
**Online — Create a Bot here** with that machine selected. Provider credentials
must still be configured on the destination. The join script installs the worker
through `lemon service` by default and exits after it is online.

### Loopback credential ownership

Named workers check that a literal-loopback controller or approved private MCP
listener belongs to their own OS user before sending credentials. Linux checks
`/proc/net/tcp` and `tcp6`; macOS uses `lsof`. Missing ownership evidence fails
closed, so another local account cannot harvest credentials by occupying a
stopped tunnel's port. Reconnecting uses the normal worker backoff.

If you deliberately run the controller or tunnel as a different OS user, set
`LEMON_NODE_TRUST_LOOPBACK_LISTENER=1` in the worker's service environment to opt
out. This trusts all literal-loopback listeners and should not be enabled on a
shared host with untrusted local accounts.

### Select a compatible destination runtime

Configure runtime selection **on the controller before issuing an invitation**.
The generated command never defaults to the latest published release. The join
script never runs an unvetted `lemon` from the destination's `PATH`: a PATH
runtime is reused only when it reports the exact pinned version and passes the
bot capability gate.

- **Same-host source development:** for a loopback controller URL (`localhost`,
  `127.0.0.1`, or `::1`), the default is the controller's actual source checkout,
  derived from its compile-time source directory when `bin/lemon` and `mix.exs`
  are present there. This uses that checkout's `bin/lemon`, not an older installed
  release. Start the controller from the integrated checkout that implements the
  required bot runtime features.
- **Remote or explicitly selected source (source controllers only):** provision a
  compatible checkout on the destination yourself, then set
  `LEMON_NODE_SOURCE_CHECKOUT` to its absolute
  **destination-local** path. The Elixir setting is
  `:lemon_control_plane, :node_source_checkout`. The path need not exist on the
  controller, but `mix.exs` and executable `bin/lemon` must exist at that path on
  the destination. This explicit source setting takes priority over all other
  selection. The command does not clone a branch, build a VM, or provision that
  checkout.
- **Published or private packaged build:** packaged controllers default to their
  running release version and the canonical GitHub release base URL. Source
  controllers selecting a release must provide an exact version and HTTPS base
  URL; packaged controllers can override these defaults with the same settings.
  Set
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

A version string, including one equal to the controller's, does not prove that a
build supports the bot APIs. When a version pin is configured, the selected
binary's actual `lemon version` must match it, **and** its feature gate must pass.
Remote invitations from source controllers
without a destination source checkout or both packaged-build settings return
`INVALID_REQUEST`:
`Configure a destination source checkout or an explicit node install version and HTTPS base URL`.
An invalid source path setting returns
`Configure an absolute destination node source checkout`; an invalid version
setting returns `Configure an exact node install version`.

Compatibility is an API contract, not merely a matching version:

| Component | Required contract |
| --- | --- |
| Controller | Read-only `node.pair.preview`, `node.pair.invite`, `node.pair.invite.revoke`, and exact `nodes.list` enrollment/repair reconciliation with durable node IDs and `enrollmentInviteId`. |
| Destination CLI | `node capabilities --json --require-bot` must exit zero only for a complete bot runtime; `node join --invite-code-stdin` must use restricted enrollment and persist destination-local credentials. |
| Pinned destination build | `version` must report the configured exact pin; it must still pass the capability gate. |
| Repair flow | Controller-bound repair invitation and generation-checked challenge exchange retain the durable node ID; the destination runs the returned credential-free command and enters the separate code at its hidden prompt. |

Use [node files and secrets](node-files-and-secrets.md) for the destination
capability and credential-proof contracts. Capability readiness does not claim
that model-provider credentials are configured.

For an integrated source checkout, the actual launcher can inspect itself without
starting a worker or connecting to a controller:

```bash
/absolute/path/to/lemon/bin/lemon node capabilities --json --require-bot
```

The JSON has `{protocol,lemonVersion,methods,features,botReady,missingFeatures}`.
Protocol is `1`; `features` has ten required booleans: `hostIO`, `filesystemCAS`,
`deletePreviews`, `encryptedSecrets`, `ptyShell`, `mcpDiscovery`, `profileSync`,
`liveStreaming`, `repairInvites`, and `nativeExecutionPolicy`, plus optional
`botFolder` for per-Bot working folders. Required Python
primitives/helper assets, the large native tool-policy JSON envelope and native
privacy-context protocol version 1 are checked, not assumed. Profile readiness
includes owning `node.profile.paths`; native policy readiness also requires the
actual worker's nested `coding_agent.run.nativePrivacyContext` version-1 descriptor.
`missingFeatures` is sorted; any false flag makes `botReady:false`, and
`--require-bot` returns failure before enrollment. You can additionally use
`--expected-version EXACT_CALVER`; the version pin alone is never readiness.

After exact durable enrollment reconciliation, query the authenticated worker:

```json
{"type":"req","id":"runtime-1","method":"node.runtime.features","params":{"nodeId":"NODE_ID"}}
```

Its result adds the target `nodeId` to the same software inventory. A product
must require this live destination's `botReady:true` before marking it ready.
Do not substitute controller capabilities, an online socket or a version string.
This check does not assert model-provider login or OS grants; inspect those
separately with the actual provider service and `node.capabilities.get`.

## Issue an invitation

On the already-authenticated operator WebSocket, request:

```json
{"type":"req","id":"invite-1","method":"node.pair.invite","params":{"nodeName":"studio-mac","purpose":"lemon_bot","labels":{"location":"studio","platform":"mac"},"expiresInMs":900000}}
```

The success payload contains:

- `inviteId`: invitation identifier;
- `inviteCode`: short-lived enrollment credential;
- `joinCommand`: the credential-free copy-paste script command;
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

Treat `inviteCode` as secret until used or expired. Never put it in shell commands,
environment variables, logs, issues, telemetry, or transcripts. `joinCommand`
contains no enrollment, operator, or node credential. Only the issuing RPC returns
the code; the controller stores its digest rather than its plaintext.

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

Copy the returned `joinCommand` to a terminal on the destination. Packaged
controllers download `join-node.sh` over HTTPS from the exact release tag:
`<baseURL>/releases/download/v<VERSION>/join-node.sh`, then invoke Bash.
Source controllers invoke the destination checkout's `scripts/join-node.sh`.
Enter the separately returned one-use code at the
**hidden terminal prompt**. The prompt reads `/dev/tty`, not the piped script stdin.
The script disables tracing, restores terminal echo on exit/interruption, validates
the bounded code without normalizing special characters, and passes it once to
`node join --invite-code-stdin`. It never puts the code in process arguments or
environment variables. A controlling terminal is required; EOF or invalid input
stops before downloads, runtime inspection, or enrollment.

**Publication prerequisite:** the matching release must publish `join-node.sh`
and the canonical `install.sh` as version-scoped assets. Neither script is fetched
from mutable `main`. Packaged controllers default to their running release version
and `https://github.com/z80dev/lemon`; `LEMON_NODE_INSTALL_VERSION` and
`LEMON_NODE_INSTALL_BASE_URL` can select an exact published version and trusted
HTTPS release base URL. Packaged controllers never generate source-checkout joins.
There is no independent join-script URL override.

A local checkout can run the same script before publication:

```bash
bash /path/to/lemon/scripts/join-node.sh --name studio-mac \
  --controller wss://controller.example/ws --source /path/to/lemon
```

For packaged installs, replace `--source` with the controller's exact
`--version VERSION --base-url HTTPS_RELEASE_BASE_URL`. Do not invent a release pin
or assume a matching version has the required APIs.

Source mode uses only the provisioned checkout's `bin/lemon` and requires its
`mix.exs`; it never falls back to a PATH executable. Release mode first reuses
`$HOME/.lemon/bin/lemon`,
if it reports the exact version and passes `node capabilities --json --require-bot`.
Otherwise it fetches
the canonical `install.sh` from the same base URL and exact release tag,
and installs that exact `LEMON_VERSION` and `LEMON_INSTALL_BASE_URL` with
`--profile full --require-bot --force --skip-setup --no-modify-path`. The pin
selects the release whatever channel its manifest publishes; installation
installs no TUI and stages the runtime, runs `node capabilities --json
--require-bot --expected-version <version>` on it in a throwaway home, and only
then promotes it, leaving any live install untouched on failure. The join script
repeats the version/capability gate. This selects a bot-capable canonical
full/min Lemon runtime, never the standalone `lemon_bot` backend artifact.
Enrollment and the service use that stable launcher through `versions/current`;
installing a pin flips the pointer so restarts use the selected version.

Review remote scripts according to your policy. The installer requires `curl`,
`tar`, and `python3` on a supported macOS/Linux host; source checkouts require
their normal development dependencies. See [installation](../install.md).
Missing capabilities, installation failure, an unavailable checkout, or a wrong
version stop before enrollment. This does not run provider setup.

`--invite-code-stdin` implies `--pair` and cannot be combined with operator/session
token flags, `--node-id`, or `--repair`. The old argv credential flag is removed.
For repair, only the operator supplies the durable `nodeId` when issuing the
invitation; the destination enters its separate code, not recovery credentials
or a caller-selected identity. Do not retry an uncertain enrollment outcome.

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

By default the script calls `lemon service install worker --invite-code-stdin
--wait 60 --json`, passing the code only on stdin, and exits once the worker is
online. It reports persistence: login, boot, session (logged-in only), or none.
An unavailable lifecycle command fails clearly, without a foreground fallback.
Add `--foreground` (`--no-service` is an alias) to keep the worker in the terminal.
Inspect or repair a worker with:

```bash
lemon service status worker --name studio-mac --json
lemon service repair worker --name studio-mac
```

To enroll directly through the lifecycle command, pipe the code once to
`lemon service install worker --name NAME --controller URL --cwd "$HOME"
--invite-code-stdin`. It runs a private `node join --enroll-only` exchange, then
starts the persistent worker without the code. The one-shot exits after saving
the credential and reaching online; an uncertain enrollment is never retried.
Readiness uses `worker-status.json` and the manager's PID, not log scraping.

Configure model-provider credentials **on the destination** with
`lemon setup model` (or inspect readiness with `lemon setup model --json`); the
noninteractive installer does not copy credentials from the controller or run
provider setup. A detected Codex CLI login is copied only with your consent;
each execution machine keeps its own model credentials.

For headless use, save the script to a file and pass `--code-stdin` with the
43-character code plus newline on stdin. `--code-fd N` accepts an already-open
descriptor 3–9, including when the script itself is piped to Bash. These options
are mutually exclusive; neither puts the code in argv or the environment.
`--json` emits only the lifecycle JSON document on stdout (service mode only).
Exit status is 0 for online, 1 for not attempted, 2 for an enrollment attempt
without an installed unit, or 3 for installed but not online yet. Never reuse a
code after an attempted or uncertain enrollment; ask the owner for a repair invite.

## Working directory and host-access roots

Add `--cwd` with an existing absolute destination-local project directory to
the join script; its default is `$HOME`. File RPCs use
the destination OS user's home as the allowed root by default. To permit a
project outside home, configure roots on the destination:

```bash
lemon node join --name studio-mac \
  --controller wss://controller.example/ws \
  --cwd /srv/bots/project \
  --allowed-root /srv/bots --allowed-root "$HOME"
```

This example reconnects **after enrollment** using the destination's saved
credential. During enrollment the join script preserves your launch directory;
start it from the desired existing project directory.

`--allowed-root` is repeatable. Explicit roots **extend** the home default, so
home remains permitted. These flags become destination-local
worker policy; callers cannot override them through file/shell RPC arguments.
File RPC paths and shell opening working directories must resolve within allowed
roots. A PTY is still a full shell running as the destination user: root checks
are not an OS sandbox and do not restrict commands to those directories. Use a
dedicated OS account/container and tool policy for stronger isolation. Enrollment
itself does not isolate bots on the same host.

### Bot folder

Workers advertising `features.botFolder` support profiles with
`workingDirectory: "profile_files"`. These runs start in the destination's
`~/.lemon/profiles/<profileId>/files` (0700), separate from managed persona,
memory and skills files. The validated profile ID determines the path; callers
cannot supply a folder root. Older workers and `node_default` profiles retain
the worker's default working directory.

Attachments and relative shared-file paths use the same folder when file RPCs
carry `profileId`; absolute paths and destination allowed roots remain unchanged.
The Bot folder is not an OS sandbox. Its project config is not loaded: runtime
configuration still comes from the worker's default cwd.

With the durable `workspace_read_exempt` policy enabled, safe `read`, `ls` and
non-following `grep` calls within that folder need no approval. Symlink escapes,
hard-linked reads and `find` never qualify. The first unreviewed read permanently
fences that session's `webfetch` and `websearch` behind approval, including after
restore and in later child tasks. Workspace folder-review policy can disable
the exemption; a run request alone cannot enable it.


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
It runs the destination user's shell with worker-local cwd, opened through the
same descriptor-root resolver and applied with `fchdir` before forking. Substituted
symlinks cannot redirect that opening cwd. Startup reads one bounded binary policy
frame without consuming subsequent terminal input; importing the shared resolver
does not start a second packet server. Output streams in
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

For later starts, omit `--invite-code-stdin` and reuse the stored credential:

```bash
lemon node join --name studio-mac --controller wss://controller.example/ws \
  --cwd /srv/bots/project --allowed-root /srv/bots --allowed-root "$HOME"
```

Credential files are mode 0600 in a mode 0700 directory, keyed by durable node ID
and bound to the exact controller URL. Node sessions expire after seven days
**without contact**: the controller renews them on connect and hourly while
connected, without rotating credentials or interrupting work.

A rejected stored credential parks the running worker in `needs_reauthorization`
instead of restarting it; a missing credential parks it in `needs_enrollment`.
No work runs while parked. Check local state without contacting the controller:

```bash
lemon node status --name studio-mac --json
```

Use **Machines → Reconnect** in Lemon Bot to issue an owner-authorized repair
invite (described below), then run its join command on the destination machine.
The parked worker detects saved replacement credentials within about five
seconds and resumes with the same durable identity. Network and controller-store
outages retry automatically with backoff capped at sixty seconds; they do not
require re-enrollment. Name conflicts retry every minute.

The controller owner can also use the operator-authorized `--pair` flow with
the locally stored recovery credential, retaining the same identity and metadata:

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
The measured terminal tool list advertises the real `lsp_diagnostics` builtin only
when registered and shell machinery is supported. Its destination-local workspace
checks may run language tooling, so product access requires both files and shell
effective `read_interact`, including review ceilings and native approvals. It is
not a read-only/baseline grant or a guarantee every language checker is installed.

Machine dispatch resolves only exact durable IDs. A different node whose
display name happens to equal another node's ID cannot receive that machine's
files, secrets, terminals or inspection requests, including when the intended
machine is offline.
