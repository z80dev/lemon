defmodule LemonControlPlane.ProviderStatus do
  @moduledoc false

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonCore.{Config, Secrets}

  # Presence only: never resolve OAuth (which can refresh over the network),
  # decrypt keys, execute external secret sources, or discover remote models.
  def snapshot(config \\ Config.load()) do
    secret_names =
      case Secrets.list() do
        {:ok, entries} -> MapSet.new(entries, & &1.name)
        _ -> MapSet.new()
      end

    providers = config.providers || %{}

    default =
      provider_id(config.agent.default_provider || model_provider(config.agent.default_model))

    ids =
      (Map.keys(providers) ++ LemonAi.Models.get_providers() ++ [default])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&provider_id/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.flat_map(ids, fn id ->
      cfg = ProviderNames.provider_config(providers, id) || Map.get(providers, id, %{})
      present = credential_present?(id, cfg, secret_names)

      configured =
        id == default or Enum.any?(cfg, fn {_key, value} -> present?(value) end) or present

      if configured do
        credential =
          cond do
            ProviderNames.keyless?(id) or cfg[:auth] == "none" -> "not_required"
            present -> "present"
            true -> "missing"
          end

        [
          %{
            "id" => id,
            "configured" => true,
            "credential" => credential,
            "default" => id == default,
            "lastError" =>
              LemonAi.CallDispatcher.last_error(ProviderNames.canonical_name(id) || id)
          }
        ]
      else
        []
      end
    end)
  end

  defp credential_present?(id, cfg, names) do
    oauth? = cfg[:auth_source] == "oauth"

    refs =
      if oauth? do
        [
          cfg[:oauth_secret],
          cfg[:api_key_secret],
          ProviderNames.oauth_default_secret_name(id) || ProviderNames.default_secret_name(id)
        ]
      else
        [
          cfg[:api_key_secret],
          cfg[:oauth_secret],
          ProviderNames.default_secret_name(id),
          ProviderNames.oauth_default_secret_name(id),
          cfg[:service_account_json_secret]
        ]
      end

    stored? = Enum.any?(refs, &(is_binary(&1) and MapSet.member?(names, &1)))

    if oauth? do
      stored?
    else
      stored? or present?(cfg[:api_key]) or present?(cfg[:service_account_json]) or
        Enum.any?([cfg[:api_key_env] | ProviderNames.env_vars(id)], &env_present?/1) or
        ambient_credentials?(ProviderNames.canonical_name(id), cfg, names)
    end
  end

  defp ambient_credentials?("google_vertex", _cfg, _names) do
    env_present?("GOOGLE_APPLICATION_CREDENTIALS_JSON") or
      case System.get_env("GOOGLE_APPLICATION_CREDENTIALS") do
        path when is_binary(path) and path != "" -> File.regular?(path)
        _ -> false
      end
  end

  defp ambient_credentials?(id, cfg, names)
       when id in ["amazon_bedrock", "bedrock_converse_stream"] do
    (env_present?("AWS_ACCESS_KEY_ID") or secret_present?(cfg[:access_key_id_secret], names)) and
      (env_present?("AWS_SECRET_ACCESS_KEY") or
         secret_present?(cfg[:secret_access_key_secret], names))
  end

  defp ambient_credentials?(_, _, _), do: false
  defp secret_present?(name, names), do: is_binary(name) and MapSet.member?(names, name)
  defp env_present?(name) when is_binary(name), do: present?(System.get_env(name))
  defp env_present?(_), do: false
  defp present?(value), do: value not in [nil, "", false, [], %{}]
  defp provider_id(nil), do: nil
  defp provider_id(id), do: ProviderNames.config_name(id) || to_string(id)

  defp model_provider(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, _model] -> provider
      _ -> nil
    end
  end

  defp model_provider(_), do: nil
end
