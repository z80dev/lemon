defmodule LemonAi.Models.OpenAI do
  @moduledoc """
  Model definitions for the OpenAI provider.

  The catalog is data: `priv/models/open_ai.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.

  `codex_models/0` exposes only the ChatGPT OAuth models declared by the
  reference catalog, with their own limits and service-tier pricing. OAuth
  subscription access does not imply zero token cost in usage estimates.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("open_ai.json")
  @models Catalog.load!("open_ai.json")

  # Source: oh-my-pi/packages/catalog/src/models.json, openai-codex (chat
  # models only). The ChatGPT surface has its own context windows and prices,
  # so entries are declared whole instead of inheriting direct-API metadata.
  # Specs: {id, name, context_window, {input, output, cache_read, cache_write},
  # long_context | nil}. Long-context rates apply above 272k input tokens.
  @codex_priority_cost 2.5

  @codex_specs [
    {"gpt-5.6-luna", "GPT-5.6 Luna", 1_000_000, {0.2, 1.2, 0.02, 0.25}, {0.4, 1.8, 0.04, 0.5}},
    {"gpt-5.6-sol", "GPT-5.6 Sol", 1_000_000, {4, 20, 0.4, 5}, {10, 45, 1, 12.5}},
    {"gpt-5.6-terra", "GPT-5.6 Terra", 1_000_000, {2, 12, 0.2, 2.5}, {4, 18, 0.4, 5}},
    {"gpt-6-astra", "GPT-6 Astra", 272_000, {10, 50, 1, 0}, nil},
    {"gpt-6-luna", "GPT-6 Luna", 272_000, {0.1, 0.5, 0.01, 0}, nil},
    {"gpt-6-sol", "GPT-6 Sol", 272_000, {2, 10, 0.2, 0}, nil},
    {"gpt-6.1-sol", "GPT-6.1 Sol", 500_000, {2, 10, 0.1, 0}, nil},
    {"gpt-daybreak-blue-latest", "Daybreak Blue", 272_000, {5, 30, 0.5, 6.25}, nil}
  ]

  @codex_models Map.new(@codex_specs, fn {id, name, context_window, costs, long_context} ->
                  {input, output, cache_read, cache_write} = costs

                  long_context =
                    case long_context do
                      nil ->
                        nil

                      {lc_input, lc_output, lc_cache_read, lc_cache_write} ->
                        %{
                          input_threshold: 272_000,
                          input: lc_input,
                          output: lc_output,
                          cache_read: lc_cache_read,
                          cache_write: lc_cache_write
                        }
                    end

                  {id,
                   %Model{
                     id: id,
                     name: name,
                     api: :openai_codex_responses,
                     provider: :openai_codex,
                     base_url: "https://chatgpt.com",
                     reasoning: true,
                     adaptive_thinking: false,
                     reasoning_efforts: [:low, :medium, :high, :xhigh],
                     input: [:text, :image],
                     cost: %LemonAi.Types.ModelCost{
                       input: input,
                       output: output,
                       cache_read: cache_read,
                       cache_write: cache_write,
                       long_context: long_context
                     },
                     context_window: context_window,
                     max_tokens: 128_000,
                     service_tier_cost: %{"flex" => 0.5, "priority" => @codex_priority_cost}
                   }}
                end)

  @doc "Returns all OpenAI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models

  @doc "Returns the supported ChatGPT OAuth model catalog."
  @spec codex_models() :: %{String.t() => Model.t()}
  def codex_models, do: @codex_models
end
