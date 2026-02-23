defmodule Ai.Models.Anthropic do
  @moduledoc """
  Model definitions for the Anthropic provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "claude-3-5-haiku-20241022" => %Model{
      id: "claude-3-5-haiku-20241022",
      name: "Claude Haiku 3.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 4.0, cache_read: 0.08, cache_write: 1.0},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-5-haiku-latest" => %Model{
      id: "claude-3-5-haiku-latest",
      name: "Claude Haiku 3.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 4.0, cache_read: 0.08, cache_write: 1.0},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-5-sonnet-20240620" => %Model{
      id: "claude-3-5-sonnet-20240620",
      name: "Claude Sonnet 3.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-5-sonnet-20241022" => %Model{
      id: "claude-3-5-sonnet-20241022",
      name: "Claude Sonnet 3.5 v2",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-7-sonnet-20250219" => %Model{
      id: "claude-3-7-sonnet-20250219",
      name: "Claude Sonnet 3.7",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-3-7-sonnet-latest" => %Model{
      id: "claude-3-7-sonnet-latest",
      name: "Claude Sonnet 3.7 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-6" => %Model{
      id: "claude-sonnet-4.6",
      name: "Claude Sonnet 4.6",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-6" => %Model{
      id: "claude-opus-4.6",
      name: "Claude Opus 4.6",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 128_000
    },
    "claude-opus-4-6-thinking" => %Model{
      id: "claude-opus-4-6-thinking",
      name: "Claude Opus 4.6 (Thinking)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 128_000
    },
    "claude-3-haiku-20240307" => %Model{
      id: "claude-3-haiku-20240307",
      name: "Claude Haiku 3",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 1.25, cache_read: 0.03, cache_write: 0.3},
      context_window: 200_000,
      max_tokens: 4096
    },
    "claude-3-opus-20240229" => %Model{
      id: "claude-3-opus-20240229",
      name: "Claude Opus 3",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 4096
    },
    "claude-3-sonnet-20240229" => %Model{
      id: "claude-3-sonnet-20240229",
      name: "Claude Sonnet 3",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 0.3},
      context_window: 200_000,
      max_tokens: 4096
    },
    "claude-haiku-4-5" => %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-haiku-4-5-20251001" => %Model{
      id: "claude-haiku-4-5-20251001",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-0" => %Model{
      id: "claude-opus-4-0",
      name: "Claude Opus 4 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-1" => %Model{
      id: "claude-opus-4-1",
      name: "Claude Opus 4.1 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-1-20250805" => %Model{
      id: "claude-opus-4-1-20250805",
      name: "Claude Opus 4.1",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-20250514" => %Model{
      id: "claude-opus-4-20250514",
      name: "Claude Opus 4",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-5" => %Model{
      id: "claude-opus-4-5",
      name: "Claude Opus 4.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-5-20251101" => %Model{
      id: "claude-opus-4-5-20251101",
      name: "Claude Opus 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-0" => %Model{
      id: "claude-sonnet-4-0",
      name: "Claude Sonnet 4 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-20250514" => %Model{
      id: "claude-sonnet-4-20250514",
      name: "Claude Sonnet 4",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-5" => %Model{
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-5-20250929" => %Model{
      id: "claude-sonnet-4-5-20250929",
      name: "Claude Sonnet 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
"claude-opus-4-6" => %Model{
                          id: "claude-opus-4-6",
                          name: "Claude Opus 4.6",
                          api: :anthropic_messages,
                          provider: :anthropic,
                          base_url: "https://api.anthropic.com",
                          reasoning: true,
                          input: [:text, :image],
                          cost: %ModelCost{
                            input: 5.0,
                            output: 25.0,
                            cache_read: 0.5,
                            cache_write: 6.25
                          },
                          context_window: 200_000,
                          max_tokens: 128_000
                        },
                        "claude-sonnet-4-6" => %Model{
                          id: "claude-sonnet-4-6",
                          name: "Claude Sonnet 4.6",
                          api: :anthropic_messages,
                          provider: :anthropic,
                          base_url: "https://api.anthropic.com",
                          reasoning: true,
                          input: [:text, :image],
                          cost: %ModelCost{
                            input: 3.0,
                            output: 15.0,
                            cache_read: 0.3,
                            cache_write: 3.75
                          },
                          context_window: 200_000,
                          max_tokens: 64_000
                        }
  }

  @doc "Returns all Anthropic model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
