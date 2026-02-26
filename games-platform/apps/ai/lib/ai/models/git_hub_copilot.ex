defmodule Ai.Models.GitHubCopilot do
  @moduledoc """
  Model definitions for the GitHubCopilot provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
    "claude-haiku-4.5" => %Model{
      id: "claude-haiku-4.5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_000
    },
    "claude-opus-4.5" => %Model{
      id: "claude-opus-4.5",
      name: "Claude Opus 4.5",
      api: :anthropic_messages,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_000
    },
    "claude-opus-4.6" => %Model{
      id: "claude-opus-4.6",
      name: "Claude Opus 4.6",
      api: :anthropic_messages,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4" => %Model{
      id: "claude-sonnet-4",
      name: "Claude Sonnet 4",
      api: :anthropic_messages,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_000
    },
    "claude-sonnet-4.5" => %Model{
      id: "claude-sonnet-4.5",
      name: "Claude Sonnet 4.5",
      api: :anthropic_messages,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_000
    },
    "claude-sonnet-4.6" => %Model{
      id: "claude-sonnet-4.6",
      name: "Claude Sonnet 4.6",
      api: :anthropic_messages,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_000
    },
    "gemini-2.5-pro" => %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :openai_completions,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "gemini-3-flash-preview" => %Model{
      id: "gemini-3-flash-preview",
      name: "Gemini 3 Flash",
      api: :openai_completions,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "gemini-3-pro-preview" => %Model{
      id: "gemini-3-pro-preview",
      name: "Gemini 3 Pro Preview",
      api: :openai_completions,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "gemini-3.1-pro-preview" => %Model{
      id: "gemini-3.1-pro-preview",
      name: "Gemini 3.1 Pro Preview",
      api: :openai_completions,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "gpt-4.1" => %Model{
      id: "gpt-4.1",
      name: "GPT-4.1",
      api: :openai_completions,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 16_384
    },
    "gpt-4o" => %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_completions,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 16_384
    },
    "gpt-5" => %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 128_000
    },
    "gpt-5-mini" => %Model{
      id: "gpt-5-mini",
      name: "GPT-5-mini",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "gpt-5.1" => %Model{
      id: "gpt-5.1",
      name: "GPT-5.1",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "gpt-5.1-codex" => %Model{
      id: "gpt-5.1-codex",
      name: "GPT-5.1-Codex",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-max" => %Model{
      id: "gpt-5.1-codex-max",
      name: "GPT-5.1-Codex-max",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-mini" => %Model{
      id: "gpt-5.1-codex-mini",
      name: "GPT-5.1-Codex-mini",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 128_000
    },
    "gpt-5.2" => %Model{
      id: "gpt-5.2",
      name: "GPT-5.2",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "gpt-5.2-codex" => %Model{
      id: "gpt-5.2-codex",
      name: "GPT-5.2-Codex",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 272_000,
      max_tokens: 128_000
    },
    "grok-code-fast-1" => %Model{
      id: "grok-code-fast-1",
      name: "Grok Code Fast 1",
      api: :openai_completions,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    }
  }

  @doc "Returns all GitHubCopilot model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
