# Lemon Bot web

A separate React/Vite assistant client, not Lemon Web or the TUI. Your named Bots run on your own desktop or swarm hosts. The browser uses native Lemon Bot product APIs through `@lemon-bot/sdk`; no terminal automation, demo data, virtual desktop or screen-streaming path.

## Run

From the repository root, with the real product backend configured and running:

```sh
bun --cwd products/lemon_bot/web install
bun run --cwd products/lemon_bot/web dev
```

Development listens on `http://127.0.0.1:4081`. Vite proxies `/v1` (including realtime), `/hooks` and `/mcp` to `http://127.0.0.1:4080`. Override the development target with `LEMON_BOT_DEV_BACKEND`. A saved owner account can select a trusted HTTPS backend; that deployment must allow this frontend origin for REST and WebSocket connections. Never enter the Lemon control-plane URL or operator token.

Production assets are emitted to `web/dist`; the backend serves them outside `/v1`. Use HTTPS except for loopback development. If using a configured OIDC provider, register the exact frontend redirect URLs used by account sign-in and account linking. PKCE verifiers remain in the current browser tab. Swarm credentials remain server-side.

## First use

1. Connect to your product backend. An empty deployment requests the one-time owner setup code printed in its operator terminal. Otherwise sign in to your owner account.
2. Attach your host using its **server-issued**, one-use join command. Run it on the destination and wait for verified online status. Configure the host's actual provider authentication and supervise its worker. Copying a command does not prove enrollment.
3. Create a named Bot with a focused job on that host, or review a template to create a separate owned copy. Co-resident Bots share the OS user's files, browser sessions and CLI credentials; personas are not host isolation.
4. Open its chat and give it a concrete task. Text, references, real files and explicit voice input use placed conversations. Stop requests cancel a real run; only its terminal cancelled state proves it stopped, and prior external effects are not undone.

There is no Team Bot publishing, manager assignment, live other-user Bot access, cross-human room membership, Team memory/skills or shared connector authority. Workspace/Public templates contain reviewed declarative content and always create a separate owned Bot, never access to the publisher's live Bot or credentials.

## Connect iPhone from a desktop browser

Open **Connect iPhone** in the roster or Settings (canonical screen `device.pairing`). Explicitly create a five-minute, one-use pairing QR. The QR encodes the backend's actual `pairUrl`, not your browser session or an operator credential. It is rendered locally with `qrcode.react`; no QR image service receives the link.

The backend must advertise its reachable HTTPS public URL. Tailscale Serve is the recommended deployment when desktop and iPhone already have Tailscale reachability. This screen does not provision Tailscale, discover an overlay, or prove phone reachability. A localhost QR works only for same-machine development/Simulator; it cannot connect a physical iPhone to the desktop's localhost.

Scan in Lemon Bot for iOS, inspect the exact cluster and backend origin, then request connection. The browser shows the pending device name, expiry and verification code. Compare that code with the phone and explicitly **Approve** or **Deny**. Approval gives the phone its own device-bound product session, not the browser's session. The paired session lasts **until revoked** (`expiresAtMs: null`). Revoke the device here or revoke its session under Account. Reopening iOS restores its Keychain-backed connection; offline phone state is not permission to replay mutations.

Only explicit button actions mutate pairing/device state. Refresh and polling use GET only. A lost mutation receipt retains its fixed nonce and safe resource metadata in the authenticated tab's session storage and fences another consequential intent until authoritative reconciliation. For a lost QR issuance receipt, a separately labelled explicit action requests the original receipt with the **same** issuance nonce until the original five-minute deadline; it never extends expiry, creates another session or makes a consumed code reusable. Pair URLs exist only in the mounted screen's memory and disappear on claim, expiry, navigation or logout. Safe pending resources contain no QR secret. Nothing stores QR or pairing credentials in public caches, logs, account metadata or URLs belonging to the web app.

## Assistant destinations

- **Bots / chat:** named Bots, Identity/Job/Memory, own conversations/tasks, attributed streaming transcript, tool activity, typed cards, structured questions, masked secrets, human steps, run-bound approvals and reviewed editable drafts.
- **Hosts & files:** real enrollment/repair/capabilities, privileged file access and transfers, explicit interactive VT terminal, write-only secrets and reviewed host operations. Host process execution and interactive terminals remain distinct.
- **Memory / skills / routines:** owner memory corrections and reviewed imports, provisioned skills, schedule/webhook/channel/external-event routines with actual tests and run history.
- **Inbox / activity / upcoming:** real decisions, notifications, work outcomes, reminders and exact-resource navigation.
- **Settings:** owner account/password/sessions/devices, cluster identity, appearance, notifications/voice, policies, usage/spend limits and necessary provider/network/host configuration. Ordinary chat does not require directory, SCIM or enterprise setup.
- **Connections:** machine-labelled MCP setup/tool controls/account consent, real channel install/link flows, email availability/approval/claim/read/search and X account setup. Unconfigured providers show their actual prerequisites, never fake connected state.

The canonical [API](../contracts/api.md), [cards](../contracts/cards.md) and [coverage](../contracts/coverage.md) define wire schemas, ACLs, state machines and provider prerequisites. This guide does not claim exercised coverage.

## Keyboard and accessibility

Cmd/Ctrl K opens commands and search; Cmd/Ctrl Shift F searches Bots; Cmd/Ctrl N creates a Bot; Cmd/Ctrl B opens the compact roster; Cmd/Ctrl comma opens settings; Cmd/Ctrl Shift comma opens Bot settings; Cmd/Ctrl 1–9 selects visible Bots. Composer Enter sends and Shift Enter adds a line. Every shortcut has on-screen equivalents. Input fields and native browser-reserved shortcuts are not hijacked. Small screens use a roster drawer and responsive file/terminal layouts. Light/dark/system appearance, labelled controls, visible focus, semantic notices, skip navigation and reduced-motion styling are built in.

On touch screens, tap a message to show its 44px copy, reply and reaction controls.
**Copy link to message** opens the selected message after sign-in; it contains no
session credential. Failed message history loads offer **Try again**, and active
work is never represented as an empty conversation.

User-facing copy calls the account container a **workspace** and the execution
device a **machine**. **Computer user** means the machine's operating-system
account. API and configuration identifiers retain their canonical names.

## Credential, cache, voice and unknown-outcome boundaries

Bearer sessions use tab-scoped session storage, not URLs or local-storage account lists. Saved backend/email/cluster chooser metadata contains no bearer. Private state is fetched after login and replaced on authoritative sync. Realtime revocation closes the authenticated workspace. Downloads use short-lived authorized tickets, not persisted file identities. HTML/document snapshots never gain app-origin scripting authority. The service worker caches no private API responses; push clicks navigate and authenticated reads reconcile the exact resource.

Text/document previews are bounded to 8 MiB; table views bound rows/columns and do not evaluate formulas. The authorized unchanged original remains downloadable. Conversion errors and unsupported formats show explicit errors, not synthetic documents.

Microphone capture begins only after explicit action, has stop/cancel controls and releases tracks. Dictation is reviewable **unsent** text. Active voice chat uses STT → ordinary message/run stream → TTS. Local browser speech fallbacks are labelled; backend audio providers are separately advertised capabilities. Background or lock-screen microphone continuity is not promised.

No mutation is automatically replayed after a lost response. Unknown outcomes retain draft input and fixed nonce/resource IDs, fence consequential intents and offer read-only reconciliation. Revisions bind edits. Destructive dialogs disclose exact affected/retained scope, expire, require typed confirmation and remain mounted until acknowledgment. Offline destructive actions and approvals are never queued. Read failures are errors, not synthetic empty lists or success. Realtime cursors are acknowledged only after authoritative event application; refresh never treats a watermark as a replacement snapshot.

## Connection recovery

The connection panel names the product service origin (the browser origin through
the Vite proxy in development), distinguishes network/service/proxy failures from
a disconnected Lemon link, and shows the actual retry countdown. **Try again**
replaces the realtime connection after fetching a fresh workspace snapshot; it
never replays a work command. Expired or revoked sessions return to sign-in with
an explicit explanation. Invalid saved sign-in callback data is discarded safely.

Owners and admins can inspect a disconnected Lemon link and request a reconnect.
Only owners can start/restart Lemon, and only when the backend advertises local
runtime control. Restart requires confirmation. Running commands are observed
with read-only polling and their output stays behind Details. An uncertain command
receipt blocks further commands rather than sending it again.

Across chat, settings, computers and connected services, **Check status** observes
an unconfirmed change; it never sends that change again. Ordinary failed reads use
**Refresh and check again**. Technical messages, request IDs and saved action
references remain available under **Details** with Copy. Only an explicit user
action can start another change after the current status has been reviewed.

Deleting account data first shows its server-issued preview and typed confirmation.
Removing an iPhone, a stored secret, a Bot section or a configuration uses the
in-app confirmation dialog; cancelling sends no deletion request. Account deletion
offers password or configured identity-provider confirmation without exposing
sign-in implementation details.

Owner account cleanup distinguishes product cleanup from actual provider receipt state, error and observation time. Ledger refresh cannot retry deletion/provider revocation or restore a deleted-user login.

## Central integration checks

Implementation workers do not run these gates:

```sh
bun --cwd products/lemon_bot/sdk/ts install
bun run --cwd products/lemon_bot/sdk/ts check
bun run --cwd products/lemon_bot/sdk/ts test
bun run --cwd products/lemon_bot/web check
bun run --cwd products/lemon_bot/web build
```

The integrating owner also exercises the connected Safari UI against the real backend, QR scan/claim/approve/completion and device/session revocation. Static build success alone does not demonstrate phone reachability or pairing.
