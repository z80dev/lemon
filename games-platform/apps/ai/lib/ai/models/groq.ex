defmodule Ai.Models.Groq do
  @moduledoc """
  Model definitions for the Groq provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "deepseek-r1-distill-llama-70b" => %Model{
      id: "deepseek-r1-distill-llama-70b",
      name: "DeepSeek R1 Distill Llama 70B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.75, output: 0.99, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8_192
    },
    "gemma2-9b-it" => %Model{
      id: "gemma2-9b-it",
      name: "Gemma 2 9B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.2, output: 0.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_192,
      max_tokens: 8_192
    },
    "llama-3.1-8b-instant" => %Model{
      id: "llama-3.1-8b-instant",
      name: "Llama 3.1 8B Instant",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.05, output: 0.08, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "llama-3.3-70b-versatile" => %Model{
      id: "llama-3.3-70b-versatile",
      name: "Llama 3.3 70B Versatile",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.59, output: 0.79, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    },
    "llama3-70b-8192" => %Model{
      id: "llama3-70b-8192",
      name: "Llama 3 70B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.59, output: 0.79, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_192,
      max_tokens: 8_192
    },
    "llama3-8b-8192" => %Model{
      id: "llama3-8b-8192",
      name: "Llama 3 8B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.05, output: 0.08, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_192,
      max_tokens: 8_192
    },
    "meta-llama/llama-4-maverick-17b-128e-instruct" => %Model{
      id: "meta-llama/llama-4-maverick-17b-128e-instruct",
      name: "Llama 4 Maverick 17B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.2, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8_192
    },
    "meta-llama/llama-4-scout-17b-16e-instruct" => %Model{
      id: "meta-llama/llama-4-scout-17b-16e-instruct",
      name: "Llama 4 Scout 17B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.11, output: 0.34, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8_192
    },
    "mistral-saba-24b" => %Model{
      id: "mistral-saba-24b",
      name: "Mistral Saba 24B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.79, output: 0.79, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 32_768
    },
    "moonshotai/kimi-k2-instruct" => %Model{
      id: "moonshotai/kimi-k2-instruct",
      name: "Kimi K2 Instruct",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 16_384
    },
    "moonshotai/kimi-k2-instruct-0905" => %Model{
      id: "moonshotai/kimi-k2-instruct-0905",
      name: "Kimi K2 Instruct 0905",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 16_384
    },
    "openai/gpt-oss-120b" => %Model{
      id: "openai/gpt-oss-120b",
      name: "GPT OSS 120B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 65_536
    },
    "openai/gpt-oss-20b" => %Model{
      id: "openai/gpt-oss-20b",
      name: "GPT OSS 20B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 65_536
    },
    "qwen-qwq-32b" => %Model{
      id: "qwen-qwq-32b",
      name: "Qwen QwQ 32B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.29, output: 0.39, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 16_384
    },
    "qwen/qwen3-32b" => %Model{
      id: "qwen/qwen3-32b",
      name: "Qwen3 32B",
      api: :openai_completions,
      provider: :groq,
      base_url: "https://api.groq.com/openai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.29, output: 0.59, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 16_384
    }
  }

  @doc "Returns all Groq model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
