# lemon_lsp

LSP capability driver for Lemon.

Owns `LemonLsp.Servers` and `LemonLsp.ServerManager` for language-server
registry metadata and supervised JSON-RPC sessions. It depends only on
`lemon_core` plus JSON support.

Configured language-server launches use the core native-process seam. Evaluation
can opt into durable local process-group tracking without changing ordinary
session ownership or protocol limits. Coding-tool diagnostics and formatters keep
their timeout/output-bounded BashExecutor path, which uses the same launch seam.

## Supported language servers

The original providers are ElixirLS (`elixir_ls`), TypeScript Language Server
(`typescript_language_server`), Pyright (`pyright`), rust-analyzer
(`rust_analyzer`), gopls (`gopls`), and clangd (`clangd`).

Additional primary providers:

| Language | Server id | Command |
| --- | --- | --- |
| TLA+ | `tlaplus` | `tlapm_lsp --stdio` |
| ZLS | `zls` | `zls` |
| HTML | `vscode_html_language_server` | `vscode-html-language-server --stdio` |
| CSS | `vscode_css_language_server` | `vscode-css-language-server --stdio` |
| JSON | `vscode_json_language_server` | `vscode-json-language-server --stdio` |
| Svelte | `svelte` | `svelteserver --stdio` |
| Vue | `vue_language_server` | `vue-language-server --stdio` |
| Astro | `astro` | `astro-ls --stdio` |
| Eclipse JDT LS | `jdtls` | `jdtls` |
| Kotlin LSP | `kotlin_lsp` | `kotlin-lsp --stdio` |
| Metals | `metals` | `metals` |
| Haskell Language Server | `hls` | `haskell-language-server-wrapper --lsp` |
| OCaml LSP | `ocamllsp` | `ocamllsp` |
| Erlang LS | `erlangls` | `erlang_ls` |
| Gleam | `gleam` | `gleam lsp` |
| Ruby LSP | `ruby_lsp` | `ruby-lsp` |
| Bash Language Server | `bashls` | `bash-language-server start` |
| Lua Language Server | `lua_language_server` | `lua-language-server` |
| Intelephense | `intelephense` | `intelephense --stdio` |
| YAML Language Server | `yamlls` | `yaml-language-server --stdio` |
| Terraform LS | `terraformls` | `terraform-ls serve` |
| Dockerfile Language Server | `dockerls` | `docker-langserver --stdio` |
| nixd | `nixd` | `nixd` |
| Odin Language Server | `ols` | `ols` |
| Dart Analysis Server | `dartls` | `dart language-server --protocol=lsp` |
| Marksman | `marksman` | `marksman server` |
| Texlab | `texlab` | `texlab` |
| GraphQL Language Server | `graphql` | `graphql-lsp server -m stream` |
| Prisma Language Server | `prismals` | `prisma-language-server --stdio` |
| Vim Language Server | `vimls` | `vim-language-server --stdio` |
| SourceKit-LSP | `sourcekit_lsp` | `sourcekit-lsp` |
| C# Language Server | `csharp_ls` | `csharp-ls` |
| Taplo | `taplo` | `taplo lsp stdio` |
| Elm Language Server | `elm` | `elm-language-server --stdio` |
| Clojure LSP | `clojure_lsp` | `clojure-lsp` |
| Solidity Language Server | `solidity` | `nomicfoundation-solidity-language-server --stdio` |

Install providers separately; `LemonLsp.Servers.list/0` reports each install hint,
command override environment variable, extensions, and LSP `language_ids`.
`LemonLsp.Servers.language_id/1` resolves extensions case-insensitively and returns
`"plaintext"` for unknown extensions. Extensions have exactly one owner; alternate
providers and supplemental linters are not registered. Root markers are literal
filenames or directories, not glob patterns. Dockerfile detection is extension-based
(`.dockerfile`); an extensionless `Dockerfile` returns `"plaintext"`.
