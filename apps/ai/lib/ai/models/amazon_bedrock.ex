defmodule Ai.Models.AmazonBedrock do
  @moduledoc """
  Model definitions for the AmazonBedrock provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
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
    },

    # Google Gemma Models
    "google.gemma-3-27b-it" => %Model{
      id: "google.gemma-3-27b-it",
      name: "Google Gemma 3 27B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.12, output: 0.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 202_752,
      max_tokens: 8192
    },
    "google.gemma-3-4b-it" => %Model{
      id: "google.gemma-3-4b-it",
      name: "Gemma 3 4B IT (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.04, output: 0.08, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },

    # MiniMax Models
    "minimax.minimax-m2" => %Model{
      id: "minimax.minimax-m2",
      name: "MiniMax M2 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_608,
      max_tokens: 128_000
    },
    "minimax.minimax-m2.1" => %Model{
      id: "minimax.minimax-m2.1",
      name: "MiniMax M2.1 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.3, output: 1.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },

    # Moonshot Models
    "moonshot.kimi-k2-thinking" => %Model{
      id: "moonshot.kimi-k2-thinking",
      name: "Kimi K2 Thinking (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },
    "moonshotai.kimi-k2.5" => %Model{
      id: "moonshotai.kimi-k2.5",
      name: "Kimi K2.5 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 0.6, output: 3.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 256_000
    },

    # NVIDIA Models
    "nvidia.nemotron-nano-12b-v2" => %Model{
      id: "nvidia.nemotron-nano-12b-v2",
      name: "NVIDIA Nemotron Nano 12B v2 VL BF16 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.2, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "nvidia.nemotron-nano-9b-v2" => %Model{
      id: "nvidia.nemotron-nano-9b-v2",
      name: "NVIDIA Nemotron Nano 9B v2 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.06, output: 0.23, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },

    # OpenAI GPT OSS Models
    "openai.gpt-oss-120b-1:0" => %Model{
      id: "openai.gpt-oss-120b-1:0",
      name: "GPT OSS 120B (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "openai.gpt-oss-20b-1:0" => %Model{
      id: "openai.gpt-oss-20b-1:0",
      name: "GPT OSS 20B (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.07, output: 0.3, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "openai.gpt-oss-safeguard-120b" => %Model{
      id: "openai.gpt-oss-safeguard-120b",
      name: "GPT OSS Safeguard 120B (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },
    "openai.gpt-oss-safeguard-20b" => %Model{
      id: "openai.gpt-oss-safeguard-20b",
      name: "GPT OSS Safeguard 20B (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.07, output: 0.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4096
    },

    # Qwen Models
    "qwen.qwen3-235b-a22b-2507-v1:0" => %Model{
      id: "qwen.qwen3-235b-a22b-2507-v1:0",
      name: "Qwen3 235B A22B 2507 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.22, output: 0.88, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 131_072
    },
    "qwen.qwen3-32b-v1:0" => %Model{
      id: "qwen.qwen3-32b-v1:0",
      name: "Qwen3 32B (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 16_384,
      max_tokens: 16_384
    },
    "qwen.qwen3-coder-30b-a3b-v1:0" => %Model{
      id: "qwen.qwen3-coder-30b-a3b-v1:0",
      name: "Qwen3 Coder 30B A3B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_144,
      max_tokens: 131_072
    },
    "qwen.qwen3-coder-480b-a35b-v1:0" => %Model{
      id: "qwen.qwen3-coder-480b-a35b-v1:0",
      name: "Qwen3 Coder 480B A35B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.22, output: 1.8, cache_read: 0.0, cache_write: 0.0},
      context_window: 131_072,
      max_tokens: 65_536
    },
    "qwen.qwen3-next-80b-a3b" => %Model{
      id: "qwen.qwen3-next-80b-a3b",
      name: "Qwen3 Next 80B A3B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.14, output: 1.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_000,
      max_tokens: 262_000
    },
    "qwen.qwen3-vl-235b-a22b" => %Model{
      id: "qwen.qwen3-vl-235b-a22b",
      name: "Qwen3 VL 235B A22B Instruct (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.3, output: 1.5, cache_read: 0.0, cache_write: 0.0},
      context_window: 262_000,
      max_tokens: 262_000
    },

    # Writer Models
    "writer.palmyra-x4-v1:0" => %Model{
      id: "writer.palmyra-x4-v1:0",
      name: "Palmyra X4 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 122_880,
      max_tokens: 8192
    },
    "writer.palmyra-x5-v1:0" => %Model{
      id: "writer.palmyra-x5-v1:0",
      name: "Palmyra X5 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 6.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 1_040_000,
      max_tokens: 8192
    },

    # ZAI Models
    "zai.glm-4.7" => %Model{
      id: "zai.glm-4.7",
      name: "GLM-4.7 (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.6, output: 2.2, cache_read: 0.0, cache_write: 0.0},
      context_window: 204_800,
      max_tokens: 131_072
    },
    "zai.glm-4.7-flash" => %Model{
      id: "zai.glm-4.7-flash",
      name: "GLM-4.7 Flash (Bedrock)",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.us-east-1.amazonaws.com",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 0.07, output: 0.4, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 131_072
    },
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

  @doc "Returns all AmazonBedrock model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
