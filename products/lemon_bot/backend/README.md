# Lemon Bot backend

A separate Bun HTTP/WebSocket product service attached to an existing Lemon controller. The product is not Lemon Web, the TUI, a second swarm, or a second agent scheduler. Wire resources and authorization are defined in [the canonical API](../contracts/api.md), [protocol](../contracts/protocol.ts), and [cards](../contracts/cards.md).

## Run

Use Bun 1.4 or newer. Start the existing authenticated Lemon controller and configure provider credentials on each execution host. From this directory:

```sh
bun install
export LEMON_BOT_CONTROL_URL='ws://127.0.0.1:4040/ws'
export LEMON_BOT_OPERATOR_TOKEN='<existing Lemon operator token>'
export LEMON_BOT_PUBLIC_URL='http://127.0.0.1:4080'
export LEMON_BOT_DATA_DIR="$HOME/.lemon/lemon_bot"
bun run start
```

`bun run dev` enables Bun watch mode. The backend loads `../web/dist` at runtime; build the web product separately with `bun --cwd ../web run build`. Missing web assets produce an explicit installation response without disabling the API. The empty deployment prints a one-use setup code to the operator terminal. It is never part of `/setup`, static assets, ordinary request logs, or clients' configuration. An unused code is encrypted in the private database and remains usable across restart; successful setup consumes it atomically.

The public origin must be reachable from execution hosts for the bot MCP endpoint. A loopback public URL works only for local development, not remote machines. Put exposed listeners behind HTTPS/WSS. Supply the configured public origin through the proxy; arbitrary browser origins are rejected. Authenticated product clients connect to `/v1` and `/v1/realtime`, never directly to the controller.

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

Provider, identity, push, image, network/egress and host-management configuration belongs to the integration team's [provider guide](../providers.md) and the canonical operator configuration. Missing credentials affect only dependent operations and report a precise prerequisite. Bot tokens and product sessions are different principals; neither exposes the Lemon operator token. Configured backend secret references resolve only explicit private environment/file sources. Destination MCP header `${LEMON_SECRET:NAME}` values resolve only on the execution machine.

## Runtime prerequisites

Use the platform implementation shipped with this product, including placed `chat.send`/profile execution, fixed submission receipts, actual cancellation/steer outcomes, named-node live events, enrollment invites, policy-rooted files, PTYs, write-only secrets, profile MCP clients, profile-scoped memory and native policy floors. Capabilities advertise the methods actually discovered from the connected controller. Unsupported or offline operations fail explicitly; absence of an acknowledgment is not reported as success.

Scheduled agent work remains Lemon cron. Its pre-launch admission callback authenticates an independent private controller secret, binds the exact routine/profile/creator/workspace/job and reserved run identities, and checks current product ACL, policies and spend ceilings **before** dispatch. Configure `LEMON_CRON_ADMISSION_ALLOWED_ORIGINS` on the controller with the exact product origin. HTTPS is required except explicitly allowlisted literal loopback HTTP (`127.0.0.1` or `[::1]`) for local development. The narrow authenticated `cron.admission.set` RPC provisions generated per-routine credentials into the controller's encrypted secret store; clients never receive them. A denied, unavailable, mismatched or timed-out admission does not launch a run and is not automatically retried. Routines using external providers also require the declared event/adapter credentials. One-off reminders are notification outbox deadlines, not cron agent jobs.

Shared machine labels and host-management authority are deliberate operator/admin grants. Co-resident bots share the OS user's files/browser/CLI identities: product ACL and native tool policy do not claim OS isolation. A Team member's private DM, notes and invocation credentials are never inherited from another member or silently replaced with the bot owner's credentials.

## Persistence and lifecycle

`product.sqlite` uses WAL and holds product entities, encrypted receipts/private metadata, auth token digests, revision/confirmation fences and a monotonically increasing persisted event sequence. Attachments are immutable checksum-checked private blobs under DATA_DIR/attachments; tickets are short-lived and recheck current access. Keep database, WAL, attachment blobs and master key together in operator backups. Losing/changing a key with existing encrypted state fails closed; do not replace the key to recover an empty-looking deployment.

Mutations reserve their nonce and fixed IDs before external work. Identical concurrent intents share their exact receipt, different bodies conflict, and replay rechecks current resource ACL and authentication authority. Public local-auth replay revalidates current credentials. Pending/uncertain effects survive restart as fenced state; the service reconciles only owning read-only receipts/history, never automatically replays a mutation. A user-visible accepted run is not a completed task, cancellation requested is not terminal cancellation, approval is not execution, and explicit draft Send is separate from permission gates.

Realtime state changes/events commit together before publication. Resume applies current ACL; deletion events retain scoped tombstones, private projections remain viewer-specific, and expired replay requires a fresh atomic `/sync` snapshot. Terminal output has a separate bounded spool and opening-user/device authority. Voice state has a durable disconnect grace and terminal transcript summary; microphone capture, dictation review and STT/TTS loops remain client-owned. No per-bot desktop or screen streaming is provided.

## Central verification

Implementation workers intentionally do not run installation, compilation, tests, formatting or linting. After all product/platform teams are merged, the integration owner should run:

```sh
bun install
bun run typecheck
bun test
bun run start
```

Behavioral tests cover actual persistence, authentication/ACL, nonce conflicts/concurrency/restart fences, revision/confirmation binding, group routing, targeted gate races/deadlines, attachment tickets/ranges/provenance, voice concurrency, and runtime adapter boundaries. These commands are prescribed checks, not a claim that they were exercised. Live verification also requires an enrolled host and real provider configuration for the corresponding integrations.
