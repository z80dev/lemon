defmodule Ai.Models.MiniMaxCN do
  @moduledoc """
  Model definitions for the MiniMaxCN provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "MiniMax-M2" => %Model{
      id: "MiniMax-M2",
      name: "MiniMax-M2",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 196_608,
      max_tokens: 128_000
    },
    "MiniMax-M2.1" => %Model{
      id: "MiniMax-M2.1",
      name: "MiniMax-M2.1",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "MiniMax-M2.5" => %Model{
      id: "MiniMax-M2.5",
      name: "MiniMax-M2.5",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.03, cache_write: 0.375},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "MiniMax-M2.5-highspeed" => %Model{
      id: "MiniMax-M2.5-highspeed",
      name: "MiniMax-M2.5-highspeed",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.4, cache_read: 0.06, cache_write: 0.375},
      context_window: 204_800,
      max_tokens: 131_072
    }
  }

  @doc "Returns all MiniMaxCN model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
