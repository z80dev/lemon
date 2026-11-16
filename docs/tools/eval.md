# Eval

## Experimental code-mode profile

`code_mode` is **opt-in**. The existing `legacy`, `coding` and `auto` defaults
and their full-authority stateful Python/JavaScript `eval` kernels below are
unchanged. Select the experiment with:

```toml
[tools.disclosure]
profile = "code_mode"
```

Or set `LEMON_TOOL_DISCLOSURE_PROFILE=code_mode`, or pass
`tool_disclosure: [profile: :code_mode]` when starting a session.
Disclosure must be enabled. Custom hand-assembled toolsets still bypass
disclosure and are not implicitly converted into sandboxes.

The small direct surface is `eval`, `eval_wait`, `read`, `ask`, `todo`, `wait`
and `nodes`, where present and policy-allowed, plus explicitly pinned/extra
tools. `tool_search` and `tool_invoke` remain available: they are not removed
without a measured promotion decision. All other allowed tools remain in the
wrapped session catalog. The `eval` description includes TypeScript declarations
generated from that catalog: tools, object keys and union alternatives have
deterministic ordering, required/optional fields and JSON-quoted names.
Unsupported schemas/references are `unknown`, not invented types. This is
declaration rendering, not TypeScript execution or an authority grant.

Code-mode `eval` accepts an async **JavaScript function body**, with explicit
`return`, `console.log`, `await`, and `tools.NAME(args)`:

```json
{"code":"const r = await tools.bash({command: \"git status --short\"}); return {exit_code: r.exit_code, stdout: r.stdout};"}
```

Cells do not share variables. The stateful Python kernel is a separate
full-authority implementation available through ordinary-profile `eval`;
it is never an implicit fallback for code-mode cells.

| Parameter | Meaning |
| --- | --- |
| `code` | JavaScript async-function body; required. |
| `timeout` | Execution deadline in seconds, default/max 600 (the existing eval maximum). |
| `yield_after` | Initial wait in seconds, default/max 30; `0` returns immediately. |

A long-running cell returns `details.status = "yielded"` and a session-scoped
`cell_id`. Yield does **not** restart code, cancel tools or release their
individual mutation locks. Re-attach without replaying effects:

```json
{"cell_id":"cell_FROM_EVAL","yield_after":30}
```

Send that object to `eval_wait`; it accepts `cell_id` and `yield_after`.
Terminal statuses are `ok`, `error`, `timeout` or `aborted`. One cell runs per
session; a second `eval` refuses while it is running. Its bounded result
(last 50 KiB; `details.truncated` reports clipping) remains attachable until a
new cell replaces it, the resource expires after 30 idle minutes, or the session
is disposed. Cells survive successful session-resource handoff; new bridged
calls pause while detached, and re-attachment refreshes the session resolver.
They are volatile: a node/runtime crash does not journal or replay a cell.
Cancellation/deadline terminates the cell and aborts/joins outstanding tools.

### Isolation and bridge authority

The chosen runtime is **Deno 2**, required on `PATH` (or the trusted programmatic
`:code_mode_runtime` executable override). Host inspection for #598 found Bun
but **no Deno**. The repository's Wasmtime sidecar executes compiled WIT
`sandboxed-tool` components and provides capability-gated host callbacks; it
does not contain a JavaScript interpreter or a source-cell API. Adding one
would be a different runtime project. Requiring optional Deno gives this
experiment an existing permission boundary without altering the WASM sidecar
or the stateful `Eval.Kernel`.

The trusted Deno driver launches a worker with `permissions: "none"`; the
process also uses explicit `--deny-read`, `--deny-write`, `--deny-net`,
`--deny-env`, `--deny-run`, `--deny-ffi`, `--deny-sys`, `--no-remote`,
`--no-npm`, `--no-config` and `--no-prompt`. Cells cannot approve permission
requests, import arbitrary local/remote modules, read ambient environment,
touch files or open connections directly. Missing/incompatible Deno fails
closed, never falling back to Bun, Node, Python or ordinary `eval`.
Code-mode cells are local-only; their bridged tools may still route through
`nodes`, under the normal destination policy.

Tool calls resolve through the existing session catalog, including argument
validation, policy, approvals, hooks, secret handling and plan-mode gates.
Denied tools never enter the catalog. The sandbox is not a second authority
plane: file/network/process effects require those wrapped calls. Inner calls
retain the existing 16-concurrent/1,000-per-cell bridge limits. `eval`,
`eval_wait` and the disclosure bridge pair cannot recursively invoke themselves
through the cell bridge. Tool results remain untrusted, including printed or
returned summaries.

Bridge results preserve `{ok, text, details, images}` and promote authentic
core result fields. Local non-PTY code-mode `bash` additionally returns
`{stdout, stderr, exit_code, output, output_combined}` using a trusted Python 3
stream relay (Python 3 is required for this path). `stdout` and `stderr` are
independently bounded captured streams; `output` retains combined arrival order.
Unlike ordinary managed bash, this local foreground path kills on timeout
rather than detaching. PTY, ACP and remote/sandbox transports that only supply
combined output report null streams and `output_combined: true`; null means
unavailable, not empty. No tool text is parsed to manufacture an exit code.

### Paired evaluation and decision

**Decision: keep opt-in.** No success/token/cost improvement has been measured
for #598, and no default or discovery-tool removal is justified. The
orchestrator runs the paired evaluation separately; this change does not
authorize paid model calls.

With Docker, matching rebuilt Lemon arena images containing Deno/Python 3,
and the arena credential proxy already running, use a fresh output directory:

```bash
python3 apps/lemon_evals/priv/coding_arena/arena.py run \
  --agents lemon-coding,lemon-code-mode --models glm-5.3=1 \
  --thinking high --repetitions 3 --seed 598 \
  --output-dir /OPERATOR/PATH/code-mode-arena \
  --proxy-log /OPERATOR/PATH/proxy.jsonl
python3 apps/lemon_evals/priv/coding_arena/arena.py report \
  --output-dir /OPERATOR/PATH/code-mode-arena \
  --proxy-log /OPERATOR/PATH/proxy.jsonl
```

Retain verifier outcomes, all attempted wire tokens, exact source/image/model
identities and pricing needed for cost per verified success. Missing usage or
pricing remains unknown. The arena records the requested profile but cannot
attest the CLI's effective disclosure profile; do not use its arm label as
observed-profile evidence or as a promotion gate. See the
[paired-disclosure protocol](../benchmarks/paired-disclosure.md) for attribution,
approval/spend controls and the report's limitations.

## Ordinary-profile kernels

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
| `node` | string | Run the cell in a kernel on that named node instead (requires the `nodes` tool; see [other machines](nodes.md)). Its `tools.*` calls then run on the same node. |

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

## Session tools

A cell can call the session's own tools through the global `tools` object and
keep their results in code; only what the cell prints, displays or returns
reaches the model.

```js
const [local, remote] = await Promise.all([
  tools.bash({command: "uptime"}),
  tools.bash({command: "uptime", node: "build-box"}),
]);
console.log(local.text.trim(), "|", remote.text.trim());
```

```python
import asyncio
rs = await asyncio.gather(*(tools.bash(command="uptime", node=n) for n in ["a", "b"]))
print([r["ok"] for r in rs])
```

- **Calling.** Any property is a tool name: JavaScript `tools.<name>(args)`
  takes one object; Python `tools.<name>(**kwargs)` or `tools.<name>({...})`.
  Both accept `tools.call(name, args)`. Every call is asynchronous: `await` it,
  and use `Promise.all` / `asyncio.gather` to run calls concurrently. Arguments
  are passed to the tool unchanged, including `node` to run it on a named
  execution node ([run tools on other machines](nodes.md)).
- **Results.** Each call resolves to `{ok, text, details, images}` (a plain dict
  in Python): `ok` is false when the tool failed, `text` joins its text blocks
  (truncated above 1 MiB), `details` is a JSON projection of the tool's details
  (`null` above 64 KiB) and `images` holds `{mimeType, data}` base64 blocks
  (4 MiB per call). An unknown or unavailable tool, or non-object arguments,
  rejects the promise / raises instead.
- **Authority.** Tools resolve from the session's own frozen catalog with its
  policy, approval, hook and plan-mode wrappers, so a cell reaches exactly the
  tools the model could call. `eval` itself and the disclosure bridge tools
  (`tool_search`, `tool_invoke`) are not callable. Inner mutating calls inherit
  the cell's session mutation lock instead of deadlocking on it.
- **Limits.** At most 16 calls run at once (later ones queue) and 1,000 per
  cell. When the cell finishes, times out or is cancelled, outstanding calls
  are aborted and killed after a two-second grace; a timeout aborts them before
  interrupting the kernel so an awaiting cell can still unwind.

## Requirements

| Language | Runtime | Notes |
| --- | --- | --- |
| Python | `python3`, or `python` | Python 3.8 or later (top-level `await`). |
| JavaScript | `bun`, or `node` | Bun is preferred; Node is used when Bun is not on `PATH`. |

If no runtime is found, the call fails with an error that names the missing
binaries. Kernels inherit Lemon's environment and run with the user's
permissions.

On Unix, startup verifies the driver's reported kernel pid against its actual
host parent, group and process birth identity. Missing `ps` or an unprovable
identity refuses execution rather than claiming that arbitrary children can be
stopped. Reset, abort, owner loss, idle disposal and crashes stop that owned
kernel group, including children reparented after their launcher exits;
signals never target an unrelated group named by a forged ready frame. A
process that deliberately escapes into a separate group is not covered.

## Policy

`eval` executes arbitrary code. It is classified with `bash`: it is serialized
with other mutating tools in a session, denied by the `safe_mode` and
`subagent_restricted` profiles, included in `minimal_core`, and its output is
fenced as untrusted shell output before it reaches the model.

## Limits

Stdin is not available to cells (Python's `input()` raises `EOFError`). Cells
run one at a time per kernel. Beyond the session tools above there are no
subagent or completion bridges and no browser integration. JavaScript
`%bun add` / `%npm` magics are intentionally not provided: JS resolves the
project's `node_modules`, not a separate kernel package environment. Use the
normal approved package-manager workflow for project dependencies, then import
them without resetting the kernel.
