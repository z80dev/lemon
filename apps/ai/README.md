# Ai

LLM provider abstraction and streaming runtime for Lemon. This app handles
provider selection, request dispatch, rate limiting, circuit breaking, and
bounded event streams for streaming responses.

## Features

- Unified streaming API across providers
- Supervised streaming tasks via `Task.Supervisor`
- Central call dispatcher with concurrency caps
- Per-provider rate limiting and circuit breaking
- Bounded `Ai.EventStream` for backpressure and cancellation

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ai` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ai, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ai>.
