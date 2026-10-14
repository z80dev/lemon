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

## Issue an invitation

On the already-authenticated operator WebSocket, request:

```json
{"type":"req","id":"invite-1","method":"node.pair.invite","params":{"nodeName":"studio-mac","purpose":"lemon_bot","labels":["studio","mac"],"expiresInMs":900000}}
```

The success payload contains:

- `inviteId`: invitation identifier;
- `inviteCode`: short-lived enrollment credential;
- `joinCommand`: the complete copy-paste command;
- `expiresAtMs`: expiry as Unix milliseconds;
- a bounded summary with no operator credentials.

`purpose` defaults to `lemon_bot`, `labels` to an empty list, and `expiresInMs` to
15 minutes. Expiry must be between 1 ms and 24 hours. Names and purposes are
nonempty strings of at most 64 UTF-8 bytes; at most 16 labels of at most 64 bytes
are accepted. Control characters are rejected. Names, purposes, and labels are
trimmed; duplicate labels are removed. The invitation's exact trimmed node name,
purpose, and labels are controller-bound, not chosen later by the joining host.
A durable name already in use cannot become a second machine.

Treat `inviteCode` and `joinCommand` as secrets until used or expired. Do not put
them in logs, public issues, telemetry, or transcripts. Only the issuing RPC
returns the code; the controller stores its digest rather than its plaintext.

## Run the command on the destination

Copy the returned `joinCommand` to a terminal on the machine being attached.
It uses an existing `lemon` executable (or `$HOME/.lemon/bin/lemon`), otherwise
fetches the existing HTTPS `install.sh` and installs Lemon with `--skip-setup
--no-modify-path`. It then runs the same `lemon node join` CLI supported by source
and packaged installations. No controller operator token appears in the command.
Review the installer before executing remote code when required by your policy.
The installer requires `curl`, `tar`, and `python3` on a supported macOS/Linux
host; see [installation](../install.md).

The underlying join invocation is:

```bash
lemon node join --name studio-mac \
  --controller wss://controller.example/ws \
  --invite-code 'THE_RETURNED_INVITE_CODE'
```

In a source checkout, use `./bin/lemon` instead. `--invite-code` implies `--pair`
and cannot be combined with operator/session token flags, `--node-id`, or
`--repair`. An invite cannot recover or overwrite an existing durable node.

The credential authenticates a restricted **enrollment** connection. It can only
request enrollment for its bound name and exchange the challenge produced by
that enrollment. It grants no operator scope, inventory access, invocation
access, general mutation authority, or general event stream. The pairing request
presents the same `inviteCode` and is automatically approved. The normal
one-time challenge exchange issues a node session token, while the pairing
response delivers node recovery material to the worker. The worker saves them
privately and reconnects as an enrolled node. No manual approval is needed.

An invite is consumed atomically once: concurrent requests cannot create two
nodes or replay it. Expired codes and wrong names fail closed; a wrong-name
attempt does not consume a valid invite. If an enrollment response is lost after
consumption, do not retry the old command indefinitely. Have the controller owner
inspect `nodes.list` and use the operator recovery/repair flow for any identity
already created; issue a new invite only for a genuinely new identity/name.

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
node row includes `id`, `name`, `purpose`, `labels`, online/offline status, last
seen timestamps, capability names, and session credential state. Store the
controller-issued durable node ID as the machine identity; do not use the
WebSocket connection ID. Ordinary pre-invite nodes report a null purpose and
empty labels unless their durable metadata already has them.

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
legacy node without recovery material requires explicit `--pair --repair
--node-id EXISTING_NODE_ID` with operator authority. Invites intentionally do not
replace recovery authorization.

To detach, the trusted backend calls `nodes.revoke` with `nodeId` and an exact
`confirmName`. This invalidates sessions and disconnects live sockets while
retaining the durable identity for deliberate operator recovery.
