defmodule LemonAi.Models.Discovery do
  @moduledoc """
  Runtime model discovery for OpenAI-compatible and Ollama endpoints.

  `discover/3` lists the models an endpoint serves and returns them as
  `LemonAi.Types.Model` structs built from `:model_defaults`, so a discovered
  model is immediately usable with `LemonAi.stream/3`. Two endpoint shapes are
  supported:

    * `:openai_models` - `GET {base_url}/models` (`{"data": [{"id": ...}]}`).
      Context length is read from `context_length`, `context_window`,
      `max_model_len` (vLLM) or `top_provider.context_length` when present.
    * `:ollama` - native `GET {root}/api/tags`, where `root` is `base_url`
      without its `/v1` suffix, plus a bounded `POST {root}/api/show` per model
      for context length and `thinking`/`vision` capabilities. When the native
      listing fails, falls back to `GET {root}/v1/models`. Models use the
      OpenAI-compatible `{root}/v1` base URL.

  Results are cached in `LemonAi.ModelCache` keyed by
  `{kind, provider, base_url}` (default TTL five minutes). The most recent
  successful listing per provider is also indexed so `LemonAi.Models.get_model/2`
  can return discovered metadata without network access. Requests are bounded
  by `:timeout_ms` and never retried; failures are returned, never raised, and
  are not cached.

  ## Options

    * `:api_key` - sent as `Authorization: Bearer` when present.
    * `:provider` - `Model.provider` for results (atom or binary).
    * `:api` - `:openai_completions` (default) or `:openai_responses`.
    * `:headers` - extra request headers.
    * `:timeout_ms` - connect/receive timeout per request (default 5000).
    * `:req_options` - extra `Req` options (e.g. a `Req.Test` plug).
    * `:ttl_ms` - cache freshness window (default 300000).
    * `:force_refresh` - bypass a fresh cache entry.
    * `:model_defaults` - `Model` fields every discovered model starts from.
  """

  alias LemonAi.ModelCache
  alias LemonAi.Types.{Model, ModelCost}

  @type kind :: :openai_models | :ollama

  @kinds [:openai_models, :ollama]
  @apis [:openai_completions, :openai_responses]
  @ttl_ms 300_000
  @timeout_ms 5_000
  @default_context_window 128_000
  @default_max_tokens 16_384
  @ollama_show_concurrency 8
  @ollama_show_limit 64
  @model_fields Model.__struct__() |> Map.from_struct() |> Map.keys()

  @spec discover(kind(), String.t(), keyword()) :: {:ok, [Model.t()]} | {:error, term()}
  def discover(kind, base_url, opts \\ [])

  def discover(kind, base_url, opts)
      when kind in @kinds and is_binary(base_url) and is_list(opts) do
    with {:ok, base_url} <- normalize_base_url(base_url),
         {:ok, api} <- api_option(opts) do
      provider = Keyword.get(opts, :provider)
      key = {kind, provider, base_url}

      case cached(key, opts) do
        {:ok, models} ->
          {:ok, models}

        :miss ->
          with {:ok, models} <- fetch(kind, base_url, Keyword.put(opts, :api, api)) do
            cache_write(key, provider, models)
            {:ok, models}
          end
      end
    end
  rescue
    error -> {:error, {:discovery_failed, Exception.message(error)}}
  catch
    :exit, _ -> {:error, :discovery_failed}
  end

  def discover(kind, _base_url, _opts) when kind not in @kinds,
    do: {:error, {:unsupported_discovery_kind, kind}}

  def discover(_kind, _base_url, _opts), do: {:error, :invalid_base_url}

  @doc """
  The most recently discovered model `model_id` for `provider`, from cache only
  (stale entries included). Never performs network access.
  """
  @spec cached_model(atom() | String.t(), String.t()) :: Model.t() | nil
  def cached_model(provider, model_id) when is_binary(model_id) do
    Enum.find(cached_models(provider), &(&1.id == model_id))
  end

  @doc "The most recent discovered model list for `provider`, from cache only."
  @spec cached_models(atom() | String.t()) :: [Model.t()]
  def cached_models(provider) do
    case ModelCache.read({:discovered, provider}) do
      {:ok, %{models: models}} when is_list(models) -> models
      _ -> []
    end
  rescue
    ArgumentError -> []
  end

  # ---------------------------------------------------------------------------
  # Fetching
  # ---------------------------------------------------------------------------

  defp fetch(:openai_models, base_url, opts) do
    with {:ok, body} <- get_json(base_url <> "/models", opts),
         {:ok, entries} <- openai_entries(body) do
      {:ok, build_models(entries, base_url, opts)}
    end
  end

  defp fetch(:ollama, base_url, opts) do
    root = String.replace_suffix(base_url, "/v1", "")
    openai_base = root <> "/v1"

    case get_json(root <> "/api/tags", opts) do
      {:ok, body} ->
        with {:ok, entries} <- ollama_entries(body) do
          entries = enrich_ollama(entries, root, opts)
          {:ok, build_models(entries, openai_base, opts)}
        end

      {:error, {:authentication_rejected, _}} = error ->
        error

      {:error, _native_error} ->
        fetch(:openai_models, openai_base, opts)
    end
  end

  defp get_json(url, opts), do: request(:get, url, nil, opts)

  defp request(method, url, body, opts) do
    timeout = timeout_ms(opts)

    request_opts =
      opts
      |> Keyword.get(:req_options, [])
      |> Keyword.merge(
        method: method,
        url: url,
        headers: request_headers(opts),
        connect_options: [timeout: timeout],
        receive_timeout: timeout,
        retry: false
      )
      |> then(fn req_opts -> if body, do: Keyword.put(req_opts, :json, body), else: req_opts end)

    case Req.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        decode_body(body)

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, {:authentication_rejected, status}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} ->
        {:error, :transport_failure}
    end
  end

  defp decode_body(body) when is_map(body) or is_list(body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_discovery_response}
    end
  end

  defp decode_body(_), do: {:error, :invalid_discovery_response}

  defp request_headers(opts) do
    auth =
      case Keyword.get(opts, :api_key) do
        key when is_binary(key) and key != "" -> [{"authorization", "Bearer " <> key}]
        _ -> []
      end

    extra =
      opts
      |> Keyword.get(:headers, %{})
      |> Enum.map(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)

    [{"accept", "application/json"} | auth] ++ extra
  end

  # ---------------------------------------------------------------------------
  # Response shapes
  # ---------------------------------------------------------------------------

  defp openai_entries(%{"data" => data}) when is_list(data), do: {:ok, openai_ids(data)}
  defp openai_entries(data) when is_list(data), do: {:ok, openai_ids(data)}
  defp openai_entries(_), do: {:error, :invalid_discovery_response}

  defp openai_ids(data) do
    data
    |> Enum.flat_map(fn
      %{"id" => id} = entry when is_binary(id) and id != "" ->
        [
          %{
            id: id,
            name: string_field(entry, "name"),
            context_window:
              positive_integer(
                entry["context_length"] || entry["context_window"] || entry["max_model_len"] ||
                  get_in_map(entry, ["top_provider", "context_length"])
              ),
            max_tokens:
              positive_integer(
                entry["max_completion_tokens"] ||
                  get_in_map(entry, ["top_provider", "max_completion_tokens"])
              )
          }
        ]

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp ollama_entries(%{"models" => models}) when is_list(models) do
    entries =
      models
      |> Enum.flat_map(fn
        %{} = entry ->
          case string_field(entry, "model") || string_field(entry, "name") do
            nil -> []
            id -> [%{id: id, name: string_field(entry, "name")}]
          end

        _ ->
          []
      end)
      |> Enum.uniq_by(& &1.id)

    {:ok, entries}
  end

  defp ollama_entries(_), do: {:error, :invalid_discovery_response}

  # `/api/show` adds context length and capabilities. It is best effort: a
  # failing or slow lookup leaves the defaults in place.
  defp enrich_ollama(entries, root, opts) when length(entries) <= @ollama_show_limit do
    timeout = timeout_ms(opts)

    entries
    |> Task.async_stream(
      fn entry ->
        case request(:post, root <> "/api/show", %{"model" => entry.id}, opts) do
          {:ok, %{} = show} -> Map.merge(entry, ollama_show_metadata(show))
          _ -> entry
        end
      end,
      max_concurrency: @ollama_show_concurrency,
      timeout: timeout + 1_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(entries)
    |> Enum.map(fn
      {{:ok, entry}, _original} -> entry
      {_failed, original} -> original
    end)
  end

  defp enrich_ollama(entries, _root, _opts), do: entries

  defp ollama_show_metadata(show) do
    context =
      case show["model_info"] do
        %{} = info ->
          Enum.find_value(info, fn {key, value} ->
            if is_binary(key) and
                 (String.ends_with?(key, ".context_length") or String.ends_with?(key, ".num_ctx") or
                    String.ends_with?(key, ".context_window")),
               do: positive_integer(value)
          end)

        _ ->
          nil
      end

    capabilities =
      case show["capabilities"] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> nil
      end

    %{context_window: context}
    |> then(fn meta ->
      if capabilities do
        meta
        |> Map.put(:reasoning, "thinking" in capabilities)
        |> Map.put(:input, if("vision" in capabilities, do: [:text, :image], else: [:text]))
      else
        meta
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Model construction
  # ---------------------------------------------------------------------------

  defp build_models(entries, base_url, opts) do
    defaults = model_defaults(opts)

    entries
    |> Enum.map(fn entry ->
      fields =
        entry
        |> Map.take([:context_window, :max_tokens, :reasoning, :input])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      %Model{}
      |> struct(defaults)
      |> struct(fields)
      |> Map.merge(%{
        id: entry.id,
        name: entry[:name] || entry.id,
        provider: Keyword.get(opts, :provider, defaults[:provider]),
        api: Keyword.fetch!(opts, :api),
        base_url: base_url
      })
      |> clamp_max_tokens()
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp model_defaults(opts) do
    base = %{
      input: [:text],
      cost: %ModelCost{},
      context_window: @default_context_window,
      max_tokens: @default_max_tokens
    }

    case Keyword.get(opts, :model_defaults) do
      %{} = defaults -> Map.merge(base, Map.take(defaults, @model_fields))
      _ -> base
    end
  end

  defp clamp_max_tokens(%Model{context_window: context, max_tokens: max} = model)
       when is_integer(context) and context > 0 and is_integer(max) and max > context,
       do: %{model | max_tokens: context}

  defp clamp_max_tokens(model), do: model

  # ---------------------------------------------------------------------------
  # Cache and option helpers
  # ---------------------------------------------------------------------------

  defp cached(key, opts) do
    if Keyword.get(opts, :force_refresh, false) do
      :miss
    else
      case ModelCache.read(key, Keyword.get(opts, :ttl_ms, @ttl_ms)) do
        {:ok, %{fresh: true, authoritative: true, models: models}} -> {:ok, models}
        _ -> :miss
      end
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_write(key, provider, models) do
    ModelCache.write(key, models, authoritative: true)
    if provider, do: ModelCache.write({:discovered, provider}, models, authoritative: true)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp normalize_base_url(base_url) do
    trimmed = base_url |> String.trim() |> String.trim_trailing("/")

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, trimmed}

      _ ->
        {:error, :invalid_base_url}
    end
  end

  defp api_option(opts) do
    case Keyword.get(opts, :api, :openai_completions) do
      api when api in @apis -> {:ok, api}
      other -> {:error, {:unsupported_api, other}}
    end
  end

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @timeout_ms
    end
  end

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp get_in_map(map, [key | rest]) do
    case Map.get(map, key) do
      %{} = nested when rest != [] -> get_in_map(nested, rest)
      value when rest == [] -> value
      _ -> nil
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(value) when is_float(value) and value > 0, do: trunc(value)
  defp positive_integer(_), do: nil
end
