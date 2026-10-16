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
| `action` | Required. `diagnostics`, `definition`, `type_definition`, `implementation`, `references`, `hover`, `symbols`, `rename`, `rename_file`, `reload`, `capabilities`, `code_actions`, `status` or `request`. |
| `file` | File path relative to the working directory, or absolute. |
| `line` | 1-based line for position actions. |
| `symbol` | Text on `line` to position at (first occurrence; `name#N` for the Nth). Bare identifiers match whole words; case-insensitive matching is the fallback. |
| `column` | 1-based column (code points) when `symbol` is not given. Without either, the first non-blank character is used. |
| `query` | Workspace symbol search text, the code action to apply (index or title substring), or the method for `request`. |
| `new_name` | New symbol name for `rename`, or destination path for `rename_file`. |
| `apply` | `true` writes `rename`/`rename_file`/`code_actions` edits. Default `false` (preview/list). |
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
- `diagnostics` with `file: "*"` snapshots published diagnostics across running
  clients in this session/workspace, without starting servers or waiting for fresh
  analysis. It examines at most 32 clients and 200 files per client and returns
  at most 100 diagnostics total.
- `rename_file` takes `file` and `new_name` (a destination path). It previews by
  default; `apply: true` applies `workspace/willRenameFiles` edits before moving
  the file through the same locked/checkpointed WorkspaceEdit path, then sends
  `workspace/didRenameFiles` when supported. Existing destinations are not overwritten.
- `reload` restarts the server for `file`, or all running servers in this session
  when `file` is omitted or `"*"`. `capabilities` with `file` reports the selected
  server's advertised capabilities.
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
  If an interrupted server-requested edit has no final outcome, `affected_paths`
  identifies captured paths that may have changed, with an uncertainty warning;
  the receipt does not claim those paths stayed untouched. `changed_files` still
  reports confirmed mutations from completed batches.
- `status` lists every registered server as installed, missing (with its
  install hint) or running for this session.

One initialized OS process is shared per (server id, workspace root, effective
server configuration), across durable coding sessions and direct manager users.
Session-scoped clients hold reference-counted leases. Native turns hand off
clients only after saving and every resource handoff succeed; otherwise resources
are disposed. Resumed turns bind the same durable identity. Reset rebuilds tools
for the fresh session id and releases old-id leases. Explicit abort signals the
run before disposal; explicit stop, logical delete, unexpected owner death and
10 idle minutes also release that client's lease, without stopping a server
another session still owns.

The last release starts an idle grace period: configure
`[runtime.tools.lsp] idle_timeout_ms = 30000` (the default); `0` stops immediately.
Reacquisition cancels the timer. `ServerManager.release_session/2` releases one
lease, whereas `stop_session/1` and the tool's `reload` force a shared restart.

The manager reads the latest on-disk text during synchronization, owns each URI's
monotonically increasing version, opens it once and closes it only after its last
document owner releases it. Published diagnostics are available to every owner
and delivered as `{LemonLsp.ServerManager, :diagnostics, session_id, uri, entry}`
messages. A crash fails every in-flight request with a clear error, not an
automatic request replay; the next use starts and initializes a fresh process.
Configuration changes use a different pool key on the next catalog refresh/tool
call. A missing server binary is reported with its install hint. `lsp` remains
dangerous because some servers build or run project code.

## Server Configuration

The catalog is layered as built-in defaults → `~/.lemon/config.toml` →
project `.lemon/config.toml`, using the normal Lemon config loader. Configure
servers under `[runtime.tools.lsp.servers.<id>]`; known ids override individual
fields and unknown ids add servers (requiring `command` and non-empty
`extensions`, or its alias `file_types`). Server ids should use lowercase
letters and underscores.

```toml
[runtime.tools.lsp.servers.clangd]
command = "/opt/llvm/bin/clangd"
args = ["--background-index"]
root_markers = ["compile_commands.json", ".git"]
initialization_options = { clangdFileStatus = true }
env = { CLANGD_FLAGS = "" }

[runtime.tools.lsp.servers.pyright]
disabled = true

[runtime.tools.lsp.servers.my_language]
command = "my-language-server"
args = ["--stdio"]
extensions = [".mylang"]
language_id = "my-language"
```

Lists replace inherited lists; nested tables merge with project values winning.
`language_id` sets the LSP language id for all configured extensions; without it,
built-in per-extension ids remain intact. Extensions are case-insensitive and
may omit the leading dot. Disabled servers are absent from selection and lookup.
The documented `LEMON_LSP_*_COMMAND` variables still take priority over TOML
commands. Explicit `reload` also restarts an already-running shared server.

`CodingAgent.Tools.Lsp.Client` coordinates synchronization and initialization;
only `LemonLsp.ServerManager` opens LSP processes. The separately named
`lsp_diagnostics` and `LspFormatter` helpers execute local checker/formatter
commands, not LSP servers, and do not use this catalog.


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

External checkers use the deadline-aware process executor. A timeout terminates
the checker process group and descendants, rather than only the BEAM caller.

## Local Checker Install Guide

The preview runner uses local workspace tools when they are present:

| Language | File extensions | Checker path | Install notes |
| --- | --- | --- | --- |
| Elixir | `.ex`, `.exs`, `.heex` | syntax parser, then `mix compile --return-errors` when a `mix.exs` workspace exists | Install Elixir and Mix. |
| JavaScript | `.js`, `.cjs`, `.mjs` | `node --check` | Install Node.js. |
| TypeScript | `.ts`, `.tsx`, `.jsx` | `tsc --noEmit --pretty false` when `tsconfig.json` exists, preferring workspace `node_modules/.bin/tsc` when present | Install TypeScript in the workspace or on `PATH`. |
| Python | `.py` | `python3 -m py_compile` or `python -m py_compile` | Install Python 3. |
| Rust | `.rs` | `cargo check --message-format=short` when `Cargo.toml` exists | Install Rust and Cargo. |
| Go | `.go` | `go vet ./...` when `go.mod` exists (does not execute tests) | Install Go. |
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
| `tlaplus` | TLA+ | `tlapm_lsp --stdio` | `LEMON_LSP_TLAPLUS_COMMAND` | Install TLAPM and put tlapm_lsp on PATH. |
| `zls` | ZLS | `zls` | `LEMON_LSP_ZLS_COMMAND` | Install ZLS and put zls on PATH. |
| `vscode_html_language_server` | HTML | `vscode-html-language-server --stdio` | `LEMON_LSP_VSCODE_HTML_LANGUAGE_SERVER_COMMAND` | Install with npm install -g vscode-langservers-extracted. |
| `vscode_css_language_server` | CSS | `vscode-css-language-server --stdio` | `LEMON_LSP_VSCODE_CSS_LANGUAGE_SERVER_COMMAND` | Install with npm install -g vscode-langservers-extracted. |
| `vscode_json_language_server` | JSON | `vscode-json-language-server --stdio` | `LEMON_LSP_VSCODE_JSON_LANGUAGE_SERVER_COMMAND` | Install with npm install -g vscode-langservers-extracted. |
| `svelte` | Svelte | `svelteserver --stdio` | `LEMON_LSP_SVELTE_COMMAND` | Install with npm install -g svelte-language-server. |
| `vue_language_server` | Vue | `vue-language-server --stdio` | `LEMON_LSP_VUE_LANGUAGE_SERVER_COMMAND` | Install with npm install -g @vue/language-server. |
| `astro` | Astro | `astro-ls --stdio` | `LEMON_LSP_ASTRO_COMMAND` | Install with npm install -g @astrojs/language-server. |
| `jdtls` | Eclipse JDT LS | `jdtls` | `LEMON_LSP_JDTLS_COMMAND` | Install Eclipse JDT LS and put jdtls on PATH. |
| `kotlin_lsp` | Kotlin LSP | `kotlin-lsp --stdio` | `LEMON_LSP_KOTLIN_LSP_COMMAND` | Install JetBrains kotlin-lsp and put kotlin-lsp on PATH. |
| `metals` | Metals | `metals` | `LEMON_LSP_METALS_COMMAND` | Install Metals with Coursier: cs install metals. |
| `hls` | Haskell Language Server | `haskell-language-server-wrapper --lsp` | `LEMON_LSP_HLS_COMMAND` | Install Haskell Language Server with ghcup install hls. |
| `ocamllsp` | OCaml LSP | `ocamllsp` | `LEMON_LSP_OCAMLLSP_COMMAND` | Install with opam install ocaml-lsp-server. |
| `erlangls` | Erlang LS | `erlang_ls` | `LEMON_LSP_ERLANGLS_COMMAND` | Install Erlang LS and put erlang_ls on PATH. |
| `gleam` | Gleam | `gleam lsp` | `LEMON_LSP_GLEAM_COMMAND` | Install Gleam and put gleam on PATH. |
| `ruby_lsp` | Ruby LSP | `ruby-lsp` | `LEMON_LSP_RUBY_LSP_COMMAND` | Install with gem install ruby-lsp. |
| `bashls` | Bash Language Server | `bash-language-server start` | `LEMON_LSP_BASHLS_COMMAND` | Install with npm install -g bash-language-server. |
| `lua_language_server` | Lua Language Server | `lua-language-server` | `LEMON_LSP_LUA_LANGUAGE_SERVER_COMMAND` | Install lua-language-server and put it on PATH. |
| `intelephense` | Intelephense | `intelephense --stdio` | `LEMON_LSP_INTELEPHENSE_COMMAND` | Install with npm install -g intelephense. |
| `yamlls` | YAML Language Server | `yaml-language-server --stdio` | `LEMON_LSP_YAMLLS_COMMAND` | Install with npm install -g yaml-language-server. |
| `terraformls` | Terraform LS | `terraform-ls serve` | `LEMON_LSP_TERRAFORMLS_COMMAND` | Install HashiCorp terraform-ls and put it on PATH. |
| `dockerls` | Dockerfile Language Server | `docker-langserver --stdio` | `LEMON_LSP_DOCKERLS_COMMAND` | Install with npm install -g dockerfile-language-server-nodejs. |
| `nixd` | nixd | `nixd` | `LEMON_LSP_NIXD_COMMAND` | Install with nix profile install nixpkgs#nixd. |
| `ols` | Odin Language Server | `ols` | `LEMON_LSP_OLS_COMMAND` | Install OLS and put ols on PATH. |
| `dartls` | Dart Analysis Server | `dart language-server --protocol=lsp` | `LEMON_LSP_DARTLS_COMMAND` | Install the Dart SDK and put dart on PATH. |
| `marksman` | Marksman | `marksman server` | `LEMON_LSP_MARKSMAN_COMMAND` | Install Marksman and put marksman on PATH. |
| `texlab` | Texlab | `texlab` | `LEMON_LSP_TEXLAB_COMMAND` | Install Texlab and put texlab on PATH. |
| `graphql` | GraphQL Language Server | `graphql-lsp server -m stream` | `LEMON_LSP_GRAPHQL_COMMAND` | Install with npm install -g graphql-language-service-cli. |
| `prismals` | Prisma Language Server | `prisma-language-server --stdio` | `LEMON_LSP_PRISMALS_COMMAND` | Install with npm install -g @prisma/language-server. |
| `vimls` | Vim Language Server | `vim-language-server --stdio` | `LEMON_LSP_VIMLS_COMMAND` | Install with npm install -g vim-language-server. |
| `sourcekit_lsp` | SourceKit-LSP | `sourcekit-lsp` | `LEMON_LSP_SOURCEKIT_LSP_COMMAND` | Install the Swift toolchain and put sourcekit-lsp on PATH. |
| `csharp_ls` | C# Language Server | `csharp-ls` | `LEMON_LSP_CSHARP_LS_COMMAND` | Install with dotnet tool install --global csharp-ls. |
| `taplo` | Taplo | `taplo lsp stdio` | `LEMON_LSP_TAPLO_COMMAND` | Install with cargo install taplo-cli --locked --features lsp. |
| `elm` | Elm Language Server | `elm-language-server --stdio` | `LEMON_LSP_ELM_COMMAND` | Install with npm install -g @elm-tooling/elm-language-server. |
| `clojure_lsp` | Clojure LSP | `clojure-lsp` | `LEMON_LSP_CLOJURE_LSP_COMMAND` | Install clojure-lsp and put it on PATH. |
| `solidity` | Solidity Language Server | `nomicfoundation-solidity-language-server --stdio` | `LEMON_LSP_SOLIDITY_COMMAND` | Install with npm install -g @nomicfoundation/solidity-language-server. |

The registry assigns each extension to one primary server and omits supplemental
linters. Language ids are available through `LemonLsp.Servers.language_id/1`;
unknown extensions (including extensionless `Dockerfile`) return `"plaintext"`.
Dockerfile LSP registration covers `.dockerfile` files.

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
