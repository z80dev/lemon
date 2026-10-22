# Lemon Bot backend

A Bun HTTP/WebSocket service for personally owned assistants attached to an existing Lemon controller. Each named Bot runs for its owner on that person’s machine. Groups coordinate 2–6 of the same owner’s Bots. See the [API](../contracts/api.md), [protocol](../contracts/protocol.ts), and [cards](../contracts/cards.md) for wire resources and authorization.

## Run
### Standalone installation

The canonical release installer supports `--profile lemon_bot` on Linux x86_64,
Linux arm64 and macOS arm64. Follow the [versioned release installation
guide](../../../docs/release/versioning_and_channels.md). The bundle contains
`bot/bin/lemon-bot`, the complete external `bot/web` app, and its native image
dependencies; running it requires no installed Bun, Node, Elixir or source checkout.
Then run `lemon-bot` rather than `bun run start`. `lemon-bot --version` reports the
exact release CalVer and `lemon-bot --help` describes startup; neither initializes
private product state.

With no environment, `lemon-bot` serves `http://127.0.0.1:4100` with private state
in `~/.lemon/lemon_bot`. On first start in a terminal it asks which Lemon to use:

1. **This machine.** The controller is found the way the Lemon launchers find it
   (`LEMON_CONTROL_PLANE_PORT`, then `~/.lemon/ports.env`, then 4040) and authenticated
   with the launcher-managed `~/.lemon/run/control-plane-<port>.token`. If Lemon is
   installed but stopped, `lemon-bot` offers to start it (running `lemon setup
   --if-required` and `lemon daemon`). The credential is re-read before each
   connection attempt, so a backend left waiting connects as soon as Lemon starts.
2. **Another machine.** Enter its `wss://…/ws` controller address and its operator
   token (hidden input; on that machine it is in `~/.lemon/run/control-plane-<port>.token`).
   The connection is verified before saving.

The choice is saved in `DATA_DIR/controller.json` (mode 0600; a remote token is
encrypted with the product master key). Later starts reuse it and, for this machine,
still offer to start a stopped Lemon. `lemon-bot --choose-lemon` asks again. Without
a terminal (a service manager) no question is asked: the saved choice, or else the
local Lemon, is used, and owners can choose **Start** in the app when the installed
`~/.lemon/bin/lemon` launcher exists. Explicit `LEMON_BOT_CONTROL_URL` or
`LEMON_BOT_OPERATOR_TOKEN` always override the saved choice. A same-machine
credential is never sent to a controller on another host.

Keep `LEMON_BOT_DATA_DIR`, private operator configuration and server credential
sources outside the versioned installation. Installing the backend does not
install or replace the controller/worker: those use canonical full/min runtime
profiles, and newly invited workers install the matching published Lemon release.
An empty backend never prints setup credentials in startup logs. When started in a
terminal, it shows the one-use owner setup code on the controlling terminal only;
otherwise use the explicit local [owner setup command](#provider-free-owner-setup).
Never put the controller operator credential in a browser, generated join command,
archive or log.

### Source development


Use Bun 1.4 or newer. Model/provider credentials on execution hosts are needed for Bot work, not owner setup or management. From this directory:

```sh
bun install
bun run start
```

`bun run start` follows the same startup as `lemon-bot`, including the Lemon choice. `bun run dev` enables Bun watch mode. Source execution loads `../web/dist`; build the web product separately with `bun --cwd ../web run build`. Packaged execution loads `bot/web` beside its executable independently of the working directory. `LEMON_BOT_WEB_ROOT` explicitly overrides either layout. Missing web assets produce an explicit installation response without disabling the API. Startup logs never contain a setup code.

The public origin must be reachable from execution hosts for the bot MCP endpoint. Use reachable HTTPS, normally Tailscale Serve, for managed Bot provisioning and phone connections. A loopback public URL supports same-machine API/Simulator development but is not evidence that an enrolled worker shares the backend's network namespace. Supply the configured public origin through the proxy; arbitrary browser origins are rejected. Authenticated product clients connect to `/v1` and `/v1/realtime`, never directly to the controller.

Operator `approvedPrivateMcpOrigins` explicitly approves private first-party origins. Literal-loopback HTTP is permitted only for the configured first-party origin. Bot provisioning still requires a reachable address and verified machine placement. See the [provider guide](../providers.md) for the validated operator configuration.

| Environment | Requirement / default |
| --- | --- |
| `LEMON_BOT_CONTROL_URL` | Exact credential-free controller `/ws` URL; overrides the saved choice. Default: this machine's Lemon, `ws://127.0.0.1:<port>/ws`. |
| `LEMON_BOT_OPERATOR_TOKEN` | Controller operator credential, server-only; overrides the saved choice. Required for a controller on another machine. Default for this machine: `LEMON_CONTROL_PLANE_OPERATOR_TOKEN`, then the launcher-managed token file. |
| `LEMON_BOT_PUBLIC_URL` | Product origin; HTTPS off loopback. Default `http://127.0.0.1:<port>`; required when `LEMON_BOT_HOST` is not loopback. |
| `LEMON_BOT_DATA_DIR` | Private persistent directory. Default `~/.lemon/lemon_bot`. |
| `LEMON_BOT_HOST`, `LEMON_BOT_PORT` | `127.0.0.1`, `4100`; listener binding. |
| `LEMON_BOT_ENCRYPTION_KEY` | Optional base64 32-byte durable key; otherwise generated private `master.key`. |
| `LEMON_BOT_CONFIG_FILE` | Optional operator JSON file; otherwise DATA_DIR/config.json. Missing file uses the validated empty provider configuration. |
| `LEMON_BOT_TRUSTED_OVERLAY` | Default false. Set exactly `true` only when off-loopback HTTP/WS is protected by an operator-trusted encrypted overlay. Not a general TLS bypass. |
| `LEMON_BOT_WEB_ROOT` | Optional explicit web assets directory; otherwise source `web/dist` or packaged `bot/web`. |
| `LEMON_BOT_RUNTIME_LAUNCHER` | Optional absolute path to an existing executable Lemon launcher (`<checkout>/bin/lemon` or installed `lemon`); invalid paths fail startup. Enables owner-only start/stop/restart only for a loopback controller. Defaults to an installed `~/.lemon/bin/lemon` when the controller is this machine's discovered Lemon. |

Workspace Owners and Admins can inspect the attached instance with `GET /v1/instance` and reconnect its controller link with `POST /v1/instance/reconnect`. The response includes release/build metadata, provider credential presence and channel health, never secret values. Optional malformed upstream sections stay null rather than failing the status read. Owners alone can invoke listed `runtime.actions`: a local launcher enables start/stop/restart, while a connected local or remote controller can advertise restart/stop through its lifecycle RPCs. `runtime.via` identifies the selected route; launcher takes precedence on loopback. Stop/restart require `confirm:true`; POSTs require `clientNonce`. A 202 response is an operation receipt: poll instance status for completion. Controller Restart succeeds on a new link connection timestamp, Stop on disconnection, and either fails after 300 seconds without that observation. Launcher commands run without a shell, with all `LEMON_BOT_*` environment variables stripped, a five-minute deadline, and a 4096-byte output tail. Runtime operations are in-memory and disappear on backend restart.

Provider, identity, push, image, network/egress and host-management configuration belongs to the integration team's [provider guide](../providers.md) and the canonical operator configuration. Missing credentials affect only dependent operations and report a precise prerequisite. Bot tokens and product sessions are different principals; neither exposes the Lemon operator token. Configured backend secret references resolve only explicit private environment/file sources. Destination MCP header `${LEMON_SECRET:NAME}` values resolve only on the execution machine.

## Same-machine and SSH access

Every start keeps a private `DATA_DIR/local-access.key` (64 hex characters, mode 0600,
owned by this user; a missing or unsafe file is replaced). Whoever can read it can
already read `master.key` and the database, so it grants nothing that host access
does not. `POST /v1/auth/local` with `Authorization: Bearer <key>` and an optional
`{"displayName": "…"}` body returns an ordinary 30-day `AuthResult` for the workspace
owner. On an empty instance it first creates that owner (`<os-user>@lemon.local`, no
password) and a workspace named after the host, and discards any pending setup code.
The key is re-read per request: rewrite the file to rotate it. The Mac app uses this
to connect in one click, reading the key directly on the same machine or with
`ssh <host>` plus a loopback tunnel for another one; see
[Connect the Mac app](../apple/README.md#connect-the-mac-app). Password and SSO
accounts, invitations and the setup code below are unchanged.

## Provider-free owner setup

Start the backend separately (an interactive `lemon-bot` start already shows the code). No model
provider login, API key or default model is needed to claim the initial owner,
register phone/browser devices, sign in or inspect the management API. Missing
providers affect execution readiness, not backend reachability. This command
does **not** start/install services, provision Tailscale/Serve or enable Funnel.

In the same trusted local operator environment, run:

```sh
lemon-bot setup
# Source checkout equivalent, from products/lemon_bot/backend:
bun src/cli.ts setup
# Machine-readable discovery only; no proof issuance and no terminal required:
lemon-bot setup --print-origin
```

Both forms use the running instance's data directory and public origin: the same
defaults as `lemon-bot` or its `LEMON_BOT_DATA_DIR`/`LEMON_BOT_PUBLIC_URL`/`LEMON_BOT_PORT`
overrides. Proof issuance also requires its existing private `master.key`
or original `LEMON_BOT_ENCRYPTION_KEY`; discovery alone does not read the key.
Neither form requires controller/operator credentials in its environment.

The command reads the existing private DATA_DIR instance identity and verifies
the exact configured tailnet HTTPS origin with the shared [preflight](../contracts/preflight.md).
It sends no operator/product credential or setup proof during the read-only probe,
refuses redirects/TLS bypass and requires the advertised origin and local instance
ID to match. It prints **only the verified non-secret origin to stdout**. Normal
`setup` also displays a separately labelled **sensitive**, five-minute, one-use
owner setup code directly on the controlling terminal (`/dev/tty`), never to
stdout/stderr, startup logs or a plaintext file. A controlling terminal is required
before issuance. Do not record that terminal, share screenshots or put the code
in argv, a URL, QR, browser storage, analytics or clipboard automatically.

On phone or Web, explicitly open that exact trusted HTTPS origin and use the
existing owner setup form: enter the separate code, choose account credentials
and name the workspace. Submit only to that instance's same-origin `/v1/setup`;
there is no central proxy or cross-origin credential flow. A browser can type the
origin/code manually; camera or native features are unnecessary. The code proves
operator custody; a URL or tailnet membership alone is **not** owner authority.
The resulting product session authorizes the same account/workspace before any
LLM sign-in. Additional phones use existing owner-approved pairing.

The proof is encrypted at rest with its digest, absolute expiry and attempt count
in private product metadata. Re-running `setup` during its lifetime reprints the
same proof without extending expiry or resetting attempts. Ten attempts exhaust
it across restarts and minute-rate resets; only an explicit local command can
replace an expired/exhausted proof. The existing ten-per-minute setup/global
authentication limits still apply, including after local renewal. Claiming
atomically consumes the proof and creates one owner/workspace/session even when
requests race; expiry is checked again after password hashing. A fixed-nonce lost
response can reconcile only the original still-authorized session using the same
account credentials, never create another owner/session. Old pre-upgrade codes
without an expiry are refused; request a new proof locally.

Already configured instances refuse new owner setup and retain all existing
accounts, workspace and device pairing. `setup --print-origin` still works for
read-only discovery; use normal sign-in/pairing instead of re-bootstrap. For
explicit **same-machine development/release smoke only**, append
`--same-machine` (including with `--print-origin`) to permit literal loopback
`127.0.0.1`/`[::1]` HTTP. This never means physical-phone readiness.

Mock/unit coverage does not establish real phone/Tailscale or provider access.
Operator acceptance must separately verify the printed TLS origin from the phone
and browser, claim a fresh isolated instance once, reconnect the same workspace,
and demonstrate a second claim is refused. Provider sign-in/real model execution
is separate and never performed automatically by this command or its tests.

## Runtime prerequisites

The controller must support Bot profiles, machine placement, message submission and cancellation, live events, enrollment, files, terminals, secrets, connected tools and profile memory. Capabilities reflect support discovered from the connected controller. Unsupported or offline operations fail explicitly.

Scheduled agent work remains Lemon cron. Its pre-launch admission callback authenticates an independent private controller secret, binds the exact routine/profile/creator/workspace/job and reserved run identities, and checks current product ACL, policies and spend ceilings **before** dispatch. Configure `LEMON_CRON_ADMISSION_ALLOWED_ORIGINS` on the controller with the exact product origin. HTTPS is required except explicitly allowlisted literal loopback HTTP (`127.0.0.1` or `[::1]`) for local development. The narrow authenticated `cron.admission.set` RPC provisions generated per-routine credentials into the controller's encrypted secret store; clients never receive them. A denied, unavailable, mismatched or timed-out admission does not launch a run and is not automatically retried. Routines using external providers also require the declared event/adapter credentials. One-off reminders are notification outbox deadlines, not cron agent jobs.

Native continuations use a separate authenticated issuer: configure `LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS` on the controller with the exact product origin. Bot provisioning calls `profile.followup.admission.set` and requires its exact acknowledgement before readiness. The internal admission route looks up authoritative `runs.followup.lineage.get` data for the fixed fresh run, retains the actual source principal, applies current target authority plus inherited restrictive floors, and provisions that run's own invocation proof. An unavailable/denied issuer cannot silently fall back to profile-owner credentials. See [runtime prerequisites](src/runtime/README.md) for the bounded receipt and uncertainty lifecycle.

Co-resident Bots share the OS user's files/browser/CLI identities: product authorization and native tool policy do not claim OS isolation. Bots and their execution machines must have the same actual owner. Explicit host-management authority remains a separate administrative capability, not a grant to another person's Bot, persona, credentials or chat.

## Persistence and lifecycle

`product.sqlite` uses WAL and holds product entities, encrypted receipts/private metadata, auth token digests, revision/confirmation fences and a monotonically increasing persisted event sequence. Attachments are immutable checksum-checked private blobs under DATA_DIR/attachments; tickets are short-lived and recheck current access. Keep database, WAL, attachment blobs and master key together in operator backups. Losing/changing a key with existing encrypted state fails closed; do not replace the key to recover an empty-looking deployment.

Mutations reserve their nonce and fixed IDs before external work. Identical concurrent intents share their exact receipt, different bodies conflict, and replay rechecks current resource ACL and authentication authority. Public local-auth replay revalidates current credentials. Pending/uncertain effects survive restart as fenced state; the service reconciles only owning read-only receipts/history, never automatically replays a mutation. A user-visible accepted run is not a completed task, cancellation requested is not terminal cancellation, approval is not execution, and explicit draft Send is separate from permission gates.

Product MCP tools verify the calling Bot and run before reading tool arguments. Credentials use reserved destination-local `lemon_bot/` secret names. Handoffs preserve the owner and verified reply destination. Groups route work to selected owned Bots; rejected targets are reported separately. Memory is stored in the assigned Lemon profile.

Account deletion revokes sessions and fences token issuance before cleanup. It completes reachable product cleanup independently of provider failures; an unconfirmed external revocation remains `outcome_unknown`. The remaining workspace Owner can inspect the bounded, read-only `/v1/account-teardowns` list and detail resources after the deleted account loses its sessions. These expose stages, timestamps, request IDs and actual provider receipt observations—not private transcripts, credentials, login restoration, or a replay button. The final Owner must explicitly transfer ownership before deletion.

Realtime changes and events commit together before publication. Reconnect restores only currently authorized data; an expired cursor requires a fresh `/sync` snapshot. Terminal output has separate buffering and device authorization. Voice sessions retain a disconnect grace period and transcript summary; microphone capture, dictation review and speech playback are controlled by the client.

## Connect an iPhone

Configure a reachable HTTPS `LEMON_BOT_PUBLIC_URL`; Tailscale Serve on the desktop is the recommended deployment. The product does not provision Tailscale or host a networking relay. Loopback HTTP is only for same-machine development/Simulator and cannot attach a remote phone.

The desktop owner creates a five-minute one-use pairing QR. The phone previews the exact cluster/origin, claims it with its installation identity, and displays the same six-digit verification code as the desktop. The owner approves that device once. Completion privately returns one device-bound product session for Keychain storage; it remains valid until revoked, not until the QR expires. QR URLs never contain an operator credential, desktop session, or permanent phone token.

Pending completion evolves with the same nonce. Lost completion responses replay the same encrypted session receipt only before the original five-minute deadline; after that, pair again rather than mint another session. Existing connected credentials survive QR expiry, but device deletion, account/workspace revocation and logout revoke their actual authority. A paired bearer cannot register another installation to evade its device binding. Desktop-only pairing events contain safe state, never credentials; clients without an identified desktop device can use the owner list/detail endpoints.

Before creating a phone QR, read authenticated `GET /v1/identity` on the intended
configured backend and preflight the advertised HTTPS origin against that instance
and workspace. `GET /v1/setup` is the minimal public product fingerprint, not a
generic health probe. A Phoenix 404 (including Lemon Web), controller health or an
HTTP 200 landing page is not the Bot API. The four-key QR carries the expected
instance and workspace IDs; public setup does not disclose workspace identity.
See the shared [preflight contract](../contracts/preflight.md) for TypeScript SDK,
Mac/iOS and CLI predicates, bounded progress observation and TLS requirements.

Reopening a paired app restores its saved cluster/account selection. Offline state keeps the saved connection without automatically replaying mutations. Revoked credentials require an explicit reconnect.

## Contributor checks

From this directory:

```sh
bun install
bun test
bun run typecheck
```

The packaged `scripts/verify_release_runtime_boot --single <tarball> --profile lemon_bot`
gate uses a clean HOME, verifies the web build, consumes the real one-use setup
code privately, and uploads a valid PNG through the authenticated API to exercise
the on-disk native image decoder. Version/help do not load native image libraries;
their success alone is not evidence the image pipeline works.
The executable includes Sharp's complete JavaScript dependency graph. Only the
host-native addon and its sibling libvips shared libraries remain on disk; native
loading uses an absolute executable-relative path, not runtime package lookup.
On HTTP failure the gate prints only status/API classification and bounded,
allowlisted native-image diagnostic classifications. It never prints raw backend
errors, private logs, setup codes, session tokens or filesystem paths.

Live verification requires an enrolled machine and real provider configuration for the integrations being exercised.
