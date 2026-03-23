import Config

level =
  case System.get_env("LEMON_LOG_LEVEL") do
    nil ->
      nil

    "" ->
      nil

    raw ->
      case raw |> String.trim() |> String.downcase() do
        "debug" -> :debug
        "info" -> :info
        "notice" -> :notice
        "warning" -> :warning
        "warn" -> :warning
        "error" -> :error
        "critical" -> :critical
        "alert" -> :alert
        "emergency" -> :emergency
        _ -> nil
      end
  end

if is_atom(level) and not is_nil(level) do
  # Keep global logger and default handler aligned so env-level overrides
  # reliably suppress lower-severity logs (e.g., debug).
  config :logger, level: level
  config :logger, :default_handler, level: level
end

access_token = System.get_env("LEMON_WEB_ACCESS_TOKEN")

if is_binary(access_token) and access_token != "" do
  config :lemon_web, :access_token, access_token
end

sim_ui_access_token = System.get_env("LEMON_SIM_UI_ACCESS_TOKEN")

if is_binary(sim_ui_access_token) and sim_ui_access_token != "" do
  config :lemon_sim_ui, :access_token, sim_ui_access_token
end

uploads_dir = System.get_env("LEMON_WEB_UPLOADS_DIR")

if is_binary(uploads_dir) and uploads_dir != "" do
  config :lemon_web, :uploads_dir, uploads_dir
end

# Auto-loop: automatically start and restart games
if System.get_env("LEMON_SIM_AUTO_LOOP") in ["1", "true", "TRUE"] do
  werewolf_players =
    case System.get_env("LEMON_SIM_WEREWOLF_PLAYERS") do
      nil -> 6
      "" -> 6
      n -> String.to_integer(n)
    end

  config :lemon_sim_ui, :auto_loop, [
    {:werewolf, [player_count: werewolf_players]}
  ]
end

if config_env() == :prod do
  release_name = System.get_env("RELEASE_NAME")

  configure_endpoint = fn otp_app, endpoint, env_prefix, default_port, required_release ->
    required? = release_name == required_release
    secret_key_base = System.get_env("#{env_prefix}_SECRET_KEY_BASE")

    if required? or (is_binary(secret_key_base) and secret_key_base != "") do
      host = System.get_env("#{env_prefix}_HOST") || "localhost"

      port =
        String.to_integer(System.get_env("#{env_prefix}_PORT") || Integer.to_string(default_port))

      endpoint_config = [
        url: [host: host, port: 443, scheme: "https"],
        http: [ip: {0, 0, 0, 0}, port: port],
        secret_key_base: secret_key_base || System.fetch_env!("#{env_prefix}_SECRET_KEY_BASE")
      ]

      endpoint_config =
        if System.get_env("PHX_SERVER") in ["1", "true", "TRUE"] do
          Keyword.put(endpoint_config, :server, true)
        else
          endpoint_config
        end

      config otp_app, endpoint, endpoint_config
    end
  end

  configure_endpoint.(:lemon_web, LemonWeb.Endpoint, "LEMON_WEB", 4080, "lemon_runtime_full")

  configure_endpoint.(
    :lemon_sim_ui,
    LemonSimUi.Endpoint,
    "LEMON_SIM_UI",
    4090,
    "sim_broadcast_platform"
  )
end
