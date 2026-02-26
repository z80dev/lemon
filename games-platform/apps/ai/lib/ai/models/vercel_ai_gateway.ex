defmodule Ai.Models.VercelAIGateway do
  @moduledoc """
  Model definitions for the VercelAIGateway provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
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

  @doc "Returns all VercelAIGateway model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
