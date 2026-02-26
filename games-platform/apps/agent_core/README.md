# AgentCore

Core agent runtime for Lemon. This app provides the OTP building blocks for
agent processes, supervised loops, bounded event streams, and subagent
supervision/registry infrastructure.

## Features

- `AgentCore.Agent` GenServer for agent state and orchestration
- Supervised loop execution under `Task.Supervisor`
- `AgentCore.EventStream` for bounded, cancelable event streaming
- Subagent supervision and registry for discoverability

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `agent_core` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:agent_core, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/agent_core>.
