defmodule LemonControlPlane.Methods.ConfigGet do
  @moduledoc """
  Handler for the config.get control plane method.

  Read-scope callers see only the explicitly public fields below, and only
  scalar values, scrubbed through `LemonCore.Redact.project/2`. Every other
  stored value (`config.set` accepts arbitrary JSON) needs `operator.admin`
  and is returned through the shared projector, which masks values under
  sensitive keys at any depth, including inside lists, and scrubs credential
  assignments inside strings.

  Only allowed config keys are read from `Application.get_env`, which also
  prevents atom table exhaustion from arbitrary key lookups.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.ConfigStore
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.Redact

  # Allowed config keys that can be retrieved from Application.get_env. These
  # are also the only fields a read-scope caller may see.
  @allowed_app_config_keys %{
    "logLevel" => {:logger, :level},
    "env" => {:lemon_control_plane, :env},
    "maxPayload" => {:lemon_control_plane, :max_payload},
    "tickIntervalMs" => {:lemon_control_plane, :tick_interval_ms},
    "heartbeatEnabled" => {:lemon_automation, :heartbeat_enabled},
    "heartbeatIntervalMs" => {:lemon_automation, :heartbeat_interval_ms},
    "cronEnabled" => {:lemon_automation, :cron_enabled},
    "skillsPath" => {:lemon_skills, :skills_path},
    "routerModel" => {:lemon_router, :default_model},
    "routerThinkingLevel" => {:lemon_router, :default_thinking_level}
  }
  @public_keys Map.keys(@allowed_app_config_keys)

  @impl true
  def name, do: "config.get"

  @impl true
  def scopes, do: [:read]

  @doc """
  Returns the list of allowed config key strings.
  """
  @spec allowed_config_keys() :: [String.t()]
  def allowed_config_keys, do: @public_keys

  @impl true
  def handle(params, ctx) do
    admin? = admin?(ctx)

    case params["key"] do
      nil ->
        with {:ok, config} <- get_all_config(admin?) do
          {:ok, Map.put(config, "summary", summary(config, admin?))}
        end

      key ->
        with {:ok, value} <- requested_value(key, admin?) do
          {:ok, %{"key" => key, "value" => value, "summary" => summary(key, value, admin?)}}
        end
    end
  end

  defp requested_value(key, admin?) do
    cond do
      admin? ->
        with {:ok, value} <- get_config_value(key), do: {:ok, project_admin(value, key)}

      key in @public_keys ->
        with {:ok, value} <- get_config_value(key), do: {:ok, public_value(value)}

      true ->
        {:ok, nil}
    end
  end

  defp admin?(%{auth: auth}) when is_map(auth),
    do: Authorize.authorize(auth, name(), [:admin]) == :ok

  defp admin?(_ctx), do: false

  defp summary(key, value, admin?) do
    sensitive? = Redact.sensitive_key?(key)

    %{
      "requestedKey" => key,
      "keyCount" => 1,
      "found" => not is_nil(value),
      "sensitive" => sensitive?,
      "valueReturned" => not sensitive? and not is_nil(value),
      "adminRequired" => not admin? and key not in @public_keys,
      "cleanup" => cleanup()
    }
  end

  defp summary(config, admin?) when is_map(config) do
    %{
      "keyCount" => map_size(config),
      "sensitiveKeyCount" => config |> Map.keys() |> Enum.count(&Redact.sensitive_key?/1),
      "publicFieldsOnly" => not admin?,
      "cleanup" => cleanup()
    }
  end

  defp cleanup do
    %{
      "includesSensitiveValues" => false,
      "includesCredentialValues" => false,
      "includesSecretValues" => false
    }
  end

  # A stored value wins; an unset key falls back to the allowed application config.
  defp get_config_value(key) do
    case ConfigStore.fetch(key) do
      {:ok, nil} -> {:ok, get_app_config_value(key)}
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> unavailable()
    end
  end

  # Safely get application config only for allowed keys
  defp get_app_config_value(key) do
    case Map.get(@allowed_app_config_keys, key) do
      nil ->
        # Key not in allowed list - return nil instead of creating atom
        nil

      {app, config_key} ->
        Application.get_env(app, config_key)
    end
  end

  defp get_all_config(admin?) do
    case ConfigStore.fetch_all() do
      {:ok, stored} ->
        stored_map = Map.new(stored, fn {k, v} -> {to_string(k), v} end)

        app_config =
          Enum.reduce(@allowed_app_config_keys, %{}, fn {key, {app, config_key}}, acc ->
            case Application.get_env(app, config_key) do
              nil -> acc
              value -> Map.put(acc, key, value)
            end
          end)

        config = Map.merge(app_config, stored_map)

        if admin? do
          {:ok, Redact.operator(config)}
        else
          {:ok,
           config
           |> Map.take(@public_keys)
           |> Map.new(fn {key, value} -> {key, public_value(value)} end)
           |> Map.reject(fn {_key, value} -> is_nil(value) end)}
        end

      {:error, _reason} ->
        unavailable()
    end
  end

  defp unavailable, do: {:error, Errors.unavailable("Configuration is unavailable")}

  # Projecting the value under its own key masks it when the key is sensitive.
  defp project_admin(nil, _key), do: nil
  defp project_admin(value, key), do: Redact.operator(%{key => value}) |> Map.values() |> hd()

  # Public fields are scalars; any structured value under a public key is
  # withheld rather than walked.
  defp public_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_atom(value),
       do: Redact.project(value)

  defp public_value(_value), do: nil
end
