defmodule Ai.Models.GoogleGeminiCLI do
  @moduledoc """
  Model definitions for the GoogleGeminiCLI provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
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

  @doc "Returns all GoogleGeminiCLI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
