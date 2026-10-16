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
- **Rich `display(value)`.** Both kernels emit PNG/JPEG bytes, Markdown and JSON
  through a private 0600 JSONL side channel, separate from stdout. Images become
  `ImageContent` blocks; Markdown and formatted JSON become text content blocks.
  Byte buffers are detected by PNG/JPEG signatures. Strings default to Markdown;
  other JSON-serializable values default to JSON. Explicit MIME bundles work:
  `display({"text/markdown": "**hello**"})` and
  `display({"application/json": {"answer": 42}})`. Python also accepts
  `display(value, mime="image/png")` and standard `_repr_png_`, `_repr_jpeg_`,
  `_repr_markdown_` and `_repr_json_` methods; JavaScript accepts the MIME type as
  its second argument. Rich outputs are collected when the cell finishes and do
  not alter the captured stdout. Limits are 1 MiB per serialized display,
  4 MiB / 32 displays per cell; exceeding a limit returns a cell error without
  resetting the kernel.
- **Python magics.** A standalone `%pip install <arguments>` cell runs
  `<kernel Python> -m pip install ...` in the kernel environment, without a shell
  or resetting variables/imports. `%load "path with spaces.py"` executes a UTF-8
  file in that same namespace; paths resolve from the kernel cwd. Installation
  and load errors are ordinary cell errors and retain earlier state.
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
- **Timeouts and cancellation.** A deadline first sends SIGINT and allows a
  two-second grace period for the cell to unwind, preserving variables/imports
  when it does. Python and Node synchronous execution support this interruption.
  Uninterruptible native calls and pending JavaScript asynchronous work may not
  unwind; after grace the kernel/process tree is killed and the next call starts
  fresh. The result explicitly says whether state was preserved or lost.
  Cancellation still kills immediately.
- **Lifetime.** State survives native executor turns only when saving succeeds
  and every tool resource accepts handoff; failure disposes the resources.
  A resumed turn reuses the same kernel. Reset rebuilds tools for the fresh
  session id and disposes old-id kernels. Explicit abort signals the run before
  disposal; explicit stop, delete, unexpected owner death, or 30 minutes without
  use also dispose of kernels. A root
  that exits (`os._exit()` or `process.exit()`) also kills its owned process group
  and reports its exit status; the next call starts fresh.

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
run one at a time per kernel. There are no `tool.*` callbacks, subagent or
completion bridges, or browser integration. JavaScript `%bun add` / `%npm`
magics are intentionally not provided: JS resolves the project's `node_modules`,
not a separate kernel package environment. Use the normal approved package-manager
workflow for project dependencies, then import them without resetting the kernel.
