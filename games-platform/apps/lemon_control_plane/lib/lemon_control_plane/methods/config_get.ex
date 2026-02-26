defmodule LemonControlPlane.Methods.ConfigGet do
  @moduledoc """
  Handler for the config.get control plane method.

  Retrieves configuration values.

  Note: Only allowed config keys can be retrieved via Application.get_env
  to prevent atom table exhaustion from arbitrary key lookups.
  """

  @behaviour LemonControlPlane.Method

  # Allowed config keys that can be retrieved from Application.get_env.
  # This prevents atom exhaustion from arbitrary key lookups.
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

  @impl true
  def name, do: "config.get"

  @impl true
  def scopes, do: [:read]

  @doc """
  Returns the list of allowed config key strings.
  """
  @spec allowed_config_keys() :: [String.t()]
  def allowed_config_keys, do: Map.keys(@allowed_app_config_keys)

  @impl true
  def handle(params, _ctx) do
    key = params["key"]

    if key do
      # Get specific key
      value = get_config_value(key)
      {:ok, %{"key" => key, "value" => value}}
    else
      # Get all config
      config = get_all_config()
      {:ok, config}
    end
  end

  defp get_config_value(key) do
    # First check the store (user-set values)
    case LemonCore.Store.get(:system_config, key) do
      nil ->
        # Fall back to Application.get_env only for allowed keys
        get_app_config_value(key)
      value ->
        value
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

  defp get_all_config do
    # Gather config from multiple sources
    stored = LemonCore.Store.list(:system_config)

    stored_map =
      if is_list(stored) do
        Enum.into(stored, %{}, fn {k, v} -> {to_string(k), v} end)
      else
        %{}
      end

    # Merge with application config (only allowed keys)
    app_config =
      Enum.reduce(@allowed_app_config_keys, %{}, fn {key, {app, config_key}}, acc ->
        value = Application.get_env(app, config_key)
        if value != nil do
          Map.put(acc, key, format_config_value(value))
        else
          acc
        end
      end)

    Map.merge(app_config, stored_map)
  rescue
    _ -> %{}
  end

  defp format_config_value(value) when is_atom(value), do: to_string(value)
  defp format_config_value(value), do: value
end
