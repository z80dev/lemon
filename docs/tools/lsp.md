# LSP Tools

Lemon has three language-tooling paths:

- `lsp`: the model-facing code-intelligence tool (diagnostics, navigation,
  symbols, rename, code actions, raw requests) backed by supervised language
  servers.
- `lsp_diagnostics`: the model-facing coding-agent tool for one-file
  diagnostics through local checkers and post-edit baseline/delta checks.
- supervised LSP sessions: BEAM-owned stdio language-server processes managed
  through the in-process `LemonLsp.ServerManager` API, which `lsp` uses.

Status and support bundles expose capabilities, counters, hashes, and install
hints, not raw file contents, raw workspace roots, raw session ids, diagnostic
output, or server I/O.

## Model-Facing `lsp` Tool

`lsp` talks to a real language server. The server is chosen by file extension
(see the [install guide](#language-server-install-guide)); its workspace root
is the nearest ancestor of the file, inside the working directory, that holds
one of the server's root markers (for clangd `compile_commands.json` or
`compile_flags.txt`), else the working directory.

| Parameter | Meaning |
| --- | --- |
| `action` | Required. `diagnostics`, `definition`, `type_definition`, `implementation`, `references`, `hover`, `symbols`, `rename`, `code_actions`, `status` or `request`. |
| `file` | File path relative to the working directory, or absolute. |
| `line` | 1-based line for position actions. |
| `symbol` | Text on `line` to position at (first occurrence; `name#N` for the Nth). Bare identifiers match whole words; case-insensitive matching is the fallback. |
| `column` | 1-based column (code points) when `symbol` is not given. Without either, the first non-blank character is used. |
| `query` | Workspace symbol search text, the code action to apply (index or title substring), or the method for `request`. |
| `new_name` | New name for `rename`. |
| `apply` | `true` writes `rename`/`code_actions` edits. Default `false` (preview/list). |
| `timeout` | Seconds, default 20, clamped to 5..300. |
| `payload` | JSON params for `request`; otherwise params are built from `file`/`line`/`symbol`. |

Examples:

```json
{"action":"references","file":"src/util.c","line":3,"symbol":"add_numbers"}
{"action":"rename","file":"src/main.c","line":6,"symbol":"add_numbers","new_name":"sum_numbers","apply":true}
{"action":"code_actions","file":"src/main.c","line":8,"apply":true,"query":"0"}
{"action":"symbols","query":"add_num"}
{"action":"request","file":"src/main.c","line":6,"symbol":"total","query":"textDocument/documentHighlight"}
```

Behavior:

- Locations print as `path:line:col` relative to the working directory with a
  one-line excerpt around each. Positions sent to the server are converted to
  UTF-16 offsets; printed columns are code points.
- `references` prints context for the first 50 results, plain locations up to
  500, and the total count. Workspace symbols are capped at 200 and
  diagnostics at 100 per file. Output above ~48 KB is saved to the session
  spill directory and referenced from the result.
- `diagnostics` uses pull diagnostics when the server advertises them, else
  waits (within `timeout`) for the server to publish diagnostics for the
  document version it was just sent.
- `symbols` with `file` lists document symbols; with only `query` it searches
  the workspace through the session's running servers (or servers whose root
  marker is in the working directory).
- `code_actions` uses the symbol's range, the column, or the whole line, and
  sends the diagnostics overlapping it. Applying resolves the action through
  `codeAction/resolve` when needed and runs its command through
  `workspace/executeCommand`, applying edits the server sends back.
- Applied edits support text edits and create/rename/delete file operations.
  Every affected path is locked, validated like `write`/`edit` targets and
  checkpointed before the first write; text edits are validated (overlaps,
  ranges, snippets) before any file is written; files are replaced atomically
  and the session's read tracker is refreshed, so a later `edit` is not
  rejected as stale. Applying calls are serialized with other mutating tools in
  the session; read-only calls run in parallel.
  A code action retains chronological `checkpoint_ids` for its direct edit and
  every server-requested batch, including partial failure or cancellation.
  Rewinding restores these batches in reverse order, recovering the pre-action
  state for repeated as well as disjoint paths. A failed action reports
  `success: false`; its receipt still identifies any committed paths and
  recoverable checkpoints.
- `status` lists every registered server as installed, missing (with its
  install hint) or running for this session.

One initialized server is kept per (session, server, workspace root). Opened
documents are re-synced (`didChange` with a new version) whenever their bytes
on disk change. Servers stop when the owning session ends or after 10 idle
minutes. A missing server binary is reported with its install hint. `lsp` is
in the dangerous-tool set because some servers build or run project code.

## `lsp_diagnostics` Tool

`lsp_diagnostics` accepts a file path relative to the active working directory:

```json
{"path":"lib/example.ex"}
```

`write`, `edit`, and `patch` can opt into post-edit diagnostics with:

```json
{"diagnostics":true}
```

The post-edit path compares a pre-edit baseline with the post-edit result and
reports newly introduced diagnostics separately from pre-existing issues.
Missing tools or unsupported file types return structured skipped results
instead of failing the edit.

## Local Checker Install Guide

The preview runner uses local workspace tools when they are present:

| Language | File extensions | Checker path | Install notes |
| --- | --- | --- | --- |
| Elixir | `.ex`, `.exs`, `.heex` | syntax parser, then `mix compile --return-errors` when a `mix.exs` workspace exists | Install Elixir and Mix. |
| JavaScript | `.js`, `.cjs`, `.mjs` | `node --check` | Install Node.js. |
| TypeScript | `.ts`, `.tsx`, `.jsx` | `tsc --noEmit --pretty false` when `tsconfig.json` exists, preferring workspace `node_modules/.bin/tsc` when present | Install TypeScript in the workspace or on `PATH`. |
| Python | `.py` | `python3 -m py_compile` or `python -m py_compile` | Install Python 3. |
| Rust | `.rs` | `cargo check --message-format=short` when `Cargo.toml` exists | Install Rust and Cargo. |
| Go | `.go` | `go test ./...` when `go.mod` exists | Install Go. |
| C/C++ | `.c`, `.h`, `.cc`, `.cpp`, `.cxx`, `.hh`, `.hpp`, `.hxx` | `clang`/`gcc`/`cc` or `clang++`/`g++`/`c++` with `-fsyntax-only` | Install a C/C++ compiler; install `clangd` separately for supervised LSP sessions. |

The runner intentionally skips TypeScript, Rust, and Go when the expected
workspace marker is missing. C/C++ syntax checks run per file when a compiler is
available. That keeps single-file edits predictable outside a real project.

## Language Server Install Guide

The supervised stdio manager registers these language servers:

| Server id | Language | Command | Override env var | Install notes |
| --- | --- | --- | --- | --- |
| `elixir_ls` | Elixir | `elixir-ls` | `LEMON_LSP_ELIXIR_LS_COMMAND` | Install ElixirLS and put `elixir-ls` on `PATH`; alternatives `elixir-ls-language-server`, `language_server.sh`, and launcher paths such as `launch.sh` are also supported. Lemon sets `ELS_MODE=language_server` for this server. |
| `typescript_language_server` | TypeScript/JavaScript | `typescript-language-server --stdio` | `LEMON_LSP_TYPESCRIPT_COMMAND` | `npm install -g typescript typescript-language-server`. |
| `pyright` | Python | `pyright-langserver --stdio` | `LEMON_LSP_PYRIGHT_COMMAND` | `npm install -g pyright`. |
| `rust_analyzer` | Rust | `rust-analyzer` | `LEMON_LSP_RUST_ANALYZER_COMMAND` | Install rust-analyzer and put it on `PATH`. |
| `gopls` | Go | `gopls` | `LEMON_LSP_GOPLS_COMMAND` | `go install golang.org/x/tools/gopls@latest`. |
| `clangd` | C/C++ | `clangd` | `LEMON_LSP_CLANGD_COMMAND` | Install clangd and provide `compile_commands.json` or `compile_flags.txt` in the workspace for useful diagnostics. |

Override env vars can point at either a command on `PATH` or an absolute local
executable path. Public status redacts absolute paths to command basenames.

## Supervised Session API

The in-process session API is defined by
[`LemonLsp.ServerManager`](../../apps/lemon_lsp/lib/lemon_lsp/server_manager.ex):
start/initialize a session, open/change/close documents, send requests or
notifications, and stop the session. It is not exposed as control-plane RPCs.

Session status reports request/response counts, notification counts, open and
known document counts, redacted document URI hashes, diagnostic batch counts,
and severity counts. It does not expose raw text, raw URIs, workspace paths,
server logs, or diagnostic messages.

Language-server stderr is discarded by the launcher so log writes can never
interleave with JSON-RPC frames or leak private workspace paths to the caller
console; the parser still discards non-LSP prefixes and only records redacted
frame counters from valid JSON-RPC messages. When a language-server launcher
spawns child processes, `stop_session` also terminates those children so
wrapper-style servers do not outlive the BEAM-owned session. A session started
with an `owner` pid stops when that process exits. If a JSON-RPC request times
out, the manager by default treats the session as unhealthy, replies with
`:request_timeout`, terminates the launcher plus descendants, and records the
recent session as `:request_timeout` instead of leaving a stuck port alive;
requests made with `on_timeout: :cancel` send `$/cancelRequest` and keep the
session.

The manager answers server-initiated requests as a headless client
(configuration defaults, workspace folders, progress and capability
registration). `workspace/applyEdit` is accepted only during
`request_with_edits/4`, which requires an `apply_edit` callback returning
`{:ok, receipt}` or `{:error, reason}`. The callback runs outside the manager
through the caller's mutation/checkpoint path; the server receives
`applied: true` only after the filesystem application succeeds. Partial failures
and expired requests receive `applied: false`. Receipts/outcomes are returned in
application order. Only one edit-capturing operation may run per server session;
ordinary requests remain available during callbacks. Timeout or caller death
cancels the operation and stops its in-flight callback.

The manager records both push diagnostics from
`textDocument/publishDiagnostics` notifications and pull diagnostics from
`textDocument/diagnostic` responses. Public status keeps only URI hashes,
diagnostic counts, severity counts, and timestamps; the latest raw diagnostics
per document stay in-process for `document_diagnostics/2`.

## Focused Test Coverage

From the umbrella root:

```bash
mix test apps/coding_agent/test/coding_agent/tools/lsp_diagnostics_test.exs \
  apps/coding_agent/test/coding_agent/tools/lsp_test.exs \
  apps/coding_agent/test/coding_agent/tools/lsp_clangd_test.exs \
  apps/coding_agent/test/coding_agent/tools/lsp \
  apps/lemon_lsp/test --seed 1
```

These exercise supervised server startup, framing, server-initiated requests,
document diagnostics, timeout cleanup, wrapper-child termination, the `lsp`
tool against a scripted fake server, and (when `clangd` is on `PATH`) against
real clangd. They are not proof that a particular language server is
installed or correctly configured on an operator's machine.
