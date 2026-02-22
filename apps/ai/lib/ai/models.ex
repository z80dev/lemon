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
    "claude-opus-4-6-thinking" => %Model{
      id: "claude-opus-4-6-thinking",
      name: "Claude Opus 4.6 (Thinking)",
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
  # Amazon Bedrock Models
  # ============================================================================

  @amazon_bedrock_models %{
    # Amazon Nova Models
    "amazon.nova-2-lite-v1:0" => %Model{
      id: "amazon.nova-2-lite-v1:0",
      name: "Nova 2 Lite",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.33, output: 2.75, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "amazon.nova-lite-v1:0" => %Model{
      id: "amazon.nova-lite-v1:0",
      name: "Nova Lite",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.06, output: 0.24, cache_read: 0.015, cache_write: 0.0},
      context_window: 300_000,
      max_tokens: 8192
    },
    "amazon.nova-micro-v1:0" => %Model{
      id: "amazon.nova-micro-v1:0",
      name: "Nova Micro",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.035, output: 0.14, cache_read: 0.00875, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "amazon.nova-premier-v1:0" => %Model{
      id: "amazon.nova-premier-v1:0",
      name: "Nova Premier",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 12.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 16384
    },
    "amazon.nova-pro-v1:0" => %Model{
      id: "amazon.nova-pro-v1:0",
      name: "Nova Pro",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 3.2, cache_read: 0.2, cache_write: 0.0},
      context_window: 300_000,
      max_tokens: 8192
    },

    # Amazon Titan Models
    "amazon.titan-text-express-v1" => %Model{
      id: "amazon.titan-text-express-v1",
      name: "Titan Text G1 - Express",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.2, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },

    # Anthropic Claude Models (Standard)
    "anthropic.claude-3-haiku-20240307-v1:0" => %Model{
      id: "anthropic.claude-3-haiku-20240307-v1:0",
      name: "Claude Haiku 3 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 1.25, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 4096
    },
    "anthropic.claude-3-sonnet-20240229-v1:0" => %Model{
      id: "anthropic.claude-3-sonnet-20240229-v1:0",
      name: "Claude Sonnet 3 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 4096
    },
    "anthropic.claude-3-opus-20240229-v1:0" => %Model{
      id: "anthropic.claude-3-opus-20240229-v1:0",
      name: "Claude Opus 3 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 4096
    },
    "anthropic.claude-3-5-sonnet-20240620-v1:0" => %Model{
      id: "anthropic.claude-3-5-sonnet-20240620-v1:0",
      name: "Claude Sonnet 3.5 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192
    },
    "anthropic.claude-3-5-sonnet-20241022-v2:0" => %Model{
      id: "anthropic.claude-3-5-sonnet-20241022-v2:0",
      name: "Claude Sonnet 3.5 v2 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192
    },
    "anthropic.claude-3-5-haiku-20241022-v1:0" => %Model{
      id: "anthropic.claude-3-5-haiku-20241022-v1:0",
      name: "Claude Haiku 3.5 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.8, output: 4.0, cache_read: 0.08, cache_write: 1.0},
      context_window: 200_000,
      max_tokens: 8192
    },
    "anthropic.claude-3-7-sonnet-20250219-v1:0" => %Model{
      id: "anthropic.claude-3-7-sonnet-20250219-v1:0",
      name: "Claude Sonnet 3.7 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192
    },
    "anthropic.claude-sonnet-4-20250514-v1:0" => %Model{
      id: "anthropic.claude-sonnet-4-20250514-v1:0",
      name: "Claude Sonnet 4 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic.claude-sonnet-4-5-20250929-v1:0" => %Model{
      id: "anthropic.claude-sonnet-4-5-20250929-v1:0",
      name: "Claude Sonnet 4.5 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic.claude-sonnet-4-6" => %Model{
      id: "anthropic.claude-sonnet-4-6",
      name: "Claude Sonnet 4.6 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic.claude-opus-4-20250514-v1:0" => %Model{
      id: "anthropic.claude-opus-4-20250514-v1:0",
      name: "Claude Opus 4 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "anthropic.claude-opus-4-5-20251101-v1:0" => %Model{
      id: "anthropic.claude-opus-4-5-20251101-v1:0",
      name: "Claude Opus 4.5 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic.claude-opus-4-6-v1" => %Model{
      id: "anthropic.claude-opus-4-6-v1",
      name: "Claude Opus 4.6 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 128_000
    },
    "anthropic.claude-haiku-4-5-20251001-v1:0" => %Model{
      id: "anthropic.claude-haiku-4-5-20251001-v1:0",
      name: "Claude Haiku 4.5 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic.claude-opus-4-1-20250805-v1:0" => %Model{
      id: "anthropic.claude-opus-4-1-20250805-v1:0",
      name: "Claude Opus 4.1 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },

    # Meta Llama Models
    "meta.llama3-1-8b-instruct-v1:0" => %Model{
      id: "meta.llama3-1-8b-instruct-v1:0",
      name: "Llama 3.1 8B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.22, output: 0.22, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "meta.llama3-1-70b-instruct-v1:0" => %Model{
      id: "meta.llama3-1-70b-instruct-v1:0",
      name: "Llama 3.1 70B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.72, output: 0.72, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "meta.llama3-2-1b-instruct-v1:0" => %Model{
      id: "meta.llama3-2-1b-instruct-v1:0",
      name: "Llama 3.2 1B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.1, output: 0.1, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_000,
      max_tokens: 4096
    },
    "meta.llama3-2-3b-instruct-v1:0" => %Model{
      id: "meta.llama3-2-3b-instruct-v1:0",
      name: "Llama 3.2 3B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.15, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_000,
      max_tokens: 4096
    },
    "meta.llama3-2-11b-instruct-v1:0" => %Model{
      id: "meta.llama3-2-11b-instruct-v1:0",
      name: "Llama 3.2 11B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.16, output: 0.16, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "meta.llama3-2-90b-instruct-v1:0" => %Model{
      id: "meta.llama3-2-90b-instruct-v1:0",
      name: "Llama 3.2 90B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.72, output: 0.72, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "meta.llama3-3-70b-instruct-v1:0" => %Model{
      id: "meta.llama3-3-70b-instruct-v1:0",
      name: "Llama 3.3 70B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.72, output: 0.72, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "meta.llama4-scout-17b-instruct-v1:0" => %Model{
      id: "meta.llama4-scout-17b-instruct-v1:0",
      name: "Llama 4 Scout 17B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.17, output: 0.66, cache_read: 0.0, cache_write: 0.0},
      context_window: 3_500_000,
      max_tokens: 16_384
    },
    "meta.llama4-maverick-17b-instruct-v1:0" => %Model{
      id: "meta.llama4-maverick-17b-instruct-v1:0",
      name: "Llama 4 Maverick 17B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.24, output: 0.97, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 16_384
    },

    # DeepSeek Models
    "deepseek.r1-v1:0" => %Model{
      id: "deepseek.r1-v1:0",
      name: "DeepSeek-R1 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.35, output: 5.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_768
    },
    "deepseek.v3-v1:0" => %Model{
      id: "deepseek.v3-v1:0",
      name: "DeepSeek-V3.1 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.58, output: 1.68, cache_read: 0.0, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 81_920
    },
    "deepseek.v3.2-v1:0" => %Model{
      id: "deepseek.v3.2-v1:0",
      name: "DeepSeek-V3.2 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.62, output: 1.85, cache_read: 0.0, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 81_920
    },

    # Cohere Models
    "cohere.command-r-v1:0" => %Model{
      id: "cohere.command-r-v1:0",
      name: "Command R (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "cohere.command-r-plus-v1:0" => %Model{
      id: "cohere.command-r-plus-v1:0",
      name: "Command R+ (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },

    # Mistral Models
    "mistral.mistral-large-2402-v1:0" => %Model{
      id: "mistral.mistral-large-2402-v1:0",
      name: "Mistral Large 24.02 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "mistral.ministral-3-8b-instruct" => %Model{
      id: "mistral.ministral-3-8b-instruct",
      name: "Ministral 3 8B (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.15, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "mistral.ministral-3-14b-instruct" => %Model{
      id: "mistral.ministral-3-14b-instruct",
      name: "Ministral 14B 3.0 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.2, output: 0.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "mistral.voxtral-mini-3b-2507" => %Model{
      id: "mistral.voxtral-mini-3b-2507",
      name: "Voxtral Mini 3B 2507 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.04, output: 0.04, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "mistral.voxtral-small-24b-2507" => %Model{
      id: "mistral.voxtral-small-24b-2507",
      name: "Voxtral Small 24B 2507 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.35, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_000,
      max_tokens: 8192
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
    "gemini-3-flash" => %Model{
      id: "gemini-3-flash",
      name: "Gemini 3 Flash",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.5, output: 3.0, cache_read: 0.5, cache_write: 0.0},
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
    "gemini-3-pro" => %Model{
      id: "gemini-3-pro",
      name: "Gemini 3 Pro",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
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
    "gemini-3.1-pro-preview-customtools" => %Model{
      id: "gemini-3.1-pro-preview-customtools",
      name: "Gemini 3.1 Pro Preview (Custom Tools)",
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
    },

    # ============================================================================
    # Google Antigravity Models (Internal Google CLI)
    # ============================================================================
    "gemini-3-pro-high" => %Model{
      id: "gemini-3-pro-high",
      name: "Gemini 3 Pro High (Antigravity)",
      api: :google_gemini_cli,
      provider: :google_antigravity,
      base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 2.375},
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "gemini-3-pro-low" => %Model{
      id: "gemini-3-pro-low",
      name: "Gemini 3 Pro Low (Antigravity)",
      api: :google_gemini_cli,
      provider: :google_antigravity,
      base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 2.375},
      context_window: 1_048_576,
      max_tokens: 65_535
    }
  }

  # Extract antigravity models into separate attribute for registry
  @google_antigravity_models Map.filter(@google_models, fn {_id, model} ->
                               model.provider == :google_antigravity
                             end)

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
    },
    "k2p5" => %Model{
      id: "k2p5",
      name: "Kimi K2.5",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: "https://api.kimi.com/coding",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
    "kimi-k2-thinking" => %Model{
      id: "kimi-k2-thinking",
      name: "Kimi K2 Thinking",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: "https://api.kimi.com/coding",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    }
  }

  # ============================================================================
  # OpenCode Models (OpenAI-compatible API)
  # ============================================================================

  @opencode_models %{
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

  # ============================================================================
  # xAI Models (Grok series via OpenAI-compatible API)
  # ============================================================================

  @xai_models %{
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
    }
  }

  # ============================================================================
  # Mistral Models
  # ============================================================================

  @mistral_models %{
    "codestral-latest" => %Model{
      id: "codestral-latest",
      name: "Codestral",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 0.9, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    },
    "codestral-2501" => %Model{
      id: "codestral-2501",
      name: "Codestral 2501",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 0.9, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    },
    "devstral-latest" => %Model{
      id: "devstral-latest",
      name: "Devstral",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "mistral-large-latest" => %Model{
      id: "mistral-large-latest",
      name: "Mistral Large",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "mistral-medium-latest" => %Model{
      id: "mistral-medium-latest",
      name: "Mistral Medium",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "mistral-small-latest" => %Model{
      id: "mistral-small-latest",
      name: "Mistral Small",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.2, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "pixtral-large-latest" => %Model{
      id: "pixtral-large-latest",
      name: "Pixtral Large",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    }
  }

  # ============================================================================
  # Cerebras Models
  # ============================================================================

  @cerebras_models %{
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
    }
  }

  # ============================================================================
  # DeepSeek Models
  # ============================================================================

  @deepseek_models %{
    "deepseek-chat" => %Model{
      id: "deepseek-chat",
      name: "DeepSeek V3",
      api: :openai_completions,
      provider: :deepseek,
      base_url: "https://api.deepseek.com/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.27, output: 1.1, cache_read: 0.07, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 8192
    },
    "deepseek-reasoner" => %Model{
      id: "deepseek-reasoner",
      name: "DeepSeek R1",
      api: :openai_completions,
      provider: :deepseek,
      base_url: "https://api.deepseek.com/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.55, output: 2.19, cache_read: 0.14, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 8192
    },
    "deepseek-r1" => %Model{
      id: "deepseek-r1",
      name: "DeepSeek R1 (Alias)",
      api: :openai_completions,
      provider: :deepseek,
      base_url: "https://api.deepseek.com/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.55, output: 2.19, cache_read: 0.14, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 8192
    }
  }

  # ============================================================================
  # Qwen Models (Alibaba Cloud)
  # ============================================================================

  @qwen_models %{
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

  # ============================================================================
  # MiniMax Models
  # ============================================================================

  @minimax_models %{
    "minimax-m2" => %Model{
      id: "minimax-m2",
      name: "MiniMax M2",
      api: :openai_completions,
      provider: :minimax,
      base_url: "https://api.minimaxi.chat/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    },
    "minimax-m2.1" => %Model{
      id: "minimax-m2.1",
      name: "MiniMax M2.1",
      api: :openai_completions,
      provider: :minimax,
      base_url: "https://api.minimaxi.chat/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    },
    "minimax-m2.5" => %Model{
      id: "minimax-m2.5",
      name: "MiniMax M2.5",
      api: :openai_completions,
      provider: :minimax,
      base_url: "https://api.minimaxi.chat/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.8, output: 3.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8192
    }
  }

  # ============================================================================
  # Z.ai Models (GLM Series)
  # ============================================================================

  @zai_models %{
    "glm-4.5-flash" => %Model{
      id: "glm-4.5-flash",
      name: "GLM 4.5 Flash",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "glm-4.5-air" => %Model{
      id: "glm-4.5-air",
      name: "GLM 4.5 Air",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "glm-4.5" => %Model{
      id: "glm-4.5",
      name: "GLM 4.5",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "glm-4.7" => %Model{
      id: "glm-4.7",
      name: "GLM 4.7",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.8, output: 3.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8192
    },
    "glm-5" => %Model{
      id: "glm-5",
      name: "GLM 5",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 4.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 16384
    }
  }

  # ============================================================================
  # Provider Models
  # ============================================================================

  @amazon_bedrock_models Map.merge(
                           @amazon_bedrock_models,
                           %{
                             "amazon.titan-text-express-v1:0:8k" => %Model{
                               id: "amazon.titan-text-express-v1:0:8k",
                               name: "Titan Text G1 - Express",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.2,
                                 output: 0.6,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "eu.anthropic.claude-haiku-4-5-20251001-v1:0" => %Model{
                               id: "eu.anthropic.claude-haiku-4-5-20251001-v1:0",
                               name: "Claude Haiku 4.5 (EU)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 1.0,
                                 output: 5.0,
                                 cache_read: 0.1,
                                 cache_write: 1.25
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "eu.anthropic.claude-opus-4-5-20251101-v1:0" => %Model{
                               id: "eu.anthropic.claude-opus-4-5-20251101-v1:0",
                               name: "Claude Opus 4.5 (EU)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 5.0,
                                 output: 25.0,
                                 cache_read: 0.5,
                                 cache_write: 6.25
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "eu.anthropic.claude-opus-4-6-v1" => %Model{
                               id: "eu.anthropic.claude-opus-4-6-v1",
                               name: "Claude Opus 4.6 (EU)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 5.0,
                                 output: 25.0,
                                 cache_read: 0.5,
                                 cache_write: 6.25
                               },
                               context_window: 200_000,
                               max_tokens: 128_000
                             },
                             "eu.anthropic.claude-sonnet-4-20250514-v1:0" => %Model{
                               id: "eu.anthropic.claude-sonnet-4-20250514-v1:0",
                               name: "Claude Sonnet 4 (EU)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "eu.anthropic.claude-sonnet-4-5-20250929-v1:0" => %Model{
                               id: "eu.anthropic.claude-sonnet-4-5-20250929-v1:0",
                               name: "Claude Sonnet 4.5 (EU)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "eu.anthropic.claude-sonnet-4-6" => %Model{
                               id: "eu.anthropic.claude-sonnet-4-6",
                               name: "Claude Sonnet 4.6 (EU)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "global.anthropic.claude-haiku-4-5-20251001-v1:0" => %Model{
                               id: "global.anthropic.claude-haiku-4-5-20251001-v1:0",
                               name: "Claude Haiku 4.5 (Global)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 1.0,
                                 output: 5.0,
                                 cache_read: 0.1,
                                 cache_write: 1.25
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "global.anthropic.claude-opus-4-5-20251101-v1:0" => %Model{
                               id: "global.anthropic.claude-opus-4-5-20251101-v1:0",
                               name: "Claude Opus 4.5 (Global)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 5.0,
                                 output: 25.0,
                                 cache_read: 0.5,
                                 cache_write: 6.25
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "global.anthropic.claude-opus-4-6-v1" => %Model{
                               id: "global.anthropic.claude-opus-4-6-v1",
                               name: "Claude Opus 4.6 (Global)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 5.0,
                                 output: 25.0,
                                 cache_read: 0.5,
                                 cache_write: 6.25
                               },
                               context_window: 200_000,
                               max_tokens: 128_000
                             },
                             "global.anthropic.claude-sonnet-4-20250514-v1:0" => %Model{
                               id: "global.anthropic.claude-sonnet-4-20250514-v1:0",
                               name: "Claude Sonnet 4 (Global)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "global.anthropic.claude-sonnet-4-5-20250929-v1:0" => %Model{
                               id: "global.anthropic.claude-sonnet-4-5-20250929-v1:0",
                               name: "Claude Sonnet 4.5 (Global)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "global.anthropic.claude-sonnet-4-6" => %Model{
                               id: "global.anthropic.claude-sonnet-4-6",
                               name: "Claude Sonnet 4.6 (Global)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "google.gemma-3-27b-it" => %Model{
                               id: "google.gemma-3-27b-it",
                               name: "Google Gemma 3 27B Instruct",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 0.12,
                                 output: 0.2,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 202_752,
                               max_tokens: 8_192
                             },
                             "google.gemma-3-4b-it" => %Model{
                               id: "google.gemma-3-4b-it",
                               name: "Gemma 3 4B IT",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 0.04,
                                 output: 0.08,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "minimax.minimax-m2" => %Model{
                               id: "minimax.minimax-m2",
                               name: "MiniMax M2",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.3,
                                 output: 1.2,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 204_608,
                               max_tokens: 128_000
                             },
                             "minimax.minimax-m2.1" => %Model{
                               id: "minimax.minimax-m2.1",
                               name: "MiniMax M2.1",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.3,
                                 output: 1.2,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 204_800,
                               max_tokens: 131_072
                             },
                             "moonshot.kimi-k2-thinking" => %Model{
                               id: "moonshot.kimi-k2-thinking",
                               name: "Kimi K2 Thinking",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.6,
                                 output: 2.5,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 256_000,
                               max_tokens: 256_000
                             },
                             "moonshotai.kimi-k2.5" => %Model{
                               id: "moonshotai.kimi-k2.5",
                               name: "Kimi K2.5",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 0.6,
                                 output: 3.0,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 256_000,
                               max_tokens: 256_000
                             },
                             "nvidia.nemotron-nano-12b-v2" => %Model{
                               id: "nvidia.nemotron-nano-12b-v2",
                               name: "NVIDIA Nemotron Nano 12B v2 VL BF16",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 0.2,
                                 output: 0.6,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "nvidia.nemotron-nano-9b-v2" => %Model{
                               id: "nvidia.nemotron-nano-9b-v2",
                               name: "NVIDIA Nemotron Nano 9B v2",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.06,
                                 output: 0.23,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "openai.gpt-oss-120b-1:0" => %Model{
                               id: "openai.gpt-oss-120b-1:0",
                               name: "gpt-oss-120b",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.15,
                                 output: 0.6,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "openai.gpt-oss-20b-1:0" => %Model{
                               id: "openai.gpt-oss-20b-1:0",
                               name: "gpt-oss-20b",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.07,
                                 output: 0.3,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "openai.gpt-oss-safeguard-120b" => %Model{
                               id: "openai.gpt-oss-safeguard-120b",
                               name: "GPT OSS Safeguard 120B",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.15,
                                 output: 0.6,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "openai.gpt-oss-safeguard-20b" => %Model{
                               id: "openai.gpt-oss-safeguard-20b",
                               name: "GPT OSS Safeguard 20B",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.07,
                                 output: 0.2,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 128_000,
                               max_tokens: 4_096
                             },
                             "qwen.qwen3-235b-a22b-2507-v1:0" => %Model{
                               id: "qwen.qwen3-235b-a22b-2507-v1:0",
                               name: "Qwen3 235B A22B 2507",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.22,
                                 output: 0.88,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 262_144,
                               max_tokens: 131_072
                             },
                             "qwen.qwen3-32b-v1:0" => %Model{
                               id: "qwen.qwen3-32b-v1:0",
                               name: "Qwen3 32B (dense)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.15,
                                 output: 0.6,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 16_384,
                               max_tokens: 16_384
                             },
                             "qwen.qwen3-coder-30b-a3b-v1:0" => %Model{
                               id: "qwen.qwen3-coder-30b-a3b-v1:0",
                               name: "Qwen3 Coder 30B A3B Instruct",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.15,
                                 output: 0.6,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 262_144,
                               max_tokens: 131_072
                             },
                             "qwen.qwen3-coder-480b-a35b-v1:0" => %Model{
                               id: "qwen.qwen3-coder-480b-a35b-v1:0",
                               name: "Qwen3 Coder 480B A35B Instruct",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.22,
                                 output: 1.8,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 131_072,
                               max_tokens: 65_536
                             },
                             "qwen.qwen3-next-80b-a3b" => %Model{
                               id: "qwen.qwen3-next-80b-a3b",
                               name: "Qwen/Qwen3-Next-80B-A3B-Instruct",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.14,
                                 output: 1.4,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 262_000,
                               max_tokens: 262_000
                             },
                             "qwen.qwen3-vl-235b-a22b" => %Model{
                               id: "qwen.qwen3-vl-235b-a22b",
                               name: "Qwen/Qwen3-VL-235B-A22B-Instruct",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: false,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 0.3,
                                 output: 1.5,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 262_000,
                               max_tokens: 262_000
                             },
                             "us.anthropic.claude-haiku-4-5-20251001-v1:0" => %Model{
                               id: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
                               name: "Claude Haiku 4.5 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 1.0,
                                 output: 5.0,
                                 cache_read: 0.1,
                                 cache_write: 1.25
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "us.anthropic.claude-opus-4-1-20250805-v1:0" => %Model{
                               id: "us.anthropic.claude-opus-4-1-20250805-v1:0",
                               name: "Claude Opus 4.1 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 15.0,
                                 output: 75.0,
                                 cache_read: 1.5,
                                 cache_write: 18.75
                               },
                               context_window: 200_000,
                               max_tokens: 32_000
                             },
                             "us.anthropic.claude-opus-4-20250514-v1:0" => %Model{
                               id: "us.anthropic.claude-opus-4-20250514-v1:0",
                               name: "Claude Opus 4 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 15.0,
                                 output: 75.0,
                                 cache_read: 1.5,
                                 cache_write: 18.75
                               },
                               context_window: 200_000,
                               max_tokens: 32_000
                             },
                             "us.anthropic.claude-opus-4-5-20251101-v1:0" => %Model{
                               id: "us.anthropic.claude-opus-4-5-20251101-v1:0",
                               name: "Claude Opus 4.5 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 5.0,
                                 output: 25.0,
                                 cache_read: 0.5,
                                 cache_write: 6.25
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "us.anthropic.claude-opus-4-6-v1" => %Model{
                               id: "us.anthropic.claude-opus-4-6-v1",
                               name: "Claude Opus 4.6 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 5.0,
                                 output: 25.0,
                                 cache_read: 0.5,
                                 cache_write: 6.25
                               },
                               context_window: 200_000,
                               max_tokens: 128_000
                             },
                             "us.anthropic.claude-sonnet-4-20250514-v1:0" => %Model{
                               id: "us.anthropic.claude-sonnet-4-20250514-v1:0",
                               name: "Claude Sonnet 4 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "us.anthropic.claude-sonnet-4-5-20250929-v1:0" => %Model{
                               id: "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
                               name: "Claude Sonnet 4.5 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "us.anthropic.claude-sonnet-4-6" => %Model{
                               id: "us.anthropic.claude-sonnet-4-6",
                               name: "Claude Sonnet 4.6 (US)",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text, :image],
                               cost: %ModelCost{
                                 input: 3.0,
                                 output: 15.0,
                                 cache_read: 0.3,
                                 cache_write: 3.75
                               },
                               context_window: 200_000,
                               max_tokens: 64_000
                             },
                             "writer.palmyra-x4-v1:0" => %Model{
                               id: "writer.palmyra-x4-v1:0",
                               name: "Palmyra X4",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 2.5,
                                 output: 10.0,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 122_880,
                               max_tokens: 8_192
                             },
                             "writer.palmyra-x5-v1:0" => %Model{
                               id: "writer.palmyra-x5-v1:0",
                               name: "Palmyra X5",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.6,
                                 output: 6.0,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 1_040_000,
                               max_tokens: 8_192
                             },
                             "zai.glm-4.7" => %Model{
                               id: "zai.glm-4.7",
                               name: "GLM-4.7",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.6,
                                 output: 2.2,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 204_800,
                               max_tokens: 131_072
                             },
                             "zai.glm-4.7-flash" => %Model{
                               id: "zai.glm-4.7-flash",
                               name: "GLM-4.7-Flash",
                               api: :bedrock_converse_stream,
                               provider: :amazon_bedrock,
                               base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
                               reasoning: true,
                               input: [:text],
                               cost: %ModelCost{
                                 input: 0.07,
                                 output: 0.4,
                                 cache_read: 0.0,
                                 cache_write: 0.0
                               },
                               context_window: 200_000,
                               max_tokens: 131_072
                             }
                           }
                         )

  @anthropic_models Map.merge(
                      @anthropic_models,
                      %{
                        "claude-opus-4-6" => %Model{
                          id: "claude-opus-4-6",
                          name: "Claude Opus 4.6",
                          api: :anthropic_messages,
                          provider: :anthropic,
                          base_url: "https://api.anthropic.com",
                          reasoning: true,
                          input: [:text, :image],
                          cost: %ModelCost{
                            input: 5.0,
                            output: 25.0,
                            cache_read: 0.5,
                            cache_write: 6.25
                          },
                          context_window: 200_000,
                          max_tokens: 128_000
                        },
                        "claude-sonnet-4-6" => %Model{
                          id: "claude-sonnet-4-6",
                          name: "Claude Sonnet 4.6",
                          api: :anthropic_messages,
                          provider: :anthropic,
                          base_url: "https://api.anthropic.com",
                          reasoning: true,
                          input: [:text, :image],
                          cost: %ModelCost{
                            input: 3.0,
                            output: 15.0,
                            cache_read: 0.3,
                            cache_write: 3.75
                          },
                          context_window: 200_000,
                          max_tokens: 64_000
                        }
                      }
                    )

  @azure_openai_responses_models %{
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

  @cerebras_models Map.merge(
                     @cerebras_models,
                     %{
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
                   )

  @github_copilot_models %{
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

  @google_models Map.merge(
                   @google_models,
                   %{
                     "gemini-2.5-flash-lite-preview-09-2025" => %Model{
                       id: "gemini-2.5-flash-lite-preview-09-2025",
                       name: "Gemini 2.5 Flash Lite Preview 09-25",
                       api: :google_generative_ai,
                       provider: :google,
                       base_url: "https://generativelanguage.googleapis.com/v1beta",
                       reasoning: true,
                       input: [:text, :image],
                       cost: %ModelCost{
                         input: 0.1,
                         output: 0.4,
                         cache_read: 0.025,
                         cache_write: 0.0
                       },
                       context_window: 1_048_576,
                       max_tokens: 65_536
                     },
                     "gemini-2.5-flash-preview-09-2025" => %Model{
                       id: "gemini-2.5-flash-preview-09-2025",
                       name: "Gemini 2.5 Flash Preview 09-25",
                       api: :google_generative_ai,
                       provider: :google,
                       base_url: "https://generativelanguage.googleapis.com/v1beta",
                       reasoning: true,
                       input: [:text, :image],
                       cost: %ModelCost{
                         input: 0.3,
                         output: 2.5,
                         cache_read: 0.075,
                         cache_write: 0.0
                       },
                       context_window: 1_048_576,
                       max_tokens: 65_536
                     },
                     "gemini-live-2.5-flash" => %Model{
                       id: "gemini-live-2.5-flash",
                       name: "Gemini Live 2.5 Flash",
                       api: :google_generative_ai,
                       provider: :google,
                       base_url: "https://generativelanguage.googleapis.com/v1beta",
                       reasoning: true,
                       input: [:text, :image],
                       cost: %ModelCost{
                         input: 0.5,
                         output: 2.0,
                         cache_read: 0.0,
                         cache_write: 0.0
                       },
                       context_window: 128_000,
                       max_tokens: 8_000
                     },
                     "gemini-live-2.5-flash-preview-native-audio" => %Model{
                       id: "gemini-live-2.5-flash-preview-native-audio",
                       name: "Gemini Live 2.5 Flash Preview Native Audio",
                       api: :google_generative_ai,
                       provider: :google,
                       base_url: "https://generativelanguage.googleapis.com/v1beta",
                       reasoning: true,
                       input: [:text],
                       cost: %ModelCost{
                         input: 0.5,
                         output: 2.0,
                         cache_read: 0.0,
                         cache_write: 0.0
                       },
                       context_window: 131_072,
                       max_tokens: 65_536
                     }
                   }
                 )

  @google_antigravity_models Map.merge(
                               @google_antigravity_models,
                               %{
                                 "claude-opus-4-5-thinking" => %Model{
                                   id: "claude-opus-4-5-thinking",
                                   name: "Claude Opus 4.5 Thinking (Antigravity)",
                                   api: :google_gemini_cli,
                                   provider: :google_antigravity,
                                   base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
                                   reasoning: true,
                                   input: [:text, :image],
                                   cost: %ModelCost{
                                     input: 5.0,
                                     output: 25.0,
                                     cache_read: 0.5,
                                     cache_write: 6.25
                                   },
                                   context_window: 200_000,
                                   max_tokens: 64_000
                                 },
                                 "claude-opus-4-6-thinking" => %Model{
                                   id: "claude-opus-4-6-thinking",
                                   name: "Claude Opus 4.6 Thinking (Antigravity)",
                                   api: :google_gemini_cli,
                                   provider: :google_antigravity,
                                   base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
                                   reasoning: true,
                                   input: [:text, :image],
                                   cost: %ModelCost{
                                     input: 5.0,
                                     output: 25.0,
                                     cache_read: 0.5,
                                     cache_write: 6.25
                                   },
                                   context_window: 200_000,
                                   max_tokens: 128_000
                                 },
                                 "claude-sonnet-4-5" => %Model{
                                   id: "claude-sonnet-4-5",
                                   name: "Claude Sonnet 4.5 (Antigravity)",
                                   api: :google_gemini_cli,
                                   provider: :google_antigravity,
                                   base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
                                   reasoning: false,
                                   input: [:text, :image],
                                   cost: %ModelCost{
                                     input: 3.0,
                                     output: 15.0,
                                     cache_read: 0.3,
                                     cache_write: 3.75
                                   },
                                   context_window: 200_000,
                                   max_tokens: 64_000
                                 },
                                 "claude-sonnet-4-5-thinking" => %Model{
                                   id: "claude-sonnet-4-5-thinking",
                                   name: "Claude Sonnet 4.5 Thinking (Antigravity)",
                                   api: :google_gemini_cli,
                                   provider: :google_antigravity,
                                   base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
                                   reasoning: true,
                                   input: [:text, :image],
                                   cost: %ModelCost{
                                     input: 3.0,
                                     output: 15.0,
                                     cache_read: 0.3,
                                     cache_write: 3.75
                                   },
                                   context_window: 200_000,
                                   max_tokens: 64_000
                                 },
                                 "gemini-3-flash" => %Model{
                                   id: "gemini-3-flash",
                                   name: "Gemini 3 Flash (Antigravity)",
                                   api: :google_gemini_cli,
                                   provider: :google_antigravity,
                                   base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
                                   reasoning: true,
                                   input: [:text, :image],
                                   cost: %ModelCost{
                                     input: 0.5,
                                     output: 3.0,
                                     cache_read: 0.5,
                                     cache_write: 0.0
                                   },
                                   context_window: 1_048_576,
                                   max_tokens: 65_535
                                 },
                                 "gpt-oss-120b-medium" => %Model{
                                   id: "gpt-oss-120b-medium",
                                   name: "GPT-OSS 120B Medium (Antigravity)",
                                   api: :google_gemini_cli,
                                   provider: :google_antigravity,
                                   base_url: "https://daily-cloudcode-pa.sandbox.googleapis.com",
                                   reasoning: false,
                                   input: [:text],
                                   cost: %ModelCost{
                                     input: 0.09,
                                     output: 0.36,
                                     cache_read: 0.0,
                                     cache_write: 0.0
                                   },
                                   context_window: 131_072,
                                   max_tokens: 32_768
                                 }
                               }
                             )

  @google_gemini_cli_models %{
    "gemini-2.0-flash" => %Model{
      id: "gemini-2.0-flash",
      name: "Gemini 2.0 Flash (Cloud Code Assist)",
      api: :google_gemini_cli,
      provider: :google_gemini_cli,
      base_url: "https://cloudcode-pa.googleapis.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 8_192
    },
    "gemini-2.5-flash" => %Model{
      id: "gemini-2.5-flash",
      name: "Gemini 2.5 Flash (Cloud Code Assist)",
      api: :google_gemini_cli,
      provider: :google_gemini_cli,
      base_url: "https://cloudcode-pa.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "gemini-2.5-pro" => %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro (Cloud Code Assist)",
      api: :google_gemini_cli,
      provider: :google_gemini_cli,
      base_url: "https://cloudcode-pa.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "gemini-3-flash-preview" => %Model{
      id: "gemini-3-flash-preview",
      name: "Gemini 3 Flash Preview (Cloud Code Assist)",
      api: :google_gemini_cli,
      provider: :google_gemini_cli,
      base_url: "https://cloudcode-pa.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "gemini-3-pro-preview" => %Model{
      id: "gemini-3-pro-preview",
      name: "Gemini 3 Pro Preview (Cloud Code Assist)",
      api: :google_gemini_cli,
      provider: :google_gemini_cli,
      base_url: "https://cloudcode-pa.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_535
    }
  }

  @google_vertex_models %{
    "gemini-1.5-flash" => %Model{
      id: "gemini-1.5-flash",
      name: "Gemini 1.5 Flash (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.01875, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8_192
    },
    "gemini-1.5-flash-8b" => %Model{
      id: "gemini-1.5-flash-8b",
      name: "Gemini 1.5 Flash-8B (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0375, output: 0.15, cache_read: 0.01, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8_192
    },
    "gemini-1.5-pro" => %Model{
      id: "gemini-1.5-pro",
      name: "Gemini 1.5 Pro (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8_192
    },
    "gemini-2.0-flash" => %Model{
      id: "gemini-2.0-flash",
      name: "Gemini 2.0 Flash (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0375, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 8_192
    },
    "gemini-2.0-flash-lite" => %Model{
      id: "gemini-2.0-flash-lite",
      name: "Gemini 2.0 Flash Lite (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.01875, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-flash" => %Model{
      id: "gemini-2.5-flash",
      name: "Gemini 2.5 Flash (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.3, output: 2.5, cache_read: 0.03, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-flash-lite" => %Model{
      id: "gemini-2.5-flash-lite",
      name: "Gemini 2.5 Flash Lite (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.01, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-flash-lite-preview-09-2025" => %Model{
      id: "gemini-2.5-flash-lite-preview-09-2025",
      name: "Gemini 2.5 Flash Lite Preview 09-25 (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.1, output: 0.4, cache_read: 0.01, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-2.5-pro" => %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-3-flash-preview" => %Model{
      id: "gemini-3-flash-preview",
      name: "Gemini 3 Flash Preview (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.5, output: 3.0, cache_read: 0.05, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "gemini-3-pro-preview" => %Model{
      id: "gemini-3-pro-preview",
      name: "Gemini 3 Pro Preview (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "gemini-3.1-pro-preview" => %Model{
      id: "gemini-3.1-pro-preview",
      name: "Gemini 3.1 Pro Preview (Vertex)",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://{location}-aiplatform.googleapis.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 12.0, cache_read: 0.2, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    }
  }

  @groq_models %{
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

  @huggingface_models %{
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

  @kimi_models Map.merge(
                 @kimi_models,
                 %{
                   "k2p5" => %Model{
                     id: "k2p5",
                     name: "Kimi K2.5",
                     api: :anthropic_messages,
                     provider: :kimi,
                     base_url: "https://api.kimi.com/coding",
                     reasoning: true,
                     input: [:text, :image],
                     cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
                     context_window: 262_144,
                     max_tokens: 32_768
                   },
                   "kimi-k2-thinking" => %Model{
                     id: "kimi-k2-thinking",
                     name: "Kimi K2 Thinking",
                     api: :anthropic_messages,
                     provider: :kimi,
                     base_url: "https://api.kimi.com/coding",
                     reasoning: true,
                     input: [:text],
                     cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
                     context_window: 262_144,
                     max_tokens: 32_768
                   }
                 }
               )

  @minimax_models Map.merge(
                    @minimax_models,
                    %{
                      "MiniMax-M2" => %Model{
                        id: "MiniMax-M2",
                        name: "MiniMax-M2",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.3,
                          output: 1.2,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 196_608,
                        max_tokens: 128_000
                      },
                      "MiniMax-M2.1" => %Model{
                        id: "MiniMax-M2.1",
                        name: "MiniMax-M2.1",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.3,
                          output: 1.2,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 204_800,
                        max_tokens: 131_072
                      },
                      "MiniMax-M2.5" => %Model{
                        id: "MiniMax-M2.5",
                        name: "MiniMax-M2.5",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.3,
                          output: 1.2,
                          cache_read: 0.03,
                          cache_write: 0.375
                        },
                        context_window: 204_800,
                        max_tokens: 131_072
                      },
                      "MiniMax-M2.5-highspeed" => %Model{
                        id: "MiniMax-M2.5-highspeed",
                        name: "MiniMax-M2.5-highspeed",
                        api: :anthropic_messages,
                        provider: :minimax,
                        base_url: "https://api.minimax.io/anthropic",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.6,
                          output: 2.4,
                          cache_read: 0.06,
                          cache_write: 0.375
                        },
                        context_window: 204_800,
                        max_tokens: 131_072
                      }
                    }
                  )

  @minimax_cn_models %{
    "MiniMax-M2" => %Model{
      id: "MiniMax-M2",
      name: "MiniMax-M2",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 196_608,
      max_tokens: 128_000
    },
    "MiniMax-M2.1" => %Model{
      id: "MiniMax-M2.1",
      name: "MiniMax-M2.1",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "MiniMax-M2.5" => %Model{
      id: "MiniMax-M2.5",
      name: "MiniMax-M2.5",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.03, cache_write: 0.375},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "MiniMax-M2.5-highspeed" => %Model{
      id: "MiniMax-M2.5-highspeed",
      name: "MiniMax-M2.5-highspeed",
      api: :anthropic_messages,
      provider: :minimax_cn,
      base_url: "https://api.minimaxi.com/anthropic",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.4, cache_read: 0.06, cache_write: 0.375},
      context_window: 204_800,
      max_tokens: 131_072
    }
  }

  @mistral_models Map.merge(
                    @mistral_models,
                    %{
                      "devstral-2512" => %Model{
                        id: "devstral-2512",
                        name: "Devstral 2",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.4,
                          output: 2.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 262_144,
                        max_tokens: 262_144
                      },
                      "devstral-medium-2507" => %Model{
                        id: "devstral-medium-2507",
                        name: "Devstral Medium",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.4,
                          output: 2.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      },
                      "devstral-medium-latest" => %Model{
                        id: "devstral-medium-latest",
                        name: "Devstral 2",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.4,
                          output: 2.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 262_144,
                        max_tokens: 262_144
                      },
                      "devstral-small-2505" => %Model{
                        id: "devstral-small-2505",
                        name: "Devstral Small 2505",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.1,
                          output: 0.3,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      },
                      "devstral-small-2507" => %Model{
                        id: "devstral-small-2507",
                        name: "Devstral Small",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.1,
                          output: 0.3,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      },
                      "labs-devstral-small-2512" => %Model{
                        id: "labs-devstral-small-2512",
                        name: "Devstral Small 2",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text, :image],
                        cost: %ModelCost{
                          input: 0.0,
                          output: 0.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 256_000,
                        max_tokens: 256_000
                      },
                      "magistral-medium-latest" => %Model{
                        id: "magistral-medium-latest",
                        name: "Magistral Medium",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 2.0,
                          output: 5.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 16_384
                      },
                      "magistral-small" => %Model{
                        id: "magistral-small",
                        name: "Magistral Small",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: true,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.5,
                          output: 1.5,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      },
                      "ministral-3b-latest" => %Model{
                        id: "ministral-3b-latest",
                        name: "Ministral 3B",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.04,
                          output: 0.04,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      },
                      "ministral-8b-latest" => %Model{
                        id: "ministral-8b-latest",
                        name: "Ministral 8B",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.1,
                          output: 0.1,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      },
                      "mistral-large-2411" => %Model{
                        id: "mistral-large-2411",
                        name: "Mistral Large 2.1",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 2.0,
                          output: 6.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 131_072,
                        max_tokens: 16_384
                      },
                      "mistral-large-2512" => %Model{
                        id: "mistral-large-2512",
                        name: "Mistral Large 3",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text, :image],
                        cost: %ModelCost{
                          input: 0.5,
                          output: 1.5,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 262_144,
                        max_tokens: 262_144
                      },
                      "mistral-medium-2505" => %Model{
                        id: "mistral-medium-2505",
                        name: "Mistral Medium 3",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text, :image],
                        cost: %ModelCost{
                          input: 0.4,
                          output: 2.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 131_072,
                        max_tokens: 131_072
                      },
                      "mistral-medium-2508" => %Model{
                        id: "mistral-medium-2508",
                        name: "Mistral Medium 3.1",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text, :image],
                        cost: %ModelCost{
                          input: 0.4,
                          output: 2.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 262_144,
                        max_tokens: 262_144
                      },
                      "mistral-nemo" => %Model{
                        id: "mistral-nemo",
                        name: "Mistral Nemo",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.15,
                          output: 0.15,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      },
                      "mistral-small-2506" => %Model{
                        id: "mistral-small-2506",
                        name: "Mistral Small 3.2",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text, :image],
                        cost: %ModelCost{
                          input: 0.1,
                          output: 0.3,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 16_384
                      },
                      "open-mistral-7b" => %Model{
                        id: "open-mistral-7b",
                        name: "Mistral 7B",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.25,
                          output: 0.25,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 8_000,
                        max_tokens: 8_000
                      },
                      "open-mixtral-8x22b" => %Model{
                        id: "open-mixtral-8x22b",
                        name: "Mixtral 8x22B",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 2.0,
                          output: 6.0,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 64_000,
                        max_tokens: 64_000
                      },
                      "open-mixtral-8x7b" => %Model{
                        id: "open-mixtral-8x7b",
                        name: "Mixtral 8x7B",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text],
                        cost: %ModelCost{
                          input: 0.7,
                          output: 0.7,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 32_000,
                        max_tokens: 32_000
                      },
                      "pixtral-12b" => %Model{
                        id: "pixtral-12b",
                        name: "Pixtral 12B",
                        api: :openai_completions,
                        provider: :mistral,
                        base_url: "https://api.mistral.ai/v1",
                        reasoning: false,
                        input: [:text, :image],
                        cost: %ModelCost{
                          input: 0.15,
                          output: 0.15,
                          cache_read: 0.0,
                          cache_write: 0.0
                        },
                        context_window: 128_000,
                        max_tokens: 128_000
                      }
                    }
                  )

  @openrouter_models %{
    "ai21/jamba-large-1.7" => %Model{
      id: "ai21/jamba-large-1.7",
      name: "AI21: Jamba Large 1.7",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 4_096
    },
    "alibaba/tongyi-deepresearch-30b-a3b" => %Model{
      id: "alibaba/tongyi-deepresearch-30b-a3b",
      name: "Tongyi DeepResearch 30B A3B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.09,
        output: 0.44999999999999996,
        cache_read: 0.09,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 131_072
    },
    "allenai/olmo-3.1-32b-instruct" => %Model{
      id: "allenai/olmo-3.1-32b-instruct",
      name: "AllenAI: Olmo 3.1 32B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.6,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 65_536,
      max_tokens: 4_096
    },
    "amazon/nova-2-lite-v1" => %Model{
      id: "amazon/nova-2-lite-v1",
      name: "Amazon: Nova 2 Lite",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.3, output: 2.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 65_535
    },
    "amazon/nova-lite-v1" => %Model{
      id: "amazon/nova-lite-v1",
      name: "Amazon: Nova Lite 1.0",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.06, output: 0.24, cache_read: 0.0, cache_write: 0.0},
      context_window: 300_000,
      max_tokens: 5_120
    },
    "amazon/nova-micro-v1" => %Model{
      id: "amazon/nova-micro-v1",
      name: "Amazon: Nova Micro 1.0",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.035, output: 0.14, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 5_120
    },
    "amazon/nova-premier-v1" => %Model{
      id: "amazon/nova-premier-v1",
      name: "Amazon: Nova Premier 1.0",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 12.5, cache_read: 0.625, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 32_000
    },
    "amazon/nova-pro-v1" => %Model{
      id: "amazon/nova-pro-v1",
      name: "Amazon: Nova Pro 1.0",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.7999999999999999,
        output: 3.1999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 300_000,
      max_tokens: 5_120
    },
    "anthropic/claude-3-haiku" => %Model{
      id: "anthropic/claude-3-haiku",
      name: "Anthropic: Claude 3 Haiku",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 1.25, cache_read: 0.03, cache_write: 0.3},
      context_window: 200_000,
      max_tokens: 4_096
    },
    "anthropic/claude-3.5-haiku" => %Model{
      id: "anthropic/claude-3.5-haiku",
      name: "Anthropic: Claude 3.5 Haiku",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.7999999999999999,
        output: 4.0,
        cache_read: 0.08,
        cache_write: 1.0
      },
      context_window: 200_000,
      max_tokens: 8_192
    },
    "anthropic/claude-3.5-sonnet" => %Model{
      id: "anthropic/claude-3.5-sonnet",
      name: "Anthropic: Claude 3.5 Sonnet",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 6.0, output: 30.0, cache_read: 0.6, cache_write: 7.5},
      context_window: 200_000,
      max_tokens: 8_192
    },
    "anthropic/claude-3.7-sonnet" => %Model{
      id: "anthropic/claude-3.7-sonnet",
      name: "Anthropic: Claude 3.7 Sonnet",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic/claude-3.7-sonnet:thinking" => %Model{
      id: "anthropic/claude-3.7-sonnet:thinking",
      name: "Anthropic: Claude 3.7 Sonnet (thinking)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic/claude-haiku-4.5" => %Model{
      id: "anthropic/claude-haiku-4.5",
      name: "Anthropic: Claude Haiku 4.5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 1.0,
        output: 5.0,
        cache_read: 0.09999999999999999,
        cache_write: 1.25
      },
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic/claude-opus-4" => %Model{
      id: "anthropic/claude-opus-4",
      name: "Anthropic: Claude Opus 4",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "anthropic/claude-opus-4.1" => %Model{
      id: "anthropic/claude-opus-4.1",
      name: "Anthropic: Claude Opus 4.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "anthropic/claude-opus-4.5" => %Model{
      id: "anthropic/claude-opus-4.5",
      name: "Anthropic: Claude Opus 4.5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic/claude-opus-4.6" => %Model{
      id: "anthropic/claude-opus-4.6",
      name: "Anthropic: Claude Opus 4.6",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 1_000_000,
      max_tokens: 128_000
    },
    "anthropic/claude-sonnet-4" => %Model{
      id: "anthropic/claude-sonnet-4",
      name: "Anthropic: Claude Sonnet 4",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "anthropic/claude-sonnet-4.5" => %Model{
      id: "anthropic/claude-sonnet-4.5",
      name: "Anthropic: Claude Sonnet 4.5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "anthropic/claude-sonnet-4.6" => %Model{
      id: "anthropic/claude-sonnet-4.6",
      name: "Anthropic: Claude Sonnet 4.6",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 128_000
    },
    "arcee-ai/trinity-large-preview:free" => %Model{
      id: "arcee-ai/trinity-large-preview:free",
      name: "Arcee AI: Trinity Large Preview (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_000,
      max_tokens: 4_096
    },
    "arcee-ai/trinity-mini" => %Model{
      id: "arcee-ai/trinity-mini",
      name: "Arcee AI: Trinity Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.045, output: 0.15, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "arcee-ai/trinity-mini:free" => %Model{
      id: "arcee-ai/trinity-mini:free",
      name: "Arcee AI: Trinity Mini (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "arcee-ai/virtuoso-large" => %Model{
      id: "arcee-ai/virtuoso-large",
      name: "Arcee AI: Virtuoso Large",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.75, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 64_000
    },
    "auto" => %Model{
      id: "auto",
      name: "Auto",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 2_000_000,
      max_tokens: 30_000
    },
    "baidu/ernie-4.5-21b-a3b" => %Model{
      id: "baidu/ernie-4.5-21b-a3b",
      name: "Baidu: ERNIE 4.5 21B A3B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.07, output: 0.28, cache_read: 0.0, cache_write: 0.0},
      context_window: 120_000,
      max_tokens: 8_000
    },
    "baidu/ernie-4.5-vl-28b-a3b" => %Model{
      id: "baidu/ernie-4.5-vl-28b-a3b",
      name: "Baidu: ERNIE 4.5 VL 28B A3B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.14, output: 0.56, cache_read: 0.0, cache_write: 0.0},
      context_window: 30_000,
      max_tokens: 8_000
    },
    "bytedance-seed/seed-1.6" => %Model{
      id: "bytedance-seed/seed-1.6",
      name: "ByteDance Seed: Seed 1.6",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
    "bytedance-seed/seed-1.6-flash" => %Model{
      id: "bytedance-seed/seed-1.6-flash",
      name: "ByteDance Seed: Seed 1.6 Flash",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
    "cohere/command-r-08-2024" => %Model{
      id: "cohere/command-r-08-2024",
      name: "Cohere: Command R (08-2024)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_000
    },
    "cohere/command-r-plus-08-2024" => %Model{
      id: "cohere/command-r-plus-08-2024",
      name: "Cohere: Command R+ (08-2024)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_000
    },
    "deepseek/deepseek-chat" => %Model{
      id: "deepseek/deepseek-chat",
      name: "DeepSeek: DeepSeek V3",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.32,
        output: 0.8899999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 163_840,
      max_tokens: 163_840
    },
    "deepseek/deepseek-chat-v3-0324" => %Model{
      id: "deepseek/deepseek-chat-v3-0324",
      name: "DeepSeek: DeepSeek V3 0324",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.19, output: 0.87, cache_read: 0.095, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 65_536
    },
    "deepseek/deepseek-chat-v3.1" => %Model{
      id: "deepseek/deepseek-chat-v3.1",
      name: "DeepSeek: DeepSeek V3.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.75, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 7_168
    },
    "deepseek/deepseek-r1" => %Model{
      id: "deepseek/deepseek-r1",
      name: "DeepSeek: R1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.7, output: 2.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 64_000,
      max_tokens: 16_000
    },
    "deepseek/deepseek-r1-0528" => %Model{
      id: "deepseek/deepseek-r1-0528",
      name: "DeepSeek: R1 0528",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 1.75,
        cache_read: 0.19999999999999998,
        cache_write: 0.0
      },
      context_window: 163_840,
      max_tokens: 65_536
    },
    "deepseek/deepseek-v3.1-terminus" => %Model{
      id: "deepseek/deepseek-v3.1-terminus",
      name: "DeepSeek: DeepSeek V3.1 Terminus",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.21,
        output: 0.7899999999999999,
        cache_read: 0.1300000002,
        cache_write: 0.0
      },
      context_window: 163_840,
      max_tokens: 4_096
    },
    "deepseek/deepseek-v3.1-terminus:exacto" => %Model{
      id: "deepseek/deepseek-v3.1-terminus:exacto",
      name: "DeepSeek: DeepSeek V3.1 Terminus (exacto)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.21,
        output: 0.7899999999999999,
        cache_read: 0.16799999999999998,
        cache_write: 0.0
      },
      context_window: 163_840,
      max_tokens: 4_096
    },
    "deepseek/deepseek-v3.2" => %Model{
      id: "deepseek/deepseek-v3.2",
      name: "DeepSeek: DeepSeek V3.2",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.26, output: 0.38, cache_read: 0.13, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 4_096
    },
    "deepseek/deepseek-v3.2-exp" => %Model{
      id: "deepseek/deepseek-v3.2-exp",
      name: "DeepSeek: DeepSeek V3.2 Exp",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.27, output: 0.41, cache_read: 0.0, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 65_536
    },
    "google/gemini-2.0-flash-001" => %Model{
      id: "google/gemini-2.0-flash-001",
      name: "Google: Gemini 2.0 Flash",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.024999999999999998,
        cache_write: 0.08333333333333334
      },
      context_window: 1_048_576,
      max_tokens: 8_192
    },
    "google/gemini-2.0-flash-lite-001" => %Model{
      id: "google/gemini-2.0-flash-lite-001",
      name: "Google: Gemini 2.0 Flash Lite",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 8_192
    },
    "google/gemini-2.5-flash" => %Model{
      id: "google/gemini-2.5-flash",
      name: "Google: Gemini 2.5 Flash",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.3,
        output: 2.5,
        cache_read: 0.03,
        cache_write: 0.08333333333333334
      },
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "google/gemini-2.5-flash-lite" => %Model{
      id: "google/gemini-2.5-flash-lite",
      name: "Google: Gemini 2.5 Flash Lite",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.01,
        cache_write: 0.08333333333333334
      },
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "google/gemini-2.5-flash-lite-preview-09-2025" => %Model{
      id: "google/gemini-2.5-flash-lite-preview-09-2025",
      name: "Google: Gemini 2.5 Flash Lite Preview 09-2025",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.01,
        cache_write: 0.08333333333333334
      },
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "google/gemini-2.5-pro" => %Model{
      id: "google/gemini-2.5-pro",
      name: "Google: Gemini 2.5 Pro",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.375},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "google/gemini-2.5-pro-preview" => %Model{
      id: "google/gemini-2.5-pro-preview",
      name: "Google: Gemini 2.5 Pro Preview 06-05",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.375},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "google/gemini-2.5-pro-preview-05-06" => %Model{
      id: "google/gemini-2.5-pro-preview-05-06",
      name: "Google: Gemini 2.5 Pro Preview 05-06",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.375},
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "google/gemini-3-flash-preview" => %Model{
      id: "google/gemini-3-flash-preview",
      name: "Google: Gemini 3 Flash Preview",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.5,
        output: 3.0,
        cache_read: 0.049999999999999996,
        cache_write: 0.08333333333333334
      },
      context_window: 1_048_576,
      max_tokens: 65_535
    },
    "google/gemini-3-pro-preview" => %Model{
      id: "google/gemini-3-pro-preview",
      name: "Google: Gemini 3 Pro Preview",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 2.0,
        output: 12.0,
        cache_read: 0.19999999999999998,
        cache_write: 0.375
      },
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "google/gemini-3.1-pro-preview" => %Model{
      id: "google/gemini-3.1-pro-preview",
      name: "Google: Gemini 3.1 Pro Preview",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 2.0,
        output: 12.0,
        cache_read: 0.19999999999999998,
        cache_write: 0.375
      },
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "google/gemma-3-27b-it" => %Model{
      id: "google/gemma-3-27b-it",
      name: "Google: Gemma 3 27B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.04, output: 0.15, cache_read: 0.02, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 65_536
    },
    "google/gemma-3-27b-it:free" => %Model{
      id: "google/gemma-3-27b-it:free",
      name: "Google: Gemma 3 27B (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8_192
    },
    "inception/mercury" => %Model{
      id: "inception/mercury",
      name: "Inception: Mercury",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.25, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "inception/mercury-coder" => %Model{
      id: "inception/mercury-coder",
      name: "Inception: Mercury Coder",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.25, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "kwaipilot/kat-coder-pro" => %Model{
      id: "kwaipilot/kat-coder-pro",
      name: "Kwaipilot: KAT-Coder-Pro V1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.207, output: 0.828, cache_read: 0.0414, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 128_000
    },
    "meta-llama/llama-3-8b-instruct" => %Model{
      id: "meta-llama/llama-3-8b-instruct",
      name: "Meta: Llama 3 8B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.03, output: 0.04, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_192,
      max_tokens: 16_384
    },
    "meta-llama/llama-3.1-405b-instruct" => %Model{
      id: "meta-llama/llama-3.1-405b-instruct",
      name: "Meta: Llama 3.1 405B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 4.0, output: 4.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_000,
      max_tokens: 4_096
    },
    "meta-llama/llama-3.1-70b-instruct" => %Model{
      id: "meta-llama/llama-3.1-70b-instruct",
      name: "Meta: Llama 3.1 70B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 0.39999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "meta-llama/llama-3.1-8b-instruct" => %Model{
      id: "meta-llama/llama-3.1-8b-instruct",
      name: "Meta: Llama 3.1 8B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.02,
        output: 0.049999999999999996,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 16_384,
      max_tokens: 16_384
    },
    "meta-llama/llama-3.3-70b-instruct" => %Model{
      id: "meta-llama/llama-3.3-70b-instruct",
      name: "Meta: Llama 3.3 70B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.32,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 16_384
    },
    "meta-llama/llama-3.3-70b-instruct:free" => %Model{
      id: "meta-llama/llama-3.3-70b-instruct:free",
      name: "Meta: Llama 3.3 70B Instruct (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 128_000
    },
    "meta-llama/llama-4-maverick" => %Model{
      id: "meta-llama/llama-4-maverick",
      name: "Meta: Llama 4 Maverick",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 16_384
    },
    "meta-llama/llama-4-scout" => %Model{
      id: "meta-llama/llama-4-scout",
      name: "Meta: Llama 4 Scout",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.08, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 327_680,
      max_tokens: 16_384
    },
    "minimax/minimax-m1" => %Model{
      id: "minimax/minimax-m1",
      name: "MiniMax: MiniMax M1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.2,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 40_000
    },
    "minimax/minimax-m2" => %Model{
      id: "minimax/minimax-m2",
      name: "MiniMax: MiniMax M2",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.255, output: 1.0, cache_read: 0.03, cache_write: 0.0},
      context_window: 196_608,
      max_tokens: 65_536
    },
    "minimax/minimax-m2.1" => %Model{
      id: "minimax/minimax-m2.1",
      name: "MiniMax: MiniMax M2.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.27, output: 0.95, cache_read: 0.0299999997, cache_write: 0.0},
      context_window: 196_608,
      max_tokens: 4_096
    },
    "minimax/minimax-m2.5" => %Model{
      id: "minimax/minimax-m2.5",
      name: "MiniMax: MiniMax M2.5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.1, cache_read: 0.15, cache_write: 0.0},
      context_window: 196_608,
      max_tokens: 65_536
    },
    "mistralai/codestral-2508" => %Model{
      id: "mistralai/codestral-2508",
      name: "Mistral: Codestral 2508",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.3,
        output: 0.8999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 256_000,
      max_tokens: 4_096
    },
    "mistralai/devstral-2512" => %Model{
      id: "mistralai/devstral-2512",
      name: "Mistral: Devstral 2 2512",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 4_096
    },
    "mistralai/devstral-medium" => %Model{
      id: "mistralai/devstral-medium",
      name: "Mistral: Devstral Medium",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/devstral-small" => %Model{
      id: "mistralai/devstral-small",
      name: "Mistral: Devstral Small 1.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.3,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/ministral-14b-2512" => %Model{
      id: "mistralai/ministral-14b-2512",
      name: "Mistral: Ministral 3 14B 2512",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.19999999999999998,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 4_096
    },
    "mistralai/ministral-3b-2512" => %Model{
      id: "mistralai/ministral-3b-2512",
      name: "Mistral: Ministral 3 3B 2512",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.09999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/ministral-8b-2512" => %Model{
      id: "mistralai/ministral-8b-2512",
      name: "Mistral: Ministral 3 8B 2512",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.15, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 4_096
    },
    "mistralai/mistral-large" => %Model{
      id: "mistralai/mistral-large",
      name: "Mistral Large",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "mistralai/mistral-large-2407" => %Model{
      id: "mistralai/mistral-large-2407",
      name: "Mistral Large 2407",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/mistral-large-2411" => %Model{
      id: "mistralai/mistral-large-2411",
      name: "Mistral Large 2411",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/mistral-large-2512" => %Model{
      id: "mistralai/mistral-large-2512",
      name: "Mistral: Mistral Large 3 2512",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.5, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 4_096
    },
    "mistralai/mistral-medium-3" => %Model{
      id: "mistralai/mistral-medium-3",
      name: "Mistral: Mistral Medium 3",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/mistral-medium-3.1" => %Model{
      id: "mistralai/mistral-medium-3.1",
      name: "Mistral: Mistral Medium 3.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/mistral-nemo" => %Model{
      id: "mistralai/mistral-nemo",
      name: "Mistral: Mistral Nemo",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.02, output: 0.04, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 16_384
    },
    "mistralai/mistral-saba" => %Model{
      id: "mistralai/mistral-saba",
      name: "Mistral: Saba",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.6,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 4_096
    },
    "mistralai/mistral-small-24b-instruct-2501" => %Model{
      id: "mistralai/mistral-small-24b-instruct-2501",
      name: "Mistral: Mistral Small 3",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.049999999999999996,
        output: 0.08,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 16_384
    },
    "mistralai/mistral-small-3.1-24b-instruct:free" => %Model{
      id: "mistralai/mistral-small-3.1-24b-instruct:free",
      name: "Mistral: Mistral Small 3.1 24B (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "mistralai/mistral-small-3.2-24b-instruct" => %Model{
      id: "mistralai/mistral-small-3.2-24b-instruct",
      name: "Mistral: Mistral Small 3.2 24B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.06, output: 0.18, cache_read: 0.03, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "mistralai/mistral-small-creative" => %Model{
      id: "mistralai/mistral-small-creative",
      name: "Mistral: Mistral Small Creative",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.3,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 4_096
    },
    "mistralai/mixtral-8x22b-instruct" => %Model{
      id: "mistralai/mixtral-8x22b-instruct",
      name: "Mistral: Mixtral 8x22B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 65_536,
      max_tokens: 4_096
    },
    "mistralai/mixtral-8x7b-instruct" => %Model{
      id: "mistralai/mixtral-8x7b-instruct",
      name: "Mistral: Mixtral 8x7B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.54, output: 0.54, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 16_384
    },
    "mistralai/pixtral-large-2411" => %Model{
      id: "mistralai/pixtral-large-2411",
      name: "Mistral: Pixtral Large 2411",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "mistralai/voxtral-small-24b-2507" => %Model{
      id: "mistralai/voxtral-small-24b-2507",
      name: "Mistral: Voxtral Small 24B 2507",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.3,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_000,
      max_tokens: 4_096
    },
    "moonshotai/kimi-k2" => %Model{
      id: "moonshotai/kimi-k2",
      name: "MoonshotAI: Kimi K2 0711",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 2.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "moonshotai/kimi-k2-0905" => %Model{
      id: "moonshotai/kimi-k2-0905",
      name: "MoonshotAI: Kimi K2 0905",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.0,
        cache_read: 0.15,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "moonshotai/kimi-k2-0905:exacto" => %Model{
      id: "moonshotai/kimi-k2-0905:exacto",
      name: "MoonshotAI: Kimi K2 0905 (exacto)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 4_096
    },
    "moonshotai/kimi-k2-thinking" => %Model{
      id: "moonshotai/kimi-k2-thinking",
      name: "MoonshotAI: Kimi K2 Thinking",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.47,
        output: 2.0,
        cache_read: 0.14100000000000001,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "moonshotai/kimi-k2.5" => %Model{
      id: "moonshotai/kimi-k2.5",
      name: "MoonshotAI: Kimi K2.5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.22999999999999998,
        output: 3.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 262_144
    },
    "nex-agi/deepseek-v3.1-nex-n1" => %Model{
      id: "nex-agi/deepseek-v3.1-nex-n1",
      name: "Nex AGI: DeepSeek V3.1 Nex N1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.27, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 163_840
    },
    "nvidia/llama-3.1-nemotron-70b-instruct" => %Model{
      id: "nvidia/llama-3.1-nemotron-70b-instruct",
      name: "NVIDIA: Llama 3.1 Nemotron 70B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.2, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 16_384
    },
    "nvidia/llama-3.3-nemotron-super-49b-v1.5" => %Model{
      id: "nvidia/llama-3.3-nemotron-super-49b-v1.5",
      name: "NVIDIA: Llama 3.3 Nemotron Super 49B V1.5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 4_096
    },
    "nvidia/nemotron-3-nano-30b-a3b" => %Model{
      id: "nvidia/nemotron-3-nano-30b-a3b",
      name: "NVIDIA: Nemotron 3 Nano 30B A3B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.049999999999999996,
        output: 0.19999999999999998,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 4_096
    },
    "nvidia/nemotron-3-nano-30b-a3b:free" => %Model{
      id: "nvidia/nemotron-3-nano-30b-a3b:free",
      name: "NVIDIA: Nemotron 3 Nano 30B A3B (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 4_096
    },
    "nvidia/nemotron-nano-12b-v2-vl:free" => %Model{
      id: "nvidia/nemotron-nano-12b-v2-vl:free",
      name: "NVIDIA: Nemotron Nano 12B 2 VL (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 128_000
    },
    "nvidia/nemotron-nano-9b-v2" => %Model{
      id: "nvidia/nemotron-nano-9b-v2",
      name: "NVIDIA: Nemotron Nano 9B V2",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.04, output: 0.16, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "nvidia/nemotron-nano-9b-v2:free" => %Model{
      id: "nvidia/nemotron-nano-9b-v2:free",
      name: "NVIDIA: Nemotron Nano 9B V2 (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "openai/gpt-3.5-turbo" => %Model{
      id: "openai/gpt-3.5-turbo",
      name: "OpenAI: GPT-3.5 Turbo",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 16_385,
      max_tokens: 4_096
    },
    "openai/gpt-3.5-turbo-0613" => %Model{
      id: "openai/gpt-3.5-turbo-0613",
      name: "OpenAI: GPT-3.5 Turbo (older v0613)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 4_095,
      max_tokens: 4_096
    },
    "openai/gpt-3.5-turbo-16k" => %Model{
      id: "openai/gpt-3.5-turbo-16k",
      name: "OpenAI: GPT-3.5 Turbo 16k",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 4.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 16_385,
      max_tokens: 4_096
    },
    "openai/gpt-4" => %Model{
      id: "openai/gpt-4",
      name: "OpenAI: GPT-4",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 30.0, output: 60.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_191,
      max_tokens: 4_096
    },
    "openai/gpt-4-0314" => %Model{
      id: "openai/gpt-4-0314",
      name: "OpenAI: GPT-4 (older v0314)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 30.0, output: 60.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_191,
      max_tokens: 4_096
    },
    "openai/gpt-4-1106-preview" => %Model{
      id: "openai/gpt-4-1106-preview",
      name: "OpenAI: GPT-4 Turbo (older v1106)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 10.0, output: 30.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "openai/gpt-4-turbo" => %Model{
      id: "openai/gpt-4-turbo",
      name: "OpenAI: GPT-4 Turbo",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 30.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "openai/gpt-4-turbo-preview" => %Model{
      id: "openai/gpt-4-turbo-preview",
      name: "OpenAI: GPT-4 Turbo Preview",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 10.0, output: 30.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "openai/gpt-4.1" => %Model{
      id: "openai/gpt-4.1",
      name: "OpenAI: GPT-4.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "openai/gpt-4.1-mini" => %Model{
      id: "openai/gpt-4.1-mini",
      name: "OpenAI: GPT-4.1 Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 1.5999999999999999,
        cache_read: 0.09999999999999999,
        cache_write: 0.0
      },
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "openai/gpt-4.1-nano" => %Model{
      id: "openai/gpt-4.1-nano",
      name: "OpenAI: GPT-4.1 Nano",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.024999999999999998,
        cache_write: 0.0
      },
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "openai/gpt-4o" => %Model{
      id: "openai/gpt-4o",
      name: "OpenAI: GPT-4o",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-4o-2024-05-13" => %Model{
      id: "openai/gpt-4o-2024-05-13",
      name: "OpenAI: GPT-4o (2024-05-13)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "openai/gpt-4o-2024-08-06" => %Model{
      id: "openai/gpt-4o-2024-08-06",
      name: "OpenAI: GPT-4o (2024-08-06)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-4o-2024-11-20" => %Model{
      id: "openai/gpt-4o-2024-11-20",
      name: "OpenAI: GPT-4o (2024-11-20)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-4o-audio-preview" => %Model{
      id: "openai/gpt-4o-audio-preview",
      name: "OpenAI: GPT-4o Audio",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-4o-mini" => %Model{
      id: "openai/gpt-4o-mini",
      name: "OpenAI: GPT-4o-mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.075, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-4o-mini-2024-07-18" => %Model{
      id: "openai/gpt-4o-mini-2024-07-18",
      name: "OpenAI: GPT-4o-mini (2024-07-18)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.075, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-4o:extended" => %Model{
      id: "openai/gpt-4o:extended",
      name: "OpenAI: GPT-4o (extended)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 6.0, output: 18.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "openai/gpt-5" => %Model{
      id: "openai/gpt-5",
      name: "OpenAI: GPT-5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-codex" => %Model{
      id: "openai/gpt-5-codex",
      name: "OpenAI: GPT-5 Codex",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-image" => %Model{
      id: "openai/gpt-5-image",
      name: "OpenAI: GPT-5 Image",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-image-mini" => %Model{
      id: "openai/gpt-5-image-mini",
      name: "OpenAI: GPT-5 Image Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 2.0, cache_read: 0.25, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-mini" => %Model{
      id: "openai/gpt-5-mini",
      name: "OpenAI: GPT-5 Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.25,
        output: 2.0,
        cache_read: 0.024999999999999998,
        cache_write: 0.0
      },
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-nano" => %Model{
      id: "openai/gpt-5-nano",
      name: "OpenAI: GPT-5 Nano",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.049999999999999996,
        output: 0.39999999999999997,
        cache_read: 0.005,
        cache_write: 0.0
      },
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-pro" => %Model{
      id: "openai/gpt-5-pro",
      name: "OpenAI: GPT-5 Pro",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 120.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.1" => %Model{
      id: "openai/gpt-5.1",
      name: "OpenAI: GPT-5.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.1-chat" => %Model{
      id: "openai/gpt-5.1-chat",
      name: "OpenAI: GPT-5.1 Chat",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-5.1-codex" => %Model{
      id: "openai/gpt-5.1-codex",
      name: "OpenAI: GPT-5.1-Codex",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.1-codex-max" => %Model{
      id: "openai/gpt-5.1-codex-max",
      name: "OpenAI: GPT-5.1-Codex-Max",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.1-codex-mini" => %Model{
      id: "openai/gpt-5.1-codex-mini",
      name: "OpenAI: GPT-5.1-Codex-Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.25,
        output: 2.0,
        cache_read: 0.024999999999999998,
        cache_write: 0.0
      },
      context_window: 400_000,
      max_tokens: 100_000
    },
    "openai/gpt-5.2" => %Model{
      id: "openai/gpt-5.2",
      name: "OpenAI: GPT-5.2",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.2-chat" => %Model{
      id: "openai/gpt-5.2-chat",
      name: "OpenAI: GPT-5.2 Chat",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-5.2-codex" => %Model{
      id: "openai/gpt-5.2-codex",
      name: "OpenAI: GPT-5.2-Codex",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.2-pro" => %Model{
      id: "openai/gpt-5.2-pro",
      name: "OpenAI: GPT-5.2 Pro",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 21.0, output: 168.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-oss-120b" => %Model{
      id: "openai/gpt-oss-120b",
      name: "OpenAI: gpt-oss-120b",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.039, output: 0.19, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "openai/gpt-oss-120b:exacto" => %Model{
      id: "openai/gpt-oss-120b:exacto",
      name: "OpenAI: gpt-oss-120b (exacto)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.039, output: 0.19, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "openai/gpt-oss-120b:free" => %Model{
      id: "openai/gpt-oss-120b:free",
      name: "OpenAI: gpt-oss-120b (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "openai/gpt-oss-20b" => %Model{
      id: "openai/gpt-oss-20b",
      name: "OpenAI: gpt-oss-20b",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.03, output: 0.14, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "openai/gpt-oss-20b:free" => %Model{
      id: "openai/gpt-oss-20b:free",
      name: "OpenAI: gpt-oss-20b (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "openai/gpt-oss-safeguard-20b" => %Model{
      id: "openai/gpt-oss-safeguard-20b",
      name: "OpenAI: gpt-oss-safeguard-20b",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.037, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 65_536
    },
    "openai/o1" => %Model{
      id: "openai/o1",
      name: "OpenAI: o1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 60.0, cache_read: 7.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3" => %Model{
      id: "openai/o3",
      name: "OpenAI: o3",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3-deep-research" => %Model{
      id: "openai/o3-deep-research",
      name: "OpenAI: o3 Deep Research",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 40.0, cache_read: 2.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3-mini" => %Model{
      id: "openai/o3-mini",
      name: "OpenAI: o3 Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.55, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3-mini-high" => %Model{
      id: "openai/o3-mini-high",
      name: "OpenAI: o3 Mini High",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.55, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3-pro" => %Model{
      id: "openai/o3-pro",
      name: "OpenAI: o3 Pro",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 20.0, output: 80.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o4-mini" => %Model{
      id: "openai/o4-mini",
      name: "OpenAI: o4 Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.275, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o4-mini-deep-research" => %Model{
      id: "openai/o4-mini-deep-research",
      name: "OpenAI: o4 Mini Deep Research",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o4-mini-high" => %Model{
      id: "openai/o4-mini-high",
      name: "OpenAI: o4 Mini High",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.275, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openrouter/auto" => %Model{
      id: "openrouter/auto",
      name: "Auto Router",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 2_000_000,
      max_tokens: 4_096
    },
    "openrouter/free" => %Model{
      id: "openrouter/free",
      name: "Free Models Router",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 4_096
    },
    "prime-intellect/intellect-3" => %Model{
      id: "prime-intellect/intellect-3",
      name: "Prime Intellect: INTELLECT-3",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 1.1,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 131_072
    },
    "qwen/qwen-2.5-72b-instruct" => %Model{
      id: "qwen/qwen-2.5-72b-instruct",
      name: "Qwen2.5 72B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.12, output: 0.39, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 16_384
    },
    "qwen/qwen-2.5-7b-instruct" => %Model{
      id: "qwen/qwen-2.5-7b-instruct",
      name: "Qwen: Qwen2.5 7B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.04,
        output: 0.09999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 4_096
    },
    "qwen/qwen-max" => %Model{
      id: "qwen/qwen-max",
      name: "Qwen: Qwen-Max ",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 1.5999999999999999,
        output: 6.3999999999999995,
        cache_read: 0.32,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 8_192
    },
    "qwen/qwen-plus" => %Model{
      id: "qwen/qwen-plus",
      name: "Qwen: Qwen-Plus",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 1.2,
        cache_read: 0.08,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 32_768
    },
    "qwen/qwen-plus-2025-07-28" => %Model{
      id: "qwen/qwen-plus-2025-07-28",
      name: "Qwen: Qwen Plus 0728",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 1.2,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 32_768
    },
    "qwen/qwen-plus-2025-07-28:thinking" => %Model{
      id: "qwen/qwen-plus-2025-07-28:thinking",
      name: "Qwen: Qwen Plus 0728 (thinking)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 1.2,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 32_768
    },
    "qwen/qwen-turbo" => %Model{
      id: "qwen/qwen-turbo",
      name: "Qwen: Qwen-Turbo",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.049999999999999996,
        output: 0.19999999999999998,
        cache_read: 0.01,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 8_192
    },
    "qwen/qwen-vl-max" => %Model{
      id: "qwen/qwen-vl-max",
      name: "Qwen: Qwen VL Max",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.7999999999999999,
        output: 3.1999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 32_768
    },
    "qwen/qwen3-14b" => %Model{
      id: "qwen/qwen3-14b",
      name: "Qwen: Qwen3 14B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.06, output: 0.24, cache_read: 0.0, cache_write: 0.0},
      context_window: 40_960,
      max_tokens: 40_960
    },
    "qwen/qwen3-235b-a22b" => %Model{
      id: "qwen/qwen3-235b-a22b",
      name: "Qwen: Qwen3 235B A22B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.45499999999999996,
        output: 1.8199999999999998,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 8_192
    },
    "qwen/qwen3-235b-a22b-2507" => %Model{
      id: "qwen/qwen3-235b-a22b-2507",
      name: "Qwen: Qwen3 235B A22B Instruct 2507",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.071,
        output: 0.09999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 4_096
    },
    "qwen/qwen3-235b-a22b-thinking-2507" => %Model{
      id: "qwen/qwen3-235b-a22b-thinking-2507",
      name: "Qwen: Qwen3 235B A22B Thinking 2507",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "qwen/qwen3-30b-a3b" => %Model{
      id: "qwen/qwen3-30b-a3b",
      name: "Qwen: Qwen3 30B A3B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.08, output: 0.28, cache_read: 0.0, cache_write: 0.0},
      context_window: 40_960,
      max_tokens: 40_960
    },
    "qwen/qwen3-30b-a3b-instruct-2507" => %Model{
      id: "qwen/qwen3-30b-a3b-instruct-2507",
      name: "Qwen: Qwen3 30B A3B Instruct 2507",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.09, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 262_144
    },
    "qwen/qwen3-30b-a3b-thinking-2507" => %Model{
      id: "qwen/qwen3-30b-a3b-thinking-2507",
      name: "Qwen: Qwen3 30B A3B Thinking 2507",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.051,
        output: 0.33999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 4_096
    },
    "qwen/qwen3-32b" => %Model{
      id: "qwen/qwen3-32b",
      name: "Qwen: Qwen3 32B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.08, output: 0.24, cache_read: 0.04, cache_write: 0.0},
      context_window: 40_960,
      max_tokens: 40_960
    },
    "qwen/qwen3-4b:free" => %Model{
      id: "qwen/qwen3-4b:free",
      name: "Qwen: Qwen3 4B (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 40_960,
      max_tokens: 4_096
    },
    "qwen/qwen3-8b" => %Model{
      id: "qwen/qwen3-8b",
      name: "Qwen: Qwen3 8B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.049999999999999996,
        output: 0.39999999999999997,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 32_000,
      max_tokens: 8_192
    },
    "qwen/qwen3-coder" => %Model{
      id: "qwen/qwen3-coder",
      name: "Qwen: Qwen3 Coder 480B A35B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.22, output: 1.0, cache_read: 0.022, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 4_096
    },
    "qwen/qwen3-coder-30b-a3b-instruct" => %Model{
      id: "qwen/qwen3-coder-30b-a3b-instruct",
      name: "Qwen: Qwen3 Coder 30B A3B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.07, output: 0.27, cache_read: 0.0, cache_write: 0.0},
      context_window: 160_000,
      max_tokens: 32_768
    },
    "qwen/qwen3-coder-flash" => %Model{
      id: "qwen/qwen3-coder-flash",
      name: "Qwen: Qwen3 Coder Flash",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.5, cache_read: 0.06, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 65_536
    },
    "qwen/qwen3-coder-next" => %Model{
      id: "qwen/qwen3-coder-next",
      name: "Qwen: Qwen3 Coder Next",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.12, output: 0.75, cache_read: 0.06, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 65_536
    },
    "qwen/qwen3-coder-plus" => %Model{
      id: "qwen/qwen3-coder-plus",
      name: "Qwen: Qwen3 Coder Plus",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 1.0,
        output: 5.0,
        cache_read: 0.19999999999999998,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 65_536
    },
    "qwen/qwen3-coder:exacto" => %Model{
      id: "qwen/qwen3-coder:exacto",
      name: "Qwen: Qwen3 Coder 480B A35B (exacto)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.22,
        output: 1.7999999999999998,
        cache_read: 0.022,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 65_536
    },
    "qwen/qwen3-coder:free" => %Model{
      id: "qwen/qwen3-coder:free",
      name: "Qwen: Qwen3 Coder 480B A35B (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_000,
      max_tokens: 262_000
    },
    "qwen/qwen3-max" => %Model{
      id: "qwen/qwen3-max",
      name: "Qwen: Qwen3 Max",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.2, output: 6.0, cache_read: 0.24, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 65_536
    },
    "qwen/qwen3-max-thinking" => %Model{
      id: "qwen/qwen3-max-thinking",
      name: "Qwen: Qwen3 Max Thinking",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.2, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 65_536
    },
    "qwen/qwen3-next-80b-a3b-instruct" => %Model{
      id: "qwen/qwen3-next-80b-a3b-instruct",
      name: "Qwen: Qwen3 Next 80B A3B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.09, output: 1.1, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 4_096
    },
    "qwen/qwen3-next-80b-a3b-instruct:free" => %Model{
      id: "qwen/qwen3-next-80b-a3b-instruct:free",
      name: "Qwen: Qwen3 Next 80B A3B Instruct (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 4_096
    },
    "qwen/qwen3-next-80b-a3b-thinking" => %Model{
      id: "qwen/qwen3-next-80b-a3b-thinking",
      name: "Qwen: Qwen3 Next 80B A3B Thinking",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "qwen/qwen3-vl-235b-a22b-instruct" => %Model{
      id: "qwen/qwen3-vl-235b-a22b-instruct",
      name: "Qwen: Qwen3 VL 235B A22B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.88,
        cache_read: 0.11,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 4_096
    },
    "qwen/qwen3-vl-235b-a22b-thinking" => %Model{
      id: "qwen/qwen3-vl-235b-a22b-thinking",
      name: "Qwen: Qwen3 VL 235B A22B Thinking",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    },
    "qwen/qwen3-vl-30b-a3b-instruct" => %Model{
      id: "qwen/qwen3-vl-30b-a3b-instruct",
      name: "Qwen: Qwen3 VL 30B A3B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.13, output: 0.52, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    },
    "qwen/qwen3-vl-30b-a3b-thinking" => %Model{
      id: "qwen/qwen3-vl-30b-a3b-thinking",
      name: "Qwen: Qwen3 VL 30B A3B Thinking",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    },
    "qwen/qwen3-vl-32b-instruct" => %Model{
      id: "qwen/qwen3-vl-32b-instruct",
      name: "Qwen: Qwen3 VL 32B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.10400000000000001,
        output: 0.41600000000000004,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 32_768
    },
    "qwen/qwen3-vl-8b-instruct" => %Model{
      id: "qwen/qwen3-vl-8b-instruct",
      name: "Qwen: Qwen3 VL 8B Instruct",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.08, output: 0.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    },
    "qwen/qwen3-vl-8b-thinking" => %Model{
      id: "qwen/qwen3-vl-8b-thinking",
      name: "Qwen: Qwen3 VL 8B Thinking",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.117, output: 1.365, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 32_768
    },
    "qwen/qwen3.5-397b-a17b" => %Model{
      id: "qwen/qwen3.5-397b-a17b",
      name: "Qwen: Qwen3.5 397B A17B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 1.0, cache_read: 0.15, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 65_536
    },
    "qwen/qwen3.5-plus-02-15" => %Model{
      id: "qwen/qwen3.5-plus-02-15",
      name: "Qwen: Qwen3.5 Plus 2026-02-15",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.4,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 65_536
    },
    "qwen/qwq-32b" => %Model{
      id: "qwen/qwq-32b",
      name: "Qwen: QwQ 32B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.15,
        output: 0.39999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 32_768
    },
    "relace/relace-search" => %Model{
      id: "relace/relace-search",
      name: "Relace: Relace Search",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 128_000
    },
    "sao10k/l3-euryale-70b" => %Model{
      id: "sao10k/l3-euryale-70b",
      name: "Sao10k: Llama 3 Euryale 70B v2.1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.48, output: 1.48, cache_read: 0.0, cache_write: 0.0},
      context_window: 8_192,
      max_tokens: 8_192
    },
    "sao10k/l3.1-euryale-70b" => %Model{
      id: "sao10k/l3.1-euryale-70b",
      name: "Sao10K: Llama 3.1 Euryale 70B v2.2",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.65, output: 0.75, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 32_768
    },
    "stepfun/step-3.5-flash" => %Model{
      id: "stepfun/step-3.5-flash",
      name: "StepFun: Step 3.5 Flash",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.3,
        cache_read: 0.02,
        cache_write: 0.0
      },
      context_window: 256_000,
      max_tokens: 256_000
    },
    "stepfun/step-3.5-flash:free" => %Model{
      id: "stepfun/step-3.5-flash:free",
      name: "StepFun: Step 3.5 Flash (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "thedrummer/rocinante-12b" => %Model{
      id: "thedrummer/rocinante-12b",
      name: "TheDrummer: Rocinante 12B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.16999999999999998,
        output: 0.43,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 32_768
    },
    "thedrummer/unslopnemo-12b" => %Model{
      id: "thedrummer/unslopnemo-12b",
      name: "TheDrummer: UnslopNemo 12B",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 0.39999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_768,
      max_tokens: 32_768
    },
    "tngtech/deepseek-r1t2-chimera" => %Model{
      id: "tngtech/deepseek-r1t2-chimera",
      name: "TNG: DeepSeek R1T2 Chimera",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.25, output: 0.85, cache_read: 0.125, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 163_840
    },
    "upstage/solar-pro-3:free" => %Model{
      id: "upstage/solar-pro-3:free",
      name: "Upstage: Solar Pro 3 (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "x-ai/grok-3" => %Model{
      id: "x-ai/grok-3",
      name: "xAI: Grok 3",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.75, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "x-ai/grok-3-beta" => %Model{
      id: "x-ai/grok-3-beta",
      name: "xAI: Grok 3 Beta",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.75, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "x-ai/grok-3-mini" => %Model{
      id: "x-ai/grok-3-mini",
      name: "xAI: Grok 3 Mini",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 0.5, cache_read: 0.075, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "x-ai/grok-3-mini-beta" => %Model{
      id: "x-ai/grok-3-mini-beta",
      name: "xAI: Grok 3 Mini Beta",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 0.5, cache_read: 0.075, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 4_096
    },
    "x-ai/grok-4" => %Model{
      id: "x-ai/grok-4",
      name: "xAI: Grok 4",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.75, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 4_096
    },
    "x-ai/grok-4-fast" => %Model{
      id: "x-ai/grok-4-fast",
      name: "xAI: Grok 4 Fast",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.5,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 2_000_000,
      max_tokens: 30_000
    },
    "x-ai/grok-4.1-fast" => %Model{
      id: "x-ai/grok-4.1-fast",
      name: "xAI: Grok 4.1 Fast",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.5,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 2_000_000,
      max_tokens: 30_000
    },
    "x-ai/grok-code-fast-1" => %Model{
      id: "x-ai/grok-code-fast-1",
      name: "xAI: Grok Code Fast 1",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 1.5,
        cache_read: 0.02,
        cache_write: 0.0
      },
      context_window: 256_000,
      max_tokens: 10_000
    },
    "xiaomi/mimo-v2-flash" => %Model{
      id: "xiaomi/mimo-v2-flash",
      name: "Xiaomi: MiMo-V2-Flash",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.09, output: 0.29, cache_read: 0.045, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 65_536
    },
    "z-ai/glm-4-32b" => %Model{
      id: "z-ai/glm-4-32b",
      name: "Z.ai: GLM 4 32B ",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.09999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 128_000,
      max_tokens: 4_096
    },
    "z-ai/glm-4.5" => %Model{
      id: "z-ai/glm-4.5",
      name: "Z.ai: GLM 4.5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.55, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_000,
      max_tokens: 131_000
    },
    "z-ai/glm-4.5-air" => %Model{
      id: "z-ai/glm-4.5-air",
      name: "Z.ai: GLM 4.5 Air",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.13,
        output: 0.85,
        cache_read: 0.024999999999999998,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 98_304
    },
    "z-ai/glm-4.5-air:free" => %Model{
      id: "z-ai/glm-4.5-air:free",
      name: "Z.ai: GLM 4.5 Air (free)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 96_000
    },
    "z-ai/glm-4.5v" => %Model{
      id: "z-ai/glm-4.5v",
      name: "Z.ai: GLM 4.5V",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.6,
        output: 1.7999999999999998,
        cache_read: 0.11,
        cache_write: 0.0
      },
      context_window: 65_536,
      max_tokens: 16_384
    },
    "z-ai/glm-4.6" => %Model{
      id: "z-ai/glm-4.6",
      name: "Z.ai: GLM 4.6",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.35, output: 1.71, cache_read: 0.0, cache_write: 0.0},
      context_window: 202_752,
      max_tokens: 131_072
    },
    "z-ai/glm-4.6:exacto" => %Model{
      id: "z-ai/glm-4.6:exacto",
      name: "Z.ai: GLM 4.6 (exacto)",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.44, output: 1.76, cache_read: 0.11, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "z-ai/glm-4.6v" => %Model{
      id: "z-ai/glm-4.6v",
      name: "Z.ai: GLM 4.6V",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.3,
        output: 0.8999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 131_072
    },
    "z-ai/glm-4.7" => %Model{
      id: "z-ai/glm-4.7",
      name: "Z.ai: GLM 4.7",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.38, output: 1.7, cache_read: 0.19, cache_write: 0.0},
      context_window: 202_752,
      max_tokens: 65_535
    },
    "z-ai/glm-4.7-flash" => %Model{
      id: "z-ai/glm-4.7-flash",
      name: "Z.ai: GLM 4.7 Flash",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.06,
        output: 0.39999999999999997,
        cache_read: 0.0100000002,
        cache_write: 0.0
      },
      context_window: 202_752,
      max_tokens: 4_096
    },
    "z-ai/glm-5" => %Model{
      id: "z-ai/glm-5",
      name: "Z.ai: GLM 5",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.3,
        output: 2.5500000000000003,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 204_800,
      max_tokens: 131_072
    }
  }

  @vercel_ai_gateway_models %{
    "alibaba/qwen-3-14b" => %Model{
      id: "alibaba/qwen-3-14b",
      name: "Qwen3-14B",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.06, output: 0.24, cache_read: 0.0, cache_write: 0.0},
      context_window: 40_960,
      max_tokens: 16_384
    },
    "alibaba/qwen-3-235b" => %Model{
      id: "alibaba/qwen-3-235b",
      name: "Qwen3-235B-A22B",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.071, output: 0.463, cache_read: 0.0, cache_write: 0.0},
      context_window: 40_960,
      max_tokens: 16_384
    },
    "alibaba/qwen-3-30b" => %Model{
      id: "alibaba/qwen-3-30b",
      name: "Qwen3-30B-A3B",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.08, output: 0.29, cache_read: 0.0, cache_write: 0.0},
      context_window: 40_960,
      max_tokens: 16_384
    },
    "alibaba/qwen-3-32b" => %Model{
      id: "alibaba/qwen-3-32b",
      name: "Qwen 3 32B",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.3,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 40_960,
      max_tokens: 16_384
    },
    "alibaba/qwen3-235b-a22b-thinking" => %Model{
      id: "alibaba/qwen3-235b-a22b-thinking",
      name: "Qwen3 235B A22B Thinking 2507",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.3,
        output: 2.9000000000000004,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 262_114,
      max_tokens: 262_114
    },
    "alibaba/qwen3-coder" => %Model{
      id: "alibaba/qwen3-coder",
      name: "Qwen3 Coder 480B A35B Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 1.5999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 262_144,
      max_tokens: 66_536
    },
    "alibaba/qwen3-coder-30b-a3b" => %Model{
      id: "alibaba/qwen3-coder-30b-a3b",
      name: "Qwen 3 Coder 30B A3B Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.07, output: 0.27, cache_read: 0.0, cache_write: 0.0},
      context_window: 160_000,
      max_tokens: 32_768
    },
    "alibaba/qwen3-coder-next" => %Model{
      id: "alibaba/qwen3-coder-next",
      name: "Qwen3 Coder Next",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "alibaba/qwen3-coder-plus" => %Model{
      id: "alibaba/qwen3-coder-plus",
      name: "Qwen3 Coder Plus",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 1.0,
        output: 5.0,
        cache_read: 0.19999999999999998,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 65_536
    },
    "alibaba/qwen3-max-preview" => %Model{
      id: "alibaba/qwen3-max-preview",
      name: "Qwen3 Max Preview",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.2, output: 6.0, cache_read: 0.24, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_768
    },
    "alibaba/qwen3-max-thinking" => %Model{
      id: "alibaba/qwen3-max-thinking",
      name: "Qwen 3 Max Thinking",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.2, output: 6.0, cache_read: 0.24, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 65_536
    },
    "alibaba/qwen3-vl-thinking" => %Model{
      id: "alibaba/qwen3-vl-thinking",
      name: "Qwen3 VL 235B A22B Thinking",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.22, output: 0.88, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "alibaba/qwen3.5-plus" => %Model{
      id: "alibaba/qwen3.5-plus",
      name: "Qwen 3.5 Plus",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.4,
        cache_read: 0.04,
        cache_write: 0.5
      },
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "anthropic/claude-3-haiku" => %Model{
      id: "anthropic/claude-3-haiku",
      name: "Claude 3 Haiku",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 1.25, cache_read: 0.03, cache_write: 0.3},
      context_window: 200_000,
      max_tokens: 4_096
    },
    "anthropic/claude-3.5-haiku" => %Model{
      id: "anthropic/claude-3.5-haiku",
      name: "Claude 3.5 Haiku",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.7999999999999999,
        output: 4.0,
        cache_read: 0.08,
        cache_write: 1.0
      },
      context_window: 200_000,
      max_tokens: 8_192
    },
    "anthropic/claude-3.5-sonnet" => %Model{
      id: "anthropic/claude-3.5-sonnet",
      name: "Claude 3.5 Sonnet",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8_192
    },
    "anthropic/claude-3.5-sonnet-20240620" => %Model{
      id: "anthropic/claude-3.5-sonnet-20240620",
      name: "Claude 3.5 Sonnet (2024-06-20)",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 8_192
    },
    "anthropic/claude-3.7-sonnet" => %Model{
      id: "anthropic/claude-3.7-sonnet",
      name: "Claude 3.7 Sonnet",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic/claude-haiku-4.5" => %Model{
      id: "anthropic/claude-haiku-4.5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 1.0,
        output: 5.0,
        cache_read: 0.09999999999999999,
        cache_write: 1.25
      },
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic/claude-opus-4" => %Model{
      id: "anthropic/claude-opus-4",
      name: "Claude Opus 4",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "anthropic/claude-opus-4.1" => %Model{
      id: "anthropic/claude-opus-4.1",
      name: "Claude Opus 4.1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 75.0, cache_read: 1.5, cache_write: 18.75},
      context_window: 200_000,
      max_tokens: 32_000
    },
    "anthropic/claude-opus-4.5" => %Model{
      id: "anthropic/claude-opus-4.5",
      name: "Claude Opus 4.5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 200_000,
      max_tokens: 64_000
    },
    "anthropic/claude-opus-4.6" => %Model{
      id: "anthropic/claude-opus-4.6",
      name: "Claude Opus 4.6",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.5, cache_write: 6.25},
      context_window: 1_000_000,
      max_tokens: 128_000
    },
    "anthropic/claude-sonnet-4" => %Model{
      id: "anthropic/claude-sonnet-4",
      name: "Claude Sonnet 4",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "anthropic/claude-sonnet-4.5" => %Model{
      id: "anthropic/claude-sonnet-4.5",
      name: "Claude Sonnet 4.5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "anthropic/claude-sonnet-4.6" => %Model{
      id: "anthropic/claude-sonnet-4.6",
      name: "Claude Sonnet 4.6",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 128_000
    },
    "arcee-ai/trinity-large-preview" => %Model{
      id: "arcee-ai/trinity-large-preview",
      name: "Trinity Large Preview",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.25, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_000,
      max_tokens: 131_000
    },
    "bytedance/seed-1.6" => %Model{
      id: "bytedance/seed-1.6",
      name: "Seed 1.6",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.25,
        output: 2.0,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 256_000,
      max_tokens: 32_000
    },
    "cohere/command-a" => %Model{
      id: "cohere/command-a",
      name: "Command A",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 8_000
    },
    "deepseek/deepseek-v3" => %Model{
      id: "deepseek/deepseek-v3",
      name: "DeepSeek V3 0324",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.77, output: 0.77, cache_read: 0.0, cache_write: 0.0},
      context_window: 163_840,
      max_tokens: 16_384
    },
    "deepseek/deepseek-v3.1" => %Model{
      id: "deepseek/deepseek-v3.1",
      name: "DeepSeek-V3.1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.21,
        output: 0.7899999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 163_840,
      max_tokens: 128_000
    },
    "deepseek/deepseek-v3.1-terminus" => %Model{
      id: "deepseek/deepseek-v3.1-terminus",
      name: "DeepSeek V3.1 Terminus",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.27, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 65_536
    },
    "deepseek/deepseek-v3.2" => %Model{
      id: "deepseek/deepseek-v3.2",
      name: "DeepSeek V3.2",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.26, output: 0.38, cache_read: 0.13, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8_000
    },
    "deepseek/deepseek-v3.2-thinking" => %Model{
      id: "deepseek/deepseek-v3.2-thinking",
      name: "DeepSeek V3.2 Thinking",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.28, output: 0.42, cache_read: 0.028, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 64_000
    },
    "google/gemini-2.5-flash" => %Model{
      id: "google/gemini-2.5-flash",
      name: "Gemini 2.5 Flash",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 2.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 65_536
    },
    "google/gemini-2.5-flash-lite" => %Model{
      id: "google/gemini-2.5-flash-lite",
      name: "Gemini 2.5 Flash Lite",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.01,
        cache_write: 0.0
      },
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "google/gemini-2.5-flash-lite-preview-09-2025" => %Model{
      id: "google/gemini-2.5-flash-lite-preview-09-2025",
      name: "Gemini 2.5 Flash Lite Preview 09-2025",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.01,
        cache_write: 0.0
      },
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "google/gemini-2.5-flash-preview-09-2025" => %Model{
      id: "google/gemini-2.5-flash-preview-09-2025",
      name: "Gemini 2.5 Flash Preview 09-2025",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.3, output: 2.5, cache_read: 0.03, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 65_536
    },
    "google/gemini-2.5-pro" => %Model{
      id: "google/gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536
    },
    "google/gemini-3-flash" => %Model{
      id: "google/gemini-3-flash",
      name: "Gemini 3 Flash",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.5,
        output: 3.0,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "google/gemini-3-pro-preview" => %Model{
      id: "google/gemini-3-pro-preview",
      name: "Gemini 3 Pro Preview",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 2.0,
        output: 12.0,
        cache_read: 0.19999999999999998,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "google/gemini-3.1-pro-preview" => %Model{
      id: "google/gemini-3.1-pro-preview",
      name: "Gemini 3.1 Pro Preview",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 2.0,
        output: 12.0,
        cache_read: 0.19999999999999998,
        cache_write: 0.0
      },
      context_window: 1_000_000,
      max_tokens: 64_000
    },
    "inception/mercury-coder-small" => %Model{
      id: "inception/mercury-coder-small",
      name: "Mercury Coder Small Beta",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.25, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_000,
      max_tokens: 16_384
    },
    "meituan/longcat-flash-chat" => %Model{
      id: "meituan/longcat-flash-chat",
      name: "LongCat Flash Chat",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8_192
    },
    "meituan/longcat-flash-thinking" => %Model{
      id: "meituan/longcat-flash-thinking",
      name: "LongCat Flash Thinking",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8_192
    },
    "meta/llama-3.1-70b" => %Model{
      id: "meta/llama-3.1-70b",
      name: "Llama 3.1 70B Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 0.39999999999999997,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 16_384
    },
    "meta/llama-3.1-8b" => %Model{
      id: "meta/llama-3.1-8b",
      name: "Llama 3.1 8B Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.03,
        output: 0.049999999999999996,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 16_384
    },
    "meta/llama-3.2-11b" => %Model{
      id: "meta/llama-3.2-11b",
      name: "Llama 3.2 11B Vision Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.16, output: 0.16, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8_192
    },
    "meta/llama-3.2-90b" => %Model{
      id: "meta/llama-3.2-90b",
      name: "Llama 3.2 90B Vision Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.72, output: 0.72, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8_192
    },
    "meta/llama-3.3-70b" => %Model{
      id: "meta/llama-3.3-70b",
      name: "Llama 3.3 70B Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.72, output: 0.72, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8_192
    },
    "meta/llama-4-maverick" => %Model{
      id: "meta/llama-4-maverick",
      name: "Llama 4 Maverick 17B Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8_192
    },
    "meta/llama-4-scout" => %Model{
      id: "meta/llama-4-scout",
      name: "Llama 4 Scout 17B Instruct",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.08, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 8_192
    },
    "minimax/minimax-m2" => %Model{
      id: "minimax/minimax-m2",
      name: "MiniMax M2",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.03, cache_write: 0.375},
      context_window: 205_000,
      max_tokens: 205_000
    },
    "minimax/minimax-m2.1" => %Model{
      id: "minimax/minimax-m2.1",
      name: "MiniMax M2.1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.15, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "minimax/minimax-m2.1-lightning" => %Model{
      id: "minimax/minimax-m2.1-lightning",
      name: "MiniMax M2.1 Lightning",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 2.4, cache_read: 0.03, cache_write: 0.375},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "minimax/minimax-m2.5" => %Model{
      id: "minimax/minimax-m2.5",
      name: "MiniMax M2.5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.03, cache_write: 0.375},
      context_window: 204_800,
      max_tokens: 131_000
    },
    "mistral/codestral" => %Model{
      id: "mistral/codestral",
      name: "Mistral Codestral",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.3,
        output: 0.8999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 128_000,
      max_tokens: 4_000
    },
    "mistral/devstral-2" => %Model{
      id: "mistral/devstral-2",
      name: "Devstral 2",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "mistral/devstral-small" => %Model{
      id: "mistral/devstral-small",
      name: "Devstral Small 1.1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.3,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 128_000,
      max_tokens: 64_000
    },
    "mistral/devstral-small-2" => %Model{
      id: "mistral/devstral-small-2",
      name: "Devstral Small 2",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "mistral/ministral-3b" => %Model{
      id: "mistral/ministral-3b",
      name: "Ministral 3B",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.04, output: 0.04, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_000
    },
    "mistral/ministral-8b" => %Model{
      id: "mistral/ministral-8b",
      name: "Ministral 8B",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.09999999999999999,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 128_000,
      max_tokens: 4_000
    },
    "mistral/mistral-medium" => %Model{
      id: "mistral/mistral-medium",
      name: "Mistral Medium 3.1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 2.0,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 128_000,
      max_tokens: 64_000
    },
    "mistral/mistral-small" => %Model{
      id: "mistral/mistral-small",
      name: "Mistral Small",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.3,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 32_000,
      max_tokens: 4_000
    },
    "mistral/pixtral-12b" => %Model{
      id: "mistral/pixtral-12b",
      name: "Pixtral 12B 2409",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.15, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_000
    },
    "mistral/pixtral-large" => %Model{
      id: "mistral/pixtral-large",
      name: "Pixtral Large",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_000
    },
    "moonshotai/kimi-k2" => %Model{
      id: "moonshotai/kimi-k2",
      name: "Kimi K2",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.5, output: 2.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 16_384
    },
    "moonshotai/kimi-k2-thinking" => %Model{
      id: "moonshotai/kimi-k2-thinking",
      name: "Kimi K2 Thinking",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.47,
        output: 2.0,
        cache_read: 0.14100000000000001,
        cache_write: 0.0
      },
      context_window: 216_144,
      max_tokens: 216_144
    },
    "moonshotai/kimi-k2-thinking-turbo" => %Model{
      id: "moonshotai/kimi-k2-thinking-turbo",
      name: "Kimi K2 Thinking Turbo",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.15, output: 8.0, cache_read: 0.15, cache_write: 0.0},
      context_window: 262_114,
      max_tokens: 262_114
    },
    "moonshotai/kimi-k2-turbo" => %Model{
      id: "moonshotai/kimi-k2-turbo",
      name: "Kimi K2 Turbo",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 2.4, output: 10.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 16_384
    },
    "moonshotai/kimi-k2.5" => %Model{
      id: "moonshotai/kimi-k2.5",
      name: "Kimi K2.5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.5, output: 2.8, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "nvidia/nemotron-nano-12b-v2-vl" => %Model{
      id: "nvidia/nemotron-nano-12b-v2-vl",
      name: "Nvidia Nemotron Nano 12B V2 VL",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.6,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 131_072
    },
    "nvidia/nemotron-nano-9b-v2" => %Model{
      id: "nvidia/nemotron-nano-9b-v2",
      name: "Nvidia Nemotron Nano 9B V2",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.04, output: 0.16, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "openai/codex-mini" => %Model{
      id: "openai/codex-mini",
      name: "Codex Mini",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.5, output: 6.0, cache_read: 0.375, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/gpt-4-turbo" => %Model{
      id: "openai/gpt-4-turbo",
      name: "GPT-4 Turbo",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 30.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096
    },
    "openai/gpt-4.1" => %Model{
      id: "openai/gpt-4.1",
      name: "GPT-4.1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "openai/gpt-4.1-mini" => %Model{
      id: "openai/gpt-4.1-mini",
      name: "GPT-4.1 mini",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.39999999999999997,
        output: 1.5999999999999999,
        cache_read: 0.09999999999999999,
        cache_write: 0.0
      },
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "openai/gpt-4.1-nano" => %Model{
      id: "openai/gpt-4.1-nano",
      name: "GPT-4.1 nano",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.39999999999999997,
        cache_read: 0.03,
        cache_write: 0.0
      },
      context_window: 1_047_576,
      max_tokens: 32_768
    },
    "openai/gpt-4o" => %Model{
      id: "openai/gpt-4o",
      name: "GPT-4o",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-4o-mini" => %Model{
      id: "openai/gpt-4o-mini",
      name: "GPT-4o mini",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.075, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-5" => %Model{
      id: "openai/gpt-5",
      name: "GPT-5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.13, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-chat" => %Model{
      id: "openai/gpt-5-chat",
      name: "GPT-5 Chat",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-5-codex" => %Model{
      id: "openai/gpt-5-codex",
      name: "GPT-5-Codex",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.13, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-mini" => %Model{
      id: "openai/gpt-5-mini",
      name: "GPT-5 mini",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.25, output: 2.0, cache_read: 0.03, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-nano" => %Model{
      id: "openai/gpt-5-nano",
      name: "GPT-5 nano",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.049999999999999996,
        output: 0.39999999999999997,
        cache_read: 0.01,
        cache_write: 0.0
      },
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5-pro" => %Model{
      id: "openai/gpt-5-pro",
      name: "GPT-5 pro",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 120.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 272_000
    },
    "openai/gpt-5.1-codex" => %Model{
      id: "openai/gpt-5.1-codex",
      name: "GPT-5.1-Codex",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.13, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.1-codex-max" => %Model{
      id: "openai/gpt-5.1-codex-max",
      name: "GPT 5.1 Codex Max",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.125, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.1-codex-mini" => %Model{
      id: "openai/gpt-5.1-codex-mini",
      name: "GPT-5.1 Codex mini",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.25,
        output: 2.0,
        cache_read: 0.024999999999999998,
        cache_write: 0.0
      },
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.1-instant" => %Model{
      id: "openai/gpt-5.1-instant",
      name: "GPT-5.1 Instant",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.13, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-5.1-thinking" => %Model{
      id: "openai/gpt-5.1-thinking",
      name: "GPT 5.1 Thinking",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.25, output: 10.0, cache_read: 0.13, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.2" => %Model{
      id: "openai/gpt-5.2",
      name: "GPT 5.2",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.18, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.2-chat" => %Model{
      id: "openai/gpt-5.2-chat",
      name: "GPT-5.2 Chat",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384
    },
    "openai/gpt-5.2-codex" => %Model{
      id: "openai/gpt-5.2-codex",
      name: "GPT-5.2-Codex",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.75, output: 14.0, cache_read: 0.175, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-5.2-pro" => %Model{
      id: "openai/gpt-5.2-pro",
      name: "GPT 5.2 ",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 21.0, output: 168.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 400_000,
      max_tokens: 128_000
    },
    "openai/gpt-oss-120b" => %Model{
      id: "openai/gpt-oss-120b",
      name: "gpt-oss-120b",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.09999999999999999,
        output: 0.5,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 131_072
    },
    "openai/gpt-oss-20b" => %Model{
      id: "openai/gpt-oss-20b",
      name: "gpt-oss-20b",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.07, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 8_192
    },
    "openai/gpt-oss-safeguard-20b" => %Model{
      id: "openai/gpt-oss-safeguard-20b",
      name: "gpt-oss-safeguard-20b",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.075, output: 0.3, cache_read: 0.037, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 65_536
    },
    "openai/o1" => %Model{
      id: "openai/o1",
      name: "o1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 15.0, output: 60.0, cache_read: 7.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3" => %Model{
      id: "openai/o3",
      name: "o3",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 8.0, cache_read: 0.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3-deep-research" => %Model{
      id: "openai/o3-deep-research",
      name: "o3-deep-research",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 10.0, output: 40.0, cache_read: 2.5, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3-mini" => %Model{
      id: "openai/o3-mini",
      name: "o3-mini",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.55, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o3-pro" => %Model{
      id: "openai/o3-pro",
      name: "o3 Pro",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 20.0, output: 80.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "openai/o4-mini" => %Model{
      id: "openai/o4-mini",
      name: "o4-mini",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 1.1, output: 4.4, cache_read: 0.275, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 100_000
    },
    "perplexity/sonar" => %Model{
      id: "perplexity/sonar",
      name: "Sonar",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 1.0, output: 1.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 127_000,
      max_tokens: 8_000
    },
    "perplexity/sonar-pro" => %Model{
      id: "perplexity/sonar-pro",
      name: "Sonar Pro",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 8_000
    },
    "prime-intellect/intellect-3" => %Model{
      id: "prime-intellect/intellect-3",
      name: "INTELLECT 3",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 1.1,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 131_072,
      max_tokens: 131_072
    },
    "vercel/v0-1.0-md" => %Model{
      id: "vercel/v0-1.0-md",
      name: "v0-1.0-md",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_000
    },
    "vercel/v0-1.5-md" => %Model{
      id: "vercel/v0-1.5-md",
      name: "v0-1.5-md",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 32_768
    },
    "xai/grok-2-vision" => %Model{
      id: "xai/grok-2-vision",
      name: "Grok 2 Vision",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 32_768,
      max_tokens: 32_768
    },
    "xai/grok-3" => %Model{
      id: "xai/grok-3",
      name: "Grok 3 Beta",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "xai/grok-3-fast" => %Model{
      id: "xai/grok-3-fast",
      name: "Grok 3 Fast Beta",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 5.0, output: 25.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "xai/grok-3-mini" => %Model{
      id: "xai/grok-3-mini",
      name: "Grok 3 Mini Beta",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 0.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "xai/grok-3-mini-fast" => %Model{
      id: "xai/grok-3-mini-fast",
      name: "Grok 3 Mini Fast Beta",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 4.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "xai/grok-4" => %Model{
      id: "xai/grok-4",
      name: "Grok 4",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "xai/grok-4-fast-non-reasoning" => %Model{
      id: "xai/grok-4-fast-non-reasoning",
      name: "Grok 4 Fast Non-Reasoning",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.5,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 2_000_000,
      max_tokens: 256_000
    },
    "xai/grok-4-fast-reasoning" => %Model{
      id: "xai/grok-4-fast-reasoning",
      name: "Grok 4 Fast Reasoning",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.5,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 2_000_000,
      max_tokens: 256_000
    },
    "xai/grok-4.1-fast-non-reasoning" => %Model{
      id: "xai/grok-4.1-fast-non-reasoning",
      name: "Grok 4.1 Fast Non-Reasoning",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.5,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 2_000_000,
      max_tokens: 30_000
    },
    "xai/grok-4.1-fast-reasoning" => %Model{
      id: "xai/grok-4.1-fast-reasoning",
      name: "Grok 4.1 Fast Reasoning",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 0.5,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 2_000_000,
      max_tokens: 30_000
    },
    "xai/grok-code-fast-1" => %Model{
      id: "xai/grok-code-fast-1",
      name: "Grok Code Fast 1",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 1.5,
        cache_read: 0.02,
        cache_write: 0.0
      },
      context_window: 256_000,
      max_tokens: 256_000
    },
    "xiaomi/mimo-v2-flash" => %Model{
      id: "xiaomi/mimo-v2-flash",
      name: "MiMo V2 Flash",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.09, output: 0.29, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 32_000
    },
    "zai/glm-4.5" => %Model{
      id: "zai/glm-4.5",
      name: "GLM-4.5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 131_072
    },
    "zai/glm-4.5-air" => %Model{
      id: "zai/glm-4.5-air",
      name: "GLM 4.5 Air",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.19999999999999998,
        output: 1.1,
        cache_read: 0.03,
        cache_write: 0.0
      },
      context_window: 128_000,
      max_tokens: 96_000
    },
    "zai/glm-4.5v" => %Model{
      id: "zai/glm-4.5v",
      name: "GLM 4.5V",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.6,
        output: 1.7999999999999998,
        cache_read: 0.0,
        cache_write: 0.0
      },
      context_window: 65_536,
      max_tokens: 16_384
    },
    "zai/glm-4.6" => %Model{
      id: "zai/glm-4.6",
      name: "GLM 4.6",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.44999999999999996,
        output: 1.7999999999999998,
        cache_read: 0.11,
        cache_write: 0.0
      },
      context_window: 200_000,
      max_tokens: 96_000
    },
    "zai/glm-4.6v" => %Model{
      id: "zai/glm-4.6v",
      name: "GLM-4.6V",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{
        input: 0.3,
        output: 0.8999999999999999,
        cache_read: 0.049999999999999996,
        cache_write: 0.0
      },
      context_window: 128_000,
      max_tokens: 24_000
    },
    "zai/glm-4.6v-flash" => %Model{
      id: "zai/glm-4.6v-flash",
      name: "GLM-4.6V-Flash",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 24_000
    },
    "zai/glm-4.7" => %Model{
      id: "zai/glm-4.7",
      name: "GLM 4.7",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.43, output: 1.75, cache_read: 0.08, cache_write: 0.0},
      context_window: 202_752,
      max_tokens: 120_000
    },
    "zai/glm-4.7-flashx" => %Model{
      id: "zai/glm-4.7-flashx",
      name: "GLM 4.7 FlashX",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 0.06,
        output: 0.39999999999999997,
        cache_read: 0.01,
        cache_write: 0.0
      },
      context_window: 200_000,
      max_tokens: 128_000
    },
    "zai/glm-5" => %Model{
      id: "zai/glm-5",
      name: "GLM-5",
      api: :anthropic_messages,
      provider: :vercel_ai_gateway,
      base_url: "https://ai-gateway.vercel.sh",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{
        input: 1.0,
        output: 3.1999999999999997,
        cache_read: 0.19999999999999998,
        cache_write: 0.0
      },
      context_window: 202_800,
      max_tokens: 131_072
    }
  }

  @xai_models Map.merge(
                @xai_models,
                %{
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
              )

  @zai_models Map.merge(
                @zai_models,
                %{
                  "glm-4.5v" => %Model{
                    id: "glm-4.5v",
                    name: "GLM-4.5V",
                    api: :openai_completions,
                    provider: :zai,
                    base_url: "https://api.z.ai/api/coding/paas/v4",
                    reasoning: true,
                    input: [:text, :image],
                    cost: %ModelCost{input: 0.6, output: 1.8, cache_read: 0.0, cache_write: 0.0},
                    context_window: 64_000,
                    max_tokens: 16_384
                  },
                  "glm-4.6" => %Model{
                    id: "glm-4.6",
                    name: "GLM-4.6",
                    api: :openai_completions,
                    provider: :zai,
                    base_url: "https://api.z.ai/api/coding/paas/v4",
                    reasoning: true,
                    input: [:text],
                    cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.11, cache_write: 0.0},
                    context_window: 204_800,
                    max_tokens: 131_072
                  },
                  "glm-4.6v" => %Model{
                    id: "glm-4.6v",
                    name: "GLM-4.6V",
                    api: :openai_completions,
                    provider: :zai,
                    base_url: "https://api.z.ai/api/coding/paas/v4",
                    reasoning: true,
                    input: [:text, :image],
                    cost: %ModelCost{input: 0.3, output: 0.9, cache_read: 0.0, cache_write: 0.0},
                    context_window: 128_000,
                    max_tokens: 32_768
                  },
                  "glm-4.7-flash" => %Model{
                    id: "glm-4.7-flash",
                    name: "GLM-4.7-Flash",
                    api: :openai_completions,
                    provider: :zai,
                    base_url: "https://api.z.ai/api/coding/paas/v4",
                    reasoning: true,
                    input: [:text],
                    cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
                    context_window: 200_000,
                    max_tokens: 131_072
                  }
                }
              )

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
    :amazon_bedrock => @amazon_bedrock_models,
    :google => @google_models,
    :google_antigravity => @google_antigravity_models,
    :kimi => @kimi_models,
    :opencode => @opencode_models,
    :xai => @xai_models,
    :mistral => @mistral_models,
    :cerebras => @cerebras_models,
    :deepseek => @deepseek_models,
    :qwen => @qwen_models,
    :minimax => @minimax_models,
    :zai => @zai_models,
    :azure_openai_responses => @azure_openai_responses_models,
    :github_copilot => @github_copilot_models,
    :google_gemini_cli => @google_gemini_cli_models,
    :google_vertex => @google_vertex_models,
    :groq => @groq_models,
    :huggingface => @huggingface_models,
    :minimax_cn => @minimax_cn_models,
    :openrouter => @openrouter_models,
    :vercel_ai_gateway => @vercel_ai_gateway_models
  }

  # Keep provider iteration deterministic for lookups like find_by_id/1 where
  # duplicate model IDs can exist across providers (e.g. OpenAI vs Azure/OpenAI,
  # Google vs Vertex). Canonical providers should be checked first.
  @providers [
    :anthropic,
    :openai,
    :"openai-codex",
    :amazon_bedrock,
    :google,
    :google_antigravity,
    :kimi,
    :opencode,
    :xai,
    :mistral,
    :cerebras,
    :deepseek,
    :qwen,
    :minimax,
    :zai,
    :azure_openai_responses,
    :github_copilot,
    :google_gemini_cli,
    :google_vertex,
    :groq,
    :huggingface,
    :minimax_cn,
    :openrouter,
    :vercel_ai_gateway
  ]

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
    get_providers()
    |> Enum.flat_map(&get_models/1)
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
  Check if a model supports the xhigh thinking level.

  Supported models:
  - GPT-5.2 / GPT-5.3 model families
  - Anthropic Opus 4.6 models (xhigh maps to adaptive effort "max")

  Ported from Pi's model-resolver.

  ## Examples

      iex> model = Ai.Models.get_model(:openai, "gpt-5.2")
      iex> Ai.Models.supports_xhigh?(model)
      true

      iex> model = Ai.Models.get_model(:anthropic, "claude-opus-4-6-20250514")
      iex> Ai.Models.supports_xhigh?(model)
      true

      iex> model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.supports_xhigh?(model)
      false
  """
  @spec supports_xhigh?(Model.t()) :: boolean()
  def supports_xhigh?(%Model{id: id, api: api}) do
    cond do
      String.contains?(id, "gpt-5.2") or String.contains?(id, "gpt-5.3") ->
        true
      api == :anthropic_messages and
          (String.contains?(id, "opus-4-6") or String.contains?(id, "opus-4.6")) ->
        true
      true ->
        false
    end
  end

  @default_thinking_budgets %{
    minimal: 1024,
    low: 2048,
    medium: 8192,
    high: 16384
  }

  @doc """
  Adjust max tokens to accommodate a thinking budget for a given reasoning level.

  Computes the thinking token budget for the requested level (clamping xhigh
  to high), then increases `base_max_tokens` by that amount without exceeding
  `model_max_tokens`. If the resulting max is smaller than the budget, the
  budget is reduced to leave at least 1024 output tokens.

  Ported from Pi's adjustMaxTokensForThinking.

  ## Parameters

    - `base_max_tokens` - The base output token limit before thinking
    - `model_max_tokens` - The model's hard maximum token limit
    - `reasoning_level` - One of `:minimal`, `:low`, `:medium`, `:high`, `:xhigh`
    - `custom_budgets` - Optional map overriding default budgets per level

  ## Returns

  A tuple `{max_tokens, thinking_budget}`.

  ## Examples

      iex> Ai.Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)
      {24576, 16384}

      iex> Ai.Models.adjust_max_tokens_for_thinking(8192, 200_000, :medium, %{medium: 4096})
      {12288, 4096}
  """
  @spec adjust_max_tokens_for_thinking(
          non_neg_integer(),
          non_neg_integer(),
          atom(),
          map()
        ) :: {non_neg_integer(), non_neg_integer()}
  def adjust_max_tokens_for_thinking(base_max_tokens, model_max_tokens, reasoning_level, custom_budgets \\ %{}) do
    min_output_tokens = 1024
    level = clamp_reasoning(reasoning_level)
    budgets = Map.merge(@default_thinking_budgets, custom_budgets)
    thinking_budget = Map.get(budgets, level, 0)
    max_tokens = min(base_max_tokens + thinking_budget, model_max_tokens)

    thinking_budget = if max_tokens <= thinking_budget do
      max(0, max_tokens - min_output_tokens)
    else
      thinking_budget
    end

    {max_tokens, thinking_budget}
  end

  @doc """
  Clamp a reasoning level, mapping `:xhigh` to `:high` for providers that
  don't support it.

  ## Examples

      iex> Ai.Models.clamp_reasoning(:xhigh)
      :high

      iex> Ai.Models.clamp_reasoning(:medium)
      :medium

      iex> Ai.Models.clamp_reasoning(nil)
      nil
  """
  @spec clamp_reasoning(atom() | nil) :: atom() | nil
  def clamp_reasoning(nil), do: nil
  def clamp_reasoning(:xhigh), do: :high
  def clamp_reasoning(level) when level in [:minimal, :low, :medium, :high], do: level
  def clamp_reasoning(_), do: nil

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
    Enum.find_value(get_providers(), fn provider ->
      get_model(provider, model_id)
    end)
  end

  @doc """
  Check if two models are equal by comparing both their id and provider.
  Returns false if either model is nil.

  Ported from Pi's modelsAreEqual.

  ## Examples

      iex> model1 = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> model2 = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> Ai.Models.models_equal?(model1, model2)
      true

      iex> model1 = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      iex> model2 = Ai.Models.get_model(:openai, "gpt-4o")
      iex> Ai.Models.models_equal?(model1, model2)
      false

      iex> Ai.Models.models_equal?(nil, model1)
      false

  """
  @spec models_equal?(Model.t() | nil, Model.t() | nil) :: boolean()
  def models_equal?(nil, _b), do: false
  def models_equal?(_a, nil), do: false
  def models_equal?(%Model{id: id_a, provider: provider_a}, %Model{id: id_b, provider: provider_b}) do
    id_a == id_b and provider_a == provider_b
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
