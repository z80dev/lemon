# Lemon Bot web

A separate React/Vite assistant client, not Lemon Web or the TUI. Your named Bots run on your own desktop or swarm hosts. The browser uses native Lemon Bot product APIs through `@lemon-bot/sdk`; no terminal automation, demo data, virtual desktop or screen-streaming path.

## Run

From the repository root, with the real product backend configured and running:

```sh
bun --cwd products/lemon_bot/web install
bun run --cwd products/lemon_bot/web dev
```

Development listens on `http://127.0.0.1:4081`. Vite proxies `/v1` (including realtime), `/hooks` and `/mcp` to `http://127.0.0.1:4100`. Override the development target with `LEMON_BOT_DEV_BACKEND`. A saved owner account can select a trusted HTTPS backend; that deployment must allow this frontend origin for REST and WebSocket connections. Never enter the Lemon control-plane URL or operator token.

Production assets are emitted to `web/dist`; the backend serves them outside `/v1`. Use HTTPS except for loopback development. If using a configured OIDC provider, register the exact frontend redirect URLs used by account sign-in and account linking. PKCE verifiers remain in the current browser tab. Swarm credentials remain server-side.

## First use

Follow [Lemon Bot getting started](../../../docs/getting-started/lemon-bot.md) for installation, local-owner sign-in and first Bot creation; use [model setup](../../../docs/user-guide/setup.md) for destination-local model connection and [attaching a bot machine](../../../docs/user-guide/attaching-a-bot-machine.md) for another execution host. There is no anonymous signup; a public origin or tailnet connection alone grants no account authority.

Owner sign-in and management work before model authentication. **Verified** and **Saved** both allow Bot creation, but Saved is not a successful live check. Co-resident Bots share the OS user's files, browser sessions and CLI credentials; personas are not host isolation.

Create a Bot with a name and the preselected machine. **Standard** grants
Terminal and Files (and Browser where supported), while still asking before
commands; **Chat only** omits local tool access. Approval cards show the command
and offer **Allow once**, an eligible **Allow Terminal for this chat**, or **Deny**.
Remembered chat/Bot permissions can be revoked with **Stop allowing**; they do
not bypass workspace policy. A Bot can separately request missing access through
an owner-only card, applied after its current task before continuing the request.
See the [access and approval contract](../contracts/api.md#7-backend-mcp-bot-tools)
and [getting-started guide](../../../docs/getting-started/lemon-bot.md) for scope.

With no Bots, the home card offers creation when a computer is already online;
otherwise it explains connecting a computer first.

Sidebar previews use each conversation's last-entry ID. When it points at a tool
event, the sidebar checks the preceding 20 transcript sequences for the latest
previewable entry and caches the result until the last-entry ID changes.

There is no Team Bot publishing, manager assignment, live other-user Bot access, cross-human room membership, Team memory/skills or shared connector authority. Workspace/Public templates contain reviewed declarative content and always create a separate owned Bot, never access to the publisher's live Bot or credentials.

## Connect iPhone from a desktop browser

The canonical [getting-started guide](../../../docs/getting-started/lemon-bot.md) covers reachable HTTPS, desktop-approved pairing and revocation. The browser renders the backend's one-use pairing link locally with `qrcode.react`; no QR service receives it. The phone gets its own device-bound product session, not the browser's session or operator credential.

Contributor invariants: preview/refresh/polling are read-only; creating a QR and approving a device require explicit action. Unknown mutations retain the original nonce and fence conflicting actions. Pair URLs remain only in the mounted screen's memory, not cached account metadata or logs. A lost issuance receipt can be reconciled only within its original deadline; successful phone sessions last until revoked. See the [preflight contract](../contracts/preflight.md).

## Assistant destinations

- **Bots / chat:** named Bots, Identity/Job/Memory, own conversations/tasks, attributed streaming transcript, tool activity, typed cards, structured questions, masked secrets, human steps, run-bound approvals and reviewed editable drafts.
- **Hosts & files:** real enrollment/repair/capabilities, privileged file access and transfers, explicit interactive VT terminal, write-only secrets and reviewed host operations. Host process execution and interactive terminals remain distinct.
- **Memory / skills / routines:** owner memory corrections and reviewed imports, provisioned skills, schedule/webhook/channel/external-event routines with actual tests and run history.
- **Inbox / activity / upcoming:** real decisions, notifications, work outcomes, reminders and exact-resource navigation.
- **Settings:** owner account/password/sessions/devices, cluster identity, appearance, notifications/voice, policies, usage/spend limits and necessary provider/network/host configuration. Ordinary chat does not require directory, SCIM or enterprise setup.
- **Connections:** machine-labelled MCP setup/tool controls/account consent, real channel install/link flows, email availability/approval/claim/read/search and X account setup. Unconfigured providers show their actual prerequisites, never fake connected state.

Bot access on web and Mac is grouped into Everyday, collapsed Control this Mac,
and Connections. Controls use Off / View only / Full; Terminal cannot enforce
View only. Machine measurements provide capability names and human status
messages; differing requested/effective access shows a warning and next step.
The single Why disclosure retains raw reasons and shared policy explanations.
Desktop and session-scoped capabilities that have no native grant mapping are
inspection-only here; configure them on the assigned machine or in Connections.
Saving applies the returned grant immediately only when the Bot is idle; during
active work the change queues until that task finishes, with **Stop task** available.
Refresh access rechecks the machine. These controls do not change workspace
review policy or request macOS privacy permissions; those belong on the assigned Mac.

The canonical [API](../contracts/api.md), [cards](../contracts/cards.md) and [coverage](../contracts/coverage.md) define wire schemas, ACLs, state machines and provider prerequisites. This guide does not claim exercised coverage.

## Keyboard and accessibility

Cmd/Ctrl K opens commands and search; Cmd/Ctrl Shift F searches Bots; Cmd/Ctrl N creates a Bot; Cmd/Ctrl B opens the compact roster; Cmd/Ctrl comma opens settings; Cmd/Ctrl Shift comma opens Bot settings; Cmd/Ctrl 1–9 selects visible Bots. Composer Enter sends and Shift Enter adds a line. Every shortcut has on-screen equivalents. Input fields and native browser-reserved shortcuts are not hijacked. Small screens use a roster drawer and responsive file/terminal layouts. Light/dark/system appearance, labelled controls, visible focus, semantic notices, skip navigation and reduced-motion styling are built in.

On touch screens, tap a message to show its 44px copy, reply and reaction controls.
**Copy link to message** opens the selected message after sign-in; it contains no
session credential. Failed message history loads offer **Try again**, and active
work is never represented as an empty conversation.

Reply chips identify the original author and show a 40-character message preview.
The Send button shows its keyboard hint on hover and keyboard focus.

Feature destinations load on demand, including computer/terminal, Bot, settings,
library and conversation screens. The web version comes from `package.json` at
build time; device registration, About and minimum-version checks use that same
version, with semantic-version precedence (including prereleases).

User-facing copy calls the account container a **workspace** and the execution
device a **machine**. **Computer user** means the machine's operating-system
account. API and configuration identifiers retain their canonical names.

Machine measurements show when they were last updated and recheck their age every
15 seconds, even without new server data. File paths start in the destination's
default folder (not necessarily its home folder); links outside allowed folders
are blocked. Terminal output gaps mean earlier output is unavailable, not that a
command succeeded; available sequence numbers remain under **Details**. Operation
progress counts finished targets separately from queued or unknown outcomes.
Memory source links open the source conversation, and template identifiers and
revisions stay under **Details**. Channel and X setup distinguish provider
availability from a connected account and show message support or requested
permissions before authorization.

## Credential, cache, voice and unknown-outcome boundaries

Bearer sessions use tab-scoped session storage, not URLs or local-storage account lists. Saved backend/email/cluster chooser metadata contains no bearer. Private state is fetched after login and replaced on authoritative sync. Realtime revocation closes the authenticated workspace. Downloads use short-lived authorized tickets, not persisted file identities. HTML/document snapshots never gain app-origin scripting authority. The service worker caches no private API responses; push clicks navigate and authenticated reads reconcile the exact resource.

Text/document previews are bounded to 8 MiB; table views bound rows/columns and do not evaluate formulas. The authorized unchanged original remains downloadable. Conversion errors and unsupported formats show explicit errors, not synthetic documents.

Microphone capture begins only after explicit action, has stop/cancel controls and releases tracks. Dictation is reviewable **unsent** text. Active voice chat uses STT → ordinary message/run stream → TTS. Local browser speech fallbacks are labelled; backend audio providers are separately advertised capabilities. Background or lock-screen microphone continuity is not promised.

Notification settings distinguish browser registration and subscription from
server delivery for browsers and iPhones. If server delivery is not set up, ask
your administrator to enable it; browser permission alone does not enable delivery.
**Check browser status** reads the browser subscription without changing it.
The in-app inbox keeps alerts even when browser notifications are off.

Voice settings separately label **Server voice** and **Browser voice** samples.
Server samples use the configured server provider; browser samples use the
browser's voices. Browser dictation may send audio to the browser vendor.
Saved microphone inputs that have not been connected in this visit are labelled
**not connected yet** rather than presented as confirmed available devices.

No mutation is automatically replayed after a lost response. Unknown outcomes retain draft input and fixed nonce/resource IDs, fence consequential intents and offer read-only reconciliation. Revisions bind edits. Destructive dialogs disclose exact affected/retained scope, expire, require typed confirmation and remain mounted until acknowledgment. Offline destructive actions and approvals are never queued. Read failures are errors, not synthetic empty lists or success. Realtime cursors are acknowledged only after authoritative event application; refresh never treats a watermark as a replacement snapshot.

Provider API-key input is an exception to retained drafts: it is always cleared
on submit, including failure, and never stored in local or session storage.
The password field requests `autocomplete=off`; browsers and extensions may
ignore that hint, and Web cannot prevent screenshots or screen recording.
Codex sign-in opens the verification URL only from an explicit browser action;
the displayed URL/code remain a manual fallback if new tabs are blocked.
Device polling pauses outside the active settings view. All tokens and OAuth
exchange remain on the execution target, not in browser state.

## Connection recovery

The connection panel names the product service origin (the browser origin through
the Vite proxy in development), distinguishes network/service/proxy failures from
a disconnected Lemon link, and shows the actual retry countdown. **Try again**
replaces the realtime connection after fetching a fresh workspace snapshot; it
never replays a work command. Expired or revoked sessions return to sign-in with
an explicit explanation. Invalid saved sign-in callback data is discarded safely.

Owners and admins can inspect a disconnected Lemon link and request a reconnect.
Only owners can run the runtime actions advertised by the backend. A launcher on
the service host can start, stop or restart Lemon; remote controller control can
restart or stop it, but cannot start Lemon while it is down. Missing actions show
the service's explanation. Stop and restart require confirmation. Running commands
are observed with read-only polling and their output stays behind Details. An
uncertain command receipt blocks further commands rather than sending it again.

**Settings → Instance** shows Lemon's version, release channel and short commit,
per-channel connection state and last error. The owner-only **Settings → Providers** section
manages credentials on the controller or a selected owned execution machine:
add/replace a write-only API key, Codex device sign-in, consented Codex CLI login
import, confirmed local disconnect, and a separate confirmed default provider/model
change. **Check now** performs a non-generating readiness check (which may refresh
the target's OAuth token). **Saved** means Lemon checks it on your first message,
not that a live check passed. Resolver validation remains separate from live
readiness. See the shared [Providers workflow and browser limitations](../providers.md#providers-settings-on-web-iphone-and-mac).

Across chat, settings, computers and connected services, **Check status** observes
an unconfirmed change; it never sends that change again. Ordinary failed reads use
**Refresh and check again**. Technical messages, request IDs and saved action
references remain available under **Details** with Copy. Only an explicit user
action can start another change after the current status has been reviewed.

Deleting account data first shows its server-issued preview and typed confirmation.
Removing an iPhone, a stored secret, a Bot section or a configuration uses the
in-app confirmation dialog; cancelling sends no deletion request. Account deletion
offers password, configured identity-provider confirmation, or a fresh local
confirmation after `lemon-bot open` for a passwordless owner.

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
