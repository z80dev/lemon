defmodule Ai.Models.HuggingFace do
  @moduledoc """
  Model definitions for the HuggingFace provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "deepseek-ai/DeepSeek-R1-0528" => %Model{
      id: "deepseek-ai/DeepSeek-R1-0528",
      name: "DeepSeek-R1-0528",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 5.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 163_840
    },
    "deepseek-ai/DeepSeek-V3.2" => %Model{
      id: "deepseek-ai/DeepSeek-V3.2",
      name: "DeepSeek-V3.2",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.28, output: 0.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 65_536
    },
    "MiniMaxAI/MiniMax-M2.1" => %Model{
      id: "MiniMaxAI/MiniMax-M2.1",
      name: "MiniMax-M2.1",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "MiniMaxAI/MiniMax-M2.5" => %Model{
      id: "MiniMaxAI/MiniMax-M2.5",
      name: "MiniMax-M2.5",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.03, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "moonshotai/Kimi-K2-Instruct" => %Model{
      id: "moonshotai/Kimi-K2-Instruct",
      name: "Kimi-K2-Instruct",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 16_384
    },
    "moonshotai/Kimi-K2-Instruct-0905" => %Model{
      id: "moonshotai/Kimi-K2-Instruct-0905",
      name: "Kimi-K2-Instruct-0905",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 16_384
    },
    "moonshotai/Kimi-K2-Thinking" => %Model{
      id: "moonshotai/Kimi-K2-Thinking",
      name: "Kimi-K2-Thinking",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.5, cache_read: 0.15, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 262_144
    },
    "moonshotai/Kimi-K2.5" => %Model{
      id: "moonshotai/Kimi-K2.5",
      name: "Kimi-K2.5",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 3.0, cache_read: 0.1, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 262_144
    },
    "Qwen/Qwen3-235B-A22B-Thinking-2507" => %Model{
      id: "Qwen/Qwen3-235B-A22B-Thinking-2507",
      name: "Qwen3-235B-A22B-Thinking-2507",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 131_072
    },
    "Qwen/Qwen3-Coder-480B-A35B-Instruct" => %Model{
      id: "Qwen/Qwen3-Coder-480B-A35B-Instruct",
      name: "Qwen3-Coder-480B-A35B-Instruct",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 66_536
    },
    "Qwen/Qwen3-Coder-Next" => %Model{
      id: "Qwen/Qwen3-Coder-Next",
      name: "Qwen3-Coder-Next",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.2, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 65_536
    },
    "Qwen/Qwen3-Next-80B-A3B-Instruct" => %Model{
      id: "Qwen/Qwen3-Next-80B-A3B-Instruct",
      name: "Qwen3-Next-80B-A3B-Instruct",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.25, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 66_536
    },
    "Qwen/Qwen3-Next-80B-A3B-Thinking" => %Model{
      id: "Qwen/Qwen3-Next-80B-A3B-Thinking",
      name: "Qwen3-Next-80B-A3B-Thinking",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 131_072
    },
    "Qwen/Qwen3.5-397B-A17B" => %Model{
      id: "Qwen/Qwen3.5-397B-A17B",
      name: "Qwen3.5-397B-A17B",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 3.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
    "XiaomiMiMo/MiMo-V2-Flash" => %Model{
      id: "XiaomiMiMo/MiMo-V2-Flash",
      name: "MiMo-V2-Flash",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.1, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 4_096
    },
    "zai-org/GLM-4.7" => %Model{
      id: "zai-org/GLM-4.7",
      name: "GLM-4.7",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.11, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "zai-org/GLM-4.7-Flash" => %Model{
      id: "zai-org/GLM-4.7-Flash",
      name: "GLM-4.7-Flash",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 128_000
    },
    "zai-org/GLM-5" => %Model{
      id: "zai-org/GLM-5",
      name: "GLM-5",
      api: :openai_completions,
      provider: :huggingface,
      base_url: "https://router.huggingface.co/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.2, cache_read: 0.2, cache_write: 0.0},
      context_window: 202_752,
      max_tokens: 131_072
    }
  }

  @doc "Returns all HuggingFace model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
