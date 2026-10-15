# Web client changelog

## Unreleased

- Messaging-first polish. Conversations drop the page heading for a floating Bot pill that toggles a right-hand panel (Activity: live run, steps and recent outcomes with Stop; Details: Bot facts, settings links and the existing conversation details; Library: files, memory, routines, skills, connected apps). On phones the panel opens as a full-screen sheet.
- Transcript: grouped, borderless bubbles with date separators; user bubbles use the Bot's color. Reactions, reply, copy and feedback appear on hover, or on long-press/context menu on touch. Existing reactions show as small chips.
- A failed, stopped or unconfirmed run shows as one quiet "Couldn't finish this. Retry · Details" row in place of an empty assistant bubble. Run IDs, error codes and diagnostic request IDs appear only under Details. Retry puts your original message back in the composer for review; it never resends automatically.
- A compact live "working…" row above the composer shows the current step, with Stop, and opens Activity. Find-in-conversation moved behind ⌘F and the header search button.
- Floating pill composer: "+" menu (attach, skills/references, delivery mode, voice call, save/clear draft), auto-growing field, dictation, and a round send button in the Bot's color. Enter sends on keyboards; on touch, Return inserts a newline.
- Calmer home: Bot avatars and recent conversations first, with Inbox/Activity/Upcoming as small links. Admin destinations (hosts, skills, routines, Connect iPhone, cluster settings) moved into the account menu; "Connect apps" is a footer pill.
- The lemon mascot (soft blob, wonky face) is now a crisp SVG for the brand mark, the default Bot avatars (recolored per Bot), the empty states and the sign-in illustration. Added a favicon, an Apple touch icon and a web app manifest.
- iPhone Safari: `viewport-fit=cover` with safe-area insets, 16px inputs (no zoom on focus), Add to Home Screen metadata, and light/dark theme colors. Refreshed warm olive/cream light and dark palettes, 15px body text, pill buttons.

## 1.0.0

- Introduce the separate Lemon Bot React/Vite product client with a Bot-centric roster, calm status anchor, responsive workspace, command/search navigation, task-aware links and light/dark/reduced-motion presentation.
- Add real typed transcript/card, file and explicit voice workflows, durable drafts, unknown-outcome reconciliation, exact revision/confirmation-bound actions, and authenticated realtime resume through the TypeScript SDK.
- Add owned-machine enrollment, host/file/VT PTY/secret management; Bot identity/jobs/templates/groups/scoped memory; skills/routines; and configured provider, identity, governance, network, setup, export and spend-management screens.
- Add explicit browser installation/Web Push registration and a private-cache-free notification service worker. No screen streaming, virtual desktops, ambient capture, demo data or browser-held operator authority.
- Add explicit group Leave/succession with terminal-work conflict reconciliation; Owner-only account cleanup receipt observation and credential-free diagnostic handoff after revocation; and honest nullable/historical X identity labels.

Provider/host capability prerequisites and shared resource contracts remain defined in `../contracts/`. Release notes describe implemented surfaces, not exercised integration or provider verification.
