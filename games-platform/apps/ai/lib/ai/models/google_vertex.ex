defmodule Ai.Models.GoogleVertex do
  @moduledoc """
  Model definitions for the GoogleVertex provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
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

  @doc "Returns all GoogleVertex model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
