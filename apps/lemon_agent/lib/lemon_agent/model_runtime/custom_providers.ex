defmodule LemonAgent.ModelRuntime.CustomProviders do
  @moduledoc """
  Turns `[providers.<id>]` config tables into `LemonAi.Types.Model` structs.

  A provider id that names neither a `ProviderNames` provider nor a
  `LemonAi.Models` registry provider is a *custom provider* (omp `models.yml`
  parity). Its models keep the config id as a binary `provider`, use the
  allowlisted wire `api`, the configured `base_url`, and provider-level
  `headers` as a case-insensitive baseline under per-model and caller headers.
  `auth = "none"` marks every
  model `compat.allow_missing_api_key`, so OpenAI-compatible wire modules send no
  Authorization header when no key resolves.

  Model ids not listed under a custom provider are synthesized with defaults
  when the provider uses `discovery` or lists no models (any id is accepted, as
  in omp). `discovery = "openai" | "ollama"` additionally lists the endpoint's
  models through `LemonAi.Models.Discovery` for pickers.

  Discovery and cache-only resolution use `Credentials.build_get_api_key/1`
  with the full effective config, selecting the same healthy pool/default
  credential as requests. Pass the full config/settings map to preserve routing;
  a bare providers map has only the single-credential scope.

  On a built-in provider, `models` entries add catalog models or replace the
  catalog entry with the same id; they inherit the provider's catalog wire API
  and base URL unless they override them.

  No atoms are created from config input: wire APIs and input modalities map
  through explicit allowlists.
  """

  alias LemonAi.Providers.RequestHeaders
  alias LemonAi.Models.Presets
  alias LemonAi.Types.{Model, ModelCost}
  alias LemonAgent.ModelRuntime.{Credentials, ProviderNames}
  alias LemonCore.Config.Providers

  @default_context_window 128_000
  @default_max_tokens 16_384

  @typedoc "A provider config table, as resolved by `LemonCore.Config.Providers`."
  @type provider_config :: map()

  @doc """
  Config table for `provider` by exact or normalized (`-`/`_`, case) config key,
  regardless of whether the provider is built in.
  """
  @spec config_for(map() | nil, atom() | String.t() | nil) :: provider_config() | nil
  def config_for(providers_or_cfg, provider) do
    case find_config(providers_or_cfg, provider) do
      {_id, cfg} -> cfg
      nil -> nil
    end
  end

  @doc "`{config_id, config}` when `provider` is a configured custom provider, else `nil`."
  @spec custom_provider(map() | nil, atom() | String.t() | nil) ::
          {String.t(), provider_config()} | nil
  def custom_provider(providers_or_cfg, provider) do
    if builtin?(provider), do: nil, else: find_config(providers_or_cfg, provider)
  end

  @doc "Configured custom providers as `{config_id, config}` pairs, sorted by id."
  @spec custom_providers(map() | nil) :: [{String.t(), provider_config()}]
  def custom_providers(providers_or_cfg) do
    providers_or_cfg
    |> providers_map()
    |> Enum.flat_map(fn
      {id, cfg} when is_map(cfg) ->
        id = to_string(id)
        if builtin?(id), do: [], else: [{id, cfg}]

      _ ->
        []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "True when the provider config declares a keyless endpoint (`auth = \"none\"`)."
  @spec keyless?(provider_config() | nil) :: boolean()
  def keyless?(cfg) when is_map(cfg), do: Providers.canonical_auth(value(cfg, :auth)) == "none"
  def keyless?(_), do: false

  @doc "Provider-level headers with lower-case names and string values only."
  @spec headers(provider_config() | nil) :: %{optional(String.t()) => String.t()}
  def headers(cfg) when is_map(cfg), do: string_headers(value(cfg, :headers))
  def headers(_), do: %{}

  @doc """
  Wire base URL for a custom provider's models: `base_url`, with `/v1`
  appended for Ollama discovery providers configured with the server root
  (Ollama serves its OpenAI-compatible API under `/v1`).
  """
  @spec base_url(provider_config() | nil) :: String.t() | nil
  def base_url(cfg) when is_map(cfg) do
    case non_empty(value(cfg, :base_url)) do
      nil ->
        nil

      url ->
        url = String.trim_trailing(url, "/")

        if discovery_kind(cfg) == :ollama and not String.ends_with?(url, "/v1"),
          do: url <> "/v1",
          else: url
    end
  end

  def base_url(_), do: nil

  @doc "True when `provider` is a `ProviderNames` or `LemonAi.Models` registry provider."
  @spec builtin?(atom() | String.t() | nil) :: boolean()
  def builtin?(provider) do
    not is_nil(ProviderNames.canonical_name(provider)) or not is_nil(registry_provider(provider))
  end

  @doc """
  Resolves `provider` + `model_id` against configured models.

  Custom providers return their listed model, or a synthesized one when the
  provider uses discovery or lists no models. Built-in providers return a
  configured addition/replacement for that id. Dynamic presets additionally
  reuse discovery metadata from the effective credential/endpoint/header scope,
  or synthesize conservative defaults when that scope has not been discovered.
  Static catalog-only ids return `nil` so the caller's registry lookup applies.
  """
  @spec lookup(map() | nil, atom() | String.t() | nil, String.t() | nil) :: Model.t() | nil
  def lookup(_providers_or_cfg, _provider, nil), do: nil

  def lookup(providers_or_cfg, provider, model_id) when is_binary(model_id) do
    case registry_provider(provider) do
      nil -> lookup_custom(providers_or_cfg, provider, model_id)
      registry -> lookup_builtin(providers_or_cfg, provider, registry, model_id)
    end
  end

  @doc """
  Like `lookup/3`, but dynamic built-in presets never synthesize unknown ids.

  Use this for bare-id matching and qualified-selector disambiguation: accepting
  any id for an explicit preset must not capture another provider's selector.
  """
  @spec known_model(map() | nil, atom() | String.t() | nil, String.t() | nil) ::
          Model.t() | nil
  def known_model(_providers_or_cfg, _provider, nil), do: nil

  def known_model(providers_or_cfg, provider, model_id) when is_binary(model_id) do
    case registry_provider(provider) do
      nil -> lookup_custom(providers_or_cfg, provider, model_id)
      registry -> lookup_builtin(providers_or_cfg, provider, registry, model_id, true)
    end
  end

  @doc """
  Every configured model: custom provider models and built-in additions.

  Options:

    * `:discover` - list discovery providers' endpoints (default `false`).
    * `:discovery_opts` - request/cache tuning (`:req_options`, `:timeout_ms`,
      `:ttl_ms`, `:force_refresh`). Model identity, wire API and defaults come
      from the provider config, not discovery option overrides.
  """
  @spec models(map() | nil, keyword()) :: [Model.t()]
  def models(providers_or_cfg, opts \\ []) do
    custom =
      providers_or_cfg
      |> custom_providers()
      |> Enum.flat_map(fn {id, cfg} -> custom_models(providers_or_cfg, id, cfg, opts) end)

    builtin =
      providers_or_cfg
      |> providers_map()
      |> Enum.flat_map(fn
        {id, cfg} when is_map(cfg) -> builtin_additions(to_string(id), cfg)
        _ -> []
      end)

    custom ++ builtin
  end

  @doc "Wire API atom for an allowlisted `api` config value, else `nil`."
  @spec api_atom(term()) :: atom() | nil
  def api_atom(value) do
    case Providers.canonical_api(value) do
      "openai_completions" -> :openai_completions
      "openai_responses" -> :openai_responses
      "anthropic_messages" -> :anthropic_messages
      "google_generative_ai" -> :google_generative_ai
      nil -> nil
    end
  end

  # ---- Custom providers ----

  defp lookup_custom(providers_or_cfg, provider, model_id) do
    with {id, cfg} <- custom_provider(providers_or_cfg, provider) do
      case Enum.find(model_entries(cfg), &(value(&1, :id) == model_id)) do
        nil ->
          if open_model_set?(cfg),
            do:
              cached_discovered_model(providers_or_cfg, id, cfg, model_id) ||
                build_custom_model(id, cfg, %{id: model_id})

        entry ->
          build_custom_model(id, cfg, entry)
      end
    end
  end

  defp custom_models(providers_or_cfg, id, cfg, opts) do
    static = cfg |> model_entries() |> Enum.map(&build_custom_model(id, cfg, &1))
    static = Enum.reject(static, &is_nil/1)

    discovered =
      if Keyword.get(opts, :discover, false),
        do: discover(providers_or_cfg, id, cfg, Keyword.get(opts, :discovery_opts, [])),
        else: []

    # Configured entries win over discovered ones with the same id.
    static_ids = MapSet.new(static, & &1.id)
    static ++ Enum.reject(discovered, &MapSet.member?(static_ids, &1.id))
  end

  # A provider with discovery, or without a models list, accepts any model id.
  defp open_model_set?(cfg), do: discovery_kind(cfg) != nil or model_entries(cfg) == []

  defp build_custom_model(provider_id, cfg, entry) do
    api = api_atom(value(entry, :api) || value(cfg, :api))
    base_url = base_url(cfg)
    id = non_empty(value(entry, :id))

    if api && base_url && id do
      %Model{
        id: id,
        name: non_empty(value(entry, :name)) || id,
        api: api,
        provider: provider_id,
        base_url: base_url,
        reasoning: value(entry, :reasoning) == true,
        input: input_types(value(entry, :input)),
        cost: model_cost(value(entry, :cost)),
        context_window:
          positive_integer(value(entry, :context_window)) || @default_context_window,
        max_tokens: positive_integer(value(entry, :max_tokens)) || @default_max_tokens,
        headers: Map.merge(headers(cfg), string_headers(value(entry, :headers))),
        compat: compat(cfg)
      }
    end
  end

  defp compat(cfg), do: if(keyless?(cfg), do: %{allow_missing_api_key: true})

  defp discover(providers_or_cfg, id, cfg, discovery_opts) do
    kind = discovery_kind(cfg)
    api = api_atom(value(cfg, :api))
    base_url = non_empty(value(cfg, :base_url))

    if kind && api && base_url do
      opts =
        discovery_opts
        |> Keyword.take([:req_options, :force_refresh, :ttl_ms, :timeout_ms])
        |> Keyword.merge(discovery_options(providers_or_cfg, id, cfg))

      case LemonAi.Models.Discovery.discover(kind, base_url, opts) do
        {:ok, models} -> models
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  defp discovered_model_defaults(cfg) do
    %{
      context_window: @default_context_window,
      max_tokens: @default_max_tokens,
      headers: headers(cfg),
      compat: compat(cfg)
    }
  end

  defp discovery_options(providers_or_cfg, id, cfg) do
    [
      api_key: Credentials.build_get_api_key(providers_or_cfg).(id),
      provider: id,
      api: api_atom(value(cfg, :api)),
      headers: headers(cfg),
      model_defaults: discovered_model_defaults(cfg)
    ]
    |> maybe_keyword(:timeout_ms, positive_integer(value(cfg, :discovery_timeout_ms)))
  end

  # Reuse metadata only for the current credential, endpoint and wire config.
  defp cached_discovered_model(providers_or_cfg, id, cfg, model_id) do
    if kind = discovery_kind(cfg) do
      LemonAi.Models.Discovery.cached_model(
        kind,
        non_empty(value(cfg, :base_url)),
        model_id,
        discovery_options(providers_or_cfg, id, cfg)
      )
    end
  end

  defp discovery_kind(cfg) do
    case Providers.canonical_discovery(value(cfg, :discovery)) do
      "openai" -> :openai_models
      "ollama" -> :ollama
      nil -> nil
    end
  end

  # ---- Built-in additions ----

  defp lookup_builtin(providers_or_cfg, provider, registry, model_id, known_only \\ false) do
    cfg =
      if Presets.preset?(registry),
        do: ProviderNames.provider_config(providers_map(providers_or_cfg), registry) || %{},
        else: config_for(providers_or_cfg, provider) || %{}

    case Enum.find(model_entries(cfg), &(value(&1, :id) == model_id)) do
      nil -> preset_model(providers_or_cfg, registry, cfg, model_id, known_only)
      entry -> build_builtin_model(registry, cfg, entry)
    end
  end

  defp preset_model(providers_or_cfg, registry, cfg, model_id, known_only) do
    if preset = Presets.get(registry) do
      url = non_empty(value(cfg, :base_url)) || Presets.base_url(registry)
      provider_headers = headers(cfg)

      cached =
        LemonAi.Models.Discovery.cached_model(preset.discovery, url, model_id,
          provider: registry,
          api: preset.api,
          api_key: Credentials.build_get_api_key(providers_or_cfg).(registry),
          headers: provider_headers,
          model_defaults: Presets.model_defaults(registry)
        )

      case cached do
        %Model{} = model ->
          %{model | headers: RequestHeaders.merge(model.headers, provider_headers)}

        nil ->
          if not known_only,
            do: Presets.model(registry, model_id, %{base_url: url, headers: provider_headers})
      end
    end
  end

  defp builtin_additions(id, cfg) do
    case registry_provider(id) do
      nil ->
        []

      registry ->
        cfg
        |> model_entries()
        |> Enum.map(&build_builtin_model(registry, cfg, &1))
        |> Enum.reject(&is_nil/1)
    end
  end

  defp build_builtin_model(registry, cfg, entry) do
    id = non_empty(value(entry, :id))

    base =
      if id do
        if LemonAi.Models.Presets.preset?(registry),
          do: LemonAi.Models.Presets.model(registry, id),
          else: LemonAi.Models.get_model(registry, id) || template_model(registry)
      end

    if base do
      %{
        base
        | id: id,
          name: non_empty(value(entry, :name)) || if(base.id == id, do: base.name, else: id),
          provider: registry,
          api: api_atom(value(entry, :api)) || base.api,
          base_url: non_empty(value(cfg, :base_url)) || base.base_url,
          reasoning: boolean_or(value(entry, :reasoning), base.reasoning),
          input:
            if(value(entry, :input), do: input_types(value(entry, :input)), else: base.input),
          cost: if(value(entry, :cost), do: model_cost(value(entry, :cost)), else: base.cost),
          context_window: positive_integer(value(entry, :context_window)) || base.context_window,
          max_tokens: positive_integer(value(entry, :max_tokens)) || base.max_tokens,
          headers:
            %{}
            |> RequestHeaders.merge(base.headers)
            |> Map.merge(headers(cfg))
            |> Map.merge(string_headers(value(entry, :headers)))
      }
    end
  end

  defp template_model(registry) do
    case LemonAi.Models.get_models(registry) do
      [template | _] -> template
      [] -> nil
    end
  end

  # ---- Helpers ----

  defp find_config(providers_or_cfg, provider) do
    case provider_key(provider) do
      nil ->
        nil

      key ->
        providers = providers_map(providers_or_cfg)
        normalized = normalize(key)

        case Map.fetch(providers, key) do
          {:ok, cfg} when is_map(cfg) ->
            {key, cfg}

          _ ->
            Enum.find_value(providers, fn
              {id, cfg} when is_map(cfg) ->
                if normalize(to_string(id)) == normalized, do: {to_string(id), cfg}

              _ ->
                nil
            end)
        end
    end
  end

  defp providers_map(%{providers: providers}) when is_map(providers), do: providers
  defp providers_map(%{"providers" => providers}) when is_map(providers), do: providers
  defp providers_map(providers) when is_map(providers), do: providers
  defp providers_map(_), do: %{}

  defp provider_key(provider) when is_atom(provider) and not is_nil(provider),
    do: provider_key(Atom.to_string(provider))

  defp provider_key(provider) when is_binary(provider), do: non_empty(provider)
  defp provider_key(_), do: nil

  # Registry atoms spell providers with dashes or underscores; compare
  # normalized strings so no atom is created from the config id.
  defp registry_provider(provider) do
    case provider_key(provider) do
      nil ->
        nil

      key ->
        normalized = normalize(key)

        Presets.resolve(key) ||
          Enum.find(
            LemonAi.Models.get_providers(),
            &(normalize(Atom.to_string(&1)) == normalized)
          )
    end
  end

  defp normalize(value) do
    value |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  defp model_entries(cfg) do
    case value(cfg, :models) do
      models when is_list(models) -> Enum.filter(models, &is_map/1)
      _ -> []
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp string_headers(headers) when headers == %{}, do: headers

  defp string_headers(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn
      {key, value}, acc when is_binary(value) -> RequestHeaders.put(acc, key, value)
      _, acc -> acc
    end)
  end

  defp string_headers(_), do: %{}

  defp input_types(input) when is_list(input) do
    case Enum.flat_map(input, &input_type/1) |> Enum.uniq() do
      [] -> [:text]
      types -> types
    end
  end

  defp input_types(_), do: [:text]

  defp input_type("text"), do: [:text]
  defp input_type("image"), do: [:image]
  defp input_type(_), do: []

  defp model_cost(cost) when is_map(cost) do
    %ModelCost{
      input: price(value(cost, :input)),
      output: price(value(cost, :output)),
      cache_read: price(value(cost, :cache_read)),
      cache_write: price(value(cost, :cache_write))
    }
  end

  defp model_cost(_), do: %ModelCost{}

  defp price(value) when is_number(value) and value >= 0, do: value / 1
  defp price(_), do: 0.0

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil

  defp boolean_or(value, _default) when is_boolean(value), do: value
  defp boolean_or(_value, default), do: default

  defp non_empty(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp non_empty(_), do: nil

  defp maybe_keyword(opts, _key, nil), do: opts
  defp maybe_keyword(opts, key, value), do: Keyword.put(opts, key, value)
end
