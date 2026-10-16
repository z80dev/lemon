# Lemon Bot

Durable named **personally owned AI assistants** with a job, identity, skills, memory, routines, files, voice and **a machine you own**. Lemon Bot is a separate Bun/TypeScript application plugged into one running Lemon swarm. Web, macOS and iOS share one product API; iOS persistently pairs with your reachable desktop cluster through a short-lived QR and one desktop device approval. No client receives the swarm operator credential. Lemon Bot does not replace Lemon Web or the TUI.

Bots remain active when clients close. They stop being able to execute when their assigned machine or controller is unavailable: closed app and offline host are different states. Multiple bots on one machine share that OS user's files, browser sessions and CLI credentials. A bot persona/profile is not an OS sandbox; separate machines/users/containers are needed for hard isolation. The operator keeps SSH, files, terminal and host access.

## Source of truth

- [API and screens](contracts/api.md): HTTP/auth/ACL/nonce/replay, MCP tools, voice, integrations, deployment/provider prerequisites and all client destinations.
- [Wire types](contracts/protocol.ts): dependency-free request/response/resources/events, imported by backend and SDK; Swift mirrors these discriminated unions and nullability.
- [Transcript/cards](contracts/cards.md): transcript entry kinds and interactive card behavior.
- [Behavioral coverage](contracts/coverage.md): supported use cases and provider/host prerequisites.

## Architecture

```text
 macOS app ─┐
 iOS app ───┼── HTTPS + WSS ──► Lemon Bot backend ── operator /ws ──► Lemon control plane
 Web app ───┘   /v1 product API    │  SQLite             one swarm          │
                                  │  MCP /mcp (bot tools) ◄───────────────┤ named execution nodes
                                  │  APNs / Web Push                       │ = attached machines
                                  └─ webhooks /hooks/:routineId             └─ bots execute here
```

The backend stores accounts, sessions, device pairing, Bot groups, transcripts, attachments, notifications and integrations. Each Bot’s private content and live work belong to its human owner. Lemon provides execution, scheduling and machine access. Clients receive product sessions; the backend keeps the operator credential private.

| Component | Location | Role |
|---|---|---|
| Contracts | `contracts/` | Authoritative protocol, schemas, lifecycle, screens and coverage |
| Backend | `backend/` | Bun.serve, bun:sqlite, Lemon adapter, product REST/realtime, MCP, attachments, push, OIDC/SCIM/integrations/host-management adapters |
| TypeScript SDK | `sdk/ts/` | Typed HTTP, nonces, cursor reconnect and discriminated events; no operator credential |
| Web | `web/` | React/Vite responsive Bot-centric workspace and command palette; served by backend in production |
| Shared Apple kit | `apple/LemonBotKit/` | Swift models, authenticated API/socket, secure sessions/cache, deep-link routing |
| macOS | `apple/LemonBotMac/` | SwiftUI workspace, optional selected-bot compact companion, optional Codex-compatible [desktop pet](apple/LemonBotMac/DesktopPet.md) and configurable global summon/PTT mini-composer |
| iOS | `apple/LemonBotiOS/` | SwiftUI own-Bot workspace, QR scanner/paste-link pairing, Keychain connection restore, camera/files, explicit voice and share extension |

Every Bot has an assigned machine, a Lemon profile and an owner conversation. Tasks use independent sessions; groups coordinate 2–6 Bots owned by the same person. Identity, Job and Memory can be reviewed separately, including preference changes and undo. Workspace/Public templates create reviewed copies owned by the recipient.

Setup starts with a named assistant and a machine, with optional phone pairing. Usage shows provider spend and limits. Integrations and host controls depend on configured providers and permissions.

Instance provider rows show the last observed Lemon provider failure and its time.
The runtime retains one bounded, credential-free category summary per provider,
including authentication and rate-limit failures; successful calls do not erase
that history. It is in-memory diagnostic history, cleared when Lemon restarts,
not a live provider probe. Raw provider messages, paths and credentials are never
included in `providers[].lastError`.

## Running an integrated checkout

Requirements: a running authenticated Lemon controller with the required profile, placement, node-I/O, memory and live-stream RPCs; Bun 1.4+; Node 24 for Vite tooling. Owner setup and the management API work with zero model-provider credentials or default model. Bot execution later requires a supported controller default model and destination-local provider authentication; `lemon setup` configures those locally. Native builds use Xcode 26.3 and XcodeGen 2.46; signing and provisioning are required for installed Apple devices.

1. Start/reuse **the existing swarm**, following the repository [CLI guide](../../docs/user-guide/cli.md). Its configured `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` is the credential used below; do not generate a second unrelated product operator token. Default loopback control URL is `ws://127.0.0.1:4040/ws`. Configure WSS/reverse proxy for non-loopback.
2. Set backend environment in your service manager/private environment file, never commit it:

```bash
export LEMON_BOT_CONTROL_URL='ws://127.0.0.1:4040/ws'
export LEMON_BOT_OPERATOR_TOKEN='<existing controller operator token>'
export LEMON_BOT_PUBLIC_URL='http://127.0.0.1:4080'
export LEMON_BOT_DATA_DIR="$HOME/.lemon/lemon_bot"
export LEMON_BOT_HOST='127.0.0.1'
export LEMON_BOT_PORT='4080'
bun --cwd products/lemon_bot/backend install
bun run --cwd products/lemon_bot/backend start
```

`LEMON_BOT_PUBLIC_URL` is the externally reachable product origin, **not** control-plane URL. Registered bot MCP URLs, webhook URLs, OAuth callbacks and attachment downloads derive from it. Every execution node must reach it (loopback public URL cannot serve a remote node). Production uses HTTPS and matching WSS, trusted proxy origin/header validation and private data directory ownership. Backend `start` serves production built web when present; `dev` runs backend watch mode. Startup logs never contain setup credentials: on an empty DB, run the explicit local [`lemon-bot setup`](backend/README.md#provider-free-owner-setup) command (`bun src/cli.ts setup` from the backend source directory). It prints a verified tailnet HTTPS origin separately from a sensitive five-minute single-use proof shown only on the controlling terminal. Open that origin on phone/Web and use the existing owner setup form before any LLM sign-in. Normal accounts use local login/invite or configured OIDC; anonymous setup exposes only the minimal product/setup/pairing fingerprint, never workspace/account identity or setup credentials.

3. Web development and production assets:

```bash
bun --cwd products/lemon_bot/web install
bun run --cwd products/lemon_bot/web dev
# Production web assets consumed by backend:
bun run --cwd products/lemon_bot/web build
```

The web dev server runs at `http://127.0.0.1:4081`. Its `/v1` (including realtime WebSocket), `/hooks` and `/mcp` requests proxy to `http://127.0.0.1:4080`; set `LEMON_BOT_DEV_BACKEND` in the web development environment to use another backend origin. The Vite dev socket is separate from product realtime. Web never connects directly to Lemon `/ws`.

4. Native apps: generate `apple/project.yml` with XcodeGen, open `apple/LemonBot.xcodeproj`, choose LemonBotMac or LemonBotiOS, and configure signing/App Group/APNs for installed devices. macOS uses the product backend URL; iPhone uses the QR/paste-link flow below to persistently attach to that desktop cluster. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` is the reference toolchain. Share extension exchanges only explicit user-selected content through App Group, never operator authority. Credentials use Keychain. Task `lemonbot://` links contain resource IDs only; short-lived pairing QR is a separate secret-bearing account-security flow.

### Connect iPhone persistently to the desktop cluster

1. Assume desktop/phone Tailscale reachability is already configured. Set `LEMON_BOT_PUBLIC_URL` to the exact reachable HTTPS product origin (Tailscale Serve is recommended), for example `https://desktop.<tailnet>.ts.net`; every attached worker must reach it too. Lemon Bot does not provision Tailscale, host networking or another auth service. Loopback HTTP is same-machine development/Simulator only, not an iPhone remote address or trust inferred from QR.
2. In macOS or the desktop web app choose **Connect iPhone**. Authenticated owner creates a five-minute one-use QR containing only product origin, backend instance ID, cluster ID and random pairing code: `lemonbot://pair?backend=<encoded-origin>&instance=<instanceId>&cluster=<workspaceId>&code=<one-use-code>`. No operator token, desktop session bearer or permanent credential. Verify the origin is the same Bot backend/workspace first using the shared [preflight contract](contracts/preflight.md), not a controller health check or Lemon Web/Phoenix response.
3. iPhone scans with camera permission or pastes that exact link. Read-only `/v1/pairings/preview` verifies stored code/cluster without consuming it. Review exact cluster name and HTTPS origin, then explicitly Request connection. Claim consumes QR authority once and displays the same six-digit device verification code on both devices.
4. Desktop owner reviews requesting device name/code and approves once (or denies). Only approval creates a distinct device-bound product session. Phone completes with one fixed nonce; pending/denied/expired are explicit. If response is lost, identical receipt reconciliation returns the **same** device/session until original five-minute deadline, never a second mint. After deadline re-pair explicitly.
5. Phone stores its own token and cluster/account/selected Bot/conversation in Keychain/local state. Paired `AuthSession.expiresAtMs` is explicit null until revoked, unlike normal bounded login sessions. Reopen restores connection; offline keeps it without replaying work. Existing Account → Devices/Sessions lists/revokes the phone; disabled/revoked authority shows Reconnect. QR/claim credentials never enter transcript, push, audit or logs.

This phone is a client of the same desktop owner and cluster, not a new shared Team member, execution machine or source of node/operator credentials. Camera/microphone/push remain explicit iOS permissions.

### Backend configuration

Required variables fail startup on omission/invalid configuration (no fake demo fallback). Backend private SQLite DB, attachment blobs, nonce receipts and encryption key reside under DATA_DIR; protect and back them up consistently. Restore validates metadata/blob checksums before changing live state. Generated encryption master key is private 0600; alternatively supply a durable operator-provided key. A changed/missing key with existing encrypted records fails closed, not a new empty credential store.

| Variable | Required/default | Purpose |
|---|---|---|
| `LEMON_BOT_CONTROL_URL` | Required | Exact controller `/ws` endpoint; off-loopback WSS unless trusted encrypted overlay explicitly configured |
| `LEMON_BOT_OPERATOR_TOKEN` | Required | Existing daemon operator token, server-only |
| `LEMON_BOT_PUBLIC_URL` | Required | Reachable HTTPS product origin, HTTP loopback for development |
| `LEMON_BOT_DATA_DIR` | Required | Private persistent SQLite/blobs/keys/config root |
| `LEMON_BOT_RUNTIME_LAUNCHER` | Optional | Absolute existing executable Lemon launcher; enables owner-only start/stop/restart for a loopback controller and takes precedence over controller RPCs. Invalid paths fail backend startup. Remote restart/stop instead require the connected controller's advertised lifecycle methods and permissions. |
| `LEMON_BOT_HOST` / `LEMON_BOT_PORT` | `127.0.0.1` / `4080` | Bun listener binding; expose only behind trusted TLS boundary |
| `LEMON_BOT_ENCRYPTION_KEY` | Optional, otherwise private generated key | Stable 32-byte base64 master key for product session/integration credentials; never returned to client |
| `LEMON_BOT_CONFIG_FILE` | Optional, otherwise DATA_DIR/config.json | Private operator provider, redirect, origin and host-management configuration |
| `LEMON_BOT_TRUSTED_OVERLAY` | `false` | Set exactly `true` only for off-loopback HTTP/WS protected by an operator-trusted encrypted overlay |
| `LEMON_BOT_WEB_ROOT` | Optional | Override source `web/dist` or packaged `bot/web` assets directory |
| `LEMON_BOT_APNS_KEY_ID` | Optional set, all APNs fields together | APNs token-auth key identifier |
| `LEMON_BOT_APNS_TEAM_ID` | APNs set | Apple developer team identifier |
| `LEMON_BOT_APNS_PRIVATE_KEY_PATH` | APNs set | Owner-readable `.p8` key, never committed |
| `LEMON_BOT_APNS_TOPICS` | APNs set | Comma-separated allowlisted native bundle topics |
| `LEMON_BOT_APNS_ENVIRONMENTS` | `sandbox,production` | Comma-separated allowed Apple push environments |
| `LEMON_BOT_WEB_PUSH_ORIGINS` | Built-in push-service origins | Comma-separated exact HTTPS push-service origins; see [providers](providers.md) |
| `LEMON_BOT_VAPID_PUBLIC_KEY` | Optional pair | Base64url Web Push public key published via capabilities |
| `LEMON_BOT_VAPID_PRIVATE_KEY` | VAPID pair | Server-only Web Push private key |
| `LEMON_BOT_VAPID_SUBJECT` | VAPID pair | `mailto:` or HTTPS contact URI |
| `LEMON_BOT_STT_PROVIDER` | Optional `openai` / `deepgram` | Real backend transcription provider; absent means capability false, on-device dictation still usable |
| `LEMON_BOT_TTS_PROVIDER` | Optional `openai` / `elevenlabs` / `google` | Backend speech provider |
| `LEMON_BOT_OPENAI_API_KEY` | When OpenAI voice/image selected | Server provider credential, separate from swarm/local destination provider auth |
| `LEMON_BOT_DEEPGRAM_API_KEY` | Deepgram STT | Server transcription credential |
| `LEMON_BOT_ELEVENLABS_API_KEY` | ElevenLabs TTS | Server synthesis credential |
| `LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH` | Google TTS | Private service-account credential file |
| `LEMON_BOT_IMAGE_PROVIDER` | Optional `openai` | Real avatar generation provider; absent keeps character/upload but generate unavailable |

### Optional providers and integrations

Push, voice and image providers publish their configured capabilities. Foreground/inbox notifications work without push. See the [provider reference](providers.md) for push origins, voice credentials and provider prerequisites.

Model/provider authentication for Bot execution belongs on each destination machine. Configure identity, email, channels, external event sources, audit destinations and host-management providers in the private operator configuration described in the [API reference](contracts/api.md). Each integration requires actual provider credentials and permissions.

Clients discover actual provider IDs and secret-free prerequisites through `GET /v1/integration-providers`; configured is distinct from a connected account. Optional private configuration includes `connectorProviders` (exact MCP origins/OAuth/shared-service-account permission), `approvedPrivateMcpOrigins` and `reviewedSetupManifests` (exact approved scripts/groups/machines/secret-name references). Omitted lists are empty; dependent operations fail explicitly until operator-reviewed configuration exists. Discovery never exposes secrets, private scripts or raw host command manifests.
Channel/email/X setup screens also consume typed `/v1/channels/providers`, `/v1/email/providers` and `/v1/x/provider` projections. Own channel-account linking starts through `/v1/channels/principal-links/start`, proves actual external sender then confirms the reviewed identity; `/v1/event-sources/:source` defines exact supported trigger/filter schemas.

OIDC additionally requires operator-only `oidcAllowedOrigins` and exact `oidcClientApprovals` `{origin,clientId,clientSecretRef}` bindings to existing `serverSecrets`. Both default empty; no credential is sent to an IdP merely because an Owner added its provider row. Public DNS is required unless the exact HTTPS origin also appears in `oidcApprovedPrivateOrigins` (subset of allowed origins). All endpoints, DNS/TLS and credential bindings are checked before discovery/exchange/logout/probes. Local bootstrap/password accounts remain usable; managed required SSO does not silently downgrade when these prerequisites are missing.

The strict private schema also types management-user grants, private export origins, reviewed OIDC group/subject mappings, separate public X credentials, provider-account spend sources, fixed channel application principals and managed-directory Owner override. These are operator-reviewed deployment inputs, not Owner-editable credential settings or an `operatorExtras` bag; see the [provider reference](providers.md) and API private-configuration sections for exact fields and real provider prerequisites.

Automated host management, setup, network/egress application and read-only driver probes use the owning noninteractive native destination process RPC: immutable reviewed argv, destination cwd, bounded JSON stdin and verified operation/config receipts. They never use or fall back to PTY/shell-command interpolation. PTY remains only the explicit user-facing machine terminal; missing process capability is unavailable rather than a hidden alternate execution path.

## Attach and manage a machine

1. Sign in as workspace owner/admin; open **Machines → Attach a machine**. Enter friendly name, durable unique nodeName, purpose/labels. Review that a trusted worker runs with its OS user's privileges and co-resident bots share files/logins.
2. Backend creates a short-lived, one-use `node.pair.invite` with purpose lemon_bot. Copy the server-returned **joinCommand** to the destination machine. It reuses a compatible Lemon or installs the pinned release, then prompts for the enrollment code with input hidden; no enrollment secret belongs in the command, shell history or environment. Host must reach the controller and product MCP URL. Configure provider authentication locally with `lemon setup`; enrollment verifies worker software compatibility, not provider account access, model availability or remaining quota. Provider credentials do not copy from the controller.
3. Run/supervise that worker using the host's service manager. UI shows invite issued/waiting/installing-or-connecting/verified online or expiry/offline errors; it does not infer successful installation from copying a command. On actual machine.upserted online, host info/capabilities show measured version/OS/user/cwd/filesystem roots and grants. Mac OS access prompts belong to that Mac host only; Linux bots do not ask for Apple Calendar access.
4. Create a Bot onto this machine. Identity/status anchor always shows assigned host, current task and truthful idle/working/making/needs-input/offline; click avatar/header for Activity + Upcoming, Identity/Job/Memory, grants and Ideas. Files/terminal are full host access, secret UI is names-only/masked.
5. Reconnect repairs same durable node identity with a new one-use invite, not a new machine. Host management operations (update/recover/restart/suspend/recreate/delete isolated environment) require an actually configured host driver and exact-scope preview/confirmation. They are separate from detaching, never silently remove SSH/user data. Offline/unknown operation outcomes are persisted and reconciled.
6. Move an idle owned Bot with preview to an online owned destination: persona/skills/profile memory acknowledged before cutover, product history retained, native continuation starts fresh. Files/browser sessions/provider credentials do not copy automatically. Detach exact-name confirmation revokes execution trust, pauses affected work, preserves user host files/logins and offline Bot metadata.

Never approve an action just because a card says "working". Read Bot/machine/scope/consequences and exact target; Send on outward drafts is always explicit. Delete conversation, forget selected memory, disconnect connector, reset selected Bot scopes and detach machine are distinct previewed actions. Product deletion does not automatically revoke external provider sessions or erase operator backups.

## Contributor checks

From `products/lemon_bot/backend`, run `bun install`, `bun test` and `bun run typecheck`. From `products/lemon_bot/sdk/ts`, run `bun install`, `bun test` and `bun run check`.

Live integration checks require an enrolled machine and configured providers. Exercise a completed Bot response, phone pairing and revocation, and the provider-specific operations you deploy.
