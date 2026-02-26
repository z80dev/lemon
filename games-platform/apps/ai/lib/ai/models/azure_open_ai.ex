defmodule Ai.Models.AzureOpenAI do
  @moduledoc """
  Model definitions for the AzureOpenAI provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "codex-mini-latest" => %Model{
      id: "codex-mini-latest",
      name: "Codex Mini",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.5, output: 6.0, cache_read: 0.375, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "gpt-4" => %Model{
      id: "gpt-4",
      name: "GPT-4",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 30.0, output: 60.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_192,
      max_tokens: 8_192
    },
    "gpt-4-turbo" => %Model{
      id: "gpt-4-turbo",
      name: "GPT-4 Turbo",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 30.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "gpt-4.1" => %Model{
      id: "gpt-4.1",
      name: "GPT-4.1",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "gpt-4.1-mini" => %Model{
      id: "gpt-4.1-mini",
      name: "GPT-4.1 mini",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.4, output: 1.6, cache_read: 0.1, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "gpt-4.1-nano" => %Model{
      id: "gpt-4.1-nano",
      name: "GPT-4.1 nano",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.03, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "gpt-4o" => %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-4o-2024-05-13" => %Model{
      id: "gpt-4o-2024-05-13",
      name: "GPT-4o (2024-05-13)",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "gpt-4o-2024-08-06" => %Model{
      id: "gpt-4o-2024-08-06",
      name: "GPT-4o (2024-08-06)",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-4o-2024-11-20" => %Model{
      id: "gpt-4o-2024-11-20",
      name: "GPT-4o (2024-11-20)",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-4o-mini" => %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.08, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5" => %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-chat-latest" => %Model{
      id: "gpt-5-chat-latest",
      name: "GPT-5 Chat Latest",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5-codex" => %Model{
      id: "gpt-5-codex",
      name: "GPT-5-Codex",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-mini" => %Model{
      id: "gpt-5-mini",
      name: "GPT-5 Mini",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 2.0, cache_read: 0.025, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-nano" => %Model{
      id: "gpt-5-nano",
      name: "GPT-5 Nano",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.05, output: 0.4, cache_read: 0.005, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-pro" => %Model{
      id: "gpt-5-pro",
      name: "GPT-5 Pro",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 120.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 272_000
    },
    "gpt-5.1" => %Model{
      id: "gpt-5.1",
      name: "GPT-5.1",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.13, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-chat-latest" => %Model{
      id: "gpt-5.1-chat-latest",
      name: "GPT-5.1 Chat",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5.1-codex" => %Model{
      id: "gpt-5.1-codex",
      name: "GPT-5.1 Codex",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-max" => %Model{
      id: "gpt-5.1-codex-max",
      name: "GPT-5.1 Codex Max",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-mini" => %Model{
      id: "gpt-5.1-codex-mini",
      name: "GPT-5.1 Codex mini",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 2.0, cache_read: 0.025, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.2" => %Model{
      id: "gpt-5.2",
      name: "GPT-5.2",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.2-chat-latest" => %Model{
      id: "gpt-5.2-chat-latest",
      name: "GPT-5.2 Chat",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5.2-codex" => %Model{
      id: "gpt-5.2-codex",
      name: "GPT-5.2 Codex",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.2-pro" => %Model{
      id: "gpt-5.2-pro",
      name: "GPT-5.2 Pro",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 21.0, output: 168.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.3-codex" => %Model{
      id: "gpt-5.3-codex",
      name: "GPT-5.3 Codex",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.3-codex-spark" => %Model{
      id: "gpt-5.3-codex-spark",
      name: "GPT-5.3 Codex Spark",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_000
    },
    "o1" => %Model{
      id: "o1",
      name: "o1",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 60.0, cache_read: 7.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o1-pro" => %Model{
      id: "o1-pro",
      name: "o1-pro",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 150.0, output: 600.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3" => %Model{
      id: "o3",
      name: "o3",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3-deep-research" => %Model{
      id: "o3-deep-research",
      name: "o3-deep-research",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 40.0, cache_read: 2.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3-mini" => %Model{
      id: "o3-mini",
      name: "o3-mini",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.55, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3-pro" => %Model{
      id: "o3-pro",
      name: "o3-pro",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 20.0, output: 80.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o4-mini" => %Model{
      id: "o4-mini",
      name: "o4-mini",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.28, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o4-mini-deep-research" => %Model{
      id: "o4-mini-deep-research",
      name: "o4-mini-deep-research",
      api: :azure_openai_responses,
      provider: :azure_openai_responses,
      base_url: "null",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    }
  }

  @doc "Returns all AzureOpenAI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
