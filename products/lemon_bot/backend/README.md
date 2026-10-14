# Lemon Bot backend

A separate Bun HTTP/WebSocket owner-assistant service attached to an existing Lemon controller. Each named Bot runs for the person who owns it, on that person's execution host. Groups coordinate 2–6 of that owner's Bots; workspace roles never grant another person's live Bot access. There are no Team Bots, managers, publication grants or cross-user connector lending. The product is not Lemon Web, the TUI, a second swarm, or a second agent scheduler. Wire resources and authorization are defined in [the canonical API](../contracts/api.md), [protocol](../contracts/protocol.ts), and [cards](../contracts/cards.md).

## Run
### Verified standalone installation

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

Operator `approvedPrivateMcpOrigins` binds private first-party origins explicitly. The parser permits literal-loopback HTTP only for the exact configured first-party origin; this does not grant arbitrary loopback/private connector destinations or prove placement locality. Managed Bot provisioning still refuses loopback without an authoritative same-host binding. Operator settings are validated as `OperatorConfiguration`; there is no untyped extras bag.

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

Provider, identity, push, image, network/egress and host-management configuration belongs to the integration team's [provider guide](../providers.md) and the canonical operator configuration. Missing credentials affect only dependent operations and report a precise prerequisite. Bot tokens and product sessions are different principals; neither exposes the Lemon operator token. Configured backend secret references resolve only explicit private environment/file sources. Destination MCP header `${LEMON_SECRET:NAME}` values resolve only on the execution machine.

## Runtime prerequisites

Use the platform implementation shipped with this product, including placed `chat.send`/profile execution, fixed submission receipts, actual cancellation/steer outcomes, named-node live events, enrollment invites, policy-rooted files, PTYs, write-only secrets, profile MCP clients, profile-scoped memory and native policy floors. Capabilities advertise the methods actually discovered from the connected controller. Unsupported or offline operations fail explicitly; absence of an acknowledgment is not reported as success.

Scheduled agent work remains Lemon cron. Its pre-launch admission callback authenticates an independent private controller secret, binds the exact routine/profile/creator/workspace/job and reserved run identities, and checks current product ACL, policies and spend ceilings **before** dispatch. Configure `LEMON_CRON_ADMISSION_ALLOWED_ORIGINS` on the controller with the exact product origin. HTTPS is required except explicitly allowlisted literal loopback HTTP (`127.0.0.1` or `[::1]`) for local development. The narrow authenticated `cron.admission.set` RPC provisions generated per-routine credentials into the controller's encrypted secret store; clients never receive them. A denied, unavailable, mismatched or timed-out admission does not launch a run and is not automatically retried. Routines using external providers also require the declared event/adapter credentials. One-off reminders are notification outbox deadlines, not cron agent jobs.

Native continuations use a separate authenticated issuer: configure `LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS` on the controller with the exact product origin. Bot provisioning calls `profile.followup.admission.set` and requires its exact acknowledgement before readiness. The internal admission route looks up authoritative `runs.followup.lineage.get` data for the fixed fresh run, retains the actual source principal, applies current target authority plus inherited restrictive floors, and provisions that run's own invocation proof. An unavailable/denied issuer cannot silently fall back to profile-owner credentials. See [runtime prerequisites](src/runtime/README.md) for the bounded receipt and uncertainty lifecycle.

Co-resident Bots share the OS user's files/browser/CLI identities: product authorization and native tool policy do not claim OS isolation. Bots and their execution machines must have the same actual owner. Explicit host-management authority remains a separate administrative capability, not a grant to another person's Bot, persona, credentials or chat.

## Persistence and lifecycle

`product.sqlite` uses WAL and holds product entities, encrypted receipts/private metadata, auth token digests, revision/confirmation fences and a monotonically increasing persisted event sequence. Attachments are immutable checksum-checked private blobs under DATA_DIR/attachments; tickets are short-lived and recheck current access. Keep database, WAL, attachment blobs and master key together in operator backups. Losing/changing a key with existing encrypted state fails closed; do not replace the key to recover an empty-looking deployment.

Mutations reserve their nonce and fixed IDs before external work. Identical concurrent intents share their exact receipt, different bodies conflict, and replay rechecks current resource ACL and authentication authority. Public local-auth replay revalidates current credentials. Pending/uncertain effects survive restart as fenced state; the service reconciles only owning read-only receipts/history, never automatically replays a mutation. A user-visible accepted run is not a completed task, cancellation requested is not terminal cancellation, approval is not execution, and explicit draft Send is separate from permission gates.

The 18 product MCP tools authenticate an opaque native-invocation proof before inspecting tool arguments. A per-bot setup credential does not authorize a caller-selected run or conversation. Proof credentials live in reserved destination-local `lemon_bot/` secret names; ordinary secret editing and connector bindings must not repurpose that namespace. Handoffs retain the actual owner and verified return audience. Group routing wakes each selected owned Bot once; a proven refused target is **rejected**, not queued or uncertain. Memory uses the owned assigned Lemon profile rather than a second SQLite notes store.

Account deletion revokes sessions and fences token issuance before cleanup. It completes reachable product cleanup independently of provider failures; an unconfirmed external revocation remains `outcome_unknown`. The remaining workspace Owner can inspect the bounded, read-only `/v1/account-teardowns` list and detail resources after the deleted account loses its sessions. These expose stages, timestamps, request IDs and actual provider receipt observations—not private transcripts, credentials, login restoration, or a replay button. The final Owner must explicitly transfer ownership before deletion.

Realtime state changes/events commit together before publication. Resume applies current ownership; deletion events retain scoped tombstones and expired replay requires a fresh atomic `/sync` snapshot. Terminal output has a separate bounded spool and opening-user/device authority. Voice state has a durable disconnect grace and terminal transcript summary; microphone capture, dictation review and STT/TTS loops remain client-owned. No per-bot desktop or screen streaming is provided.

## Connect an iPhone

Configure a reachable HTTPS `LEMON_BOT_PUBLIC_URL`; Tailscale Serve on the desktop is the recommended deployment. The product does not provision Tailscale or host a networking relay. Loopback HTTP is only for same-machine development/Simulator and cannot attach a remote phone.

The desktop owner creates a five-minute one-use pairing QR. The phone previews the exact cluster/origin, claims it with its installation identity, and displays the same six-digit verification code as the desktop. The owner approves that device once. Completion privately returns one device-bound product session for Keychain storage; it remains valid until revoked, not until the QR expires. QR URLs never contain an operator credential, desktop session, or permanent phone token.

Pending completion evolves with the same nonce. Lost completion responses replay the same encrypted session receipt only before the original five-minute deadline; after that, pair again rather than mint another session. Existing connected credentials survive QR expiry, but device deletion, account/workspace revocation and logout revoke their actual authority. A paired bearer cannot register another installation to evade its device binding. Desktop-only pairing events contain safe state, never credentials; clients without an identified desktop device can use the owner list/detail endpoints.

Reopening a paired app restores its saved cluster/account selection. Offline state keeps the saved connection without automatically replaying mutations. Revoked credentials require an explicit reconnect.

## Central verification

Implementation workers intentionally do not run installation, compilation, tests, formatting or linting. After all product/platform teams are merged, the integration owner should run:

```sh
bun install
bun run typecheck
bun test
bun run start
```

The packaged `scripts/verify_release_runtime_boot --single <tarball> --profile lemon_bot`
gate uses a clean HOME, verifies the web build, consumes the real one-use setup
code privately, and uploads a valid PNG through the authenticated API to exercise
the on-disk native image decoder. Version/help do not load native image libraries;
their success alone is not evidence the image pipeline works.

Behavioral tests cover actual persistence, authentication/ACL, nonce conflicts/concurrency/restart fences, revision/confirmation binding, group routing, targeted gate races/deadlines, attachment tickets/ranges/provenance, voice concurrency, and runtime adapter boundaries. These commands are prescribed checks, not a claim that they were exercised. Live verification also requires an enrolled host and real provider configuration for the corresponding integrations.
