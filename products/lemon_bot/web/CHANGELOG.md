# Web client changelog

## [Unreleased]

### Changed

- Reply chips show the original author and a short message preview; Send has a keyboard-focus tooltip.
- Standardized computer connection setup as “Connect a computer” and raised status badges to 12px. Narrow sidebar headers keep their New Bot button on the logo row, truncating long connection labels instead.
- Load feature screens on demand instead of bundling all routes into the initial client chunk.

### Fixed

- Device registration, About and update requirements use the build's package version and complete semantic-version precedence instead of hardcoded version checks.

### Added

- Messaging-first polish. Conversations drop the page heading for a floating Bot pill that toggles a right-hand panel (Activity: live run, steps and recent outcomes with Stop; Details: Bot facts, settings links and the existing conversation details; Library: files, memory, routines, skills, connected apps). On phones the panel opens as a full-screen sheet.
- Transcript: grouped, borderless bubbles with date separators; user bubbles use the Bot's color. Reactions, reply, copy and feedback appear on hover, or on long-press/context menu on touch. Existing reactions show as small chips.
- A failed, stopped or unconfirmed run shows as one quiet "Couldn't finish this. Retry · Details" row in place of an empty assistant bubble. Run IDs, error codes and diagnostic request IDs appear only under Details. Retry puts your original message back in the composer for review; it never resends automatically.
- A compact live "working…" row above the composer shows the current step, with Stop, and opens Activity. Find-in-conversation moved behind ⌘F and the header search button.
- Floating pill composer: "+" menu (attach, skills/references, delivery mode, voice call, save/clear draft), auto-growing field, dictation, and a round send button in the Bot's color. Enter sends on keyboards; on touch, Return inserts a newline.
- Parity with the Mac and iPhone apps (shared design system): the same color tokens in light and dark, type scale, radii and the same lemon-blob mascot (vector, wonky face, per-Bot palette with avatar/tint/onTint, presence and unread badges, leaf brand mark, lemon account initials).
- Sidebar matches the native apps: search and new-Bot circles, pinned avatar row, Inbox and Activity rows, Bot rows with a label chip and a live status line ("··· step…", "✋ Needs you", "Couldn't finish the last request", or a markdown-free preview with "You:"), collapsible sections, Groups and tasks, "Show N hidden Bots", a floating "↓ More unreads" pill, and a footer with the account avatar (opens Settings) and "Connect apps". Right-click or "⋯" opens the Bot menu (open, details, activity, pin, read/unread, hide, move to section, reorder). On phones the chat list is the home screen ("Chats").
- Conversation: header pill over a scroll-edge fade with a "⋯" menu (details, find, search, new task, edit group, mark unread, stop, delete); 30-minute date separators; consecutive tool calls collapse to "Used N tools ›"; a typing bubble while work starts; "↓ New messages" when you've scrolled up; hover actions are 👍, copy, reply and "⋯" (more reactions, feedback, copy message ID). The working row shows the current step, elapsed time and Stop; the failed row offers Retry only for retry-safe failures and keeps Status, Request ID and Run ID (each copyable) behind Details.
- Inspector: sliding Activity/Details/Library tabs. Activity has a Now card with live steps and Stop, the machine, recent runs, upcoming, recent activity, and tasks; Details covers persona, skills, model, placement, voice, notifications, authorization and history; Library links files, memory, routines, skills and templates. On phones it is a bottom sheet.
- Settings is now one place with the native grouping and names: Account, Devices, Machines, Apps & channels, Library, Policies, Usage & exports, Network, Workspace, Preferences and About, with a sub-switcher when a pane holds several screens. Desktop shows a sidebar of icon tiles; phones show a grouped list with Done. Keyboard: ⌘, Settings, ⌘[ / ⌘] and ⌥↑/⌥↓ switch Bots, ⌥⌘I toggles the inspector, ⌘I focuses the composer, ⌘D dictation, ⌘⇧M Connect apps, ⌘⇧W skills; ⌘Return also sends.
- The lemon mascot (soft blob, wonky face) is now a crisp SVG for the brand mark, the default Bot avatars (recolored per Bot), the empty states and the sign-in illustration. Added a favicon, an Apple touch icon and a web app manifest.
- iPhone Safari: `viewport-fit=cover` with safe-area insets, 16px inputs (no zoom on focus), Add to Home Screen metadata, and light/dark theme colors. Refreshed warm olive/cream light and dark palettes, 15px body text, pill buttons.

## [1.0.0]

- Introduce the separate Lemon Bot React/Vite product client with a Bot-centric roster, calm status anchor, responsive workspace, command/search navigation, task-aware links and light/dark/reduced-motion presentation.
- Add real typed transcript/card, file and explicit voice workflows, durable drafts, unknown-outcome reconciliation, exact revision/confirmation-bound actions, and authenticated realtime resume through the TypeScript SDK.
- Add owned-machine enrollment, host/file/VT PTY/secret management; Bot identity/jobs/templates/groups/scoped memory; skills/routines; and configured provider, identity, governance, network, setup, export and spend-management screens.
- Add explicit browser installation/Web Push registration and a private-cache-free notification service worker. No screen streaming, virtual desktops, ambient capture, demo data or browser-held operator authority.
- Add explicit group Leave/succession with terminal-work conflict reconciliation; Owner-only account cleanup receipt observation and credential-free diagnostic handoff after revocation; and honest nullable/historical X identity labels.

Provider/host capability prerequisites and shared resource contracts remain defined in `../contracts/`. Release notes describe implemented surfaces, not exercised integration or provider verification.
