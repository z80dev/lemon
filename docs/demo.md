# Try Lemon on real work

A good first task is small enough to inspect and useful enough to keep. Explore
a repository, ask a follow-up, then return to the conversation from your session
list. These walkthroughs show what to look for at each step.

## Before you begin

Complete the [quickstart](getting-started/quickstart.md) to install Lemon and
connect a model provider. The examples below use the installed release. Source
contributors can use `./bin/lemon-tui` for the terminal and `./bin/lemon web` for
the browser from their Lemon checkout.

## 1. Get oriented in a project

From a repository you want to understand, start Lemon:

```bash
lemon
```

Try this prompt:

```text
Inspect this repository without changing files. Explain what it does, identify
its main entry points, and find the canonical test command. Cite the files you
used, and flag anything you could not verify.
```

Watch the tool activity and final response. You should be able to connect each
claim to a file in the repository. Follow up with a narrower question, such as
“Where would I add a new command?” or “Explain the startup path.”

Use `/status` to inspect the session and `/usage` to see reported usage. With an empty input, press
`Ctrl+C` to abort an active run. If you have a draft, the first press clears it.

## 2. Leave and come back

Run `/session info` to see the current session key. Open the session picker with
`Ctrl+X` or `/sessions`, then return to this conversation. You can also use:

```text
/resume <session-key>
/history 20
```

Restart Lemon and select the same session. Its stored transcript should still
be available, so you can continue the discussion without pasting the previous
conversation. The [CLI guide](user-guide/cli.md) covers search, titles, pinning,
archive, and export.

## 3. Open the browser

The full release includes a local browser interface:

```bash
lemon web
```

The launcher reuses a healthy runtime or starts one, waits for the Web health
check, prints the URL, and opens your browser. Use `lemon web --no-open` when you
only need the address. The default is `http://127.0.0.1:4080/`; use the printed
address if you changed your configuration.

Open a session and send a short prompt. The browser checks provider readiness,
streams session activity, accepts bounded file uploads, and shows **Stop** while
a run is active. Read [Use Lemon in a Browser](user-guide/web.md) for access
control, session management, and recovery.

For a simple runtime check, use the host and port printed by the launcher:

```bash
curl -fsS http://127.0.0.1:4080/healthz
```

A successful response checks Web health. The completed model turn from the
quickstart separately checks provider access and the chat path.

## 4. Make it your own

| Try next | Why it helps |
| --- | --- |
| [Create a profile](user-guide/profiles.md) | Give a distinct kind of work its own workspace and conversation |
| [Add a skill](user-guide/skills.md) | Reuse instructions for a recurring task |
| [Review a source for learning](user-guide/learn-from-sources.md) | Turn selected context into reviewed memory or skill drafts |
| [Connect Telegram or Discord](user-guide/setup.md#optional-telegram-or-discord) | Reach your runtime from a messaging app |
| [Explore LemonSim](benchmarks/quickstart.md) | Evaluate agents in replay-verifiable simulation worlds |

## If something fails

```bash
lemon doctor --verbose
lemon doctor --bundle
```

Doctor reports configuration and runtime diagnostics; the second command writes
a redacted support bundle. Review it before sharing. For source installs, use
`./bin/lemon doctor` with the same flags. The [support guide](support.md) explains
what to include in a report.

These walkthroughs validate individual local paths. Consult the
[support boundaries](support.md) and [release checklist](release/release_checklist_and_support_policy.md)
for integration-specific guarantees and production criteria.
