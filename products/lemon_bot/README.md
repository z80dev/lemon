# Lemon Bot

Durable named AI teammates with a job, identity, skills, memory, routines, files, voice and **a machine you own**. Lemon Bot is a separate Bun/TypeScript application plugged into one running Lemon swarm. Web, macOS and iOS share the same product API; none receives the swarm operator credential. It does not replace or change Lemon Web or the TUI.

Bots remain active when clients close. They stop being able to execute when their assigned machine or controller is unavailable: closed app and offline host are different states. Multiple bots on one machine share that OS user's files, browser sessions and CLI credentials. A bot persona/profile is not an OS sandbox; separate machines/users/containers are needed for hard isolation. The operator keeps SSH, files, terminal and host access.

## Source of truth

- [API and screens](contracts/api.md): HTTP/auth/ACL/nonce/replay, MCP tools, voice, integrations, deployment/provider prerequisites and all client destinations.
- [Wire types](contracts/protocol.ts): dependency-free request/response/resources/events, imported by backend and SDK; Swift mirrors these discriminated unions and nullability.
- [Transcript/cards](contracts/cards.md): all entry kinds, adaptation of 27 Grok typed messages and resolving state machines.
- [Behavioral coverage](contracts/coverage.md): every one of 101 Grok use cases, plus the 16 adopted Muse features and explicit provider/host prerequisites. This is design coverage, not a claim of exercised tests.

## Architecture

```text
 macOS app ─┐
 iOS app ───┼── HTTPS + WSS ──► Lemon Bot backend ── operator /ws ──► Lemon control plane
 Web app ───┘   /v1 product API    │  SQLite             one swarm          │
                                  │  MCP /mcp (bot tools) ◄───────────────┤ named execution nodes
                                  │  APNs / Web Push                       │ = attached machines
                                  └─ webhooks /hooks/:routineId             └─ bots execute here
```

The backend holds product accounts/roles/groups/ACLs, sessions, UI metadata, transcript/cards, immutable attachments, idempotency receipts, durable workspace event cursor, notifications and integration configuration. Lemon remains owner of profiles, router/session/run execution, cron scheduling, host I/O/PTY/secrets and scoped runtime memory. There is no second runtime/router/cron engine. One correlated operator connection reconnects/reconciles without replaying uncertain mutations; named-node live deltas map only to authorized product runs/conversations. Product event seq is persisted independently of Lemon's non-replayable connection seq.

| Component | Location | Role |
|---|---|---|
| Contracts | `contracts/` | Authoritative protocol, schemas, lifecycle, screens and coverage |
| Backend | `backend/` | Bun.serve, bun:sqlite, Lemon adapter, product REST/realtime, MCP, attachments, push, OIDC/SCIM/integrations/host-management adapters |
| TypeScript SDK | `sdk/ts/` | Typed HTTP, nonces, cursor reconnect and discriminated events; no operator credential |
| Web | `web/` | React/Vite responsive Bot-centric workspace and command palette; served by backend in production |
| Shared Apple kit | `apple/LemonBotKit/` | Swift models, authenticated API/socket, secure sessions/cache, deep-link routing |
| macOS | `apple/LemonBotMac/` | SwiftUI workspace, optional selected-bot compact companion and configurable global summon/PTT mini-composer |
| iOS | `apple/LemonBotiOS/` | SwiftUI adaptive workspace, camera/files, explicit voice and share extension |

A personal bot maps to a placed `lb-<stable-slug>` profile and canonical main chat; tasks use independent sessions, Team DM is per member, group has one bot-scoped session per participant. Machine row maps to durable enrolled nodeId, never a transient socket ID. Every session executes on its bot's assigned machine; shared-host credentials are not silently replaced with requester credentials. Private Team notes are bot+user backend records; shared/personal runtime memories use Lemon memory.*. Bot Identity, Job and Memory stay distinct, with inspectable preference changes/undo.

No Lemon subscription store/paywalls or vendor entitlements. Usage shows actual provider tokens/cost and configurable spend ceilings. Enterprise identity/group/network/export controls use explicit configured OIDC/SCIM/providers/host enforcement; unconfigured capability is unavailable, not fake success. Screen streaming/per-bot virtual desktop/demonstration recording, proprietary hardware, ambient mic, automatic social-account linking, payment wallet and vendor-specific cloud-agent/1Password are excluded. Written skills, owned host terminal/files/human-step handoff and real integrations preserve the corresponding work outcomes.

## Running an integrated checkout

These commands define the component entry-point contract used by the implementation teams; this contracts-only change does not claim to have built or launched those components. Requirements: running authenticated Lemon controller with the required advertised profile/placement/node-I/O/memory/live-stream RPCs, Bun 1.4+, Node 24 for Vite tooling, and destination hosts with Lemon/provider credentials. Native builds use Xcode 26.3 and XcodeGen 2.46 (iOS 26 simulator available in the reference workstation); Apple targets must supply their supported OS deployment minimums in the generated project.

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

`LEMON_BOT_PUBLIC_URL` is the externally reachable product origin, **not** control-plane URL. Registered bot MCP URLs, webhook URLs, OAuth callbacks and attachment downloads derive from it. Every execution node must reach it (loopback public URL cannot serve a remote node). Production uses HTTPS and matching WSS, trusted proxy origin/header validation and private data directory ownership. Backend `start` serves production built web when present; `dev` runs backend watch mode. On an empty DB, backend prints a one-time setup code. Open product origin, create owner with that code, name workspace, then attach a machine and create first Bot. Normal accounts use local login/invite or configured OIDC; setup is never exposed anonymously beyond setupRequired/version.

3. Web development and production assets:

```bash
bun --cwd products/lemon_bot/web install
bun run --cwd products/lemon_bot/web dev
# Production web assets consumed by backend:
bun run --cwd products/lemon_bot/web build
```

Web dev `/v1`, `/hooks` and `/mcp` proxy to backend origin; Vite dev socket is not product realtime. Web never connects directly to Lemon `/ws`.

4. Native apps: generate `apple/project.yml` with XcodeGen, open generated `apple/LemonBot.xcodeproj`, select LemonBotMac or LemonBotiOS scheme, and enter the same product backend URL in onboarding. Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` on the reference toolchain. Configure signing/team/App Group/APNs entitlements for installed device builds. Share extension exchanges user-selected content with containing app through App Group storage, not a second operator connection. Credentials use Keychain; `lemonbot://` deep links carry resource IDs, no bearer tokens.

### Backend configuration

Required variables fail startup on omission/invalid configuration (no fake demo fallback). Backend private SQLite DB, attachment blobs, nonce receipts and encryption key reside under DATA_DIR; protect and back them up consistently. Restore validates metadata/blob checksums before changing live state. Generated encryption master key is private 0600; alternatively supply a durable operator-provided key. A changed/missing key with existing encrypted records fails closed, not a new empty credential store.

| Variable | Required/default | Purpose |
|---|---|---|
| `LEMON_BOT_CONTROL_URL` | Required | Exact controller `/ws` endpoint; off-loopback WSS unless trusted encrypted overlay explicitly configured |
| `LEMON_BOT_OPERATOR_TOKEN` | Required | Existing daemon operator token, server-only |
| `LEMON_BOT_PUBLIC_URL` | Required | Reachable HTTPS product origin, HTTP loopback for development |
| `LEMON_BOT_DATA_DIR` | Required | Private persistent SQLite/blobs/keys/config root |
| `LEMON_BOT_HOST` / `LEMON_BOT_PORT` | `127.0.0.1` / `4080` | Bun listener binding; expose only behind trusted TLS boundary |
| `LEMON_BOT_ENCRYPTION_KEY` | Optional, otherwise private generated key | Stable 32-byte base64 master key for product session/integration credentials; never returned to client |
| `LEMON_BOT_CONFIG_FILE` | Optional, otherwise DATA_DIR/config.json | Operator provider/redirect/origin/host-management configuration (§11 API), secret references not model prompts |
| `LEMON_BOT_APNS_KEY_ID` | Optional set, all APNs fields together | APNs token-auth key identifier |
| `LEMON_BOT_APNS_TEAM_ID` | APNs set | Apple developer team identifier |
| `LEMON_BOT_APNS_PRIVATE_KEY_PATH` | APNs set | Owner-readable `.p8` key, never committed |
| `LEMON_BOT_APNS_TOPICS` | APNs set | Comma-separated allowlisted native bundle topics |
| `LEMON_BOT_VAPID_PUBLIC_KEY` | Optional pair | Base64url Web Push public key published via capabilities |
| `LEMON_BOT_VAPID_PRIVATE_KEY` | VAPID pair | Server-only Web Push private key |
| `LEMON_BOT_VAPID_SUBJECT` | VAPID pair | `mailto:` or HTTPS contact URI |
| `LEMON_BOT_STT_PROVIDER` | Optional `openai` / `deepgram` | Real backend transcription provider; absent means capability false, on-device dictation still usable |
| `LEMON_BOT_TTS_PROVIDER` | Optional `openai` / `elevenlabs` / `google` | Real backend speech provider; no silent-wav fake fallback |
| `LEMON_BOT_OPENAI_API_KEY` | When OpenAI voice/image selected | Server provider credential, separate from swarm/local destination provider auth |
| `LEMON_BOT_DEEPGRAM_API_KEY` | Deepgram STT | Server transcription credential |
| `LEMON_BOT_ELEVENLABS_API_KEY` | ElevenLabs TTS | Server synthesis credential |
| `LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH` | Google TTS | Private service-account credential file |
| `LEMON_BOT_IMAGE_PROVIDER` | Optional `openai` | Real avatar generation provider; absent keeps character/upload but generate unavailable |

Optional push/voice/image config publishes accurate capabilities; foreground/inbox notifications still work without push. Runtime-owned model/provider auth must be set **on each destination machine**, not sent as product client metadata. OIDC discovery/client credential refs, SCIM integration tokens, SMTP/IMAP/provisioning provider, Slack OAuth/signing/app installation, X OAuth/mention webhook/signature/public handle, GitHub/Linear/Sentry/PagerDuty verification keys/event allowlists, audit destinations, network/egress/host driver manifests and required runtime destination allowlists are configured in the private config file according to api.md. Providers need real credentials/permissions; unavailable cases return capability_unavailable, never imitation accounts/sends.

Clients discover actual provider IDs and secret-free prerequisites through `GET /v1/integration-providers`; configured is distinct from a connected account. Optional private configuration includes `connectorProviders` (exact MCP origins/OAuth/shared-service-account permission), `approvedPrivateMcpOrigins` and `reviewedSetupManifests` (exact approved scripts/groups/machines/secret-name references). Omitted lists are empty; dependent operations fail explicitly until operator-reviewed configuration exists. Discovery never exposes secrets, private scripts or raw host command manifests.
Channel/email/X setup screens also consume typed `/v1/channels/providers`, `/v1/email/providers` and `/v1/x/provider` projections. Own channel-account linking starts through `/v1/channels/principal-links/start`, proves actual external sender then confirms the reviewed identity; `/v1/event-sources/:source` defines exact supported trigger/filter schemas.

OIDC additionally requires operator-only `oidcAllowedOrigins` and exact `oidcClientApprovals` `{origin,clientId,clientSecretRef}` bindings to existing `serverSecrets`. Both default empty; no credential is sent to an IdP merely because an Owner added its provider row. Public DNS is required unless the exact HTTPS origin also appears in `oidcApprovedPrivateOrigins` (subset of allowed origins). All endpoints, DNS/TLS and credential bindings are checked before discovery/exchange/logout/probes. Local bootstrap/password accounts remain usable; managed required SSO does not silently downgrade when these prerequisites are missing.

The strict private schema also types management-user grants, private export origins, reviewed OIDC group/subject mappings, separate public X credentials, provider-account spend sources, fixed channel application principals and managed-directory Owner override. These are operator-reviewed deployment inputs, not Owner-editable credential settings or an `operatorExtras` bag; see the [provider reference](providers.md) and API private-configuration sections for exact fields and real provider prerequisites.

Automated host management, setup, network/egress application and read-only driver probes use the owning noninteractive native destination process RPC: immutable reviewed argv, destination cwd, bounded JSON stdin and verified operation/config receipts. They never use or fall back to PTY/shell-command interpolation. PTY remains only the explicit user-facing machine terminal; missing process capability is unavailable rather than a hidden alternate execution path.

## Attach and manage a machine

1. Sign in as workspace owner/admin; open **Machines → Attach a machine**. Enter friendly name, durable unique nodeName, purpose/labels. Review that a trusted worker runs with its OS user's privileges and co-resident bots share files/logins.
2. Backend creates a short-lived, one-use `node.pair.invite` with purpose lemon_bot. Copy the server-returned **joinCommand** to the destination machine. It installs Lemon if needed and enrolls via the invite, without exposing the operator token. Do not substitute a handwritten command with a controller secret. Host must reach controller and product MCP URL, and must locally configure provider auth/default cwd.
3. Run/supervise that worker using the host's service manager. UI shows invite issued/waiting/installing-or-connecting/verified online or expiry/offline errors; it does not infer successful installation from copying a command. On actual machine.upserted online, host info/capabilities show measured version/OS/user/cwd/filesystem roots and grants. Mac OS access prompts belong to that Mac host only; Linux bots do not ask for Apple Calendar access.
4. Create a Bot onto this machine. Identity/status anchor always shows assigned host, current task and truthful idle/working/making/needs-input/offline; click avatar/header for Activity + Upcoming, Identity/Job/Memory, grants and Ideas. Files/terminal are full host access, secret UI is names-only/masked.
5. Reconnect repairs same durable node identity with a new one-use invite, not a new machine. Host management operations (update/recover/restart/suspend/recreate/delete isolated environment) require an actually configured host driver and exact-scope preview/confirmation. They are separate from detaching, never silently remove SSH/user data. Offline/unknown operation outcomes are persisted and reconciled.
6. Move an idle Bot with preview to an online destination: persona/skills/scoped memory acknowledged before cutover, product history retained, native continuation starts fresh. Files/browser sessions/provider credentials do not copy automatically. Detach exact-name confirmation revokes execution trust, pauses affected work, preserves user host files/logins and offline Bot metadata.

Never approve an action just because a card says "working". Read Bot/machine/scope/consequences and exact target; Send on outward drafts is always explicit. Delete conversation, forget selected memory, disconnect connector, reset selected Bot scopes and detach machine are distinct previewed actions. Product deletion does not automatically revoke external provider sessions or erase operator backups.

## Integration verification

The contracts assignment intentionally performs no builds/tests/lint/format or live provider/enrollment probes. After component integration, orchestrator should check protocol TypeScript compilation, SDK/backend response conformance, all 101+16 coverage rows, pagination/revision/nonce/cursor edge behavior, ACL/group/private-note isolation, real node attachment/placed streaming/terminal/files/memory, expired gates and uncertain sends, OIDC/SCIM/group/network/export/provider adapters, APNs/Web Push/voice/deep links, and web/macOS/iOS screens. No contract document is evidence those paths were exercised.
