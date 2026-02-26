defmodule Ai.Models.Qwen do
  @moduledoc """
  Model definitions for the Qwen provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "qwen-turbo" => %Model{
      id: "qwen-turbo",
      name: "Qwen Turbo",
      api: :openai_completions,
      provider: :qwen,
      base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.5, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8192
    },
    "qwen-plus" => %Model{
      id: "qwen-plus",
      name: "Qwen Plus",
      api: :openai_completions,
      provider: :qwen,
      base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "qwen-max" => %Model{
      id: "qwen-max",
      name: "Qwen Max",
      api: :openai_completions,
      provider: :qwen,
      base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.4, output: 9.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 8192
    },
    "qwen-coder-plus" => %Model{
      id: "qwen-coder-plus",
      name: "Qwen Coder Plus",
      api: :openai_completions,
      provider: :qwen,
      base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.35, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "qwen-vl-max" => %Model{
      id: "qwen-vl-max",
      name: "Qwen VL Max",
      api: :openai_completions,
      provider: :qwen,
      base_url: "https://dashscope.aliyuncs.com/compatible-mode/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 9.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 8192
    }
  }

  @doc "Returns all Qwen model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
