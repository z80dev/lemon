defmodule Ai.Models.Mistral do
  @moduledoc """
  Model definitions for the Mistral provider.

  This module is auto-extracted from `Ai.Models` as part of the
  per-provider decomposition (Debt Phase 5, M2).
  """

  alias Ai.Types.{Model, ModelCost}

  @models %{
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
    },
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

  @doc "Returns all Mistral model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
