# Debugger (`debug` tool)

The `debug` tool lets the coding agent drive a real debugger through the
[Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
(DAP): set breakpoints, launch or attach, step, and inspect stack frames,
scopes, variables and expressions. Use it instead of `printf` debugging or
ad-hoc `bash` invocations of `lldb`/`gdb` when you need program state.

## Requirements

Lemon starts the adapter as a local subprocess. Install the one for your
language:

| Adapter id | Used for | Command Lemon runs | Install |
| --- | --- | --- | --- |
| `lldb-dap` | Native binaries, C/C++, Objective-C, Rust, Swift, Zig | `lldb-dap` (macOS: `xcrun -f lldb-dap`; legacy `lldb-vscode`) | macOS: `xcode-select --install`; Linux: `apt install lldb` |
| `gdb` | Native binaries, C/C++, Rust | `gdb -i dap` | GDB 14 or newer |
| `debugpy` | `.py` scripts | `python3 -m debugpy.adapter` | `pip install debugpy` |
| `dlv` | `.go` files, Go package directories, Go binaries | `dlv dap --client-addr=…` (Delve dials back over loopback TCP) | `go install github.com/go-delve/delve/cmd/dlv@latest` |
| `js-debug` | JavaScript/TypeScript | `js-debug-adapter <port> 127.0.0.1` (loopback TCP) | Standalone vscode-js-debug adapter |
| `codelldb` | C/C++, Rust, Zig | `codelldb --port <port>` (loopback TCP) | Standalone CodeLLDB adapter |
| `netcoredbg` | C#/F# | `netcoredbg --interpreter=vscode` | Samsung netcoredbg |
| `rdbg` | Ruby | `rdbg --open --host 127.0.0.1 --port <port> --command -- ruby <program> …` | `gem install debug` |

A missing adapter produces an error with the install hint above.
Adapters may request child sessions through DAP `startDebugging`. Lemon creates
an independent DAP connection and launches or attaches with the provided
configuration, preserving adapter-specific fields such as js-debug target IDs.

## Adapter selection

An explicit `adapter` always wins. Otherwise the program's extension picks the
adapter (`.py` → `debugpy`, `.go` → `dlv`, `.js`/`.ts` family → `js-debug`,
`.rb` → `rdbg`, `.cs`/`.fs` → `netcoredbg`, C-family/Rust/Zig/Swift sources →
`lldb-dap`/`gdb`/`codelldb`). Extensionless programs (compiled binaries) use the first
installed of `gdb`, then `lldb-dap`, preferring adapters whose project root
markers (`Cargo.toml`, `go.mod`, `Makefile`, …) are found above the program.
Only `dlv` accepts a directory (Go package) as `program`; for `dlv`, `.go`
files and directories debug as source (`mode=debug`) and other files as
compiled binaries (`mode=exec`).

## Actions

| Action | Parameters | Result |
| --- | --- | --- |
| `launch` | `program` (required), `args`, `adapter`, `cwd`; optional initial breakpoint `file` + `line` or `function` (+ `condition`, `hit_condition`) | Starts the program under the debugger and waits for the first stop or exit |
| `attach` | `pid` or `port` (+ `host`), `adapter`, `cwd` | Attaches to a running process or debug server |
| `set_breakpoint` | `file` + `line` (or `function`), `condition`, `hit_condition` | Sets a source (or function) breakpoint |
| `remove_breakpoint` | `file` + `line` (or `function`) | Removes it |
| `set_function_breakpoint` | `function`, `condition`, `hit_condition` | Sets a function breakpoint |
| `continue`, `step_over`, `step_in`, `step_out` | `thread_id` | Resumes and waits for the next stop or termination |
| `pause` | `thread_id` | Interrupts a running program |
| `stack_trace` | `thread_id`, `levels` (default 20) | Frames as `#0 func file:line (frame_id N)` |
| `threads` | — | Thread list; `*` marks the stopped thread |
| `scopes` | `frame_id` (default: top frame) | Scopes with their `scope_id` |
| `variables` | `scope_id` or `variable_ref` | `name = value (type) [ref N]`; expand `[ref N]` with `variable_ref` |
| `evaluate` | `expression`, `context` (`repl` default, `watch`, `hover`, `variables`, `clipboard`), `frame_id` | Expression result; `repl` also accepts debugger commands |
| `output` | — | Program and adapter output captured so far |
| `status` / `sessions` | — | Current session, stop location and breakpoints |
| `terminate` | — | Ends the debug session and kills the debuggee |
| `custom_request` | `command`, `arguments` (object) | Sends any DAP request and returns its raw body |
| `data_breakpoint_info` | `arguments`: DAP `name`, `variablesReference` / `frameId` | `dataBreakpointInfo` response including `dataId` |
| `set_data_breakpoints` | `arguments.breakpoints`: DAP data-breakpoint list (`dataId`, `accessType`, optional conditions) | Replaces data breakpoints; empty list clears them |
| `set_instruction_breakpoints` | `arguments.breakpoints`: DAP instruction-breakpoint list | Replaces instruction breakpoints |
| `read_memory` | `arguments`: `memoryReference`, positive `count`, optional `offset` | DAP `readMemory` body with base64 data |
| `disassemble` | `arguments`: `memoryReference`, positive `instructionCount`, optional offsets | DAP instructions |

Every action accepts `timeout` in seconds (default 30, clamped to 5..300). Execution
actions that do not stop within the timeout return "still running" rather than
an error; use `pause` to interrupt.

`status` / `sessions` include a recursive `children` list with session `id` and
`parent_id`. Pass `debug_session_id` to any action to target that session;
without it, actions target the root. For example:

```json
{"action": "sessions"}
{"action": "stack_trace", "debug_session_id": "debug-1-1-1"}
{"action": "continue", "debug_session_id": "debug-1-1-1"}
```

Children use the parent's adapter and working directory unless the adapter
configuration supplies a directory. Server-mode adapters (including js-debug)
reuse the parent's listening endpoint with a new connection. Child startup is
asynchronous; inspect its status/error after creation. Parent termination,
adapter exit, or coding-session teardown also disposes of all descendants.

Source breakpoints accept `log_message` (DAP `logMessage`) instead of stopping.
Log points and advanced breakpoint/memory/disassembly actions require the matching
advertised adapter capability; unsupported operations fail without sending a request.
Advanced DAP arguments and responses are limited to 128 KiB; read counts are
clamped to 131,072, and oversized responses return a clear error rather than a
partial JSON body. `custom_request` remains the explicit unrestricted DAP escape hatch.

## Example

```json
{"action": "set_breakpoint", "file": "src/main.c", "line": 42}
{"action": "launch", "program": "./build/app", "args": ["--verbose"]}
{"action": "stack_trace"}
{"action": "scopes"}
{"action": "variables", "scope_id": 1}
{"action": "evaluate", "expression": "count * 2"}
{"action": "step_over"}
{"action": "continue"}
{"action": "terminate"}
```

`launch` and the execution actions report the stop with a source excerpt:

```text
Launched build/app with lldb-dap (session debug-1).
Stopped: breakpoint (breakpoint 1.1) at src/main.c:42 in main (thread 1)
src/main.c:
  41 |   int total = 0;
> 42 |   total = add(x, y);
  43 |   printf("%d\n", total);
```

## Behavior and limits

- One active root debug session per coding session, with adapter-requested children.
  Terminate the root before launching another. Breakpoints may be set before `launch`; they are sent during the
  DAP configuration handshake and persist across relaunches in the same coding
  session.
- When breakpoints are pending at launch, the program runs straight to them.
  Without breakpoints the adapter's stop-on-entry default applies (for
  `lldb-dap` that is the process entry point, before `main`).
- Successful native executor turns preserve the debugger across save/stop/resume
  of the transient session process. Explicit abort/stop or logical reset/delete,
  failed launch, unexpected owner death and 10-minute idle expiry dispose of it.
- Locally launched adapters and their debuggees are killed on teardown; a crashed
  adapter also disposes of its launched debuggee. Attached targets are not owned:
  `terminate` disconnects without terminating them.
- Debugpy port attach connects directly to the DAP endpoint exposed by
  `python -m debugpy --listen <port>`; no second local Python adapter is launched.
- Adapter requests to open terminals (`runInTerminal`) are rejected;
  `startDebugging` supports launch/attach child sessions. Debuggee output arrives
  through the adapter and is available via `output` (a 128 KiB rolling buffer; output
  over 16 KiB is returned as a tail with the full buffer saved to a file).
- Results are bounded: up to 200 variables per call, long values clipped, and
  each result capped at 32 KiB. Program output and values are treated as
  untrusted data before they reach the model.
- `debug` executes programs, so policy treats it like `bash`: it is denied in
  `safe_mode`/`subagent_restricted` and not included in `read_only`.
- Adapter configuration files (`dap.json`) are not supported.
