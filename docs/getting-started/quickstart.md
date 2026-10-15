# Start coding with Lemon in five minutes

Connect a model, make one small repository change, and keep the same session for
larger work. You need a supported macOS or Linux machine, an interactive terminal,
`curl`, `tar`, `python3`, and a model-provider account. Prebuilt releases include
Elixir and the terminal client; model requests use your provider's account.

> **Release availability:** install the latest stable release for this guide.
> Preview releases are also available on the
> [releases page](https://github.com/z80dev/lemon/releases).

## 1. Install and connect ChatGPT

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --skip-setup
export PATH="$HOME/.lemon/bin:$PATH"
lemon setup
```

The installer verifies both runtime and TUI checksums and adds `~/.lemon/bin`
to PATH in your shell rc file; the `export` line covers the current terminal.

In setup, choose **OpenAI Codex**, then **Sign in with ChatGPT (browser OAuth)**.
Alternatively, explicitly choose **Import existing Codex CLI ChatGPT login
(read-only copy)** if you already use Codex. Import is opt-in, not an automatic
read of another client's credentials. Accept the offered default model, or select
another model available to your account. With a Claude Pro or Max plan, choose
**Anthropic**, then **Sign in with Claude Pro/Max (browser)** instead (or run
`lemon model anthropic` later). Other providers and API-key login are also
supported; see [provider setup](../user-guide/setup.md).

Skip the optional daily brief and runtime configuration for now. Setup is safe to
rerun: a usable provider is kept, not logged in again. Do not paste credentials
into chat or a repository.

## 2. Make one useful change

In your repository's terminal, start:

```bash
lemon tui
```

Lemon starts or reuses its local daemon and opens the standalone TUI in that
directory. Bare `lemon` is equivalent, including in a Tern pane, where the TUI
uses Tern's native surfaces. Send this small, reviewable first task:

```text
Read the repository instructions. Find how to run the tests. Add the test command to README if missing, run the focused tests, and show the diff.
```

Watch the streamed answer, file edits and test output. Review the diff before
keeping the change. A completed turn proves the provider and tools work together;
a green diagnostic alone is not that proof.

Use **Ctrl+O** to choose a model and **Ctrl+X** to reopen a persisted session.
While running, **Escape** stops the turn. While idle with an empty input,
**Ctrl+C twice** quits the TUI without stopping the daemon.

To revisit an earlier prompt, enter:

```text
/rewind
```

Pick a prompt and inspect the preview. Confirmation is required and cancellation
is the default. Ordinary rewind changes conversation history, **not your files**;
plan mode and the agent's todo list return to that point too, while spend is never
refunded. The explicit file-restoration option and session tree (`/tree` also
switches branches, labels entries and forks from any point) are described in the
[TUI guide](https://github.com/z80dev/lemon/blob/main/clients/tui/README.md).

If a turn fails or you stop it, `/retry` rewinds that turn (history only) and
resends the prompt. To pick up where you left off next time, start the TUI with
`lemon -c` (latest session) or `lemon -r` (session picker).

## 3. Choose your interface

**Scripts and CI:** run from the same repository. JSON mode returns one result
object; stdout is machine-readable and failures exit nonzero. This example is
read-only, so it does not need an interactive approval:

```bash
lemon -p "Explain this repository; do not edit files." --output json
```

See the [CLI guide](../user-guide/cli.md) for stdin, streaming JSON, continuation
and explicit tool-approval policy. Bare `lemon` requires a terminal.

**Tern:** type `lemon` in a Tern pane for the TUI on Tern's native surfaces.
To also get palette actions and Tern's native ACP chat, register Lemon once:

```bash
lemon tern install
```

Run `tern plugin reload`, then use **Lemon: New session in split** from the
palette, or `tern acp lemon` for the ACP chat, where Tern owns the chat, tool
cards and permissions and Lemon owns the coding session. See the
[Tern guide](../user-guide/tern.md) for registration paths and troubleshooting.

**Web dashboard:** the default full installation also includes:

```bash
lemon web --no-open
```

Open the printed local URL. Sessions show stored conversations; **Automation**
shows goals and kanban dispatch with status, progress, results and run links.
See the [web guide](../user-guide/web.md#automation-and-blueprints).

The browser uses the control-plane operator token
(`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`), which the launcher manages automatically.
Follow [sign in](../user-guide/web.md#sign-in); without a configured token, the
UI returns 503 unless explicit tokenless loopback compatibility is enabled.
Keep the token private.

## 4. Grow the workflow, not the setup ceremony

- **Parallel subagents and personas:** ask, “Use two task children in parallel:
  a scout to locate the tests and a reviewer to inspect edge cases. Summarize
  their findings; do not edit files.” Shipped `scout`, `reviewer`, and
  `security-reviewer` personas are read-only. Custom personas live in project or
  user `.lemon/agents/` directories, and existing omp (`.omp/agents/`) or Claude
  Code (`.claude/agents/`) agent definitions are picked up too;
  see [subagents and commands](https://github.com/z80dev/lemon/blob/main/apps/coding_agent/README.md#subagents-and-commands).
- **MCP tools:** inspect configured servers with `lemon mcp list`. Then follow
  the [Skills guide: managing MCP servers](../skills.md#manage-named-mcp-servers) to add and test a server before relying
  on its tools. Server processes can execute code; configure only servers you
  trust.
- **Durable goals and kanban:** ask the agent to create a repository goal and a
  board with a small, concrete task. Explicitly say whether to start execution.
  A safe first request is: “Use the goal and kanban tools to record a goal to
  improve test coverage, pause that goal, and create a board called Coverage
  with one task to add a negative-number test. Do not start any work.” Inspect
  the records in the dashboard before starting a bounded goal loop or board
  dispatch. Goal loops edit their target directory directly; Git-backed kanban
  tasks use separate worktrees whose changes need review before merging. See
  [automation controls](../user-guide/web.md#automation-and-blueprints) and the
  [coding automation guide](../user-guide/reminders-and-heartbeats.md#coding-goals-and-scheduled-coding-jobs).

## If the first turn fails

```bash
lemon doctor
```

Follow the failing check's concrete fix. Doctor checks config, resolvable
credentials, model selection, dependencies and runtime health; it does not claim
to have made a model request. For credential changes, use the
[setup guide](../user-guide/setup.md); for logs and redacted support bundles, use
[Support](../support.md). Never post tokens, raw secrets or an unreviewed bundle.
