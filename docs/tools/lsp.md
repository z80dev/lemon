# LSP Diagnostics

Lemon has two diagnostics paths:

- `lsp_diagnostics`: the model-facing coding-agent tool for one-file
  diagnostics and post-edit baseline/delta checks.
- supervised LSP sessions: BEAM-owned stdio language-server processes managed
  through the in-process `LemonLsp.ServerManager` API.

Both paths are preview surfaces. They are designed to be supportable first:
status and support bundles expose capabilities, counters, hashes, and install
hints, not raw file contents, raw workspace roots, raw session ids, diagnostic
output, or server I/O.

## Model-Facing Tool

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

Language-server stderr is redirected into the supervised port stream so noisy
servers cannot write private workspace paths directly to the caller console.
The parser discards non-LSP prefixes and only records redacted frame counters
from valid JSON-RPC messages. When a language-server launcher spawns child
processes, `stop_session` also terminates those children so wrapper-style
servers do not outlive the BEAM-owned session. If a JSON-RPC request times out,
the manager treats the session as unhealthy, replies with
`:request_timeout`, terminates the launcher plus descendants, and records the
recent session as `:request_timeout` instead of leaving a stuck port alive.

The manager records both push diagnostics from
`textDocument/publishDiagnostics` notifications and pull diagnostics from
`textDocument/diagnostic` responses. Public status keeps only URI hashes,
diagnostic counts, severity counts, and timestamps.

## Focused Test Coverage

From the umbrella root:

```bash
mix test apps/coding_agent/test/coding_agent/tools/lsp_diagnostics_test.exs \
  apps/lemon_lsp/test --seed 1
```

Exercise supervised server startup, framing, document diagnostics, timeout cleanup
and wrapper-child termination. These are local checks, not proof that a particular
language server is installed or correctly configured on an operator's machine.
