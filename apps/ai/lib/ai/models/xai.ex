defmodule Ai.Models.XAI do
  @moduledoc """
  Model definitions for the XAI provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "grok-2" => %Model{
      id: "grok-2",
      name: "Grok 2",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 2.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-2-latest" => %Model{
      id: "grok-2-latest",
      name: "Grok 2 Latest",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 2.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-2-vision" => %Model{
      id: "grok-2-vision",
      name: "Grok 2 Vision",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 2.0, cache_write: 0.0},
      context_window: 8192,
      max_tokens: 4096
    },
    "grok-2-vision-latest" => %Model{
      id: "grok-2-vision-latest",
      name: "Grok 2 Vision Latest",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 2.0, cache_write: 0.0},
      context_window: 8192,
      max_tokens: 4096
    },
    "grok-3" => %Model{
      id: "grok-3",
      name: "Grok 3",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.75, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-3-fast" => %Model{
      id: "grok-3-fast",
      name: "Grok 3 Fast",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-3-fast-latest" => %Model{
      id: "grok-3-fast-latest",
      name: "Grok 3 Fast Latest",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-3-mini" => %Model{
      id: "grok-3-mini",
      name: "Grok 3 Mini",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 0.5, cache_read: 0.075, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-3-mini-fast" => %Model{
      id: "grok-3-mini-fast",
      name: "Grok 3 Mini Fast",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 4.0, cache_read: 0.15, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-3-mini-fast-latest" => %Model{
      id: "grok-3-mini-fast-latest",
      name: "Grok 3 Mini Fast Latest",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 4.0, cache_read: 0.15, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-3-mini-latest" => %Model{
      id: "grok-3-mini-latest",
      name: "Grok 3 Mini Latest",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 0.5, cache_read: 0.075, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-4" => %Model{
      id: "grok-4",
      name: "Grok 4",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.75, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 64_000
    },
    "grok-4-1-fast" => %Model{
      id: "grok-4-1-fast",
      name: "Grok 4.1 Fast",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.2, output: 0.5, cache_read: 0.05, cache_write: 0.0},
      context_window: 2_000_000,
      max_tokens: 30_000
    },
    "grok-4-1-fast-non-reasoning" => %Model{
      id: "grok-4-1-fast-non-reasoning",
      name: "Grok 4.1 Fast (Non-Reasoning)",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.2, output: 0.5, cache_read: 0.05, cache_write: 0.0},
      context_window: 2_000_000,
      max_tokens: 30_000
    },
    "grok-4-fast" => %Model{
      id: "grok-4-fast",
      name: "Grok 4 Fast",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8192
    },
    "grok-4-fast-non-reasoning" => %Model{
      id: "grok-4-fast-non-reasoning",
      name: "Grok 4 Fast (Non-Reasoning)",
      api: :openai_completions,
      provider: :xai,
      base_url: "https://api.x.ai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.2, output: 0.5, cache_read: 0.05, cache_write: 0.0},
      context_window: 2_000_000,
      max_tokens: 30_000
    },
"grok-2-1212" => %Model{
                    id: "grok-2-1212",
                    name: "Grok 2 (1212)",
                    api: :openai_completions,
                    provider: :xai,
                    base_url: "https://api.x.ai/v1",
                    reasoning: false,
                    input: [:text],
                    cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 2.0, cache_write: 0.0},
                    context_window: 131_072,
                    max_tokens: 8_192
                  },
                  "grok-2-vision-1212" => %Model{
                    id: "grok-2-vision-1212",
                    name: "Grok 2 Vision (1212)",
                    api: :openai_completions,
                    provider: :xai,
                    base_url: "https://api.x.ai/v1",
                    reasoning: false,
                    input: [:text, :image],
                    cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 2.0, cache_write: 0.0},
                    context_window: 8_192,
                    max_tokens: 4_096
                  },
                  "grok-3-latest" => %Model{
                    id: "grok-3-latest",
                    name: "Grok 3 Latest",
                    api: :openai_completions,
                    provider: :xai,
                    base_url: "https://api.x.ai/v1",
                    reasoning: false,
                    input: [:text],
                    cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.75, cache_write: 0.0},
                    context_window: 131_072,
                    max_tokens: 8_192
                  },
                  "grok-beta" => %Model{
                    id: "grok-beta",
                    name: "Grok Beta",
                    api: :openai_completions,
                    provider: :xai,
                    base_url: "https://api.x.ai/v1",
                    reasoning: false,
                    input: [:text],
                    cost: %ModelCost{input: 5.0, output: 15.0, cache_read: 5.0, cache_write: 0.0},
                    context_window: 131_072,
                    max_tokens: 4_096
                  },
                  "grok-code-fast-1" => %Model{
                    id: "grok-code-fast-1",
                    name: "Grok Code Fast 1",
                    api: :openai_completions,
                    provider: :xai,
                    base_url: "https://api.x.ai/v1",
                    reasoning: true,
                    input: [:text],
                    cost: %ModelCost{input: 0.2, output: 1.5, cache_read: 0.02, cache_write: 0.0},
                    context_window: 256_000,
                    max_tokens: 10_000
                  },
                  "grok-vision-beta" => %Model{
                    id: "grok-vision-beta",
                    name: "Grok Vision Beta",
                    api: :openai_completions,
                    provider: :xai,
                    base_url: "https://api.x.ai/v1",
                    reasoning: false,
                    input: [:text, :image],
                    cost: %ModelCost{input: 5.0, output: 15.0, cache_read: 5.0, cache_write: 0.0},
                    context_window: 8_192,
                    max_tokens: 4_096
                  }
  }

  @doc "Returns all XAI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
