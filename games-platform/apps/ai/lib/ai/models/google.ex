defmodule Ai.Models.Google do
  @moduledoc """
  Model definitions for the Google provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
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
    },
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

  # Models that belong to the :google_antigravity virtual provider.
  # These include models from @models tagged with provider: :google_antigravity
  # plus additional antigravity-only models that don't appear in the Google
  # Generative AI catalog.
  @antigravity_models Map.merge(
                        Map.filter(@models, fn {_id, model} ->
                          model.provider == :google_antigravity
                        end),
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

  @doc "Returns all Google model definitions as a map (both :google and :google_antigravity providers)."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models

  @doc "Returns Google Antigravity model definitions as a map."
  @spec antigravity_models() :: %{String.t() => Model.t()}
  def antigravity_models, do: @antigravity_models
end
