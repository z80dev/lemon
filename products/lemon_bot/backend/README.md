# Lemon Bot backend

A Bun HTTP/WebSocket service for personally owned assistants attached to an existing Lemon controller. Each named Bot runs for its owner on that person’s machine. Groups coordinate 2–6 of the same owner’s Bots. See the [API](../contracts/api.md), [protocol](../contracts/protocol.ts), and [cards](../contracts/cards.md) for wire resources and authorization.

## Run
### Standalone installation

The canonical release installer supports `--profile lemon_bot` on Linux x86_64,
Linux arm64 and macOS arm64. Follow the [versioned release installation
guide](../../../docs/release/versioning_and_channels.md). The bundle contains
`bot/bin/lemon-bot`, the complete external `bot/web` app, and its native image
dependencies; running it requires no installed Bun, Node, Elixir or source checkout.
Configure the same private environment below, then run `lemon-bot` rather than
`bun run start`. `lemon-bot --version` reports the exact release CalVer and
`lemon-bot --help` describes startup; neither initializes private product state.

Keep `LEMON_BOT_DATA_DIR`, private operator configuration and server credential
sources outside the versioned installation. Installing the backend does not
install or replace the controller/worker: those use canonical full/min runtime
profiles, and newly invited workers install the matching published Lemon release.
An empty backend prints its real one-use local setup code; open its web origin
and consume that code to create the owner. Never put the controller operator
credential in a browser, generated join command, archive or public log.

### Source development


Use Bun 1.4 or newer. Start the existing authenticated Lemon controller and configure provider credentials on each execution host. From this directory:

```sh
bun install
export LEMON_BOT_CONTROL_URL='ws://127.0.0.1:4040/ws'
export LEMON_BOT_OPERATOR_TOKEN='<existing Lemon operator token>'
export LEMON_BOT_PUBLIC_URL='http://127.0.0.1:4080'
export LEMON_BOT_DATA_DIR="$HOME/.lemon/lemon_bot"
bun run start
```

`bun run dev` enables Bun watch mode. Source execution loads `../web/dist`; build the web product separately with `bun --cwd ../web run build`. Packaged execution loads `bot/web` beside its executable independently of the working directory. `LEMON_BOT_WEB_ROOT` explicitly overrides either layout. Missing web assets produce an explicit installation response without disabling the API. The empty deployment prints a one-use setup code to the operator terminal. It is never part of `/setup`, static assets, ordinary request logs, or clients' configuration. An unused code is encrypted in the private database and remains usable across restart; successful setup consumes it atomically.

The public origin must be reachable from execution hosts for the bot MCP endpoint. Use reachable HTTPS, normally Tailscale Serve, for managed Bot provisioning and phone connections. A loopback public URL supports same-machine API/Simulator development but is not evidence that an enrolled worker shares the backend's network namespace. Supply the configured public origin through the proxy; arbitrary browser origins are rejected. Authenticated product clients connect to `/v1` and `/v1/realtime`, never directly to the controller.

Operator `approvedPrivateMcpOrigins` explicitly approves private first-party origins. Literal-loopback HTTP is permitted only for the configured first-party origin. Bot provisioning still requires a reachable address and verified machine placement. See the [provider guide](../providers.md) for the validated operator configuration.

| Environment | Requirement / default |
| --- | --- |
| `LEMON_BOT_CONTROL_URL` | Required exact credential-free controller `/ws` URL. |
| `LEMON_BOT_OPERATOR_TOKEN` | Required existing controller operator credential, server-only. |
| `LEMON_BOT_PUBLIC_URL` | Required product origin; HTTPS off loopback. |
| `LEMON_BOT_DATA_DIR` | Required private persistent directory. |
| `LEMON_BOT_HOST`, `LEMON_BOT_PORT` | `127.0.0.1`, `4080`; listener binding. |
| `LEMON_BOT_ENCRYPTION_KEY` | Optional base64 32-byte durable key; otherwise generated private `master.key`. |
| `LEMON_BOT_CONFIG_FILE` | Optional operator JSON file; otherwise DATA_DIR/config.json. Missing file uses the validated empty provider configuration. |
| `LEMON_BOT_TRUSTED_OVERLAY` | Default false. Set exactly `true` only when off-loopback HTTP/WS is protected by an operator-trusted encrypted overlay. Not a general TLS bypass. |
| `LEMON_BOT_WEB_ROOT` | Optional explicit web assets directory; otherwise source `web/dist` or packaged `bot/web`. |
| `LEMON_BOT_RUNTIME_LAUNCHER` | Optional absolute path to an existing executable Lemon launcher (`<checkout>/bin/lemon` or installed `lemon`); invalid paths fail startup. Enables owner-only start/stop/restart only for a loopback controller. |

Workspace Owners and Admins can inspect the attached instance with `GET /v1/instance` and reconnect its controller link with `POST /v1/instance/reconnect`. Owners alone can invoke `POST /v1/instance/runtime/start`, `/stop`, or `/restart` when the launcher is configured and the controller is local. Stop/restart require `confirm:true`; POSTs require `clientNonce`. A 202 response is an operation receipt, not proof the controller is healthy: poll instance status for completion and connection state. Launcher commands run without a shell, with all `LEMON_BOT_*` environment variables stripped, a five-minute deadline, and a 4096-byte output tail. Runtime operations are in-memory and disappear on backend restart.

Provider, identity, push, image, network/egress and host-management configuration belongs to the integration team's [provider guide](../providers.md) and the canonical operator configuration. Missing credentials affect only dependent operations and report a precise prerequisite. Bot tokens and product sessions are different principals; neither exposes the Lemon operator token. Configured backend secret references resolve only explicit private environment/file sources. Destination MCP header `${LEMON_SECRET:NAME}` values resolve only on the execution machine.

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
