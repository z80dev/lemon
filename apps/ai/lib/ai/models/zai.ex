defmodule Ai.Models.ZAI do
  @moduledoc """
  Model definitions for the ZAI provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "glm-4.5-flash" => %Model{
      id: "glm-4.5-flash",
      name: "GLM-4.5-Flash",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 98_304
    },
    "glm-4.5-air" => %Model{
      id: "glm-4.5-air",
      name: "GLM-4.5-Air",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.2, output: 1.1, cache_read: 0.03, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 98_304
    },
    "glm-4.5" => %Model{
      id: "glm-4.5",
      name: "GLM-4.5",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.11, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 98_304
    },
    "glm-4.5v" => %Model{
      id: "glm-4.5v",
      name: "GLM-4.5V",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 1.8, cache_read: 0.0, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 16_384
    },
    "glm-4.6" => %Model{
      id: "glm-4.6",
      name: "GLM-4.6",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.11, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "glm-4.6v" => %Model{
      id: "glm-4.6v",
      name: "GLM-4.6V",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.3, output: 0.9, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_768
    },
    "glm-4.7" => %Model{
      id: "glm-4.7",
      name: "GLM-4.7",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.11, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "glm-4.7-flash" => %Model{
      id: "glm-4.7-flash",
      name: "GLM-4.7-Flash",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 131_072
    },
    "glm-5" => %Model{
      id: "glm-5",
      name: "GLM-5",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.2, cache_read: 0.2, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "glm-5-turbo" => %Model{
      id: "glm-5-turbo",
      name: "GLM-5-Turbo",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.2, output: 4.0, cache_read: 0.24, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 131_072
    },
    "glm-5.1" => %Model{
      id: "glm-5.1",
      name: "GLM-5.1",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.2, cache_read: 0.2, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    }
  }

  @doc "Returns all ZAI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
