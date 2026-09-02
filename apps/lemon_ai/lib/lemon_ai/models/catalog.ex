defmodule LemonAi.Models.Catalog do
  @moduledoc """
  Reads a provider's model catalog from `priv/models/<name>.json`.

  A catalog is data: one JSON object per provider, keyed by the model id the
  registry answers to (an alias key may differ from the entry's own `id`),
  each entry carrying the fields of `LemonAi.Types.Model` with `api`,
  `provider` and `input` as strings and `cost` as a `LemonAi.Types.ModelCost`
  object. The provider modules under `LemonAi.Models.*` load their file at
  compile time:

      @external_resource LemonAi.Models.Catalog.path("deep_seek.json")
      @models LemonAi.Models.Catalog.load!("deep_seek.json")
      def models, do: @models

  so a catalog edit recompiles the module and the registry keeps its
  compile-time shape. Editing a model or its price is editing the JSON file;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Types.{Model, ModelCost}

  @priv_models Path.expand("../../../priv/models", __DIR__)

  @apis %{
    "anthropic_messages" => :anthropic_messages,
    "azure_openai_responses" => :azure_openai_responses,
    "bedrock_converse_stream" => :bedrock_converse_stream,
    "google_gemini_cli" => :google_gemini_cli,
    "google_generative_ai" => :google_generative_ai,
    "google_vertex" => :google_vertex,
    "mistral_conversations" => :mistral_conversations,
    "openai_completions" => :openai_completions,
    "openai_responses" => :openai_responses
  }

  @providers %{
    "amazon_bedrock" => :amazon_bedrock,
    "anthropic" => :anthropic,
    "azure_openai_responses" => :azure_openai_responses,
    "cerebras" => :cerebras,
    "deepseek" => :deepseek,
    "fireworks" => :fireworks,
    "github_copilot" => :github_copilot,
    "google" => :google,
    "google_antigravity" => :google_antigravity,
    "google_gemini_cli" => :google_gemini_cli,
    "google_vertex" => :google_vertex,
    "groq" => :groq,
    "huggingface" => :huggingface,
    "kimi" => :kimi,
    "kimi_coding" => :kimi_coding,
    "minimax" => :minimax,
    "minimax_cn" => :minimax_cn,
    "mistral" => :mistral,
    "openai" => :openai,
    "opencode" => :opencode,
    "opencode_go" => :opencode_go,
    "openrouter" => :openrouter,
    "qwen" => :qwen,
    "vercel_ai_gateway" => :vercel_ai_gateway,
    "xai" => :xai,
    "zai" => :zai
  }

  @inputs %{"image" => :image, "text" => :text}

  @doc """
  The source path of a catalog file, for `@external_resource`.

  Resolved against the source tree, which is where the compile-time load
  happens; the files also ship in the application's `priv/models`.
  """
  @spec path(String.t()) :: Path.t()
  def path(name) when is_binary(name), do: Path.join(@priv_models, name)

  @doc "Loads a catalog into a map of model key to `LemonAi.Types.Model`."
  @spec load!(String.t()) :: %{String.t() => Model.t()}
  def load!(name) when is_binary(name) do
    source = path(name)

    source
    |> File.read!()
    |> decode!(source)
  end

  @doc false
  @spec decode!(String.t(), String.t()) :: %{String.t() => Model.t()}
  def decode!(json, source) when is_binary(json) and is_binary(source) do
    case Jason.decode!(json) do
      %{} = entries ->
        Map.new(entries, fn {key, entry} -> {key, to_model(key, entry, source)} end)

      other ->
        raise ArgumentError,
              "model catalog #{inspect(source)} must contain a top-level JSON object, got: #{inspect(other)}"
    end
  rescue
    error in Jason.DecodeError ->
      reraise ArgumentError,
              [
                message:
                  "model catalog #{inspect(source)} contains invalid JSON: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp to_model(key, %{"id" => id} = entry, source) when is_binary(id) do
    %Model{
      id: id,
      name: fetch_string!(entry, "name"),
      api: normalize_atom!(:api, Map.fetch!(entry, "api"), @apis),
      provider: normalize_atom!(:provider, Map.fetch!(entry, "provider"), @providers),
      base_url: fetch_string!(entry, "base_url"),
      reasoning: fetch_boolean!(entry, "reasoning"),
      input: to_input(Map.fetch!(entry, "input")),
      cost: to_cost(Map.fetch!(entry, "cost")),
      context_window: fetch_non_neg_integer!(entry, "context_window"),
      max_tokens: fetch_non_neg_integer!(entry, "max_tokens"),
      headers: optional_map!(entry, "headers", %{}),
      compat: optional_map!(entry, "compat", nil)
    }
  rescue
    error in [ArgumentError, KeyError, Protocol.UndefinedError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid model entry #{inspect(key)} in catalog #{inspect(source)}: #{Exception.message(error)}"
              ],
              __STACKTRACE__
  end

  defp to_model(key, entry, source) do
    raise ArgumentError,
          "invalid model entry #{inspect(key)} in catalog #{inspect(source)}: expected an object with a string id, got: #{inspect(entry)}"
  end

  defp to_cost(%{} = cost) do
    %ModelCost{
      input: fetch_non_neg_number!(cost, "input", "cost.input"),
      output: fetch_non_neg_number!(cost, "output", "cost.output"),
      cache_read: fetch_non_neg_number!(cost, "cache_read", "cost.cache_read"),
      cache_write: fetch_non_neg_number!(cost, "cache_write", "cost.cache_write")
    }
  end

  defp to_cost(other),
    do: raise(ArgumentError, "expected cost to be an object, got: #{inspect(other)}")

  defp to_input(input) when is_list(input),
    do: Enum.map(input, &normalize_atom!(:input, &1, @inputs))

  defp to_input(other),
    do: raise(ArgumentError, "expected input to be an array, got: #{inspect(other)}")

  defp fetch_string!(entry, field) do
    case Map.fetch!(entry, field) do
      value when is_binary(value) -> value
      value -> raise ArgumentError, "expected #{field} to be a string, got: #{inspect(value)}"
    end
  end

  defp fetch_boolean!(entry, field) do
    case Map.fetch!(entry, field) do
      value when is_boolean(value) -> value
      value -> raise ArgumentError, "expected #{field} to be a boolean, got: #{inspect(value)}"
    end
  end

  defp fetch_non_neg_integer!(entry, field) do
    case Map.fetch!(entry, field) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError,
              "expected #{field} to be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp fetch_non_neg_number!(entry, field, label) do
    case Map.fetch!(entry, field) do
      value when is_number(value) and value >= 0 -> value
      value -> raise ArgumentError, "expected #{label} to be non-negative, got: #{inspect(value)}"
    end
  end

  defp optional_map!(entry, field, default) do
    case Map.get(entry, field, default) do
      nil when is_nil(default) -> nil
      %{} = value -> value
      value -> raise ArgumentError, "expected #{field} to be an object, got: #{inspect(value)}"
    end
  end

  defp normalize_atom!(field, value, allowed) when is_binary(value) do
    case allowed do
      %{^value => atom} -> atom
      %{} -> raise ArgumentError, "unsupported #{field} value: #{inspect(value)}"
    end
  end

  defp normalize_atom!(field, value, _allowed) do
    raise ArgumentError, "expected #{field} to be a string, got: #{inspect(value)}"
  end
end
