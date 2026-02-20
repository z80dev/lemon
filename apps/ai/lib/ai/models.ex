defmodule Ai.Models do
  @moduledoc """
  Registry of known AI models with their capabilities and pricing.

  This module provides access to model metadata including:
  - Model identification (id, name, provider)
  - API configuration (api type, base_url)
  - Capabilities (reasoning support, input types)
  - Pricing (cost per million tokens)
  - Limits (context window, max tokens)

  ## Usage

      # Get a specific model
      model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")

      # List all models for a provider
      models = Ai.Models.get_models(:openai)

      # Check capabilities
      Ai.Models.supports_vision?(model)
      Ai.Models.supports_reasoning?(model)

  """

  alias Ai.Types.{Model, ModelCost}

  @default_openai_base_url "https://api.openai.com/v1"
  @default_openai_discovery_timeout_ms 4_000

  # ============================================================================
  # Anthropic Models
  # ============================================================================

  @anthropic_models %{
    "claude-3-5-haiku-20241022" => %Model{
      id: "claude-3-5-haiku-20241022",
      name: "Claude Haiku 3.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 4.0, cache_read: 0.08, cache_write: 1.0},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-5-haiku-latest" => %Model{
      id: "claude-3-5-haiku-latest",
      name: "Claude Haiku 3.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 4.0, cache_read: 0.08, cache_write: 1.0},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-5-sonnet-20240620" => %Model{
      id: "claude-3-5-sonnet-20240620",
      name: "Claude Sonnet 3.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-5-sonnet-20241022" => %Model{
      id: "claude-3-5-sonnet-20241022",
      name: "Claude Sonnet 3.5 v2",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192
    },
    "claude-3-7-sonnet-20250219" => %Model{
      id: "claude-3-7-sonnet-20250219",
      name: "Claude Sonnet 3.7",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-3-7-sonnet-latest" => %Model{
      id: "claude-3-7-sonnet-latest",
      name: "Claude Sonnet 3.7 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-6" => %Model{
      id: "claude-sonnet-4.6",
      name: "Claude Sonnet 4.6",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-6" => %Model{
      id: "claude-opus-4.6",
      name: "Claude Opus 4.6",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 128_000
    },
    "claude-3-haiku-20240307" => %Model{
      id: "claude-3-haiku-20240307",
      name: "Claude Haiku 3",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 1.25, cache_read: 0.03, cache_write: 0.3},
      context_window: 200_000,
      max_tokens: 4096
    },
    "claude-3-opus-20240229" => %Model{
      id: "claude-3-opus-20240229",
      name: "Claude Opus 3",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 4096
    },
    "claude-3-sonnet-20240229" => %Model{
      id: "claude-3-sonnet-20240229",
      name: "Claude Sonnet 3",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 0.3},
      context_window: 200_000,
      max_tokens: 4096
    },
    "claude-haiku-4-5" => %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-haiku-4-5-20251001" => %Model{
      id: "claude-haiku-4-5-20251001",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-0" => %Model{
      id: "claude-opus-4-0",
      name: "Claude Opus 4 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-1" => %Model{
      id: "claude-opus-4-1",
      name: "Claude Opus 4.1 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-1-20250805" => %Model{
      id: "claude-opus-4-1-20250805",
      name: "Claude Opus 4.1",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-20250514" => %Model{
      id: "claude-opus-4-20250514",
      name: "Claude Opus 4",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "claude-opus-4-5" => %Model{
      id: "claude-opus-4-5",
      name: "Claude Opus 4.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-opus-4-5-20251101" => %Model{
      id: "claude-opus-4-5-20251101",
      name: "Claude Opus 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-0" => %Model{
      id: "claude-sonnet-4-0",
      name: "Claude Sonnet 4 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-20250514" => %Model{
      id: "claude-sonnet-4-20250514",
      name: "Claude Sonnet 4",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-5" => %Model{
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5 (latest)",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "claude-sonnet-4-5-20250929" => %Model{
      id: "claude-sonnet-4-5-20250929",
      name: "Claude Sonnet 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    }
  }

  # ============================================================================
  # OpenAI Models
  # ============================================================================

  @openai_models %{
    "codex-mini-latest" => %Model{
      id: "codex-mini-latest",
      name: "Codex Mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.5, output: 6.0, cache_read: 0.375, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "gpt-4" => %Model{
      id: "gpt-4",
      name: "GPT-4",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 30.0, output: 60.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 8192,
      max_tokens: 8192
    },
    "gpt-4-turbo" => %Model{
      id: "gpt-4-turbo",
      name: "GPT-4 Turbo",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 30.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "gpt-4.1" => %Model{
      id: "gpt-4.1",
      name: "GPT-4.1",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "gpt-4.1-mini" => %Model{
      id: "gpt-4.1-mini",
      name: "GPT-4.1 mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.4, output: 1.6, cache_read: 0.1, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "gpt-4.1-nano" => %Model{
      id: "gpt-4.1-nano",
      name: "GPT-4.1 nano",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.03, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "gpt-4o" => %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-4o-2024-05-13" => %Model{
      id: "gpt-4o-2024-05-13",
      name: "GPT-4o (2024-05-13)",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "gpt-4o-2024-08-06" => %Model{
      id: "gpt-4o-2024-08-06",
      name: "GPT-4o (2024-08-06)",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-4o-2024-11-20" => %Model{
      id: "gpt-4o-2024-11-20",
      name: "GPT-4o (2024-11-20)",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-4o-mini" => %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.08, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5" => %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-chat-latest" => %Model{
      id: "gpt-5-chat-latest",
      name: "GPT-5 Chat Latest",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5-codex" => %Model{
      id: "gpt-5-codex",
      name: "GPT-5-Codex",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-mini" => %Model{
      id: "gpt-5-mini",
      name: "GPT-5 Mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 2.0, cache_read: 0.025, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-nano" => %Model{
      id: "gpt-5-nano",
      name: "GPT-5 Nano",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.05, output: 0.4, cache_read: 0.005, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5-pro" => %Model{
      id: "gpt-5-pro",
      name: "GPT-5 Pro",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 120.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 272_000
    },
    "gpt-5.1" => %Model{
      id: "gpt-5.1",
      name: "GPT-5.1",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.13, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-chat-latest" => %Model{
      id: "gpt-5.1-chat-latest",
      name: "GPT-5.1 Chat",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5.1-codex" => %Model{
      id: "gpt-5.1-codex",
      name: "GPT-5.1 Codex",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-max" => %Model{
      id: "gpt-5.1-codex-max",
      name: "GPT-5.1 Codex Max",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.1-codex-mini" => %Model{
      id: "gpt-5.1-codex-mini",
      name: "GPT-5.1 Codex mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
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
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.2-chat-latest" => %Model{
      id: "gpt-5.2-chat-latest",
      name: "GPT-5.2 Chat",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "gpt-5.2-codex" => %Model{
      id: "gpt-5.2-codex",
      name: "GPT-5.2 Codex",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.3-codex" => %Model{
      id: "gpt-5.3-codex",
      name: "GPT-5.3 Codex",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "gpt-5.3-codex-spark" => %Model{
      id: "gpt-5.3-codex-spark",
      name: "GPT-5.3 Codex Spark",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_000
    },
    "gpt-5.2-pro" => %Model{
      id: "gpt-5.2-pro",
      name: "GPT-5.2 Pro",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 21.0, output: 168.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "o1" => %Model{
      id: "o1",
      name: "o1",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 60.0, cache_read: 7.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o1-pro" => %Model{
      id: "o1-pro",
      name: "o1-pro",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 150.0, output: 600.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3" => %Model{
      id: "o3",
      name: "o3",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3-deep-research" => %Model{
      id: "o3-deep-research",
      name: "o3-deep-research",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 40.0, cache_read: 2.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3-mini" => %Model{
      id: "o3-mini",
      name: "o3-mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.55, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o3-pro" => %Model{
      id: "o3-pro",
      name: "o3-pro",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 20.0, output: 80.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o4-mini" => %Model{
      id: "o4-mini",
      name: "o4-mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.28, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "o4-mini-deep-research" => %Model{
      id: "o4-mini-deep-research",
      name: "o4-mini-deep-research",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    }
  }

  # ============================================================================
  # Google Models
  # ============================================================================

  @google_models %{
    "gemini-1.5-flash" => %Model{
      id: "gemini-1.5-flash",
      name: "Gemini 1.5 Flash",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.01875, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8192
    },
    "gemini-1.5-flash-8b" => %Model{
      id: "gemini-1.5-flash-8b",
      name: "Gemini 1.5 Flash-8B",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0375, output: 0.15, cache_read: 0.01, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8192
    },
    "gemini-1.5-pro" => %Model{
      id: "gemini-1.5-pro",
      name: "Gemini 1.5 Pro",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8192
    },
    "gemini-2.0-flash" => %Model{
      id: "gemini-2.0-flash",
      name: "Gemini 2.0 Flash",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.025, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 8192
    },
    "gemini-2.0-flash-lite" => %Model{
      id: "gemini-2.0-flash-lite",
      name: "Gemini 2.0 Flash Lite",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 8192
    },
    "gemini-2.5-flash" => %Model{
      id: "gemini-2.5-flash",
      name: "Gemini 2.5 Flash",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.3, output: 2.5, cache_read: 0.075, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-flash-lite" => %Model{
      id: "gemini-2.5-flash-lite",
      name: "Gemini 2.5 Flash Lite",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.025, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-flash-lite-preview-06-17" => %Model{
      id: "gemini-2.5-flash-lite-preview-06-17",
      name: "Gemini 2.5 Flash Lite Preview 06-17",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.025, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-flash-preview-04-17" => %Model{
      id: "gemini-2.5-flash-preview-04-17",
      name: "Gemini 2.5 Flash Preview 04-17",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0375, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-flash-preview-05-20" => %Model{
      id: "gemini-2.5-flash-preview-05-20",
      name: "Gemini 2.5 Flash Preview 05-20",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0375, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-pro" => %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.31, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-pro-preview-05-06" => %Model{
      id: "gemini-2.5-pro-preview-05-06",
      name: "Gemini 2.5 Pro Preview 05-06",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.31, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-pro-preview-06-05" => %Model{
      id: "gemini-2.5-pro-preview-06-05",
      name: "Gemini 2.5 Pro Preview 06-05",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.31, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-3-flash-preview" => %Model{
      id: "gemini-3-flash-preview",
      name: "Gemini 3 Flash Preview",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.5, output: 3.0, cache_read: 0.05, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-3-pro-preview" => %Model{
      id: "gemini-3-pro-preview",
      name: "Gemini 3 Pro Preview",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "gemini-3.1-pro" => %Model{
      id: "gemini-3.1-pro",
      name: "Gemini 3.1 Pro",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-3.1-pro-preview" => %Model{
      id: "gemini-3.1-pro-preview",
      name: "Gemini 3.1 Pro Preview",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-flash-latest" => %Model{
      id: "gemini-flash-latest",
      name: "Gemini Flash Latest",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.3, output: 2.5, cache_read: 0.075, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-flash-lite-latest" => %Model{
      id: "gemini-flash-lite-latest",
      name: "Gemini Flash-Lite Latest",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.025, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    }
  }

  # ============================================================================
  # Kimi Models (Anthropic-compatible API)
  # ============================================================================

  @kimi_models %{
    "kimi-for-coding" => %Model{
      id: "kimi-for-coding",
      name: "Kimi for Coding",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: "https://api.kimi.com/coding",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 64_000
    }
  }

  # ============================================================================
  # Combined Registry
  # ============================================================================

  # OpenAI Codex (ChatGPT OAuth) uses the Codex Responses endpoint.
  # Models are mostly the same IDs as OpenAI's Responses API, but usage is billed
  # via ChatGPT subscription, not per-token API pricing, so we set costs to 0.
  @openai_codex_models Enum.into(@openai_models, %{}, fn {id, model} ->
                         {id,
                          %Model{
                            model
                            | api: :openai_codex_responses,
                              provider: :"openai-codex",
                              base_url: "https://chatgpt.com",
                              cost: %ModelCost{
                                input: 0.0,
                                output: 0.0,
                                cache_read: 0.0,
                                cache_write: 0.0
                              }
                          }}
                       end)

  @models %{
    :anthropic => @anthropic_models,
    :openai => @openai_models,
    :"openai-codex" => @openai_codex_models,
    :google => @google_models,
    :kimi => @kimi_models
  }

  @providers Map.keys(@models)

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Get a specific model by provider and model ID.

  ## Examples

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> model.name
      "Claude Sonnet 4"

      iex> Ai.Models.get_model(:anthropic, "nonexistent")
      nil

  """
  @spec get_model(atom(), String.t()) :: Model.t() | nil
  def get_model(provider, model_id) when is_atom(provider) and is_binary(model_id) do
    case Map.get(@models, provider) do
      nil -> nil
      provider_models -> Map.get(provider_models, model_id)
    end
  end

  @doc """
  Get all models for a provider.

  ## Examples

      iex> models = Ai.Models.get_models(:anthropic)
      iex> length(models) > 0
      true

      iex> Ai.Models.get_models(:unknown_provider)
      []

  """
  @spec get_models(atom()) :: [Model.t()]
  def get_models(provider) when is_atom(provider) do
    case Map.get(@models, provider) do
      nil -> []
      provider_models -> Map.values(provider_models)
    end
  end

  @doc """
  List all known providers.

  ## Examples

      iex> providers = Ai.Models.get_providers()
      iex> :anthropic in providers
      true

  """
  @spec get_providers() :: [atom()]
  def get_providers do
    @providers
  end

  @doc """
  List all known models across all providers.

  ## Examples

      iex> models = Ai.Models.list_models()
      iex> length(models) > 0
      true

  """
  @spec list_models() :: [Model.t()]
  def list_models do
    @models
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
  end

  @type list_models_opt ::
          {:discover_openai, boolean()}
          | {:openai_api_key, String.t()}
          | {:openai_base_url, String.t()}
          | {:openai_timeout_ms, pos_integer()}

  @doc """
  List all known models with optional runtime discovery.

  ## Options

  - `:discover_openai` - When true, query OpenAI `/v1/models` and filter the
    OpenAI model list to IDs reported as available for the configured key.
    If discovery fails, returns the static model registry.
  - `:openai_api_key` - Optional API key override for discovery.
  - `:openai_base_url` - Optional OpenAI-compatible base URL override.
  - `:openai_timeout_ms` - Optional request timeout in milliseconds.
  """
  @spec list_models([list_models_opt()]) :: [Model.t()]
  def list_models(opts) when is_list(opts) do
    static_models = list_models()

    if Keyword.get(opts, :discover_openai, false) do
      case discover_openai_model_ids(opts) do
        {:ok, available_ids} ->
          filter_openai_models(static_models, available_ids)

        {:error, _reason} ->
          static_models
      end
    else
      static_models
    end
  end

  @doc """
  Backwards-compatible alias for `list_models/0`.
  """
  @deprecated "Use list_models/0"
  @spec all() :: [Model.t()]
  def all, do: list_models()

  @doc """
  Check if a model supports vision (image input).

  ## Examples

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.supports_vision?(model)
      true

      iex> model = Ai.Models.get_model(:openai, "o3-mini")
      iex> Ai.Models.supports_vision?(model)
      false

  """
  @spec supports_vision?(Model.t()) :: boolean()
  def supports_vision?(%Model{input: input}) do
    :image in input
  end

  @doc """
  Check if a model supports reasoning/thinking.

  ## Examples

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.supports_reasoning?(model)
      true

      iex> model = Ai.Models.get_model(:openai, "gpt-4o")
      iex> Ai.Models.supports_reasoning?(model)
      false

  """
  @spec supports_reasoning?(Model.t()) :: boolean()
  def supports_reasoning?(%Model{reasoning: reasoning}) do
    reasoning
  end

  @doc """
  Find a model by ID across all providers.

  Returns the first matching model found, or nil if no match.

  ## Examples

      iex> model = Ai.Models.find_by_id("gpt-4o")
      iex> model.provider
      :openai

      iex> Ai.Models.find_by_id("nonexistent")
      nil

  """
  @spec find_by_id(String.t()) :: Model.t() | nil
  def find_by_id(model_id) when is_binary(model_id) do
    Enum.find_value(@providers, fn provider ->
      get_model(provider, model_id)
    end)
  end

  @doc """
  Get model IDs for a provider.

  ## Examples

      iex> ids = Ai.Models.get_model_ids(:anthropic)
      iex> "claude-sonnet-4-20250514" in ids
      true

  """
  @spec get_model_ids(atom()) :: [String.t()]
  def get_model_ids(provider) when is_atom(provider) do
    case Map.get(@models, provider) do
      nil -> []
      provider_models -> Map.keys(provider_models)
    end
  end

  defp discover_openai_model_ids(opts) do
    with {:ok, api_key} <- resolve_openai_api_key(opts),
         {:ok, %Req.Response{status: status, body: body}} when status in 200..299 <-
           Req.get(openai_models_url(opts),
             headers: %{
               "Authorization" => "Bearer #{api_key}",
               "Accept" => "application/json"
             },
             connect_options: [timeout: openai_timeout_ms(opts)],
             receive_timeout: openai_timeout_ms(opts),
             retry: false
           ),
         %{"data" => data} when is_list(data) <- body do
      ids =
        data
        |> Enum.flat_map(fn
          %{"id" => id} when is_binary(id) and id != "" -> [id]
          _ -> []
        end)
        |> MapSet.new()

      if MapSet.size(ids) > 0 do
        {:ok, ids}
      else
        {:error, :no_models_returned}
      end
    else
      {:ok, _response} ->
        {:error, :http_error}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :invalid_response}
    end
  rescue
    _ -> {:error, :request_failed}
  end

  defp resolve_openai_api_key(opts) do
    case Keyword.get(opts, :openai_api_key) || System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp openai_models_url(opts) do
    base_url =
      Keyword.get(opts, :openai_base_url) ||
        System.get_env("OPENAI_BASE_URL") ||
        @default_openai_base_url

    "#{normalize_openai_base_url(base_url)}/models"
  end

  defp normalize_openai_base_url(base_url) when is_binary(base_url) do
    trimmed =
      base_url
      |> String.trim()
      |> String.trim_trailing("/")

    cond do
      trimmed == "" ->
        @default_openai_base_url

      String.ends_with?(trimmed, "/v1") ->
        trimmed

      true ->
        "#{trimmed}/v1"
    end
  end

  defp openai_timeout_ms(opts) do
    case Keyword.get(opts, :openai_timeout_ms, @default_openai_discovery_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_openai_discovery_timeout_ms
    end
  end

  defp filter_openai_models(models, available_ids) do
    Enum.filter(models, fn
      %Model{provider: :openai, id: id} -> MapSet.member?(available_ids, id)
      %Model{} -> true
    end)
  end
end
