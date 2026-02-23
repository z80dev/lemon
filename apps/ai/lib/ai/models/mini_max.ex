defmodule Ai.Models.MiniMax do
  @moduledoc """
  Model definitions for the MiniMax provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "minimax-m2" => %Model{
      id: "minimax-m2",
      name: "MiniMax M2",
      api: :openai_completions,
      provider: :minimax,
      base_url: "https://api.minimaxi.chat/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    },
    "minimax-m2.1" => %Model{
      id: "minimax-m2.1",
      name: "MiniMax M2.1",
      api: :openai_completions,
      provider: :minimax,
      base_url: "https://api.minimaxi.chat/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    },
    "minimax-m2.5" => %Model{
      id: "minimax-m2.5",
      name: "MiniMax M2.5",
      api: :openai_completions,
      provider: :minimax,
      base_url: "https://api.minimaxi.chat/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.8, output: 3.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    },
"MiniMax-M2" => %Model{
                        id: "MiniMax-M2",
                        name: "MiniMax-M2",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.3,
                          output: 1.2,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 196_608,
                        max_tokens: 128_000
                      },
                      "MiniMax-M2.1" => %Model{
                        id: "MiniMax-M2.1",
                        name: "MiniMax-M2.1",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.3,
                          output: 1.2,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 204_800,
                        max_tokens: 131_072
                      },
                      "MiniMax-M2.5" => %Model{
                        id: "MiniMax-M2.5",
                        name: "MiniMax-M2.5",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.3,
                          output: 1.2,
                          cache_read: 0.03,
                          cache_write: 0.375
                        },
                        context_window: 204_800,
                        max_tokens: 131_072
                      },
                      "MiniMax-M2.5-highspeed" => %Model{
                        id: "MiniMax-M2.5-highspeed",
                        name: "MiniMax-M2.5-highspeed",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.6,
                          output: 2.4,
                          cache_read: 0.06,
                          cache_write: 0.375
                        },
                        context_window: 204_800,
                        max_tokens: 131_072
                      }
  }

  @doc "Returns all MiniMax model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
