defmodule Ai.Models.OpenCode do
  @moduledoc """
  Model definitions for the OpenCode provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "big-pickle" => %Model{
      id: "big-pickle",
      name: "Big Pickle",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 128_000
    },
    "claude-3-5-haiku" => %Model{
      id: "claude-3-5-haiku",
      name: "Claude Haiku 3.5",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 4.0, cache_read: 0.08, cache_write: 1.0},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-haiku-4-5" => %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-1" => %Model{
      id: "claude-opus-4-1",
      name: "Claude Opus 4.1",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-5" => %Model{
      id: "claude-opus-4-5",
      name: "Claude Opus 4.5",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-6" => %Model{
      id: "claude-opus-4-6",
      name: "Claude Opus 4.6",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 128_000
    },
    "claude-sonnet-4" => %Model{
      id: "claude-sonnet-4",
      name: "Claude Sonnet 4",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-5" => %Model{
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-6" => %Model{
      id: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "gemini-3-flash" => %Model{
      id: "gemini-3-flash",
      name: "Gemini 3 Flash",
      api: :google_generative_ai,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.5, output: 3.0, cache_read: 0.05, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-3-pro" => %Model{
      id: "gemini-3-pro",
      name: "Gemini 3 Pro",
      api: :google_generative_ai,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-3.1-pro" => %Model{
      id: "gemini-3.1-pro",
      name: "Gemini 3.1 Pro Preview",
      api: :google_generative_ai,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "glm-4.6" => %Model{
      id: "glm-4.6",
      name: "GLM-4.6",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.1, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "glm-4.7" => %Model{
      id: "glm-4.7",
      name: "GLM-4.7",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.1, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "glm-5" => %Model{
      id: "glm-5",
      name: "GLM-5",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.2, cache_read: 0.2, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "glm-5-free" => %Model{
      id: "glm-5-free",
      name: "GLM-5 Free",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "gpt-5" => %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.07, output: 8.5, cache_read: 0.107, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-codex" => %Model{
      id: "gpt-5-codex",
      name: "GPT-5 Codex",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.07, output: 8.5, cache_read: 0.107, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-nano" => %Model{
      id: "gpt-5-nano",
      name: "GPT-5 Nano",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1" => %Model{
      id: "gpt-5.1",
      name: "GPT-5.1",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.07, output: 8.5, cache_read: 0.107, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex" => %Model{
      id: "gpt-5.1-codex",
      name: "GPT-5.1 Codex",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.07, output: 8.5, cache_read: 0.107, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-max" => %Model{
      id: "gpt-5.1-codex-max",
      name: "GPT-5.1 Codex Max",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-mini" => %Model{
      id: "gpt-5.1-codex-mini",
      name: "GPT-5.1 Codex Mini",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 2.0, cache_read: 0.025, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.2" => %Model{
      id: "gpt-5.2",
      name: "GPT-5.2",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.2-codex" => %Model{
      id: "gpt-5.2-codex",
      name: "GPT-5.2 Codex",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "trinity-large-preview-free" => %Model{
      id: "trinity-large-preview-free",
      name: "Trinity Large Preview",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "kimi-k2" => %Model{
      id: "kimi-k2",
      name: "Kimi K2",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.4, output: 2.5, cache_read: 0.4, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 262_144
    },
    "kimi-k2-thinking" => %Model{
      id: "kimi-k2-thinking",
      name: "Kimi K2 Thinking",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.4, output: 2.5, cache_read: 0.4, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 262_144
    },
    "kimi-k2.5" => %Model{
      id: "kimi-k2.5",
      name: "Kimi K2.5",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 3.0, cache_read: 0.08, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 262_144
    },
    "minimax-m2.1" => %Model{
      id: "minimax-m2.1",
      name: "MiniMax M2.1",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.1, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "minimax-m2.5" => %Model{
      id: "minimax-m2.5",
      name: "MiniMax M2.5",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.06, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "minimax-m2.5-free" => %Model{
      id: "minimax-m2.5-free",
      name: "MiniMax M2.5 Free",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: "https://opencode.ai/zen",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    }
  }

  @doc "Returns all OpenCode model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
