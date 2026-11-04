# Start coding with Lemon in five minutes

Install Lemon, connect a model, make one small repository change, and keep the
same session for larger work. You need an interactive terminal on macOS (Apple
Silicon) or Linux (x86_64 or ARM64), `curl`, `tar`, `python3`, and an account
with a model provider. The prebuilt release bundles its own Erlang/Elixir
runtime, the terminal client and the browser-automation driver, so you do not
install any of them. Browser tools additionally need Node.js 24 or later and
Chrome/Chromium; `lemon doctor` reports what is missing. Model requests use
your provider's account.

Other platforms or a container: see [Install](../install.md).

## 1. Install and connect a model

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

The installer verifies the runtime and terminal-UI checksums, installs them under
`~/.lemon`, adds `~/.lemon/bin` to PATH for new shells, and then starts
`lemon setup` in your terminal.

In setup, choose **OpenAI Codex**, then **Sign in with ChatGPT (browser OAuth)**.
If you already use the Codex CLI, you can instead choose **Import existing Codex
CLI ChatGPT login (read-only copy)**; import is opt-in and never automatic. With a
Claude Pro or Max plan, choose **Anthropic**, then **Sign in with Claude Pro/Max
(browser)**. Other providers, local servers (Ollama, LM Studio, llama.cpp, vLLM,
LiteLLM) and API-key login are also supported; see
[Set up Lemon](../user-guide/setup.md). Accept the offered default model, or pick
another one your account can use.

Setup is safe to rerun: a usable provider is kept, not logged in again. It only
asks about ports if one is already taken, and suggests a free one. Do not paste
credentials into chat or a repository. Coming from Hermes? Run
`lemon migrate hermes` after setup.

Setup prints **Setup complete** only after a passing live credential check. If
you installed with `--skip-setup`, had no terminal when installing, or stopped
setup early, run it now:

```bash
lemon setup
```

(If `lemon` is not found in the terminal you installed from, open a new
terminal or run `export PATH="$HOME/.lemon/bin:$PATH"`.)

Confirm the install:

```bash
lemon version
```

## 2. Make one useful change

Accept **Open Lemon now? [Y/n]** at the end of setup, or start it later from your
repository's terminal. The TUI opens in the directory where you launch it, so
change into your project first:

```bash
cd path/to/your/repo
lemon
```

Bare `lemon` in an interactive terminal is the same as `lemon tui`. It starts or
reuses Lemon's local daemon and opens the terminal UI. In a Tern pane, the TUI
uses Tern's native surfaces. Send this small, reviewable first task:

```text
Read the repository instructions. Find how to run the tests. Add the test command to README if missing, run the focused tests, and show the diff.
```

Watch the streamed answer, file edits and test output. Review the diff before
keeping the change. A completed turn proves the provider and tools work together;
a green diagnostic alone is not that proof.

Setup's success check is a reply arriving and `lemon doctor` showing no **FAIL**.
Get this first conversation working before adding Telegram or the Web UI.

Use **Ctrl+O** to choose a model and **Ctrl+X** to reopen a persisted session.
While running, **Escape** stops the turn. While idle with an empty input,
**Ctrl+C twice** quits the TUI without stopping the daemon (`lemon stop` stops
it).

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
`lemon -c` (latest session from this directory) or `lemon -r` (session picker).

## 3. Choose your interface

**Scripts and CI:** run from the same repository. JSON mode returns one result
object; stdout is machine-readable and failures exit nonzero. This example is
read-only, so it does not need an interactive approval:

```bash
lemon -p "Explain this repository; do not edit files." --output json
```

See the [CLI guide](../user-guide/cli.md) for stdin, streaming JSON, continuation
and explicit tool-approval policy. Bare `lemon` requires a terminal.

**Web dashboard:** the default full installation also includes a local browser
interface:

```bash
lemon web --no-open
```

Open the printed local URL (or run `lemon web` to open it for you). Sessions show
stored conversations; **Automation** shows goals and kanban dispatch with status,
progress, results and run links. See the
[web guide](../user-guide/web.md#automation-and-blueprints).

The browser uses the control-plane operator token
(`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`), which the launcher manages automatically.
Follow [sign in](../user-guide/web.md#sign-in); without a configured token, the
UI returns 503 unless explicit tokenless loopback compatibility is enabled.
Keep the token private. `lemon web` is not part of the `min` profile.

**Tern:** type `lemon` in a Tern pane for the TUI on Tern's native surfaces.
To also get palette actions and Tern's native ACP chat, register Lemon once:

```bash
lemon tern install
```

Run `tern plugin reload`, then use **Lemon: New session in split** from the
palette, or `tern acp lemon` for the ACP chat, where Tern owns the chat, tool
cards and permissions and Lemon owns the coding session. See the
[Tern guide](../user-guide/tern.md) for registration paths and troubleshooting.

**Telegram or Discord:** add a chat channel after the terminal works:
`lemon gateway setup telegram` or `lemon gateway setup discord`. See
[Set up Lemon](../user-guide/setup.md#optional-telegram-or-discord).

**Mac app:** the native macOS application is Lemon Bot, built from source
today. See [Install: Mac app](../install.md#mac-app).

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

## Keep Lemon current

```bash
lemon update check
```

`check` compares your release with the published one. Apply an update only after
reading its plan; see [Update, roll back, and uninstall](../user-guide/updates.md).

## If the first turn fails

```bash
lemon doctor
```

Follow the failing check's concrete fix. By default doctor stays offline: it
checks config, resolvable credentials, model selection, dependencies and runtime
health without contacting providers or channels. To investigate a revoked key
or connectivity problem, opt in:

```bash
lemon doctor --live --verbose
```

This makes a non-generating models-list request to the default provider and
identity requests to configured Telegram/Discord bots. Requests have a five-second
timeout and share a six-second overall live-check deadline. Unsupported/OAuth-only
endpoints are skipped; no completion is generated. Failures count as `FAIL` and
exit `1`; `--json` includes live results. Output omits raw responses, keys and URLs.
Add `--provider NAME` (or `--provider all`) to check other configured providers too.
For credential changes, use the [setup guide](../user-guide/setup.md); for logs
(`lemon logs`) and redacted support bundles, use [Support](../support.md). Never
post tokens, raw secrets or an unreviewed bundle.

Installer problems (`command not found`, checksum or glibc messages) are covered in
[Install troubleshooting](../install.md#troubleshooting).
