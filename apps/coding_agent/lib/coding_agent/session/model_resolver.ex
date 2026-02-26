defmodule CodingAgent.Session.ModelResolver do
  @moduledoc """
  Pure-function module for resolving AI model and provider configurations.

  Handles model resolution from various input formats (string specs, maps, structs),
  provider configuration lookups, API key resolution via environment variables and
  secrets, and provider-specific stream option building.
  """

  require Logger

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
    case resolve_explicit_model(model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, settings)

      _ ->
        raise ArgumentError, "unknown model #{inspect(model_spec)}"
    end
  end

  @spec resolve_explicit_model(term()) :: Ai.Types.Model.t() | nil
  def resolve_explicit_model(spec) when is_binary(spec) do
    trimmed = String.trim(spec)

    cond do
      trimmed == "" ->
        nil

      true ->
        case String.split(trimmed, ":", parts: 2) do
          [model_id] ->
            # Prefer exact model-id lookup first so slash-style provider-scoped IDs
            # (for example "google/gemini-3.1-pro-preview") continue to resolve as-is.
            lookup_model(nil, non_empty_string(model_id)) ||
              resolve_slash_model_spec(model_id)

          [provider, model_id] ->
            provider = non_empty_string(provider)
            model_id = non_empty_string(model_id)

            if model_id do
              lookup_model(provider, model_id)
            else
              nil
            end

          _ ->
            nil
        end
    end
  end

  def resolve_explicit_model(spec) when is_map(spec) do
    provider = spec[:provider] || spec["provider"]

    model_id =
      spec[:model_id] || spec["model_id"] || spec[:id] || spec["id"] || spec[:model] ||
        spec["model"]

    lookup_model(non_empty_string(provider), non_empty_string(model_id))
  end

  def resolve_explicit_model(_), do: nil

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

    model =
      case provider do
        nil ->
          Ai.Models.find_by_id(model_id)

        provider_str when is_binary(provider_str) ->
          provider_atom =
            try do
              String.to_existing_atom(provider_str)
            rescue
              ArgumentError -> String.to_atom(provider_str)
            end

          Ai.Models.get_model(provider_atom, model_id)
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
    fn provider ->
      provider_name = normalize_provider_key(provider)
      provider_cfg = provider_config(providers, provider_name)

      env_key =
        provider_name
        |> provider_env_vars()
        |> env_first()

      cond do
        is_binary(env_key) and env_key != "" ->
          env_key

        is_binary(plain_api_key = provider_config_value(provider_cfg, :api_key)) and
            plain_api_key != "" ->
          plain_api_key

        is_binary(api_key_secret = provider_config_value(provider_cfg, :api_key_secret)) and
            api_key_secret != "" ->
          resolve_secret_api_key(api_key_secret)

        is_binary(default_secret = provider_default_secret_name(provider_name)) and
            default_secret != "" ->
          resolve_secret_api_key(default_secret)

        true ->
          nil
      end
    end
  end

  @spec build_stream_options(Ai.Types.Model.t(), CodingAgent.SettingsManager.t(), map() | nil) ::
          map() | nil
  def build_stream_options(
        %{provider: :google_vertex} = _model,
        settings_manager,
        existing_opts
      ) do
    provider_cfg = provider_config(settings_manager.providers, "google_vertex")

    # Resolve Vertex-specific secrets
    project = resolve_vertex_secret(provider_cfg, :project_secret, "google_vertex_project")
    location = resolve_vertex_secret(provider_cfg, :location_secret, "google_vertex_location")

    service_account_json =
      resolve_vertex_secret(
        provider_cfg,
        :service_account_json_secret,
        "google_vertex_service_account_json"
      )

    base_opts = existing_opts || %{}

    base_opts
    |> maybe_put(:project, project)
    |> maybe_put(:location, location)
    |> maybe_put(:service_account_json, service_account_json)
  end

  def build_stream_options(_model, _settings_manager, existing_opts), do: existing_opts

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
      nil -> nil
      provider_atom -> Ai.Models.get_model(provider_atom, model_id)
    end
  end

  defp lookup_model(_provider, _model_id), do: nil

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

  @spec normalize_provider_key(atom() | String.t()) :: String.t() | nil
  defp normalize_provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp normalize_provider_key(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_provider_key(_), do: nil

  defp provider_env_vars("anthropic"), do: ["ANTHROPIC_API_KEY"]
  defp provider_env_vars("openai"), do: ["OPENAI_API_KEY"]
  defp provider_env_vars("openai-codex"), do: ["OPENAI_CODEX_API_KEY", "CHATGPT_TOKEN"]
  defp provider_env_vars("opencode"), do: ["OPENCODE_API_KEY"]
  defp provider_env_vars("kimi"), do: ["KIMI_API_KEY"]
  defp provider_env_vars("github_copilot"), do: ["GITHUB_COPILOT_API_KEY"]

  defp provider_env_vars("google"),
    do: ["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]

  defp provider_env_vars(_), do: []

  defp provider_default_secret_name(nil), do: nil

  defp provider_default_secret_name(provider_name) when is_binary(provider_name) do
    sanitized =
      provider_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    if sanitized == "", do: nil, else: "llm_#{sanitized}_api_key"
  end

  defp resolve_secret_api_key(secret_name) when is_binary(secret_name) do
    case LemonCore.Secrets.resolve(secret_name, prefer_env: false, env_fallback: true) do
      {:ok, value, _source} ->
        case Ai.Auth.OAuthSecretResolver.resolve_api_key_from_secret(secret_name, value) do
          {:ok, resolved_api_key} ->
            resolved_api_key

          :ignore ->
            value

          {:error, reason} ->
            Logger.debug("Failed to resolve OAuth secret #{secret_name}: #{inspect(reason)}")

            value
        end

      _ ->
        nil
    end
  end

  defp resolve_secret_api_key(_), do: nil

  defp env_first(names) when is_list(names) do
    Enum.find_value(names, fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp provider_config(providers, provider_name) when is_binary(provider_name) do
    Map.get(providers, provider_name) ||
      Enum.find_value(providers, fn
        {key, value} when is_atom(key) ->
          if Atom.to_string(key) == provider_name, do: value, else: nil

        _ ->
          nil
      end)
  end

  defp provider_config(_providers, _provider_name), do: nil

  defp provider_config_value(nil, _key), do: nil

  defp provider_config_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
  end

  defp resolve_vertex_secret(provider_cfg, config_key, default_secret_name) do
    # Try to get secret name from config, fall back to default
    secret_name = provider_config_value(provider_cfg, config_key) || default_secret_name

    if is_binary(secret_name) and secret_name != "" do
      resolve_secret_api_key(secret_name)
    else
      nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
