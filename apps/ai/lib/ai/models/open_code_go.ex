defmodule Ai.Models.OpenCodeGo do
  @moduledoc """
  Model definitions for the OpenCode Go provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "glm-5" => %Model{
      id: "glm-5",
      name: "GLM-5",
      api: :openai_completions,
      provider: :opencode_go,
      base_url: "https://opencode.ai/zen/go/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.2, cache_read: 0.2, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "glm-5.1" => %Model{
      id: "glm-5.1",
      name: "GLM-5.1",
      api: :openai_completions,
      provider: :opencode_go,
      base_url: "https://opencode.ai/zen/go/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.2, cache_read: 0.2, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "kimi-k2.5" => %Model{
      id: "kimi-k2.5",
      name: "Kimi K2.5",
      api: :openai_completions,
      provider: :opencode_go,
      base_url: "https://opencode.ai/zen/go/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 3.0, cache_read: 0.1, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 65_536
    },
    "minimax-m2.5" => %Model{
      id: "minimax-m2.5",
      name: "MiniMax M2.5",
      api: :anthropic_messages,
      provider: :opencode_go,
      base_url: "https://opencode.ai/zen/go",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.03, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    }
  }

  @doc "Returns all OpenCode Go model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
