# Shell and Background Processes

Start a background command with `bash` and `run_in_background: true`. Its returned
`process_id` identifies the job. Process tools are session-scoped: another session
cannot read, write or stop your processes.

Ordinary foreground commands also start under the process manager. `timeout`
limits the foreground wait (default 120000 ms, maximum 600000 ms), not the command
lifetime: expiry returns `details.process_id` and `background: true` while the
same process continues capturing output. Use `bash_output` to retrieve it; do not
rerun the command. Abort signals before detachment still stop the workload.
Session exit stops its owned jobs, including detached commands.

PTY and ACP-client terminals are exceptions: their existing executor owns the
terminal protocol/handle, not a local process-manager backend. They still kill
on timeout. A local port cannot adopt an ACP client's remote terminal handle;
supporting detachment there requires a managed terminal backend that retains
that protocol ownership through session cleanup.

## Dedicated-tool routing

`[runtime.tools.bash.interceptor] enabled = true` opts in to pre-launch routing
(default false). File reads (`cat`, `head`, `tail`, `less`, `more`) suggest `read`;
content searches (`grep`, `rg`, `ripgrep`, `ag`, `ack`) suggest `grep`; discovery
(`find`, `fd`, `locate`) suggests `find`; `ls` suggests `ls`; in-place `sed`/`perl`
edits suggest `edit`. Only available session tools trigger routing.

The scanner respects quotes/escapes and examines chained commands, subshells and
command substitutions after internal URL expansion. Stages reading piped stdin
(for example `git log | head`) are exempt; the first stage is still checked.
Refusals are error tool results before any process starts, including background
jobs and named services. Custom `rules` replace the defaults; set `enabled = false`
to disable. See [configuration](../config.md#bash-dedicated-tool-routing).
This is a convenience guard, not a shell sandbox: dynamic shell evaluation is
not resolved.

## Destructive Git guard

`bash` blocks destructive Git commands by default, before launching foreground,
background or named-service processes. The error explains the operation, risk and
how to disable it with `[runtime.tools.bash] git_guard = false`.

Blocked forms are `reset --hard`; `checkout -- <paths>`, `checkout .` and forced
checkout; worktree `restore` (including `--staged --worktree`); forced `clean`;
`stash drop`/`clear`; forced `push` (including `--force-if-includes`) without
`--force-with-lease`; `branch -D`; forced `worktree remove`; and
`switch --discard-changes`/`-f`. Soft/merge/keep reset, staged-only restore,
lease-protected push and ordinary branch checkout/switch remain allowed.
Global Git options such as `-C` and `-c` are recognized.

Task-isolation worktrees are exempt only when the task store records the prepared
workspace and Git's worktree links confirm it. Nested cwd and Git `-C` are checked
against that workspace; changing to the parent checkout is not exempt. Missing
records, symlink escapes, Git-directory overrides, environment overrides and
ambiguous shell cwd changes (including env/sudo wrappers) fail closed (no exemption).
No Git process is started to discover an exemption. These literal-command checks
are not a shell sandbox.

## Named services

Use `name` to start a long-lived service without a command deadline. Names are
scoped to the calling session and project directory; starting the same name stops
the previous workload before launching its replacement. Services require a session
id and use ProcessManager's existing ownership, output limits and cleanup.

```json
{"command":"python3 -m http.server 8765","name":"web","ready":{"port":8765}}
```

Optional `ready` accepts a `log` regular expression and/or a TCP `port` (1–65535).
The call returns when **either** supplied condition passes. `host` defaults to
`127.0.0.1`; `timeout_s` defaults to 30 seconds (positive, maximum 3600).
An early exit or readiness timeout returns an error with recent output. A timed-out
service stays managed so it can be inspected or stopped. Without `ready`, startup
returns once the service is running. `name` cannot be combined with `timeout`,
`pty: true`, or `run_in_background: true`.

`read proc://` lists services with their names and process ids. Read
`proc://web` to inspect output without consuming it, write `proc://web` to send
stdin, and write `proc://web/kill` or call `kill_process` with `process_id: "web"`
to stop it. Process ids remain valid for all existing process tools.


## Output

Ordinary foreground `bash` presents up to 50 KB / 2000 lines with head/tail
windows and records output under the same bounded capture policy as background
jobs. Larger output includes a saved
output reference; when a session artifact index is available this is an
`artifact://` handle. The manager's per-process, owner and runtime artifact
quotas still apply: detachment introduces no capture gap, but does not make
output retention unlimited. `bash_output` reports capture limits and incomplete
artifacts explicitly. PTY/ACP executors retain their existing output windows.

`pty: true` uses the system `script` utility for foreground execution. If it is
unavailable, the command still runs without a terminal, with a prepended
`pty requested but unavailable; ran without a terminal` notice and
`details.pty_fallback: true`. Background commands do not support `pty: true`.

`bash_output` normally returns complete lines produced since the preceding
consuming read and advances the job's read cursor. Set `peek: true` to return
recent buffered output without changing that cursor, including output already
read. This works for running and finished jobs. The buffer is bounded; dropped
lines and saved-output capture limits are reported in the result.

```json
{"process_id": "PROCESS_ID", "peek": true}
```

## Input and EOF

`process_input` writes the `input` string exactly as supplied. It appends nothing;
include `\n` explicitly when the program expects a line. `eof: true` closes stdin
after writing, without closing output collection or losing the exit status. An
empty string with EOF closes input without writing bytes. Further input is
rejected after EOF, and input to a process that is no longer running returns an
error. Like `bash` and `kill_process`, this tool follows the shell tool policy.

```json
{"process_id": "PROCESS_ID", "input": "answer\n"}
{"process_id": "PROCESS_ID", "input": "", "eof": true}
```

## Stop

`kill_process` accepts `signal: "term"` (the default) or `signal: "kill"`.
`term` sends SIGTERM to the owned workload, allowing cleanup, then sends SIGKILL
after a two-second grace period if it is still alive. `kill` sends SIGKILL
immediately. Queued launches are canceled without starting. The tool returns a
cancellation receipt; use `bash_output` to observe the final status.
