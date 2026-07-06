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

if System.get_env("LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER") in ["1", "true", "TRUE"] do
  config :lemon_sim_ui, :public_vending_launcher, true
end

sim_ui_suite_roots = System.get_env("LEMON_SIM_UI_SUITE_ROOTS")

if is_binary(sim_ui_suite_roots) and sim_ui_suite_roots != "" do
  config :lemon_sim_ui, :suite_roots, String.split(sim_ui_suite_roots, ":", trim: true)
end

uploads_dir = System.get_env("LEMON_WEB_UPLOADS_DIR")

if is_binary(uploads_dir) and uploads_dir != "" do
  config :lemon_web, :uploads_dir, uploads_dir
end

store_path = System.get_env("LEMON_STORE_PATH")

if is_binary(store_path) and store_path != "" do
  config :lemon_core, :store_runtime_override, backend_opts: [path: store_path]
  config :lemon_core, LemonCore.RunHistoryStore, path: store_path
  config :lemon_core, LemonCore.MemoryStore, path: store_path
  config :lemon_router, LemonRouter.RoutingFeedbackStore, path: store_path
end

control_plane_port = System.get_env("LEMON_CONTROL_PLANE_PORT")

if is_binary(control_plane_port) and control_plane_port != "" do
  config :lemon_control_plane, :port, String.to_integer(control_plane_port)
end

gateway_health_port = System.get_env("LEMON_GATEWAY_HEALTH_PORT")

if is_binary(gateway_health_port) and gateway_health_port != "" do
  config :lemon_gateway, :health_port, String.to_integer(gateway_health_port)
end

router_health_port = System.get_env("LEMON_ROUTER_HEALTH_PORT")

if is_binary(router_health_port) and router_health_port != "" do
  config :lemon_router, :health_port, String.to_integer(router_health_port)
end

goal_judge_model = System.get_env("LEMON_GOAL_JUDGE_MODEL")

if is_binary(goal_judge_model) and String.trim(goal_judge_model) != "" do
  config :lemon_automation, :goal_judge_model, String.trim(goal_judge_model)
end

# Always-on model arenas: each configured domain continuously runs league
# games with a randomized model lineup per game and records standings under
# its league dir. Enable a domain by setting LEMON_ARENA_<DOMAIN>_MODELS
# (comma-separated provider:model specs). WEREWOLF_ARENA_* remain as werewolf
# aliases from before the arenas were generalized.
arena_env = fn domain_env, suffix, werewolf_alias ->
  value = System.get_env("LEMON_ARENA_#{domain_env}_#{suffix}")

  cond do
    is_binary(value) and String.trim(value) != "" -> String.trim(value)
    domain_env == "WEREWOLF" and is_binary(werewolf_alias) -> String.trim(werewolf_alias)
    true -> nil
  end
end

arena_league_root = System.get_env("LEMON_ARENA_LEAGUE_ROOT")

arenas =
  for {domain, domain_env} <- [
        werewolf: "WEREWOLF",
        space_station: "SPACE_STATION",
        stock_market: "STOCK_MARKET",
        survivor: "SURVIVOR"
      ],
      models = arena_env.(domain_env, "MODELS", System.get_env("WEREWOLF_ARENA_MODELS")),
      models != nil do
    enabled_env =
      arena_env.(domain_env, "ENABLED", System.get_env("WEREWOLF_ARENA_ENABLED")) || "1"

    player_count =
      arena_env.(domain_env, "PLAYER_COUNT", System.get_env("WEREWOLF_ARENA_PLAYER_COUNT"))

    game_delay_ms =
      arena_env.(domain_env, "GAME_DELAY_MS", System.get_env("WEREWOLF_ARENA_GAME_DELAY_MS"))

    league_dir =
      arena_env.(domain_env, "LEAGUE_DIR", System.get_env("WEREWOLF_LEAGUE_DIR")) ||
        (arena_league_root && Path.join(arena_league_root, "#{domain}_league"))

    opts =
      [
        enabled: enabled_env in ["1", "true", "TRUE"],
        models: models |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      ] ++
        ((player_count && [player_count: String.to_integer(player_count)]) || []) ++
        ((game_delay_ms && [game_delay_ms: String.to_integer(game_delay_ms)]) || []) ++
        ((league_dir && [league_dir: league_dir]) || [])

    {domain, opts}
  end

if arenas != [] do
  config :lemon_sim_ui, :arenas, arenas
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
