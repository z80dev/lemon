# File Slash Commands

A file slash command is a reusable prompt stored as a file. Typing
`/name arguments` in the TUI, ACP client or a chat channel sends the expanded
template to the model instead of the literal text. Lemon reads the command
formats of Claude Code, Codex, GitHub Copilot, Gemini CLI, omp and generic
`.agents` harnesses in place; nothing is copied or installed.

Built-in commands win: a file named `help.md` never replaces the TUI's `/help`,
ACP's `/plan`, `/compact` or `/context`, or a channel's own commands. An
unknown `/name` is sent unchanged, exactly as before.

## Where commands live

Project roots are relative to the session working directory (not walked up to
ancestors). User roots live under your home directory. Project commands win
over user commands, Lemon-native roots win over other tools within the same
scope, and the first command with a given name wins in this order:

| Scope | Root | Files | Name |
| --- | --- | --- | --- |
| project | `.lemon/command/`, `.lemon/commands/` | `*.md` | file name |
| project | `.omp/commands/` | `*.md` | file name |
| project | `.agents/commands/`, `.agent/commands/` | `*.md` | file name |
| project | `.claude/commands/` | `**/*.md` | `git/commit.md` → `git:commit` |
| project | `.codex/prompts/`, `.codex/commands/` | `*.md` | file name |
| project | `.github/prompts/` | `*.prompt.md` | `review.prompt.md` → `review` |
| project | `.gemini/commands/` | `**/*.toml` | `git/fix.toml` → `git:fix` |
| user | `~/.lemon/agent/command/`, `~/.lemon/agent/commands/` | `*.md` | file name |
| user | `~/.omp/agent/commands/` | `*.md` | file name |
| user | `~/.agents/commands/`, `~/.agent/commands/` | `*.md` | file name |
| user | `~/.claude/commands/` | `**/*.md` | nested → `a:b` |
| user | `~/.codex/prompts/`, `~/.codex/commands/` | `*.md` | file name |
| user | `~/.gemini/commands/` | `**/*.toml` | nested → `a:b` |

`LEMON_AGENT_DIR` relocates the `~/.lemon/agent` roots. Dot-files, files over
64 KiB, names containing whitespace, and nesting deeper than four directories
are ignored.

## Markdown commands

```markdown
---
description: Commit staged work
argument-hint: [message]
---

Commit the staged changes. Message: $ARGUMENTS
```

Frontmatter is optional; without it the whole file is the template.
`description` and `argument-hint` are shown in the TUI palette, `/help` and the
ACP command list. `model` and `subtask` are read into the command definition
but do not change how the expanded prompt runs.

## Gemini TOML commands

```toml
description = "Explain code"
prompt = "Explain {{args}} step by step."
```

`prompt` is required. Gemini shell (`!{…}`) and file (`@{…}`) injections are
left as literal text.

## Arguments

Arguments are split on whitespace; single or double quotes group words.
Explicitly empty quoted arguments (`""` or `''`) keep their positional slot.

| Placeholder | Value |
| --- | --- |
| `$1` … `$9` (any number) | that argument, or empty when missing |
| `$ARGUMENTS`, `$@`, `{{args}}` | the whole argument text as typed |

Substitution happens once: argument text containing `$1` is not expanded
again. When a template has no placeholder and arguments were given, they are
appended after a blank line. An expansion larger than 256 KiB is sent as typed.

## How expansion works

Expansion happens on the daemon, against the session's working directory,
when a local channel or control-plane run starts, or when a local run receives
steering or redirect text (`CodingAgent.Commands`). The model sees, and session
history stores, the expanded text. Subagent, delegated `agent`, scheduled,
automation and async completion prompts are never expanded.

Named-node steering/redirect currently carries text without the incoming
submission's origin. Such text stays literal; Lemon never reads the
controller's command files to expand a prompt destined for another machine.

The TUI discovers the same roots locally so `/name` autocompletes, appears in
the palette and `/help`, and is sent verbatim; new command files are picked up
the next time an unknown name is typed or the palette opens. Namespaced names
such as `/git:commit` are sent as prompt text and expanded by the daemon. When
the TUI is attached to a daemon with a different working directory, the
daemon's files decide what expands.
File commands use the normal submission mode, including the one-shot Alt+Enter
override; submitting one consumes that override just like ordinary prompt text.

ACP clients receive the discovered commands in `available_commands_update`
after the built-ins, with `argument-hint` as the input hint.
