defmodule LemonAi.Models.KimiCodeDiscovery do
  @moduledoc """
  Kimi Code model discovery from `GET {base_url}/v1/models`, cached in the
  supervised `LemonAi.ModelCache`.

  Mirrors omp's `kimiCodeModelManagerOptions`: each listed row becomes a
  `kimi_coding` model on the Anthropic Messages transport at `base_url`. The
  row supplies the display name, context window (`context_length`), image
  input (`supports_image_in`), reasoning (`supports_thinking_type`, else
  `supports_reasoning`) and effort levels (`think_efforts.valid_efforts` when
  `think_efforts.support` is true; such models use adaptive thinking). The
  listing carries no output limit, so `max_tokens` comes from the documented
  per-family caps (`k3`/`k3-256k` 131072, `kimi-for-coding`/`-highspeed`
  32768), then the bundled catalog entry, then 32000. Rows for ids in the
  bundled catalog keep its pricing and compatibility flags and never lose
  image input the catalog grants.

  Requests carry `Authorization: Bearer <credential>` plus the Kimi CLI
  fingerprint, are bounded by `:timeout_ms`, and are never retried or
  redirected. Errors carry only an atom or an HTTP status, never the
  credential or response body. Results are cached by a digest of the account
  identity (the JWT `user_id`/`sub` claim, else the credential) and the
  endpoint; the cache key holds neither.

  Options: `:access_token` (required), `:base_url` (default
  `https://api.kimi.com/coding`), `:timeout_ms` (default 5000), `:ttl_ms`
  (default 300000), `:force_refresh`, `:req_options`.
  """

  alias LemonAi.{ModelCache, Models}
  alias LemonAi.Auth.{KimiCodeOAuth, OAuthFlow}
  alias LemonAi.Types.{Model, ModelCost}

  @provider :kimi_coding
  @base_url "https://api.kimi.com/coding"
  @ttl_ms 300_000
  @timeout_ms 5_000
  @default_context_window 262_144
  @default_max_tokens 32_000
  @family_max_tokens %{
    "k3" => 131_072,
    "k3-256k" => 131_072,
    "kimi-for-coding" => 32_768,
    "kimi-for-coding-highspeed" => 32_768
  }
  @efforts [
    {"none", :none},
    {"minimal", :minimal},
    {"low", :low},
    {"medium", :medium},
    {"high", :high},
    {"xhigh", :xhigh},
    {"max", :max}
  ]

  @type option ::
          {:access_token, String.t()}
          | {:base_url, String.t() | nil}
          | {:timeout_ms, pos_integer()}
          | {:ttl_ms, non_neg_integer()}
          | {:force_refresh, boolean()}
          | {:req_options, keyword()}

  @doc "List the models the Kimi Code account serves."
  @spec discover([option()]) :: {:ok, [Model.t()]} | {:error, term()}
  def discover(opts \\ []) do
    token = Keyword.get(opts, :access_token)
    base_url = normalize_base_url(Keyword.get(opts, :base_url))

    if is_binary(token) and token != "" do
      key = cache_key(token, base_url)

      case cached(key, opts) do
        {:ok, models} ->
          {:ok, models}

        :miss ->
          with {:ok, models} <- fetch(base_url, token, opts) do
            ModelCache.write(key, models, authoritative: true)
            {:ok, models}
          end
      end
    else
      {:error, :missing_kimi_code_credentials}
    end
  rescue
    ArgumentError -> {:error, :discovery_cache_unavailable}
  end

  @doc "A discovered model for this credential and endpoint, from cache only (stale entries included)."
  @spec cached_model(String.t(), [option()]) :: Model.t() | nil
  def cached_model(model_id, opts) when is_binary(model_id) do
    token = Keyword.get(opts, :access_token)

    if is_binary(token) and token != "" do
      case ModelCache.read(cache_key(token, normalize_base_url(Keyword.get(opts, :base_url)))) do
        {:ok, %{models: models}} -> Enum.find(models, &(&1.id == model_id))
        _ -> nil
      end
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Build models from a `/v1/models` response body (`{"data": [...]}` or a bare
  list). Rows without a string id are skipped.
  """
  @spec models_from_listing(term(), String.t()) :: {:ok, [Model.t()]} | {:error, term()}
  def models_from_listing(body, base_url \\ @base_url)

  def models_from_listing(%{"data" => rows}, base_url), do: models_from_listing(rows, base_url)

  def models_from_listing(rows, base_url) when is_list(rows) do
    models =
      rows
      |> Enum.flat_map(fn
        %{"id" => id} = row when is_binary(id) and id != "" -> [model(row, base_url)]
        _ -> []
      end)
      |> Enum.uniq_by(& &1.id)

    {:ok, models}
  end

  def models_from_listing(_body, _base_url), do: {:error, :invalid_discovery_response}

  @doc false
  def normalize_base_url(url) when is_binary(url) do
    case String.trim(url) |> String.trim_trailing("/") do
      "" -> @base_url
      trimmed -> trimmed
    end
  end

  def normalize_base_url(_), do: @base_url

  defp model(%{"id" => id} = row, base_url) do
    base = Models.get_model(@provider, id) || template(id)
    efforts = efforts(row)
    reasoning = reasoning?(row, base)

    input =
      if row["supports_image_in"] == true or :image in base.input,
        do: [:text, :image],
        else: [:text]

    thinking =
      cond do
        not reasoning -> %{adaptive_thinking: false, reasoning_efforts: []}
        efforts != [] -> %{adaptive_thinking: true, reasoning_efforts: efforts}
        true -> %{}
      end

    context_window = positive_integer(row["context_length"]) || base.context_window

    %{
      base
      | name: string(row["display_name"]) || base.name,
        base_url: base_url,
        reasoning: reasoning,
        input: input,
        context_window: context_window,
        max_tokens: min(Map.get(@family_max_tokens, id, base.max_tokens), context_window)
    }
    |> Map.merge(thinking)
  end

  defp template(id) do
    %Model{
      id: id,
      name: id,
      api: :anthropic_messages,
      provider: @provider,
      base_url: @base_url,
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: @default_context_window,
      max_tokens: @default_max_tokens,
      headers: %{},
      compat: %{anthropic_session_user_id: true}
    }
  end

  defp reasoning?(row, base) do
    case row["supports_thinking_type"] do
      type when type in ["only", "both"] -> true
      "no" -> false
      _ -> row["supports_reasoning"] == true or base.reasoning
    end
  end

  defp efforts(%{"think_efforts" => %{"support" => true, "valid_efforts" => valid}})
       when is_list(valid),
       do: for({name, effort} <- @efforts, name in valid, do: effort)

  defp efforts(_row), do: []

  defp fetch(base_url, token, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    request_options =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        headers: [
          {"authorization", "Bearer " <> token},
          {"accept", "application/json"} | KimiCodeOAuth.request_headers()
        ],
        connect_options: [timeout: timeout],
        receive_timeout: timeout,
        retry: false,
        redirect: false
      )

    case Req.get(base_url <> "/v1/models", request_options) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        models_from_listing(decode(body), base_url)

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, {:authentication_rejected, status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} ->
        {:error, :transport_failure}
    end
  end

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp decode(body), do: body

  defp cached(key, opts) do
    if Keyword.get(opts, :force_refresh, false) do
      :miss
    else
      case ModelCache.read(key, Keyword.get(opts, :ttl_ms, @ttl_ms)) do
        {:ok, %{fresh: true, authoritative: true, models: models}} -> {:ok, models}
        _ -> :miss
      end
    end
  end

  # OAuth access tokens rotate; key their cache entry by the account claim so
  # a refreshed token reuses the account's listing.
  defp cache_key(token, base_url) do
    identity =
      case OAuthFlow.jwt_claims(token) do
        %{"user_id" => id} when is_binary(id) and id != "" -> {:account, id}
        %{"sub" => id} when is_binary(id) and id != "" -> {:account, id}
        _ -> {:credential, token}
      end

    {@provider, :crypto.hash(:sha256, :erlang.term_to_binary(identity)),
     :crypto.hash(:sha256, base_url)}
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil
end
