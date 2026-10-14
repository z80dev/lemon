# Eval

`eval` runs code cells in persistent Python or JavaScript kernels. Each coding
session gets one kernel per language, started on first use in the session's
working directory. Variables, imports, functions and classes defined in one call
remain available in later calls, so a model can work incrementally: imports,
then definitions, then use.

## Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `language` | `"py"` or `"js"` | Kernel to run in. Required. |
| `code` | string | Cell source. Required. |
| `title` | string | Short label for the step (for example `"load config"`). |
| `timeout` | number | Cell deadline in seconds. Default 30, maximum 600. `0` disables the deadline; the cell can still be cancelled. |
| `reset` | boolean | Discard that language's kernel state before running. The other language's kernel is untouched. |

```json
{"language": "py", "title": "load", "code": "import json\nrows = json.load(open('data.json'))\nlen(rows)"}
```

```json
{"language": "py", "code": "rows[0]"}
```

## Behavior

- **Display.** Printed output (stdout, stderr and subprocess output) is
  returned as it was produced, followed by the value of the cell's trailing
  expression: Python `repr()` (nothing for `None`) or Node's `util.inspect()`
  (nothing for `undefined`). Errors return the traceback or stack, limited to
  the cell's own frames; kernel state survives ordinary errors.
- **Top-level `await`.** Works in both languages. Python cells run on a
  persistent asyncio event loop, so call `await coro()` rather than
  `asyncio.run(...)` from a cell that already awaits.
- **JavaScript scope.** Top-level `const`, `let`, `var`, `function` and `class`
  declarations become kernel globals, so they persist and can be re-declared in
  a later cell. Static `import` declarations and `require` resolve modules from
  the project root (`node_modules` there, or relative paths). TypeScript syntax
  is not transpiled.
- **Streaming.** Output streams to the client while the cell runs.
- **Output cap.** Like `bash`, the result keeps the last 50 KB / 2000 lines.
  Larger output is saved to a private file whose `artifact://` handle and path
  appear in the result; read it with `read` and `offset`/`limit`.
- **Timeouts and cancellation.** When the deadline expires or the run is
  cancelled, the kernel and every process it started are killed, and its state
  is lost. The result says so, and the next call starts a fresh kernel and
  reports that it did (`details.kernel_restarted`).
- **Lifetime.** Kernels are killed when their session ends and after 30 minutes
  without use. A kernel that exits on its own (for example `os._exit()` or
  `process.exit()`) reports its exit status; the next call starts fresh.

`details` contains `language`, `title`, `status` (`ok`, `error`, `timeout` or
`aborted`), `duration_ms`, `kernel_restarted`, `truncated` and
`full_output_path`.

## Requirements

| Language | Runtime | Notes |
| --- | --- | --- |
| Python | `python3`, or `python` | Python 3.8 or later (top-level `await`). |
| JavaScript | `bun`, or `node` | Bun is preferred; Node is used when Bun is not on `PATH`. |

If no runtime is found, the call fails with an error that names the missing
binaries. Kernels inherit Lemon's environment and run with the user's
permissions.

## Policy

`eval` executes arbitrary code. It is classified with `bash`: it is serialized
with other mutating tools in a session, denied by the `safe_mode` and
`subagent_restricted` profiles, included in `minimal_core`, and its output is
fenced as untrusted shell output before it reaches the model.

## Limits

Stdin is not available to cells (Python's `input()` raises `EOFError`). Cells
run one at a time per kernel. Only this core cell protocol is ported from omp:
there are no prelude helpers, `tool.*` callbacks, subagent or completion
bridges, magics, or browser integration.
