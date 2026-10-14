# Lemon Bot web

A separate React/Vite product client, not Lemon Web or the TUI. The Bot roster is the primary navigation: named teammates with a durable job and an assigned machine. A calm, inspectable companion anchor links to Identity, Job, Memory, Activity, Upcoming, Ideas and effective grants. All normal content comes from the product backend through `@lemon-bot/sdk`; there is no demo seed, virtual desktop or screen-streaming path.

## Run

From the repository root, after starting the separately configured real backend:

```sh
bun --cwd products/lemon_bot/web install
bun run --cwd products/lemon_bot/web dev
```

Development listens on `http://127.0.0.1:4081`. Vite proxies `/v1` (including the product realtime socket), `/hooks` and `/mcp` to `http://127.0.0.1:4080`. Override the development target with `LEMON_BOT_DEV_BACKEND`. A saved account may select a different trusted HTTPS product backend; that deployment must explicitly allow this frontend origin for REST and WebSocket connections. Never enter the Lemon control-plane URL or operator token.

```sh
# Central integration checks; implementation workers do not run these gates.
bun --cwd products/lemon_bot/sdk/ts install
bun run --cwd products/lemon_bot/sdk/ts check
bun run --cwd products/lemon_bot/sdk/ts test
bun run --cwd products/lemon_bot/web check
bun run --cwd products/lemon_bot/web build
```

Production assets are emitted to `web/dist`; the backend serves those files outside `/v1`. Serve the app and service worker over HTTPS (loopback development is the only HTTP exception). For OIDC, register the frontend's exact same-origin redirect URLs, including `/`, `/?screen=settings.account` and `/?screen=settings.identity`, with the backend operator. Provider callbacks convey one-time completion codes; PKCE verifiers remain transient in the current browser tab. Swarm credentials stay server-side.

## First use

1. Choose the product backend. An empty deployment asks for the one-time owner setup code printed in its operator terminal; existing members sign in locally, accept an invitation, or use an actually configured OIDC provider.
2. Attach a trusted machine. Copy its **server-issued**, one-use join command, run it on the destination, and wait for real verified online status. Copying a command does not prove enrollment. Configure that host's own provider authentication and supervise its worker.
3. Create a focused named Bot on that online machine, using a suggested job, custom role or reviewed template. Co-resident Bots share the OS user's files, browser logins and CLI credentials; personas are not host isolation.
4. Give it a concrete task. Text, references, actual files and explicit voice inputs use normal placed conversations. Stop cancels a real run; only a terminal cancelled state proves it stopped, and prior external effects are not undone.

## Product destinations

- Roster: pins, sections/rank/collapse, hidden and unread projections, groups and durable attention. Hide does not stop work.
- Conversations: incremental attributed transcript, tools and the complete typed card taxonomy, structured questions, masked secrets, human steps, scoped approvals, exact editable drafts with Send/Discard, reactions/replies/feedback, independent task conversations, composer drafts and real attachments.
- Bots: creation, Identity/Job/Memory, avatar crop/upload/generation, voice sample, owner/manager/team publication, duplicate, explicit selected Team copy, reviewed template publication/import, assigned-machine move and scoped reset/deletion previews.
- Machines: actual enrollment/repair state, host measurements, capabilities/OS grants, privileged files and chunked transfers, real xterm VT PTY, names-only write-only secret management, access users, detach, configured owned-host operation preview and server progress.
- Work: provisioned skills, schedule/webhook/channel/external-event routines with real tests and run history, exact event filter schemas, machine-labelled MCP setup/tool controls/account consent, real channel install/link flows, email availability/approval/claim/read/search and X OAuth/main-Bot mention setup.
- Memory: personal/team/private-note scopes, corrections, forget previews, reviewed import candidates with provenance/exclusions and explicit selection, export, inspectable preference changes and conflict-safe Undo.
- Settings: account/appearance/password/sessions/devices and deletion reauthentication; workspace/ownership/members/invites; notification/push/mic/voice; effective policy and required/personal rules; usage/nullable pricing and spend limits; OIDC/SCIM/directory; network desired/applied revisions and egress; reviewed host setup and redacted runs; export destinations, explicit participant consent and historical export artifacts.
- Search, palette, Inbox, Activity and Upcoming route to exact authorized resources. Ideas only draft prompts. Verified milestones are small and nonblocking; reduced motion has a static alternative.

The canonical [API](../contracts/api.md), [cards](../contracts/cards.md), and [coverage](../contracts/coverage.md) define schemas, ACLs, state machines and provider prerequisites; this README does not duplicate those contracts or claim exercised coverage.

## Keyboard and accessibility

Cmd/Ctrl K opens commands and visible-workspace search. Cmd/Ctrl Shift F searches Bots; Cmd/Ctrl N creates a teammate; Cmd/Ctrl B opens the compact roster; Cmd/Ctrl comma opens settings; Cmd/Ctrl Shift comma opens Bot settings; Cmd/Ctrl 1–9 selects visible roster Bots. Composer Enter sends and Shift Enter adds a line; explicit on-screen controls provide equivalents. Input fields and native browser-reserved shortcuts are not hijacked. Phone web uses a compact roster drawer, the same API editors/actions under ACL, and responsive preview/terminal layouts. Light/dark/system appearance, labelled controls, visible focus, semantic status/error notices, skip navigation and reduced-motion styling are built in.

Appearance also applies to pre-login forms: body text and field labels use the active light/dark foreground rather than a fixed light-theme color.

## Credential, voice, cache and unknown-outcome boundaries

Bearer sessions use tab-scoped session storage, not URLs or local-storage account lists. Saved backend/email/workspace chooser metadata contains no bearer. Private state is fetched after login and replaced on authoritative sync; WebSocket revocation closes the workspace. Downloads are short-lived authorized tickets, not persisted file identities. HTML/document snapshots never gain app-origin scripting authority.

Text/document previews are bounded to 8 MiB; table views bound rows/columns and never evaluate formulas. The authorized unchanged original remains downloadable. Document/HTML conversion errors and unsupported slide formats are shown explicitly rather than replaced with synthetic renderings.

Microphone capture starts only after explicit action, has visible stop/cancel controls and releases tracks. Dictation is reviewable **unsent** text; active voice chat explicitly uses STT → normal message/run stream → TTS. Web Speech/on-device synthesis are labelled local fallbacks, backend audio providers are separately advertised capabilities, and voice memos persist real backend audio. Neither ambient listening nor background/lock-screen browser microphone continuity is promised.

Web Push registration is explicit and uses the actual owned browser installation and published VAPID key. `/service-worker.js` caches no private API responses; notification clicks navigate and authenticated fetch reconciles the exact target. OS permission, backend provider configuration and Bot notification preferences are separate states.

No mutation is automatically replayed after a lost response. Unknown outcomes retain input and diagnostic nonce/reserved resource IDs, fence subsequent consequential intents, and offer read-only reconciliation. Revisions bind edits; destructive dialogs show exact affected and retained scope, expire, require typed confirmation and stay mounted until the parent receives an acknowledged result. Offline destructive actions and approvals are never queued. Read failures are errors, never synthetic empty lists or success. Unconfigured provider/host screens surface actual discovery prerequisites rather than claiming connected or applied state.

Unknown errors remain inputs to the shared diagnostic notice; only boolean conditions control surrounding notices and reconciliation buttons. Provider filter variants are narrowed to JSON objects before the guided editor reads schema fields; typed boolean, null, primitive and array values, required fields and separate human broad-listener consent are retained.

Mixed group admission is shown per Bot: admitted targets keep their real started/queued/steering status, and `rejected` targets show the referenced failed Run’s actual bounded reason and request ID. A zero-admission refusal that persisted the original user entry retains the nonce for read-only reconciliation instead of a duplicate send. After prerequisites are corrected, a new explicit reviewed message may address only the refused targets; admitted work is not replayed.

Group details offer explicit own-member Leave with an existing enabled human successor chosen by the creator, or previewed deletion for the last human. Conflicting active/delegated work retains membership and fixed run IDs for authoritative terminal-state reads; cancellation acknowledgment alone is insufficient. Own `conversation.left` events clear that room’s local state and navigation, while another member’s departure retains the room.

Workspace Owners can inspect the canonical `/account-teardowns` list/detail from Account cleanup. Product cleanup, actual per-provider receipt states, errors and observation times remain separate. Status refresh is read-only: no Delete retry, provider revocation replay, private-content access or deleted-user login restoration. A deletion request retains only safe operation/user/request diagnostics for Owner handoff after session revocation, separately from cleared credential/session caches. Pending X authorization renders unverified identity explicitly; retained verified handles in failed/needs-auth states are labelled historical.
