# lemon_lsp

LSP capability driver for Lemon.

Owns `LemonLsp.Servers` and `LemonLsp.ServerManager` for language-server
registry metadata and supervised JSON-RPC sessions. It depends only on
`lemon_core` plus JSON support.
