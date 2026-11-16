# Instruction files and rules

Native coding sessions load repository instruction files and prompt rules into
the system prompt automatically; stream rules stay dormant until output matches.
Lemon reads the files other coding agents use,
so a repository set up for Claude Code, Codex, Gemini CLI, GitHub Copilot,
Cursor, Windsurf or Cline works without migration. These files are repository
data with the same trust as `AGENTS.md`: keep secrets and untrusted content out
of them.

The prompt is recomposed before each user prompt, so edits to these files are
picked up without restarting the session.

## Instruction files

Every directory from the filesystem root down to the working directory can
contribute:

| Location | Files |
| --- | --- |
| The directory itself | `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `CLAUDE.local.md` |
| `.claude/` | `CLAUDE.md`, `AGENTS.md` |
| `.lemon/` | `CLAUDE.md`, `AGENTS.md` |
| `.gemini/` | `GEMINI.md` |
| `.agents/`, `.agent/`, `.omp/` | `AGENTS.md` |
| `.github/` | `copilot-instructions.md` |

Each config directory holds only its own file names; for example
`.github/AGENTS.md` and a top-level `copilot-instructions.md` are not read.

Global files are loaded before any directory file:

| File | Tool |
| --- | --- |
| `~/.claude/CLAUDE.md`, `~/.claude/AGENTS.md` | Claude Code |
| `~/.gemini/GEMINI.md` | Gemini CLI |
| `~/.codex/AGENTS.md` | Codex |
| `~/.config/opencode/AGENTS.md` | OpenCode |
| `~/.agents/AGENTS.md`, `~/.agent/AGENTS.md` | `.agents` convention |
| `~/.copilot/copilot-instructions.md` (or `$COPILOT_HOME/copilot-instructions.md`) | GitHub Copilot CLI |
| `~/.lemon/CLAUDE.md`, `~/.lemon/AGENTS.md`, `~/.lemon/agent/{CLAUDE,AGENTS}.md` | Lemon |

`~` is the `HOME` environment variable; `~/.lemon/agent` follows
`LEMON_AGENT_DIR`.

Other tools' user-global files (`~/.gemini`, `~/.codex`, `~/.config/opencode`,
`~/.agents`, `~/.agent`, `~/.copilot`) are read by default whenever they exist,
the same way Lemon already reads `~/.claude/CLAUDE.md` and `~/.claude/skills`.
They are passive text added to the prompt; nothing in them is executed. To keep
one out of Lemon sessions, remove or rename the file.

### Order and scope

Files are rendered global first, then from the filesystem root down to the
working directory. Within one directory, its own files come before its config
directories in the table order above. Each file carries a header with its path
and scope: a global file applies everywhere, and a directory file applies to
that directory and its descendants. A file inside a config directory such as
`.github/` or `.gemini/` is scoped to the directory that contains the config
directory. More specific instructions override broader ones.

A physical file is loaded once, even when it is reachable through a symlink, a
hard link or as both a global and an ancestor file.

Instruction files in directories below the working directory are not loaded.
The session's environment block lists their paths (including `GEMINI.md`,
`CLAUDE.local.md` and `.github/copilot-instructions.md`) so the model reads them
before editing there.

### `@` imports

An `@path` token inside an instruction file is replaced with the referenced
file's content:

```markdown
Read @docs/architecture.md before changing storage code.
Personal aliases live in @~/.notes/aliases.md.
```

- The `@` must start a line or follow a space or tab, so `user@example.com` and
  `git@github.com:org/repo.git` are never imports.
- Relative paths resolve from the importing file's directory, not the working
  directory. `~` and `~/...` resolve from the home directory; absolute paths are
  used as-is.
- Tokens inside fenced code blocks and inline code spans stay literal. Inline
  spans close only on the opening backtick-run length, including across lines.
- Trailing `. , ; : ! ? ) ] } " '` is not part of the path, so
  `@docs/setup.md.` imports `docs/setup.md`.
- Imports recurse up to five hops. A file already imported into the same
  expansion is not imported again, so cycles stop silently.
- A missing, unreadable or non-text target leaves the original `@path` text.
- Each imported file contributes at most 64 KiB, and one instruction file at
  most 256 KiB of imported content.

## Rules

Rule files are Markdown, optionally with YAML frontmatter, that apply always,
only to some files or tasks, or when streamed model output matches a pattern.

### Sources

Project rules, highest precedence first:

| Source | Location |
| --- | --- |
| Lemon | `.lemon/rules/*.md`, `.lemon/rules/*.mdc` |
| `.agents` convention | `.agent/rules/*.{md,mdc}`, `.agents/rules/*.{md,mdc}` |
| Cursor | `.cursor/rules/**/*.{mdc,md}`, legacy `.cursorrules` |
| Windsurf | `.windsurf/rules/*.md`, legacy `.windsurfrules` |
| Cline | `.clinerules` file, or `.clinerules/*.md` |
| GitHub Copilot | `.github/instructions/**/*.instructions.md` |

`.lemon/rules`, `.agent(s)/rules` and `.clinerules` are searched from the
working directory up to the Git repository root (or the home directory when no
repository is closer; the home directory itself is not a project directory).
Nearer directories win, and only the nearest `.clinerules` is used. The other
sources are read from the working directory only.

Global rules: `~/.lemon/agent/rules/*.{md,mdc}`, `~/.agent/rules`,
`~/.agents/rules` and Windsurf's `~/.codeium/windsurf/memories/global_rules.md`.

A rule's name is its path relative to its rules directory without the extension
(`.instructions.md` for GitHub files), for example `testing` or
`frontend/react`. The legacy single files are named `cursorrules`,
`windsurfrules`, `clinerules` and `global_rules`. When two rules share a name,
the first one found wins, so a project rule replaces a global rule of the same
name.

### Frontmatter

```markdown
---
description: Database migration conventions
globs: priv/repo/**/*.exs, lib/**/migrations/*.ex
alwaysApply: false
---
Write reversible migrations...
```

| Field | Meaning |
| --- | --- |
| `description` | When the rule applies; lists the rule in the rulebook |
| `globs` | Files the rule applies to: a YAML list or a comma-separated string (`{a,b}` groups stay intact) |
| `alwaysApply` | `true` injects the full rule into every prompt |
| `enabled` | `false` ignores the file (it does not shadow a global rule) |
| `streamPattern` | Non-empty, byte-oriented regex source; keeps the rule out of the prompt until streamed output matches |
| `injectionLimit` | Positive integer limiting this rule's journaled correction injections; default `1` |
| `trigger` (Windsurf) | `always_on` always applies; `glob` and `model_decision` use `globs`/`description`; `manual` keeps the rule out of the prompt |
| `applyTo` (GitHub) | Comma-separated globs; `*`, `**` or `**/*` makes the rule always apply. Without `description`, one is generated from the globs |

Legacy single-file rules (`.cursorrules`, `.windsurfrules`, a `.clinerules`
file and Windsurf `global_rules.md`) always apply unless they have a
`streamPattern`. Frontmatter that is not valid YAML, such as Cursor's unquoted
`globs: *.ts`, is read as plain `key: value` lines. Kebab-case keys such as
`always-apply`, `stream-pattern` and `injection-limit` are accepted. Files with
an empty body are ignored.

An invalid `streamPattern` (including an empty string, non-string value or
unsupported UTF mode), or a supplied `injectionLimit` that is not a positive
integer, disables that declaration. It never becomes an ordinary prompt rule.
Name precedence is resolved first, so the invalid declaration still shadows
lower-priority rules of the same name. Quote regex sources with YAML single
quotes to preserve backslashes; limits are integers, not quoted strings.

### How rules reach the model

- **Stream rules** contribute no body, name, description, path or rulebook
  entry before a match, even when `alwaysApply`, `description`, `globs`,
  Windsurf triggers or GitHub `applyTo` would otherwise expose them.
- **Always-apply rules** are injected in full after the instruction files,
  under "Always-apply rules".
- **Rulebook rules** (not always-apply, with a description or globs) are listed
  in a "Rulebook" index with their name, description, globs and absolute file
  path. The model is told to `read` a rule before working on matching files or
  when its description applies.
- Ordinary rules with neither a description nor globs, and Windsurf `manual`
  rules without a stream pattern, are not surfaced.

Rules are sorted by name, so the prompt is byte-stable while the files are
unchanged.

### Streaming corrections

For example, `.lemon/rules/no-inner-html.md` can contain:

```markdown
---
streamPattern: '\bdangerouslySetInnerHTML\b'
injectionLimit: 1
---
Do not use dangerouslySetInnerHTML. Render the content as ordinary text instead.
```

The pattern watches assistant text and streamed tool-argument text, not hidden
thinking. A match cancels the current model stream and retries with the rule body
in a `<system-interrupt reason="rule_violation">` correction. Rule names and
injection counts are journaled: resume and compaction do not reset the limit.
The default of one injection is a caller policy to prevent repeated corrections,
not a guarantee that the next response complies.

Patterns use byte-oriented Erlang `:re` syntax; inline modifiers such as `(?i)`
are supported, but UTF mode is forbidden. Match subjects are rolling windows,
not the whole response: anchors and lookarounds are window-local. Each window
is at most **4096 bytes**, fed in chunks of at most **1024 bytes**. A match
spanning more than 3073 bytes is not guaranteed across chunk boundaries. Text
blocks and tool calls have separate windows; patterns do not span them.

The matcher enforces these **caller safety policies**, not protocol limits or
measured performance claims:

| Resource | Limit |
| --- | --- |
| Rules per matcher | 32 |
| Regex source | 1024 bytes per rule |
| Rule name | 256 bytes |
| Rule body | 64 KiB |
| One streamed delta | 16 KiB |
| Concurrently retained text/tool streams | 32 |
| Regex engine match steps | 10,000 per match attempt |
| Regex engine recursion depth | 100 per match attempt |

Oversized configuration or deltas, excess active streams and exhausted regex
budgets fail explicitly rather than silently skipping content. These bounds
keep work per delta independent of total response length; rules are a corrective
mechanism, not an authorization boundary or a way to undo effects.

For runtime callers, `CodingAgent.Rules.stream_rules(cwd)` returns the
name-sorted, precedence-resolved stream rules with `name`, `content`,
`stream_pattern` (the source string) and `injection_limit`, plus discovery
metadata. `discover/1` includes both ordinary and valid stream declarations;
ordinary rules have `stream_pattern: nil` and `injection_limit: 1` unless a
different positive limit was supplied. `buckets/1` and `sections/1` omit all
stream rules. The runtime matcher separately enforces the size and execution
policies above.
