# Lemon Bot backend

A Bun HTTP/WebSocket service for personally owned assistants attached to an existing Lemon controller. Each named Bot runs for its owner on that person’s machine. Groups coordinate 2–6 of the same owner’s Bots. See the [API](../contracts/api.md), [protocol](../contracts/protocol.ts), and [cards](../contracts/cards.md) for wire resources and authorization.

## Run
### Standalone installation

Use [Lemon Bot getting started](../../../docs/getting-started/lemon-bot.md) for the Mac app, combined Terminal installer and first sign-in; use [attaching a bot machine](../../../docs/user-guide/attaching-a-bot-machine.md) for additional workers. The combined `bot` preset installs matching runtime and backend versions. The `lemon_bot` profile is backend-only for existing controllers and manual/remote deployments.

The Linux x86_64, Linux arm64 and macOS arm64 backend bundle contains `bot/bin/lemon-bot`, production `bot/web` assets and native image dependencies. Running the backend requires no installed Bun, Node, Elixir or source checkout. The Terminal installer itself still requires `python3`; this is separate from the Mac app's native installer and bundled runtime Python.

`lemon-bot --version` and `--help` do not initialize private product state. Interactive plain startup delegates to `up` when the runtime launcher exists; without it, startup falls back to a foreground backend and prints a pinned install command. `--no-open`, service mode and non-terminal plain startup remain foreground servers. Explicit `up --no-open` instead requests service setup without browser handoff, and `up --no-worker` skips local enrollment.

Default listener/state: `http://127.0.0.1:4100`, `~/.lemon/lemon_bot`. Keep data, private operator configuration and credentials outside versioned installations. Controller choice is stored in private `controller.json`, with remote tokens encrypted; explicit environment overrides take precedence. Never put the controller operator token in clients, join commands, archives or logs.

### Source development


Use Bun 1.4 or newer. Model/provider credentials on execution hosts are needed for Bot work, not owner setup or management. From this directory:

```sh
bun install
bun run start
```

`bun run start` uses the CLI startup modes above; `bun run dev` uses the same CLI with Bun watch mode, not a separate foreground-only entrypoint. Source execution loads `../web/dist`; build the web product separately with `bun --cwd ../web run build`. Packaged execution loads `bot/web` beside its executable independently of the working directory. `LEMON_BOT_WEB_ROOT` explicitly overrides either layout. Missing web assets produce an explicit installation response without disabling the API. Startup logs never contain setup credentials.

The public origin must be reachable from execution hosts for the bot MCP endpoint.
Use reachable HTTPS, normally Tailscale Serve, for remote workers and phone
connections. A loopback public URL supports same-machine use after the backend
verifies shared-host placement. SSH-assisted workers can instead use the managed
reverse product tunnel described in [machine attachment](../../../docs/user-guide/attaching-a-bot-machine.md#add-a-machine-over-ssh).
Supply the configured public origin through the proxy; arbitrary browser origins
are rejected. Authenticated product clients use `/v1` and `/v1/realtime`, never
the operator WebSocket.

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

The canonical [getting-started guide](../../../docs/getting-started/lemon-bot.md) covers passwordless local browser sign-in, SSH handoff and remote account sign-in. OS-account access is authority: tailnet reachability or knowing a product URL alone is not.

`lemon-bot open` verifies the running backend's exact instance/version before issuing a one-use ticket. Browser delivery passes a private handoff-file path, not the ticket, in opener argv. Headless delivery requires a controlling terminal before issuance and writes the sensitive link there, never to stdout/stderr. `open` needs a literal-loopback listener even when the configured public origin is HTTPS.

Native/CLI local sign-in uses `POST /v1/auth/local` with the same user's private `DATA_DIR/local-access.key`. The backend re-reads that key per request; an empty instance creates a passwordless owner and workspace. This returns an ordinary bounded product session, not operator authority. Apple clients' credential-storage and transport details are in the [Apple README](../apple/README.md#connect-the-mac-app).

## Provider-free owner setup

Owner sign-in, phone pairing and management do not require model credentials or a default model. Connect a model on the execution target before expecting replies; see [model setup](../../../docs/user-guide/setup.md).

The canonical [getting-started guide](../../../docs/getting-started/lemon-bot.md) explains when to use local sign-in versus the operator-issued `lemon-bot setup` proof. For source development its equivalent is `bun src/cli.ts setup`; `setup --print-origin` performs discovery only, and explicit `--same-machine` permits literal-loopback development, not physical-phone readiness.

Proof issuance verifies the configured tailnet HTTPS origin against the private instance identity, requires a controlling terminal and writes the five-minute one-use code only there. It does not start services, configure networking or sign in to a provider. Claiming is fenced against duplicate owner/session creation; already configured instances refuse re-bootstrap. See the [preflight contract](../contracts/preflight.md) and API for proof expiry, attempt limits and reconciliation semantics.

## Runtime prerequisites

The controller must support Bot profiles, machine placement, message submission and cancellation, live events, enrollment, files, terminals, secrets, connected tools and profile memory. Capabilities reflect support discovered from the connected controller. Unsupported or offline operations fail explicitly.

Scheduled agent work remains Lemon cron. Its pre-launch admission callback authenticates an independent private controller secret, binds the exact routine/profile/creator/workspace/job and reserved run identities, and checks current product ACL, policies and spend ceilings **before** dispatch. Configure `LEMON_CRON_ADMISSION_ALLOWED_ORIGINS` on the controller with the exact product origin. HTTPS is required except explicitly allowlisted literal loopback HTTP (`127.0.0.1` or `[::1]`) for local development. The narrow authenticated `cron.admission.set` RPC provisions generated per-routine credentials into the controller's encrypted secret store; clients never receive them. A denied, unavailable, mismatched or timed-out admission does not launch a run and is not automatically retried. Routines using external providers also require the declared event/adapter credentials. One-off reminders are notification outbox deadlines, not cron agent jobs.

Native continuations use a separate authenticated issuer: configure `LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS` on the controller with the exact product origin. Bot provisioning calls `profile.followup.admission.set` and requires its exact acknowledgement before readiness. The internal admission route looks up authoritative `runs.followup.lineage.get` data for the fixed fresh run, retains the actual source principal, applies current target authority plus inherited restrictive floors, and provisions that run's own invocation proof. An unavailable/denied issuer cannot silently fall back to profile-owner credentials. See [runtime prerequisites](src/runtime/README.md) for the bounded receipt and uncertainty lifecycle.

Co-resident Bots share the OS user's files/browser/CLI identities: product authorization and native tool policy do not claim OS isolation. Bots and their execution machines must have the same actual owner. Explicit host-management authority remains a separate administrative capability, not a grant to another person's Bot, persona, credentials or chat.

## Persistence and lifecycle

`product.sqlite` uses WAL and holds product entities, encrypted receipts/private metadata, auth token digests, revision/confirmation fences and a monotonically increasing persisted event sequence. Attachments are immutable checksum-checked private blobs under DATA_DIR/attachments; tickets are short-lived and recheck current access. Keep database, WAL, attachment blobs and master key together in operator backups. Losing/changing a key with existing encrypted state fails closed; do not replace the key to recover an empty-looking deployment.

### Resumable background setup

```sh
lemon-bot up [--json] [--no-open] [--no-worker] [--name NODE_NAME] [--worker-wrapper PATH]
```

`up` reuses an online machine, repairs its existing worker first, or requests a
name-bound reconnect invite. New-name conflicts try suffixes `-2` through `-4`.
When `--worker-wrapper` is supplied, even an online worker is repaired if its
service status reports a different or missing `execWrapper`. The repair uses
`--exec-wrapper` without issuing an invite; rerunning with the same wrapper is
unchanged. A failed migration is a service failure, not a reason to re-enroll.
The one-use code goes only to `lemon service install worker --invite-code-stdin`
through stdin; it never enters argv, environment, diagnostics or progress. An
uncertain enrollment is reconciled once from that invite's authoritative state,
never resent. Only a confirmed joined invite permits one fresh bound reconnect.
The temporary local-owner session is signed out in `finally`; if logout fails,
the CLI warns that it must be revoked in Account settings.

The final browser handoff invokes `lemon-bot open` with the inherited terminal
(over SSH: `open --headless`). It is omitted without a terminal or with `--no-open`.
Linux session-only persistence prompts before requesting linger; Lemon never
invokes sudo. Manager/persistence values come from `lemon service`, not guesses.

`--json` writes NDJSON to stdout: step events with
`type:"step"`, `step:"runtime|controller_choice|setup|units|linger|owner|machine|worker"`,
`state:"running|ok|skipped|failed"` and a stable `detail` or null, followed by
exactly one result:

```json
{"type":"result","status":"ready","port":4100,"machineId":"machine_id","manager":"launchd","persistence":"login"}
```

Result statuses are `ready`, `runtime_missing`, `setup_required`, `service_failed`,
`enroll_failed` or `needs_attention`; only `ready` exits 0. A runtime mismatch
warns in human mode and blocks JSON automation with `needs_attention`.
`runtime_missing` also includes the pinned, non-secret `installCommand`.
Diagnostics and prompts go to stderr. Secrets are never progress fields.

After listen the backend records
`DATA_DIR/run/lemon-bot-<port>.json` (0600) with `pid`, `startedAt` (the process's
`ps -o lstart=` identity), `port`, `instanceId` and `version`. Clean shutdown
removes only its own unchanged record. Lifecycle takeover uses this identity
together with the public setup fingerprint; a PID alone is not ownership.

Source service installs use the executable `bin/lemon-bot-source` shim.

Mutations reserve their nonce and fixed IDs before external work. Identical concurrent intents share their exact receipt, different bodies conflict, and replay rechecks current resource ACL and authentication authority. Public local-auth replay revalidates current credentials. Pending/uncertain effects survive restart as fenced state; the service reconciles only owning read-only receipts/history, never automatically replays a mutation. A user-visible accepted run is not a completed task, cancellation requested is not terminal cancellation, approval is not execution, and explicit draft Send is separate from permission gates.

Product MCP tools verify the calling Bot and run before reading tool arguments. Credentials use reserved destination-local `lemon_bot/` secret names. Handoffs preserve the owner and verified reply destination. Groups route work to selected owned Bots; rejected targets are reported separately. Memory is stored in the assigned Lemon profile.

Account deletion revokes sessions and fences token issuance before cleanup. It completes reachable product cleanup independently of provider failures; an unconfirmed external revocation remains `outcome_unknown`. The remaining workspace Owner can inspect the bounded, read-only `/v1/account-teardowns` list and detail resources after the deleted account loses its sessions. These expose stages, timestamps, request IDs and actual provider receipt observations—not private transcripts, credentials, login restoration, or a replay button. The final Owner must explicitly transfer ownership before deletion.

Realtime changes and events commit together before publication. Reconnect restores only currently authorized data; an expired cursor requires a fresh `/sync` snapshot. Terminal output has separate buffering and device authorization. Voice sessions retain a disconnect grace period and transcript summary; microphone capture, dictation review and speech playback are controlled by the client.

## Connect an iPhone

Follow [Lemon Bot getting started](../../../docs/getting-started/lemon-bot.md) for reachable HTTPS, pairing and revocation. An owner-approved phone gets a separate device-bound product session that lasts until revoked, not merely until the one-use QR expires.

The [preflight contract](../contracts/preflight.md) defines exact origin, instance and workspace checks. Controller health, Lemon Web/Phoenix and an HTTP 200 landing page are not the Bot API. Pairing reconciliation uses its original nonce/deadline; it is not permission to replay ordinary mutations.

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
