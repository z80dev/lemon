# User-managed profiles

Profiles let one Lemon runtime host durable specialist agents without adding a
second execution engine. A profile is the canonical `[profiles.<id>]` router
record plus an isolated home derived from its validated ID:

```text
~/.lemon/profiles/research/
├── config.toml
├── profile.json
├── sessions/
└── workspace/
    ├── memory/
    └── .lemon/skill/
```

The profile ID is stable. Its main conversation is always
`agent:<id>:main`; renaming the display name does not fork or lose that chat.
The native `coding_agent -> lemon_agent -> lemon_ai` path remains unchanged.

## Create and chat

```bash
lemon profile create research \
  --name "Research" \
  --description "Evidence-first research specialist" \
  --model openai:gpt-5

lemon profile show research
lemon profile chat research "Map the unresolved questions"
lemon profile roster
```

The terminal UI exposes the same server-owned records. Run `/profiles` for a
filterable node-aware roster; selecting an entry opens its stable
`agent:<id>:main` conversation. `/profile current`, `/profile show <id>`, and
`/profile open <id>` inspect or select a profile. After selection, ordinary
prompt submissions use `profile.chat` rather than generic `chat.send`, so the
daemon still derives the profile workspace and named-node route:

```text
/profiles
/profile create research --name "Research" --model openai:gpt-5 --node newphy
/profile chat research Map the unresolved questions
```

The TUI also supports `clone`, `rename`, credential-safe `export`, and guarded
`delete` subcommands. Use `/profile help` for exact syntax. Delete requires the
same profile ID again through `--confirm`; the TUI never accepts a profile home
or workspace path. Export's destination is the sole lifecycle output path.

In an installed release, `profile chat` uses the authenticated local control
plane and starts the packaged daemon when it is not already healthy. In a
source checkout, start `./bin/lemon --daemon` first; the one-shot
`./bin/lemon profile chat ...` process then submits to that runtime rather than
starting a second router whose work would disappear when the CLI exits.

Use `--node <name>` at creation time to route canonical chat through an
authenticated named execution node. The roster reports `local`, `online`, or
`offline`. For named execution, provider credentials and the effective working
directory stay destination-local; `profile_id` lets the destination derive its
own profile workspace rather than trusting a controller filesystem path.

All lifecycle reads support `--json`. Chat also accepts `--model` and
`--queue-mode collect|followup|steer|interrupt` overrides. Its working boundary
remains the derived profile workspace; generic chat/delegation APIs own any
explicit project-directory selection. Omitting overrides uses the profile and
normal runtime defaults.

## Clone, rename, and delete

```bash
lemon profile clone research research-copy --name "Research Copy"
lemon profile rename research "Research Prime"
lemon profile delete research-copy --confirm research-copy
```

Clone copies regular profile-home files but rejects symlinks and special files.
Rename updates only presentation metadata. Delete refuses the reserved
`default` profile, requires an exact matching confirmation value, and moves the
managed home to `~/.lemon/trash/profiles/` before removing its TOML table. A
failed config commit restores the home.

Lifecycle config edits are serialized and atomically replace the global config
file. Targeted TOML patching preserves unrelated tables, unknown keys, and
comments instead of decoding and rewriting the entire user file.

## Credential-safe export

```bash
lemon profile export research ./research-profile.json
```

The default export is deliberately selected-file, not a backup of the entire
home. It includes portable profile metadata, profile-local config, known
bootstrap markdown, and text files under the profile skill tree. Before
encoding it redacts sensitive assignments and recognizable inline credential
patterns.

It does not include:

- sessions or message history;
- memory content or artifacts;
- binary files or special files;
- secret-like paths such as `.env`, token, password, credential, or private-key
  files.

The JSON `exportPolicy` and command result report selected file, omission, and
redaction counts. There is intentionally no packaged CLI option to include
secrets. Review any export before sharing it.

## Control-plane API

Clients can use the equivalent JSON-RPC methods:

- `profiles.list`, `profiles.get`, and `profiles.roster` (`read` scope);
- `profiles.create`, `profiles.clone`, `profiles.rename`, `profiles.export`, and
  `profiles.delete` (`admin` scope);
- `profile.chat` (`write` scope).

`profile.chat` returns the run ID and stable session key without echoing the
prompt. It does not accept a caller-supplied working directory or node: both
come from the validated profile record. Lifecycle and export summaries are
credential-free by construction.

## Current boundaries

This first-class vertical covers durable local records, isolated assistant
workspaces, lifecycle, canonical one-to-one chat, node routing, and a roster.
Group rooms, profile-scoped cron management, import/restore, a Web form editor,
free-form TUI field editing, and merged multi-controller rosters remain
separate product work. The TUI command/picker lifecycle is complete for the
existing control-plane API; it intentionally does not invent APIs for those
remaining surfaces.
