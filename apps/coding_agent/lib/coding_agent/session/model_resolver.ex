defmodule CodingAgent.Session.ModelResolver do
  @moduledoc """
  Pure-function module for resolving AI model and provider configurations.

  Handles model resolution from various input formats (string specs, maps, structs),
  provider configuration lookups, API key resolution via environment variables and
  secrets, and provider-specific stream option building.
  """
  alias CodingAgent.SettingsManager
  alias LemonAgent.ModelRuntime.ModelRoles

  # ============================================================================
  # Model Resolution
  # ============================================================================

  @spec resolve_session_model(term(), CodingAgent.SettingsManager.t()) :: LemonAi.Types.Model.t()
  def resolve_session_model(nil, %CodingAgent.SettingsManager{} = settings) do
    resolve_default_model(settings)
  end

  def resolve_session_model(
        %LemonAi.Types.Model{} = model,
        %CodingAgent.SettingsManager{} = settings
      ) do
    apply_provider_base_url(model, settings)
  end

  def resolve_session_model("@" <> _role = selector, %SettingsManager{} = settings) do
    selector
    |> expand_role!(settings, default_selector(settings))
    |> resolve_role_model(settings)
    |> check_role_availability!(settings, selector)
  end

  def resolve_session_model(model_spec, %CodingAgent.SettingsManager{} = settings) do
    case resolve_explicit_model(model_spec, settings) do
      %LemonAi.Types.Model{} = model ->
        apply_provider_base_url(model, settings)

      _ ->
        raise ArgumentError, "unknown model #{inspect(model_spec)}"
    end
  end

  @spec resolve_explicit_model(term()) :: LemonAi.Types.Model.t() | nil
  def resolve_explicit_model(spec) when is_binary(spec) do
    resolve_explicit_model(spec, nil)
  end

  def resolve_explicit_model(spec) when is_map(spec), do: resolve_map_spec(spec, nil)

  def resolve_explicit_model(_), do: nil

  defp resolve_map_spec(spec, settings) do
    provider = spec[:provider] || spec["provider"]

    provider =
      if is_atom(provider) and not is_nil(provider), do: Atom.to_string(provider), else: provider

    model_id =
      spec[:model_id] || spec["model_id"] || spec[:id] || spec["id"] || spec[:model] ||
        spec["model"]

    lookup_model(non_empty_string(provider), non_empty_string(model_id), settings)
  end

  # Settings-aware overload: for bare model names (no provider prefix),
  # prefer providers that are configured with API keys in the user's settings.
  @spec resolve_explicit_model(term(), CodingAgent.SettingsManager.t() | nil) ::
          LemonAi.Types.Model.t() | nil
  defp resolve_explicit_model(spec, settings) when is_binary(spec) do
    trimmed = String.trim(spec)
    if trimmed == "", do: nil, else: resolve_model_spec(trimmed, settings)
  end

  defp resolve_explicit_model(spec, settings) when is_map(spec),
    do: resolve_map_spec(spec, settings)

  defp resolve_explicit_model(spec, _settings) do
    resolve_explicit_model(spec)
  end

  defp resolve_model_spec(spec, settings) do
    case String.split(spec, ":", parts: 2) do
      [model_id] ->
        bare_id = non_empty_string(model_id)

        find_model_prefer_configured(bare_id, settings) ||
          resolve_slash_model_spec(model_id, settings) || find_custom_model(bare_id, settings)

      [provider, model_id] ->
        provider = non_empty_string(provider)
        model_id = non_empty_string(model_id)
        if model_id, do: lookup_model(provider, model_id, settings)

      _ ->
        nil
    end
  end

  # When multiple providers offer the same model_id, prefer one that has
  # an API key configured in the user's settings.
  defp find_model_prefer_configured(nil, _settings), do: nil

  defp find_model_prefer_configured(model_id, %CodingAgent.SettingsManager{} = settings) do
    configured = configured_provider_atoms(settings)

    Enum.find_value(configured, fn provider ->
      LemonAi.Models.get_model(provider, model_id)
    end) || LemonAi.Models.find_by_id(model_id)
  end

  defp find_model_prefer_configured(model_id, _settings) do
    LemonAi.Models.find_by_id(model_id)
  end

  @doc """
  Resolves an explicit task selector, or uses `model_roles.task` when configured.
  Without either, the parent model is returned unchanged (including nil).
  Built-in role fallbacks use the parent model before the configured default.
  """
  @spec resolve_task_model(term(), SettingsManager.t(), term()) :: term()
  def resolve_task_model(selector, %SettingsManager{} = settings, parent_model) do
    selector =
      selector || if(Map.has_key?(settings.model_roles, "task"), do: "@task")

    cond do
      is_nil(selector) ->
        parent_model

      is_binary(selector) and String.starts_with?(String.trim(selector), "@") ->
        selector
        |> expand_role!(settings, parent_model || default_selector(settings))
        |> resolve_role_model(settings)
        |> check_role_availability!(settings, selector)

      true ->
        selector
    end
  end

  @doc "Chooses compaction, configured smol, then the active model without session mutation."
  @spec resolve_compaction_model(term(), SettingsManager.t(), LemonAi.Types.Model.t()) ::
          LemonAi.Types.Model.t()
  def resolve_compaction_model(selector, %SettingsManager{} = settings, active_model) do
    selector =
      selector ||
        cond do
          Map.has_key?(settings.model_roles, "compaction") -> "@compaction"
          Map.has_key?(settings.model_roles, "smol") -> "@smol"
          true -> active_model
        end

    selector
    |> expand_role!(settings, active_model)
    |> resolve_role_model(settings)
    |> check_role_availability!(settings, selector)
  end

  defp expand_role!(selector, settings, fallback) do
    case ModelRoles.resolve(selector, settings.model_roles, fallback) do
      {:ok, concrete} -> concrete
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp default_selector(%SettingsManager{default_model: %{model_id: "@" <> _role = selector}}),
    do: selector

  defp default_selector(%SettingsManager{default_model: selector}), do: selector

  defp resolve_role_model(spec, %SettingsManager{default_model: spec} = settings)
       when is_map(spec) and not is_struct(spec) do
    resolve_default_model(settings)
  end

  defp resolve_role_model(spec, settings), do: resolve_session_model(spec, settings)

  defp check_role_availability!(
         %LemonAi.Types.Model{provider: :"openai-codex"} = model,
         settings,
         selector
       ) do
    token = build_get_api_key(settings).(:"openai-codex")

    # Declarative model resolution also runs without credentials (for previews
    # and custom stream functions). Verify account support when a concrete
    # ChatGPT identity is available; missing/invalid auth remains the request
    # credential resolver's responsibility.
    case LemonAi.Models.OpenAICodexDiscovery.account_id(token) do
      {:ok, _} ->
        case LemonAi.Models.OpenAICodexDiscovery.ensure_available(model, access_token: token) do
          :ok ->
            model

          {:error, reason} ->
            label = if is_binary(selector), do: selector, else: "configured compaction model"
            raise ArgumentError, "Model role #{label}: #{reason}"
        end

      {:error, _} ->
        model
    end
  end

  defp check_role_availability!(model, _settings, _selector), do: model

  @spec resolve_default_model(CodingAgent.SettingsManager.t()) :: LemonAi.Types.Model.t()
  def resolve_default_model(%CodingAgent.SettingsManager{default_model: nil}) do
    # No default model configured, raise an error
    raise ArgumentError,
          "model is required: either pass :model option or configure default_model in settings"
  end

  def resolve_default_model(%SettingsManager{default_model: "@" <> _role = selector} = settings) do
    selector
    |> expand_role!(settings, nil)
    |> resolve_role_model(settings)
    |> check_role_availability!(settings, selector)
  end

  def resolve_default_model(
        %SettingsManager{default_model: %{model_id: "@" <> _role = selector}} = settings
      ) do
    selector
    |> expand_role!(settings, nil)
    |> resolve_role_model(settings)
    |> check_role_availability!(settings, selector)
  end

  def resolve_default_model(%CodingAgent.SettingsManager{default_model: config} = settings)
      when is_map(config) do
    provider = Map.get(config, :provider)
    model_id = Map.get(config, :model_id)
    base_url = Map.get(config, :base_url)
    provider = canonical_registry_provider(provider)
    provider = route_default_provider(provider, model_id, settings)

    model =
      case provider do
        nil ->
          LemonAi.Models.find_by_id(model_id)

        provider_atom when is_atom(provider_atom) ->
          # model_id may be prefixed (e.g. "zai:glm-5-turbo"); try as-is first,
          # then strip the provider prefix for a direct registry lookup.
          LemonAgent.ModelRuntime.CustomProviders.lookup(
            settings.providers,
            provider_atom,
            model_id
          ) ||
            LemonAi.Models.get_model(provider_atom, model_id) ||
            case String.split(model_id, ":", parts: 2) do
              [_prefix, bare_id] when bare_id != "" ->
                LemonAi.Models.get_model(provider_atom, bare_id)

              _ ->
                nil
            end || provider_model(provider_atom, model_id) ||
            LemonAi.Models.find_by_id(model_id)

        provider_str when is_binary(provider_str) ->
          lookup_model(provider_str, model_id, settings)
      end

    case model do
      nil ->
        raise ArgumentError,
              "unknown model #{inspect(model_id)}" <>
                if(provider, do: " for provider #{inspect(provider)}", else: "")

      model ->
        model =
          if is_binary(base_url) and base_url != "" do
            %{model | base_url: base_url}
          else
            model
          end

        apply_provider_base_url(model, settings)
    end
  end

  @spec runtime_fallback_models(
          LemonAi.Types.Model.t(),
          CodingAgent.SettingsManager.t(),
          keyword()
        ) :: [LemonAi.Types.Model.t()]
  def runtime_fallback_models(model, settings, opts \\ [])

  def runtime_fallback_models(
        %LemonAi.Types.Model{} = model,
        %CodingAgent.SettingsManager{} = settings,
        opts
      ) do
    routing = settings.provider_routing || %{}
    session_scope = Keyword.get(opts, :session_scope) || :global

    cond do
      Map.get(routing, :enabled, true) == false ->
        []

      is_nil(model.provider) or is_nil(model.id) ->
        []

      true ->
        routing
        |> routing_candidate_providers(model.id, session_scope)
        |> lead_with_pinned_provider(session_scope)
        |> Enum.map(&fallback_model(&1, model.id, settings, routing))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(
          &(normalize_provider_id(&1.provider) == normalize_provider_id(model.provider))
        )
        |> Enum.uniq_by(&normalize_provider_id(&1.provider))
    end
  end

  def runtime_fallback_models(_model, _settings, _opts), do: []

  # ============================================================================
  # Provider Configuration
  # ============================================================================

  @spec apply_provider_base_url(LemonAi.Types.Model.t(), CodingAgent.SettingsManager.t()) ::
          LemonAi.Types.Model.t()
  def apply_provider_base_url(model, %CodingAgent.SettingsManager{providers: providers}) do
    provider_key =
      case model.provider do
        p when is_atom(p) -> Atom.to_string(p)
        p when is_binary(p) -> p
        _ -> nil
      end

    provider_cfg = provider_key && Map.get(providers, provider_key)
    base_url = provider_cfg && Map.get(provider_cfg, :base_url)

    if is_binary(base_url) and base_url != "" and base_url != model.base_url do
      %{model | base_url: base_url}
    else
      model
    end
  end

  @spec build_get_api_key(CodingAgent.SettingsManager.t()) :: (atom() -> String.t() | nil)
  def build_get_api_key(%CodingAgent.SettingsManager{} = settings) do
    # Pass the whole settings (not just providers) so pool credentials from
    # provider_routing participate in resolution; with no pools configured the
    # lookup is identical to a bare providers map.
    LemonAgent.ModelRuntime.Credentials.build_get_api_key(settings)
  end

  @spec build_stream_options(
          LemonAi.Types.Model.t(),
          CodingAgent.SettingsManager.t(),
          map() | nil,
          String.t() | nil
        ) :: LemonAi.Types.StreamOptions.t()
  def build_stream_options(
        model,
        %CodingAgent.SettingsManager{providers: providers},
        existing_opts,
        cwd
      ) do
    LemonAgent.ModelRuntime.StreamOptions.build_stream_options(
      model,
      providers,
      existing_opts,
      cwd
    )
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @spec first_non_empty_binary([term()]) :: String.t() | nil
  def first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, fn v -> is_binary(v) and String.trim(v) != "" end)
  end

  # ---- Private helpers ----

  @spec resolve_slash_model_spec(String.t(), SettingsManager.t() | nil) ::
          LemonAi.Types.Model.t() | nil
  defp resolve_slash_model_spec(model_spec, settings) when is_binary(model_spec) do
    case String.split(model_spec, "/", parts: 2) do
      [provider, model_id] ->
        provider = non_empty_string(provider)
        model_id = non_empty_string(model_id)

        if provider && model_id do
          lookup_model(provider, model_id, settings)
        else
          nil
        end

      _ ->
        nil
    end
  end

  # User-defined `[providers.<id>]` models (custom providers and additions to
  # built-in providers) take precedence over the registry.
  defp lookup_model(provider, model_id, %SettingsManager{providers: providers})
       when is_binary(provider) and is_binary(model_id) do
    LemonAgent.ModelRuntime.CustomProviders.lookup(providers, provider, model_id) ||
      lookup_model(provider, model_id)
  end

  defp lookup_model(provider, model_id, _settings), do: lookup_model(provider, model_id)

  # Bare ids also match models listed under a custom provider.
  defp find_custom_model(model_id, %SettingsManager{providers: providers})
       when is_binary(model_id) do
    providers
    |> LemonAgent.ModelRuntime.CustomProviders.models()
    |> Enum.find(&(&1.id == model_id))
  end

  defp find_custom_model(_model_id, _settings), do: nil

  @spec lookup_model(String.t() | nil, String.t() | nil) :: LemonAi.Types.Model.t() | nil
  defp lookup_model(_provider, nil), do: nil

  defp lookup_model(nil, model_id) when is_binary(model_id) do
    LemonAi.Models.find_by_id(model_id)
  end

  defp lookup_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    case provider_to_atom(provider) do
      nil ->
        nil

      provider_atom ->
        LemonAi.Models.get_model(provider_atom, model_id) ||
          provider_model(provider_atom, model_id)
    end
  end

  defp lookup_model(_provider, _model_id), do: nil

  defp provider_model(provider_atom, model_id) do
    template = LemonAi.Models.get_models(provider_atom) |> List.first()
    base = LemonAi.Models.find_by_id(model_id) || template

    if base do
      %{
        base
        | id: model_id,
          provider: provider_atom,
          api: (template && template.api) || provider_atom,
          base_url: (template && template.base_url) || base.base_url
      }
    end
  end

  # Extract provider atoms from the settings' configured providers map.
  # Only returns providers that have some form of API key configured.
  defp configured_provider_atoms(%CodingAgent.SettingsManager{providers: providers})
       when is_map(providers) do
    providers
    |> Enum.filter(fn {_name, cfg} ->
      is_map(cfg) and has_api_key_config?(cfg)
    end)
    |> Enum.map(fn {name, _cfg} -> provider_to_atom(to_string(name)) end)
    |> Enum.reject(&is_nil/1)
  end

  defp configured_provider_atoms(_), do: []

  defp route_default_provider(provider, model_id, %CodingAgent.SettingsManager{} = settings) do
    routing = settings.provider_routing || %{}

    cond do
      Map.get(routing, :enabled, true) == false ->
        provider

      is_nil(provider) or is_nil(model_id) ->
        provider

      provider_credentials_ready?(provider, settings, routing) ->
        provider

      true ->
        routing
        |> routing_candidate_providers(model_id, :global)
        |> Enum.find_value(provider, fn fallback_provider ->
          if fallback_model_available?(fallback_provider, model_id, settings) and
               provider_credentials_ready?(fallback_provider, settings, routing) do
            fallback_provider
          end
        end)
    end
  end

  defp provider_credentials_ready?(_provider, _settings, %{require_credentials: false}), do: true

  defp provider_credentials_ready?(provider, %CodingAgent.SettingsManager{} = settings, routing) do
    LemonAgent.ModelRuntime.Credentials.provider_has_credentials?(provider, settings.providers,
      provider_routing: routing
    )
  end

  defp fallback_model_available?(provider, model_id, settings) do
    model = lookup_model(to_string(provider), model_id, settings)
    match?(%LemonAi.Types.Model{}, model)
  end

  defp fallback_model(provider, model_id, %CodingAgent.SettingsManager{} = settings, routing) do
    if provider_credentials_ready?(provider, settings, routing) do
      provider
      |> to_string()
      |> lookup_model(model_id, settings)
      |> case do
        %LemonAi.Types.Model{} = model -> apply_provider_base_url(model, settings)
        _ -> nil
      end
    end
  end

  # Ordered fallback provider candidates from the shared routing plan.
  # LemonAgent.ModelRuntime.ProviderRouting owns the precedence (profile
  # fallback_providers -> profile distribution -> credential pool -> global
  # fallback_providers), pool rotation, and circuit-breaker demotion; this
  # maps the plan's canonical provider ids back to config names so model and
  # credential lookups keep resolving dashed provider names (e.g.
  # "openai-codex").
  #
  # Callers with a stable session identity pass it as the rotation scope so a
  # session keeps its claimed pool slot across resolutions (provider prompt
  # caches are per provider+credential); the :global default advances the
  # rotation once per resolution.
  defp routing_candidate_providers(routing, model_id, session_scope) when is_map(routing) do
    config = %LemonCore.Config{agent: %{provider_routing: routing}}

    %{"model" => model_id}
    |> LemonAgent.ModelRuntime.ProviderRouting.plan(config,
      rotate?: true,
      rotation_key: session_scope
    )
    |> Enum.map(fn %{provider: provider} ->
      LemonAgent.ModelRuntime.ProviderNames.config_name(provider) || provider
    end)
    |> Enum.uniq()
  end

  # A committed fallback pin (see LemonAgent.ModelRuntime.SessionPins) leads
  # the candidate order on later resolutions for the same session. Best-effort:
  # no pin (or no session identity) leaves the plan order untouched.
  defp lead_with_pinned_provider(providers, session_scope) do
    case LemonAgent.ModelRuntime.SessionPins.get(session_scope) do
      %{provider: pinned} when is_binary(pinned) ->
        pinned_id = normalize_provider_id(pinned)

        case Enum.split_with(providers, &(normalize_provider_id(&1) == pinned_id)) do
          {[], _} -> providers
          {pinned_matches, others} -> pinned_matches ++ others
        end

      _ ->
        providers
    end
  end

  defp has_api_key_config?(cfg) do
    Map.has_key?(cfg, :api_key) or Map.has_key?(cfg, :api_key_secret) or
      Map.has_key?(cfg, :oauth_secret) or Map.has_key?(cfg, "api_key") or
      Map.has_key?(cfg, "api_key_secret") or Map.has_key?(cfg, "oauth_secret")
  end

  @spec provider_to_atom(String.t()) :: atom() | nil
  defp provider_to_atom(provider) when is_binary(provider) do
    normalized = normalize_registry_provider_name(provider)

    Enum.find(LemonAi.Models.get_providers(), fn known ->
      known
      |> Atom.to_string()
      |> normalize_registry_provider_name()
      |> Kernel.==(normalized)
    end)
  end

  defp provider_to_atom(_), do: nil

  # SettingsManager keeps legacy config compatibility by representing dashed
  # provider names as underscored atoms (for example :openai_codex). Model
  # registry keys retain their canonical spelling (for example
  # :"openai-codex"), so canonicalize only at this registry boundary. Unknown
  # providers are preserved for the existing custom-provider fallback path.
  defp canonical_registry_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> provider_to_atom()
    |> case do
      nil -> provider
      canonical -> canonical
    end
  end

  defp canonical_registry_provider(provider) when is_binary(provider) do
    provider_to_atom(provider) || provider
  end

  defp canonical_registry_provider(provider), do: provider

  defp normalize_registry_provider_name(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
  end

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  defp normalize_provider_id(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp normalize_provider_id(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_provider_id(_), do: nil
end
