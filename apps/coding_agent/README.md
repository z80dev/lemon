# CodingAgent

Full coding agent built on top of `AgentCore`. This app adds session
management, tool execution, persistence, UI integration, and extensions for
building coding workflows.

## Features

- Session GenServer with JSONL persistence and branching
- Built-in tools (`read`, `memory_topic`, `write`, `edit`, `patch`, `bash`, `grep`, `find`, `ls`, `webfetch`, `websearch`, `todo`, `task`, `extensions_status`) plus extension loading
- `websearch` supports Brave (default) and Perplexity providers with structured JSON output
- `webfetch` includes SSRF guards, readability extraction, optional Firecrawl fallback, and caching
- Steering and follow-up message queues
- UI integration and event subscription streams
- Coordinator for running subagent sessions

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `coding_agent` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:coding_agent, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/coding_agent>.
