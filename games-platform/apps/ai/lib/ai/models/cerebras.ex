defmodule Ai.Models.Cerebras do
  @moduledoc """
  Model definitions for the Cerebras provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "llama-3.1-8b" => %Model{
      id: "llama-3.1-8b",
      name: "Llama 3.1 8B",
      api: :openai_completions,
      provider: :cerebras,
      base_url: "https://api.cerebras.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.1, output: 0.1, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "llama-3.3-70b" => %Model{
      id: "llama-3.3-70b",
      name: "Llama 3.3 70B",
      api: :openai_completions,
      provider: :cerebras,
      base_url: "https://api.cerebras.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 0.9, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "qwen-3-32b" => %Model{
      id: "qwen-3-32b",
      name: "Qwen 3 32B",
      api: :openai_completions,
      provider: :cerebras,
      base_url: "https://api.cerebras.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 0.8, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
"gpt-oss-120b" => %Model{
                         id: "gpt-oss-120b",
                         name: "GPT OSS 120B",
                         api: :openai_completions,
                         provider: :cerebras,
                         base_url: "https://api.cerebras.ai/v1",
                         reasoning: true,
                         input: [:text],
                         cost: %ModelCost{
                           input: 0.25,
                           output: 0.69,
                           cache_read: 0.0,
                           cache_write: 0.0
                         },
                         context_window: 131_072,
                         max_tokens: 32_768
                       },
                       "llama3.1-8b" => %Model{
                         id: "llama3.1-8b",
                         name: "Llama 3.1 8B",
                         api: :openai_completions,
                         provider: :cerebras,
                         base_url: "https://api.cerebras.ai/v1",
                         reasoning: false,
                         input: [:text],
                         cost: %ModelCost{
                           input: 0.1,
                           output: 0.1,
                           cache_read: 0.0,
                           cache_write: 0.0
                         },
                         context_window: 32_000,
                         max_tokens: 8_000
                       },
                       "qwen-3-235b-a22b-instruct-2507" => %Model{
                         id: "qwen-3-235b-a22b-instruct-2507",
                         name: "Qwen 3 235B Instruct",
                         api: :openai_completions,
                         provider: :cerebras,
                         base_url: "https://api.cerebras.ai/v1",
                         reasoning: false,
                         input: [:text],
                         cost: %ModelCost{
                           input: 0.6,
                           output: 1.2,
                           cache_read: 0.0,
                           cache_write: 0.0
                         },
                         context_window: 131_000,
                         max_tokens: 32_000
                       },
                       "zai-glm-4.7" => %Model{
                         id: "zai-glm-4.7",
                         name: "Z.AI GLM-4.7",
                         api: :openai_completions,
                         provider: :cerebras,
                         base_url: "https://api.cerebras.ai/v1",
                         reasoning: false,
                         input: [:text],
                         cost: %ModelCost{
                           input: 2.25,
                           output: 2.75,
                           cache_read: 0.0,
                           cache_write: 0.0
                         },
                         context_window: 131_072,
                         max_tokens: 40_000
                       }
  }

  @doc "Returns all Cerebras model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
