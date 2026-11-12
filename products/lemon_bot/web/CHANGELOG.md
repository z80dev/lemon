# Web client changelog

## [Unreleased]

### Changed

- Bot creation preselects the sole online owned computer, presents explicit
  Standard access and keeps optional customization collapsed. Import and duplicate
  confirm their own access choice; empty chats offer one-click starter tasks.
- Create Bot checks model readiness on the selected machine, offers consented
  detected-login import before device sign-in or API-key entry, and supports Skip
  with a conversation reminder. Providers settings expose readiness, explicit
  live checks and Codex CLI import without silently copying credentials.
- Web and Mac starter tasks inspect system summaries, installed tools and running
  processes rather than personal folders, avoiding protected-folder scans.

- Surface "needs reconnecting" state and warning copy on expired or revoked machines across machine list, machine detail and chat inspector, and issue repair invites via POST.
- Connecting a computer needs only its friendly name, with optional settings under Advanced. Loopback controllers require an explicit same-computer choice before issuing an invite; verified online enrollment offers Create a Bot on that machine.
- Web and Mac grants use measured names, grouped Off / View only / Full controls, actionable status, and one Why disclosure; saved grants update from the server response.
- Reply chips show the original author and a short message preview; Send has a keyboard-focus tooltip.
- Standardized computer connection setup as “Connect a computer” and raised status badges to 12px. Narrow sidebar headers keep their New Bot button on the logo row, truncating long connection labels instead.
- Load feature screens on demand instead of bundling all routes into the initial client chunk.

### Fixed
- Settings panes scroll again: the Account password form and every long pane
  were unreachable because the settings shell clipped the workspace scroller.
  The pane list stays pinned while the pane scrolls, and switching screens starts
  at the top instead of the previous screen's offset.
- When only the Lemon link is down, settings stored by Lemon Bot (email and
  password, profile, notifications, policies, devices, owner controls) stay
  editable and no longer show "You're offline"; the Lemon-link card no longer
  claims to be trying to reach Lemon Bot's own address.
- A screen whose code can't load (Lemon Bot updated while the tab was open)
  shows a Reload card instead of blanking the whole app.
- Chat: a stopped or failed run that already wrote text shows "Stopped." /
  "Couldn't finish this." under its reply; single line breaks in replies are kept
  as on Mac and iPhone; the Unread marker no longer appears above your own
  message or replies that arrive while you watch; "/" or "@" inside a word (paths,
  email addresses) no longer opens the reference picker, which also closes after
  sending; no delivery warning flashes while a message is still sending; group
  rooms clear their unread dot when read; an online computer no longer shows a
  stale "seen 9 minutes ago"; long agent IDs wrap in the inspector.
- Email and X panes say they are turned off by workspace policy instead of
  reporting a permission error with Try again; the add-password form and
  password change use "At least 12 characters" instead of UTF-8 byte jargon, hide
  the duplicate Add button while open and render `lemon-bot open` as code; the
  identity-provider card is hidden when no provider exists; the empty profile
  avatar shows initials; Create Bot access radios sit at the card edge; the Bot
  overview shows Reload only after a failed read; approval times match other
  times; the Mac-login unlock notice has page margins.
- After first-password creation replaces a local placeholder address, the profile
  editor adopts the saved email so a later preferences change cannot restore the
  placeholder.

- Web and Mac command approvals require expanding truncated previews before Allow,
  preserve command line breaks in the card and Details, and visibly escape hidden
  or directional Unicode characters with a warning without altering execution.
- First-run home copy recognizes online computers instead of asking to connect
  one again. Mac sidebar previews retry after initial sync goes online. Both clients
  look behind trailing tool events for the latest reply without opening the chat,
  caching that result against the conversation's last-entry ID.

- Finished runs no longer leave “Writing a reply” or a caret behind when completion
  arrives late; idle or offline Bots reconcile every nonterminal run, including
  unknown outcomes. Terminal run revisions survive removal from active work, so
  delayed status reads cannot resurrect work or forward superseded results.
  Grant changes cannot be replaced by older in-flight refreshes.

- Device registration, About and update requirements use the build's package version and complete semantic-version precedence instead of hardcoded version checks.

### Added

- Private access cards let Bots request Terminal, Files or Browser with explicit
  Bot-wide consent and queued-task status. Busy-Bot changes stay editable, update
  live and offer Stop task. Supporting computers explain policy-controlled
  unreviewed Bot-folder reads; workspace administrators can require review.

- Same-computer browser sign-in uses one-use `lemon-bot open` links, strips tickets
  before routing, and explains local owner access once. Account settings show sign-in
  methods, let locally confirmed owners add email/password, and support local
  confirmation for account deletion. iPhone pairing still needs no password.

- Owner-only Providers settings use the shared product API for controller or
  owned-machine status, write-only API-key add/replace, Codex device sign-in with
  explicit browser navigation and cancellation, and confirmed local disconnect.
  Current default selection is separate and requires confirmation; credential
  actions never change it. Secret input is cleared after every submission and
  never persisted or echoed in errors; unknown outcomes are never auto-retried.

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
