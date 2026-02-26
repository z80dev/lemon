defmodule Ai.Models.DeepSeek do
  @moduledoc """
  Model definitions for the DeepSeek provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "deepseek-chat" => %Model{
      id: "deepseek-chat",
      name: "DeepSeek V3",
      api: :openai_completions,
      provider: :deepseek,
      base_url: "https://api.deepseek.com/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.27, output: 1.1, cache_read: 0.07, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 8192
    },
    "deepseek-reasoner" => %Model{
      id: "deepseek-reasoner",
      name: "DeepSeek R1",
      api: :openai_completions,
      provider: :deepseek,
      base_url: "https://api.deepseek.com/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.55, output: 2.19, cache_read: 0.14, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 8192
    },
    "deepseek-r1" => %Model{
      id: "deepseek-r1",
      name: "DeepSeek R1 (Alias)",
      api: :openai_completions,
      provider: :deepseek,
      base_url: "https://api.deepseek.com/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.55, output: 2.19, cache_read: 0.14, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 8192
    }
  }

  @doc "Returns all DeepSeek model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
