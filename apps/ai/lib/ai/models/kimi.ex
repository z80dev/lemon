defmodule Ai.Models.Kimi do
  @moduledoc """
  Model definitions for the Kimi provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "kimi-for-coding" => %Model{
      id: "kimi-for-coding",
      name: "Kimi for Coding",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: "https://api.kimi.com/coding",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 64_000
    },
    "k2p5" => %Model{
      id: "k2p5",
      name: "Kimi K2.5",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: "https://api.kimi.com/coding",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
    "kimi-k2-thinking" => %Model{
      id: "kimi-k2-thinking",
      name: "Kimi K2 Thinking",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: "https://api.kimi.com/coding",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
"k2p5" => %Model{
                     id: "k2p5",
                     name: "Kimi K2.5",
                     api: :anthropic_messages,
                     provider: :kimi,
                     base_url: "https://api.kimi.com/coding",
                     reasoning: true,
                     input: [:text, :image],
                     cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
                     context_window: 262_144,
                     max_tokens: 32_768
                   },
                   "kimi-k2-thinking" => %Model{
                     id: "kimi-k2-thinking",
                     name: "Kimi K2 Thinking",
                     api: :anthropic_messages,
                     provider: :kimi,
                     base_url: "https://api.kimi.com/coding",
                     reasoning: true,
                     input: [:text],
                     cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
                     context_window: 262_144,
                     max_tokens: 32_768
                   }
  }

  @doc "Returns all Kimi model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
