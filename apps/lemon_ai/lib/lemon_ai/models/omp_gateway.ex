defmodule LemonAi.Models.OmpGateway do
  @moduledoc """
  Models served by an omp auth gateway (`omp auth-gateway serve`).

  The gateway is a credential-holding forward proxy: it accepts OpenAI Chat
  Completions (`/v1/chat/completions`), Anthropic Messages (`/v1/messages`) and
  OpenAI Responses (`/v1/responses`) requests, resolves the provider credential
  from omp's auth broker and dispatches through omp's own provider logic. Lemon
  holds only the gateway bearer, never a provider credential.

  Gateway model ids are omp `provider/id` pairs (`anthropic/claude-sonnet-4-5`).
  Each model uses the wire closest to its native API so provider features
  survive the translation: Anthropic Messages models use `/v1/messages`,
  Responses-family models (OpenAI, Codex, Azure) use `/v1/responses`, every
  other model uses Chat Completions. Reasoning flags, pricing and limits come
  from Lemon's own catalog entry for the same provider and id when one exists;
  the gateway's `/v1/models` row supplies its API, name, limits and input
  modalities. Rows for non-chat kinds (`judge`, `image`, `tts`, ...) are
  skipped.

  `base_url` is the gateway's OpenAI-compatible root (`http://host:4000/v1`);
  Anthropic Messages models use the same server without `/v1` because the
  Anthropic wire module appends `/v1/messages` itself. Requests carry
  `x-omp-app: lemon` and `x-omp-hostname` so gateway usage attribution names
  this client; the gateway does not forward them upstream.
  """

  alias LemonAi.Types.{Model, ModelCost}

  @provider :omp_gateway
  @default_context_window 128_000
  @default_max_tokens 16_384

  # omp provider ids whose Lemon catalog provider is not the dashed→underscored id.
  @catalog_provider_overrides %{
    "kimi-code" => :kimi_coding,
    "kimi-code-global" => :kimi_coding,
    "moonshot" => :kimi,
    "opencode-zen" => :opencode
  }

  @responses_apis ~w(openai-responses openai-codex-responses azure-openai-responses)

  @completions_compat %{
    supports_store: false,
    supports_developer_role: false,
    supports_usage_in_streaming: true,
    max_tokens_field: "max_tokens"
  }

  @doc "Lemon wire API for a gateway `/v1/models` row `api` value."
  @spec wire_api(term()) :: :anthropic_messages | :openai_responses | :openai_completions
  def wire_api("anthropic-messages"), do: :anthropic_messages
  def wire_api(api) when api in @responses_apis, do: :openai_responses
  def wire_api(_), do: :openai_completions

  @doc """
  The Lemon catalog provider for an omp provider id, or `nil`. Never creates
  atoms: candidates come from `LemonAi.Models.get_providers/0`.
  """
  @spec catalog_provider(String.t()) :: atom() | nil
  def catalog_provider(omp_provider) when is_binary(omp_provider) do
    case Map.fetch(@catalog_provider_overrides, omp_provider) do
      {:ok, provider} ->
        provider

      :error ->
        normalized = String.replace(omp_provider, "-", "_")

        Enum.find(LemonAi.Models.get_providers(), fn provider ->
          provider != @provider and Atom.to_string(provider) == normalized
        end)
    end
  end

  def catalog_provider(_), do: nil

  @doc """
  The request base URL for a wire API given the gateway's `/v1` root:
  Anthropic Messages uses the server root (its wire module appends
  `/v1/messages`), every other wire the `/v1` root. Idempotent.
  """
  @spec wire_base_url(atom(), String.t()) :: String.t()
  def wire_base_url(:anthropic_messages, base_url) do
    base_url |> String.trim_trailing("/") |> String.replace_suffix("/v1", "")
  end

  def wire_base_url(_api, base_url), do: String.trim_trailing(base_url, "/")

  @doc """
  Builds the model for gateway id `id`.

  `row` is the gateway's `/v1/models` entry when known (`nil` synthesizes from
  Lemon's catalog and the id's provider prefix). `base_url` is the gateway's
  `/v1` root. `overrides` may replace any model field except identity, wire
  API and `base_url` (derived per wire API); override `headers` merge over the
  attribution headers.
  """
  @spec model(String.t(), map() | nil, String.t(), map()) :: Model.t()
  def model(id, row, base_url, overrides \\ %{}) when is_binary(id) and is_binary(base_url) do
    catalog = catalog_model(id)
    api = row_api(row) || catalog_api(catalog) || :openai_completions

    base =
      case catalog do
        %Model{} = catalog ->
          %{catalog | compat: if(catalog.api == api, do: catalog.compat)}

        nil ->
          %Model{
            reasoning: false,
            input: [:text],
            cost: %ModelCost{},
            context_window: @default_context_window,
            max_tokens: @default_max_tokens
          }
      end

    %{
      base
      | id: id,
        name: row_name(row) || (catalog && catalog.name) || id,
        api: api,
        provider: @provider,
        base_url: wire_base_url(api, base_url),
        input: row_input(row) || base.input,
        context_window: positive(row && row["context_length"]) || base.context_window,
        max_tokens: positive(row && row["max_output_tokens"]) || base.max_tokens,
        headers: Map.merge(attribution_headers(), string_map(Map.get(overrides, :headers)))
    }
    |> put_wire_compat()
    |> struct(Map.drop(overrides, [:__struct__, :base_url, :api, :provider, :id, :headers]))
    |> clamp_max_tokens()
  end

  @doc """
  Models from a gateway `/v1/models` response body; malformed and non-chat
  rows are skipped. `overrides` applies to every model (see `model/4`).
  """
  @spec models_from_listing(term(), String.t(), map()) :: {:ok, [Model.t()]} | {:error, atom()}
  def models_from_listing(%{"data" => rows}, base_url, overrides) when is_list(rows) do
    models =
      rows
      |> Enum.filter(&chat_row?/1)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.map(&model(&1["id"], &1, base_url, overrides))
      |> Enum.sort_by(& &1.id)

    {:ok, models}
  end

  def models_from_listing(_body, _base_url, _overrides), do: {:error, :invalid_discovery_response}

  @doc "Request headers that attribute gateway usage to this Lemon host."
  @spec attribution_headers() :: %{String.t() => String.t()}
  def attribution_headers do
    case :inet.gethostname() do
      {:ok, host} -> %{"x-omp-app" => "lemon", "x-omp-hostname" => List.to_string(host)}
      _ -> %{"x-omp-app" => "lemon"}
    end
  end

  defp chat_row?(%{"id" => id} = row) when is_binary(id) and id != "",
    do: row["kind"] in [nil, "chat"]

  defp chat_row?(_), do: false

  defp catalog_model(id) do
    with [omp_provider, model_id] when model_id != "" <- String.split(id, "/", parts: 2),
         provider when not is_nil(provider) <- catalog_provider(omp_provider) do
      LemonAi.Models.known_model(provider, model_id)
    else
      _ -> nil
    end
  end

  defp row_api(%{"api" => api}) when is_binary(api), do: wire_api(api)
  defp row_api(_), do: nil

  defp catalog_api(%Model{api: :anthropic_messages}), do: :anthropic_messages

  defp catalog_api(%Model{api: api})
       when api in [:openai_responses, :openai_codex_responses, :azure_openai_responses],
       do: :openai_responses

  defp catalog_api(%Model{}), do: :openai_completions
  defp catalog_api(nil), do: nil

  defp row_name(%{"display_name" => name}) when is_binary(name) and name != "", do: name
  defp row_name(_), do: nil

  defp row_input(%{"input_modalities" => modalities}) when is_list(modalities) do
    case Enum.flat_map(modalities, fn
           "text" -> [:text]
           "image" -> [:image]
           _ -> []
         end) do
      [] -> nil
      input -> Enum.uniq(input)
    end
  end

  defp row_input(_), do: nil

  # Chat Completions is a translation surface for every model; keep the request
  # to widely accepted fields and send reasoning effort only to reasoning models.
  defp put_wire_compat(%Model{api: :openai_completions, compat: nil} = model),
    do: %{
      model
      | compat: Map.put(@completions_compat, :supports_reasoning_effort, model.reasoning)
    }

  defp put_wire_compat(model), do: model

  defp string_map(%{} = map), do: map
  defp string_map(_), do: %{}

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(value) when is_float(value) and value > 0, do: trunc(value)
  defp positive(_), do: nil

  defp clamp_max_tokens(%Model{context_window: context, max_tokens: max} = model)
       when is_integer(context) and context > 0 and is_integer(max) and max > context,
       do: %{model | max_tokens: context}

  defp clamp_max_tokens(model), do: model
end
