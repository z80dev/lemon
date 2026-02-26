defmodule Ai.Models.KimiCoding do
  @moduledoc """
  Model definitions for the KimiCoding provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "kimi-k2-coding" => %Model{
      id: "kimi-k2-coding",
      name: "Kimi K2 Coding",
      api: :anthropic_messages,
      provider: :kimi_coding,
      base_url: "https://api.moonshot.ai/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
    "kimi-k2.5-coding" => %Model{
      id: "kimi-k2.5-coding",
      name: "Kimi K2.5 Coding",
      api: :anthropic_messages,
      provider: :kimi_coding,
      base_url: "https://api.moonshot.ai/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    }
  }

  @doc "Returns all KimiCoding model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
