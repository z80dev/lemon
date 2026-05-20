defmodule CodingAgent.Session.ModelResolver do
  @moduledoc """
  Pure-function module for resolving AI model and provider configurations.

  Handles model resolution from various input formats (string specs, maps, structs),
  provider configuration lookups, API key resolution via environment variables and
  secrets, and provider-specific stream option building.
  """

  # ============================================================================
  # Model Resolution
  # ============================================================================

  @spec resolve_session_model(term(), CodingAgent.SettingsManager.t()) :: Ai.Types.Model.t()
  def resolve_session_model(nil, %CodingAgent.SettingsManager{} = settings) do
    resolve_default_model(settings)
  end

  def resolve_session_model(%Ai.Types.Model{} = model, %CodingAgent.SettingsManager{} = settings) do
    apply_provider_base_url(model, settings)
  end

  def resolve_session_model(model_spec, %CodingAgent.SettingsManager{} = settings) do
    case resolve_explicit_model(model_spec, settings) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, settings)

      _ ->
        raise ArgumentError, "unknown model #{inspect(model_spec)}"
    end
  end

  @spec resolve_explicit_model(term()) :: Ai.Types.Model.t() | nil
  def resolve_explicit_model(spec) when is_binary(spec) do
    resolve_explicit_model(spec, nil)
  end

  def resolve_explicit_model(spec) when is_map(spec) do
    provider = spec[:provider] || spec["provider"]

    model_id =
      spec[:model_id] || spec["model_id"] || spec[:id] || spec["id"] || spec[:model] ||
        spec["model"]

    lookup_model(non_empty_string(provider), non_empty_string(model_id))
  end

  def resolve_explicit_model(_), do: nil

  # Settings-aware overload: for bare model names (no provider prefix),
  # prefer providers that are configured with API keys in the user's settings.
  @spec resolve_explicit_model(term(), CodingAgent.SettingsManager.t() | nil) ::
          Ai.Types.Model.t() | nil
  defp resolve_explicit_model(spec, settings) when is_binary(spec) do
    trimmed = String.trim(spec)
    if trimmed == "", do: nil, else: resolve_model_spec(trimmed, settings)
  end

  defp resolve_explicit_model(spec, _settings) do
    resolve_explicit_model(spec)
  end

  defp resolve_model_spec(spec, settings) do
    case String.split(spec, ":", parts: 2) do
      [model_id] ->
        bare_id = non_empty_string(model_id)

        find_model_prefer_configured(bare_id, settings) ||
          resolve_slash_model_spec(model_id)

      [provider, model_id] ->
        provider = non_empty_string(provider)
        model_id = non_empty_string(model_id)
        if model_id, do: lookup_model(provider, model_id)

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
      Ai.Models.get_model(provider, model_id)
    end) || Ai.Models.find_by_id(model_id)
  end

  defp find_model_prefer_configured(model_id, _settings) do
    Ai.Models.find_by_id(model_id)
  end

  @spec resolve_default_model(CodingAgent.SettingsManager.t()) :: Ai.Types.Model.t()
  def resolve_default_model(%CodingAgent.SettingsManager{default_model: nil}) do
    # No default model configured, raise an error
    raise ArgumentError,
          "model is required: either pass :model option or configure default_model in settings"
  end

  def resolve_default_model(%CodingAgent.SettingsManager{default_model: config} = settings)
      when is_map(config) do
    provider = Map.get(config, :provider)
    model_id = Map.get(config, :model_id)
    base_url = Map.get(config, :base_url)
    provider = route_default_provider(provider, model_id, settings)

    model =
      case provider do
        nil ->
          Ai.Models.find_by_id(model_id)

        provider_atom when is_atom(provider_atom) ->
          # model_id may be prefixed (e.g. "zai:glm-5-turbo"); try as-is first,
          # then strip the provider prefix for a direct registry lookup.
          Ai.Models.get_model(provider_atom, model_id) ||
            case model_id && String.split(model_id, ":", parts: 2) do
              [_prefix, bare_id] when bare_id != "" ->
                Ai.Models.get_model(provider_atom, bare_id)

              _ ->
                nil
            end || provider_model(provider_atom, model_id) ||
            Ai.Models.find_by_id(model_id)

        provider_str when is_binary(provider_str) ->
          lookup_model(provider_str, model_id)
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

  @spec runtime_fallback_models(Ai.Types.Model.t(), CodingAgent.SettingsManager.t()) :: [
          Ai.Types.Model.t()
        ]
  def runtime_fallback_models(
        %Ai.Types.Model{} = model,
        %CodingAgent.SettingsManager{} = settings
      ) do
    routing = settings.provider_routing || %{}

    cond do
      Map.get(routing, :enabled, true) == false ->
        []

      is_nil(model.provider) or is_nil(model.id) ->
        []

      true ->
        routing
        |> routing_fallback_providers(model.id)
        |> Enum.map(&fallback_model(&1, model.id, settings, routing))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(
          &(normalize_provider_id(&1.provider) == normalize_provider_id(model.provider))
        )
        |> Enum.uniq_by(&normalize_provider_id(&1.provider))
    end
  end

  def runtime_fallback_models(_model, _settings), do: []

  # ============================================================================
  # Provider Configuration
  # ============================================================================

  @spec apply_provider_base_url(Ai.Types.Model.t(), CodingAgent.SettingsManager.t()) ::
          Ai.Types.Model.t()
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
  def build_get_api_key(%CodingAgent.SettingsManager{providers: providers}) do
    LemonAiRuntime.build_get_api_key(providers)
  end

  @spec build_stream_options(
          Ai.Types.Model.t(),
          CodingAgent.SettingsManager.t(),
          map() | nil,
          String.t() | nil
        ) :: Ai.Types.StreamOptions.t()
  def build_stream_options(
        model,
        %CodingAgent.SettingsManager{providers: providers},
        existing_opts,
        cwd
      ) do
    LemonAiRuntime.build_stream_options(model, providers, existing_opts, cwd)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @spec first_non_empty_binary([term()]) :: String.t() | nil
  def first_non_empty_binary(list) when is_list(list) do
    Enum.find(list, fn v -> is_binary(v) and String.trim(v) != "" end)
  end

  # ---- Private helpers ----

  @spec resolve_slash_model_spec(String.t()) :: Ai.Types.Model.t() | nil
  defp resolve_slash_model_spec(model_spec) when is_binary(model_spec) do
    case String.split(model_spec, "/", parts: 2) do
      [provider, model_id] ->
        provider = non_empty_string(provider)
        model_id = non_empty_string(model_id)

        if provider && model_id do
          lookup_model(provider, model_id)
        else
          nil
        end

      _ ->
        nil
    end
  end

  @spec lookup_model(String.t() | nil, String.t() | nil) :: Ai.Types.Model.t() | nil
  defp lookup_model(_provider, nil), do: nil

  defp lookup_model(nil, model_id) when is_binary(model_id) do
    Ai.Models.find_by_id(model_id)
  end

  defp lookup_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    case provider_to_atom(provider) do
      nil ->
        nil

      provider_atom ->
        Ai.Models.get_model(provider_atom, model_id) || provider_model(provider_atom, model_id)
    end
  end

  defp lookup_model(_provider, _model_id), do: nil

  defp provider_model(provider_atom, model_id) do
    template = Ai.Models.get_models(provider_atom) |> List.first()
    base = Ai.Models.find_by_id(model_id) || template

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
        |> routing_fallback_providers(model_id)
        |> Enum.find_value(provider, fn fallback_provider ->
          if fallback_model_available?(fallback_provider, model_id) and
               provider_credentials_ready?(fallback_provider, settings, routing) do
            fallback_provider
          end
        end)
    end
  end

  defp provider_credentials_ready?(_provider, _settings, %{require_credentials: false}), do: true

  defp provider_credentials_ready?(provider, %CodingAgent.SettingsManager{} = settings, _routing) do
    LemonAiRuntime.provider_has_credentials?(provider, settings.providers)
  end

  defp fallback_model_available?(provider, model_id) do
    model = lookup_model(to_string(provider), model_id)
    match?(%Ai.Types.Model{}, model)
  end

  defp fallback_model(provider, model_id, %CodingAgent.SettingsManager{} = settings, routing) do
    if provider_credentials_ready?(provider, settings, routing) do
      provider
      |> to_string()
      |> lookup_model(model_id)
      |> case do
        %Ai.Types.Model{} = model -> apply_provider_base_url(model, settings)
        _ -> nil
      end
    end
  end

  defp routing_fallback_providers(routing, model_id) when is_map(routing) do
    profile_name = routing_value(routing, :default_profile)

    profile =
      named_routing_config(
        routing_value(routing, :profiles, %{}),
        profile_name
      )

    pool_name =
      routing_value(profile || %{}, :credential_pool) || routing_value(routing, :default_pool)

    pool = named_routing_config(routing_value(routing, :credential_pools, %{}), pool_name)
    pool_providers = routing_value(pool || %{}, :providers, [])

    [
      routing_value(profile || %{}, :fallback_providers, []),
      distribution_providers(profile),
      LemonCore.ProviderPoolRotator.ordered_providers(
        {:provider_pool, profile_name, pool_name, model_id},
        pool_providers,
        routing_value(pool || %{}, :strategy, "priority")
      ),
      routing_value(routing, :fallback_providers, [])
    ]
    |> List.flatten()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp routing_fallback_providers(_, _), do: []

  defp distribution_providers(profile) when is_map(profile) do
    profile
    |> routing_value(:distribution, %{})
    |> case do
      distribution when is_map(distribution) ->
        distribution
        |> Enum.sort_by(fn {provider, weight} ->
          {-numeric_weight(weight), to_string(provider)}
        end)
        |> Enum.map(fn {provider, _weight} -> provider end)

      _ ->
        []
    end
  end

  defp distribution_providers(_), do: []

  defp named_routing_config(configs, name) when is_map(configs) and is_binary(name) do
    Map.get(configs, name) || existing_atom_routing_config(configs, name)
  end

  defp named_routing_config(_, _), do: nil

  defp existing_atom_routing_config(configs, name) do
    Map.get(configs, String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  defp routing_value(map, key, default \\ nil)

  defp routing_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp routing_value(_, _, default), do: default

  defp numeric_weight(weight) when is_integer(weight), do: weight
  defp numeric_weight(weight) when is_float(weight), do: weight
  defp numeric_weight(_), do: 0

  defp has_api_key_config?(cfg) do
    Map.has_key?(cfg, :api_key) or Map.has_key?(cfg, :api_key_secret) or
      Map.has_key?(cfg, :oauth_secret) or Map.has_key?(cfg, "api_key") or
      Map.has_key?(cfg, "api_key_secret") or Map.has_key?(cfg, "oauth_secret")
  end

  @spec provider_to_atom(String.t()) :: atom() | nil
  defp provider_to_atom(provider) when is_binary(provider) do
    normalized = String.downcase(String.trim(provider))

    Enum.find(Ai.Models.get_providers(), fn known ->
      known_str = Atom.to_string(known)
      known_str == normalized or String.replace(known_str, "_", "-") == normalized
    end)
  end

  defp provider_to_atom(_), do: nil

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
