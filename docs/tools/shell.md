# Shell and Background Processes

Start a background command with `bash` and `run_in_background: true`. Its returned
`process_id` identifies the job. Process tools are session-scoped: another session
cannot read, write or stop your processes.

## Output

Foreground `bash` keeps a leading window of about 20 KiB plus the output tail,
retaining up to 50 KB / 2000 lines of command output. Omitted middle output is marked
explicitly. Full output stays on disk; when a session artifact index is available,
the spill notice and `details.artifact_uri` expose an `artifact://` handle readable
with `read` and `offset`/`limit`. Without an index, the notice retains the output
file path instead. Output capture does not load the full spill back into memory.

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
