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

A missing adapter produces an error with the install hint above.
JavaScript/TypeScript (`vscode-js-debug`) is not supported: it requires child
debug sessions (`startDebugging`), which Lemon does not implement.

## Adapter selection

An explicit `adapter` always wins. Otherwise the program's extension picks the
adapter (`.py` → `debugpy`, `.go` → `dlv`, C-family/Rust/Swift sources →
`lldb-dap`/`gdb`). Extensionless programs (compiled binaries) use the first
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

Every action accepts `timeout` in seconds (default 30, max 600). Execution
actions that do not stop within the timeout return "still running" rather than
an error; use `pause` to interrupt.

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

- One active debug session per coding session. Terminate it before launching
  another. Breakpoints may be set before `launch`; they are sent during the
  DAP configuration handshake and persist across relaunches in the same coding
  session.
- When breakpoints are pending at launch, the program runs straight to them.
  Without breakpoints the adapter's stop-on-entry default applies (for
  `lldb-dap` that is the process entry point, before `main`).
- The debug adapter, its debug server and the debuggee are killed on
  `terminate`, when the program exits, when a launch is cancelled or fails,
  when the coding session ends, and after 10 minutes without a `debug` call.
- Adapter requests to open terminals (`runInTerminal`) or start child debug
  sessions (`startDebugging`) are rejected; debuggee output arrives through
  the adapter and is available via `output` (a 128 KiB rolling buffer; output
  over 16 KiB is returned as a tail with the full buffer saved to a file).
- Results are bounded: up to 200 variables per call, long values clipped, and
  each result capped at 32 KiB. Program output and values are treated as
  untrusted data before they reach the model.
- `debug` executes programs, so policy treats it like `bash`: it is denied in
  `safe_mode`/`subagent_restricted` and not included in `read_only`.
- Adapter configuration files (`dap.json`) and `vscode-js-debug` are not
  supported.
