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

For first-run choices, owner sign-in, model connection and permissions, use the [Lemon Bot getting-started guide](../../docs/getting-started/lemon-bot.md). Usage shows provider spend and limits; integrations and host controls depend on configured providers and permissions.

When a task needs missing Terminal, Files or Browser access, a Bot can ask through an owner-only access card. Allowing changes the Bot's access after its current task finishes, then visibly continues your original request; commands still require their normal approval. Grant edits during a task also queue, with Stop task available. Supported workers keep task files in a private per-Bot folder; folder reads can skip approval unless workspace policy requires it, and reading there makes subsequent web access ask first.

Instance provider rows show the last observed Lemon provider failure and its time.
The runtime retains one bounded, credential-free category summary per provider,
including authentication and rate-limit failures; successful calls do not erase
that history. It is in-memory diagnostic history, cleared when Lemon restarts,
not a live provider probe. Raw provider messages, paths and credentials are never
included in `providers[].lastError`.

## Install a release

Start with the [Lemon Bot getting-started guide](../../docs/getting-started/lemon-bot.md): the Mac app, the Terminal Bot installer, or attaching a second machine. The Mac app installs a runtime with bundled Python and needs no developer tools; the Terminal installer still requires a working `python3`. The DMG pipeline currently produces unsigned, unnotarized preview artifacts only; end-user distribution awaits Developer ID and notarization credentials.

## Running an integrated checkout

Requirements: an authenticated Lemon controller with the required profile, placement, node-I/O, memory and live-stream RPCs; Bun 1.4+; Node 24 for Vite tooling. Owner sign-in and management do not require model-provider credentials or a default model. Bot replies require a model and destination-local provider authentication; see [model setup](../../docs/user-guide/setup.md). Native development supports Xcode 27.2 and 27.4 with XcodeGen 2.46+; installed Apple devices require signing and provisioning.

1. Start/reuse the existing controller following the [CLI guide](../../docs/user-guide/cli.md). Keep its operator token on the backend; do not create an unrelated product token.
2. Start the backend:

```bash
bun --cwd products/lemon_bot/backend install
bun run --cwd products/lemon_bot/backend start
```

The default backend serves `http://127.0.0.1:4100` and keeps private state in `~/.lemon/lemon_bot`. Startup modes and operator environment variables are described in the [backend README](backend/README.md). Use the canonical [getting-started guide](../../docs/getting-started/lemon-bot.md) for owner sign-in rather than treating the development server as anonymous signup.

`LEMON_BOT_PUBLIC_URL` is the reachable product origin, not the controller URL. Execution machines must reach it for MCP and attachments; a remote worker cannot use the backend's loopback address. Backend `start` serves built production web assets when present; `dev` runs backend watch mode.

3. Web development and production assets:

```bash
bun --cwd products/lemon_bot/web install
bun run --cwd products/lemon_bot/web dev
# Production web assets consumed by backend:
bun run --cwd products/lemon_bot/web build
```

The web dev server runs at `http://127.0.0.1:4081`. Its `/v1` (including realtime WebSocket), `/hooks` and `/mcp` requests proxy to `http://127.0.0.1:4100`; set `LEMON_BOT_DEV_BACKEND` in the web development environment to use another backend origin. The Vite dev socket is separate from product realtime. Web never connects directly to Lemon `/ws`.

4. For native development, follow the [Apple build guide](apple/README.md#generate-build-and-launch). Configure signing, App Group and APNs for installed devices; the share extension exchanges only explicit user-selected content, never operator authority.

### Connect iPhone persistently to the desktop cluster

Follow [Lemon Bot getting started](../../docs/getting-started/lemon-bot.md) for reachable HTTPS, owner-approved phone pairing and revocation. The phone receives its own product session, never the desktop session or operator token; it is a client, not an execution machine.

### Backend configuration

Invalid configuration fails startup (no fake demo fallback). Backend private SQLite DB, attachment blobs, nonce receipts and encryption key reside under DATA_DIR; protect and back them up consistently. Restore validates metadata/blob checksums before changing live state. Generated encryption master key is private 0600; alternatively supply a durable operator-provided key. A changed/missing key with existing encrypted records fails closed, not a new empty credential store.

| Variable | Required/default | Purpose |
|---|---|---|
| `LEMON_BOT_CONTROL_URL` | This machine's Lemon, or the saved choice | Exact controller `/ws` endpoint; off-loopback WSS unless trusted encrypted overlay explicitly configured. Overrides the saved choice |
| `LEMON_BOT_OPERATOR_TOKEN` | Launcher-managed token for this machine; required for another machine | Existing daemon operator token, server-only. Overrides the saved choice |
| `LEMON_BOT_PUBLIC_URL` | `http://127.0.0.1:<port>`; required for a non-loopback host | Reachable HTTPS product origin, HTTP loopback for development |
| `LEMON_BOT_DATA_DIR` | `~/.lemon/lemon_bot` | Private persistent SQLite/blobs/keys/config root |
| `LEMON_BOT_RUNTIME_LAUNCHER` | Installed `~/.lemon/bin/lemon` for this machine's Lemon | Absolute existing executable Lemon launcher; enables owner-only start/stop/restart for a loopback controller and takes precedence over controller RPCs. Invalid paths fail backend startup. Remote restart/stop instead require the connected controller's advertised lifecycle methods and permissions. |
| `LEMON_BOT_HOST` / `LEMON_BOT_PORT` | `127.0.0.1` / `4100` | Bun listener binding; expose only behind trusted TLS boundary |
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

Use [attaching a bot machine](../../docs/user-guide/attaching-a-bot-machine.md) for SSH setup, scoped invitations, repair and service persistence. Configure model authentication on the destination; enrollment and capability checks do not establish provider access, quota or OS permission grants.

Attached workers run with their OS user's privileges. Co-resident Bots share files, browser sessions and CLI credentials; personas are not OS isolation. Detaching trust, deleting product data and host-management operations are distinct actions, not automatic erasure of the host or its external logins. Review exact targets and consequences before approval.

## Contributor checks

From `products/lemon_bot/backend`, run `bun install`, `bun test` and `bun run typecheck`. From `products/lemon_bot/sdk/ts`, run `bun install`, `bun test` and `bun run check`.

Live integration checks require an enrolled machine and configured providers. Exercise a completed Bot response, phone pairing and revocation, and the provider-specific operations you deploy.
