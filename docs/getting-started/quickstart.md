# Lemon quickstart

This path takes a new installation from zero to a verified provider-backed chat,
then proves that the session survives and shows where to go next. It uses the
prebuilt release. For repository development, use the source path in
[Install Lemon](../install.md#source-development).

## 1. Install the release

Run the installer from an interactive terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

The installer selects the release for your platform, verifies its SHA-256, and
installs under `~/.lemon`. On the normal `full` or `min` profile it opens the
idempotent setup wizard on your terminal. Complete the provider, authentication,
and default-model prompts.

If you did not let the installer modify your shell path, make the launcher
available in the current terminal:

```bash
export PATH="$HOME/.lemon/bin:$PATH"
```

Supported platforms, Linux compatibility, non-interactive flags, release
channels, and uninstall behavior are in [Install Lemon](../install.md).

## 2. Verify setup before chatting

Run the local configuration and runtime checks:

```bash
lemon config validate
lemon secrets status
lemon doctor
```

These checks prove that Lemon can resolve its config, secret store, release, and
runtime dependencies. Provider setup normally performs a live credential check
when the provider supports one. To rerun that path explicitly:

```bash
lemon setup provider
```

If you intentionally installed with `--skip-setup`, run `lemon setup` first.
Setup is safe to rerun: it performs only incomplete steps and does not replace
an existing secret key.

## 3. Prove a real model turn

Start Lemon:

```bash
lemon
```

The launcher starts the local runtime when needed and opens the terminal UI.
At the prompt, send:

```text
Reply with exactly: LEMON_READY
```

Wait for the final assistant message. A completed answer proves more than a
doctor check: the TUI connected to the runtime, the runtime created a durable
session, the selected provider accepted the request, streaming reached the
client, and the turn finalized.

Inspect the live state without leaving the TUI:

```text
/status
/session info
/usage
```

Use `/help` or `/commands` to browse commands supported by the connected
runtime. `Ctrl+C` aborts an active run; press it again while idle to quit.

## 4. Prove session continuity

First record the key shown by `/session info`. Create a second conversation:

```text
/session new quickstart-two
```

Send a short message in the new session, then press `Ctrl+X` or run `/sessions`.
Select the original session. Lemon reloads its stored transcript when switching
to a cold session.

You can also switch or replay by key:

```text
/session switch <session-key>
/resume <session-key>
/history 20
```

Quit and start `lemon` again, then use `Ctrl+X` to reopen the same session. That
is the daily continuity path. `/reset` intentionally clears the current
session; `/session delete <session-key>` deletes stored history and requires the
explicit key.

Session rename, pin, archive, search, export, and guarded prune workflows are
documented in the [CLI guide](../user-guide/cli.md).

## 5. Try the next useful capability

Pick one path rather than configuring everything at once:

| Goal | First action | Guide |
| --- | --- | --- |
| Work in a repository | Start `lemon` from that repository, then ask it to inspect before editing | [Demo Lemon](../demo.md) |
| Add a reusable skill | Run `/skills`, inspect the selected skill, then confirm installation | [Skills](../user-guide/skills.md) |
| Recall durable context | Ask the agent to search the current project memory; keep adaptive writes opt-in until reviewed | [Memory](../user-guide/memory.md) |
| Run work in the background | Use `/bg start <prompt>`, then `/bg list` and `/bg result <id>` | [Long-running harnesses](../long-running-agent-harnesses.md) |
| Keep a standing objective | Use `/goal set <objective>`, inspect `/goal status`, and pause or clear it explicitly | [Long-running harnesses](../long-running-agent-harnesses.md) |
| Browse or fetch the Web | Ask for a bounded search/fetch task and inspect sources before acting on them | [Web and Browser Tools](../tools/web.md) |
| Add Telegram or Discord | Leave the TUI, run `lemon gateway setup telegram` or `lemon gateway setup discord`, then `lemon channels` | [Setup](../user-guide/setup.md#optional-telegram-or-discord) |
| Migrate from Hermes | Preview the import before writing any Lemon state | [Migrate from Hermes](../user-guide/migrate-from-hermes.md) |

## Recovery path

If the first real turn fails, keep the failure text and check in this order:

1. `lemon config validate` — resolve malformed or conflicting config.
2. `lemon secrets status` — confirm the encrypted store is available.
3. `lemon setup provider` — correct the credential/model and rerun the live
   provider check.
4. `lemon doctor --verbose` — inspect runtime and dependency diagnostics.
5. `lemon doctor --bundle` — create a redacted support bundle if the problem
   remains.

Do not paste provider keys, raw config secrets, or an unreviewed bundle into an
issue. The [Support guide](../support.md) explains the required evidence,
redaction boundary, logs, and current support limits.
