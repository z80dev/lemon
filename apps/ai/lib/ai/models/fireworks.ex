defmodule Ai.Models.Fireworks do
  @moduledoc """
  Model definitions for the Fireworks AI provider.

  Fireworks AI hosts open-weight models behind an OpenAI-compatible API.
  Base URL: https://api.fireworks.ai/inference/v1/
  """

  alias Ai.Types.{Model, ModelCost}

  @base_url "https://api.fireworks.ai/inference/v1"

  @models %{
    "accounts/fireworks/models/deepseek-r1-0528" => %Model{
      id: "accounts/fireworks/models/deepseek-r1-0528",
      name: "Deepseek R1 05/28",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 8.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 160_000,
      max_tokens: 16_384
    },
    "accounts/fireworks/models/deepseek-v3p1" => %Model{
      id: "accounts/fireworks/models/deepseek-v3p1",
      name: "DeepSeek V3.1",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.56, output: 1.68, cache_read: 0.0, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 163_840
    },
    "accounts/fireworks/models/deepseek-v3p2" => %Model{
      id: "accounts/fireworks/models/deepseek-v3p2",
      name: "DeepSeek V3.2",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.56, output: 1.68, cache_read: 0.28, cache_write: 0.0},
      context_window: 160_000,
      max_tokens: 160_000
    },
    "accounts/fireworks/models/deepseek-v3-0324" => %Model{
      id: "accounts/fireworks/models/deepseek-v3-0324",
      name: "Deepseek V3 03-24",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.9, output: 0.9, cache_read: 0.0, cache_write: 0.0},
      context_window: 160_000,
      max_tokens: 16_384
    },
    "accounts/fireworks/models/minimax-m2" => %Model{
      id: "accounts/fireworks/models/minimax-m2",
      name: "MiniMax-M2",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.15, cache_write: 0.0},
      context_window: 192_000,
      max_tokens: 192_000
    },
    "accounts/fireworks/models/minimax-m2p1" => %Model{
      id: "accounts/fireworks/models/minimax-m2p1",
      name: "MiniMax-M2.1",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.15, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 200_000
    },
    "accounts/fireworks/models/glm-4p5" => %Model{
      id: "accounts/fireworks/models/glm-4p5",
      name: "GLM 4.5",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.55, output: 2.19, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "accounts/fireworks/models/glm-4p5-air" => %Model{
      id: "accounts/fireworks/models/glm-4p5-air",
      name: "GLM 4.5 Air",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.22, output: 0.88, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "accounts/fireworks/models/glm-4p6" => %Model{
      id: "accounts/fireworks/models/glm-4p6",
      name: "GLM 4.6",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.55, output: 2.19, cache_read: 0.28, cache_write: 0.0},
      context_window: 198_000,
      max_tokens: 198_000
    },
    "accounts/fireworks/models/glm-4p7" => %Model{
      id: "accounts/fireworks/models/glm-4p7",
      name: "GLM 4.7",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.3, cache_write: 0.0},
      context_window: 198_000,
      max_tokens: 198_000
    },
    "accounts/fireworks/models/kimi-k2-instruct" => %Model{
      id: "accounts/fireworks/models/kimi-k2-instruct",
      name: "Kimi K2 Instruct",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "accounts/fireworks/models/kimi-k2-thinking" => %Model{
      id: "accounts/fireworks/models/kimi-k2-thinking",
      name: "Kimi K2 Thinking",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.5, cache_read: 0.3, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "accounts/fireworks/routers/kimi-k2p5-turbo" => %Model{
      id: "accounts/fireworks/routers/kimi-k2p5-turbo",
      name: "Kimi K2.5 Turbo",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 3.0, cache_read: 0.1, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "accounts/fireworks/models/kimi-k2p5" => %Model{
      id: "accounts/fireworks/models/kimi-k2p5",
      name: "Kimi K2.5",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 3.0, cache_read: 0.1, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "accounts/fireworks/models/qwen3-235b-a22b" => %Model{
      id: "accounts/fireworks/models/qwen3-235b-a22b",
      name: "Qwen3 235B-A22B",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.22, output: 0.88, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "accounts/fireworks/models/gpt-oss-20b" => %Model{
      id: "accounts/fireworks/models/gpt-oss-20b",
      name: "GPT OSS 20B",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.05, output: 0.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    },
    "accounts/fireworks/models/gpt-oss-120b" => %Model{
      id: "accounts/fireworks/models/gpt-oss-120b",
      name: "GPT OSS 120B",
      api: :openai_completions,
      provider: :fireworks,
      base_url: @base_url,
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    }
  }

  @doc "Returns all Fireworks AI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
