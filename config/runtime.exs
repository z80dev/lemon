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

# Error reporting sink (Sentry). See docs/error-reporting.md. Dormant unless
# SENTRY_DSN is set: Sentry's own documented "disabled" mode is `dsn: nil`
# (the default), so absent the env var this block is skipped entirely and
# the sentry app boots inert, sending nothing.
sentry_dsn = System.get_env("SENTRY_DSN")

if is_binary(sentry_dsn) and String.trim(sentry_dsn) != "" do
  sentry_environment =
    [System.get_env("LEMON_ENV"), System.get_env("SENTRY_ENVIRONMENT")]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> case do
      nil -> to_string(config_env())
      env -> String.trim(env)
    end

  sentry_release =
    case Application.spec(:lemon_core, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end

  config :sentry,
    dsn: String.trim(sentry_dsn),
    environment_name: sentry_environment,
    release: sentry_release,
    enable_source_code_context: true,
    root_source_code_paths: [File.cwd!()]

  # Sentry.LoggerHandler only reports Logger metadata that already looks like
  # a crash/exit reason by default (capture_log_messages: false), so this
  # captures unhandled exceptions and process crashes without also mirroring
  # every Logger.error/warning call as a Sentry event.
  config :lemon_core, :logger, [
    {:handler, :sentry_handler, Sentry.LoggerHandler,
     %{
       config: %{
         metadata: [:file, :line],
         capture_log_messages: false,
         level: :error
       }
     }}
  ]
end

normalized_env = fn name ->
  case System.get_env(name) do
    value when is_binary(value) ->
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end

    _ ->
      nil
  end
end

access_token = normalized_env.("LEMON_WEB_ACCESS_TOKEN")

if is_binary(access_token) and access_token != "" do
  config :lemon_web, :access_token, access_token
end

sim_ui_access_token = normalized_env.("LEMON_SIM_UI_ACCESS_TOKEN")

if is_binary(sim_ui_access_token) and byte_size(sim_ui_access_token) < 32 do
  raise "LEMON_SIM_UI_ACCESS_TOKEN must be at least 32 bytes"
end

if admin_session_ttl = normalized_env.("LEMON_SIM_UI_ADMIN_SESSION_TTL_SECONDS") do
  case Integer.parse(admin_session_ttl) do
    {ttl, ""} when ttl in 300..86_400 ->
      config :lemon_sim_ui, :admin_session_ttl_seconds, ttl

    _ ->
      raise "LEMON_SIM_UI_ADMIN_SESSION_TTL_SECONDS must be an integer from 300 to 86400"
  end
end

sim_release_name = normalized_env.("RELEASE_NAME")
sim_ui_secret_key_base = normalized_env.("LEMON_SIM_UI_SECRET_KEY_BASE")

sim_ui_endpoint_enabled? =
  config_env() == :prod and
    (sim_release_name == "sim_broadcast_platform" or
       is_binary(sim_ui_secret_key_base))

if sim_ui_endpoint_enabled? do
  required_sim_ui_env = [
    "LEMON_SIM_UI_ACCESS_TOKEN",
    "LEMON_SIM_UI_HOST",
    "LEMON_SIM_UI_SECRET_KEY_BASE",
    "LEMON_STORE_PATH"
  ]

  missing =
    Enum.filter(required_sim_ui_env, &is_nil(normalized_env.(&1)))

  if missing != [] do
    raise "Missing required LemonSim UI production environment: #{Enum.join(missing, ", ")}"
  end

  if byte_size(sim_ui_secret_key_base) < 64 do
    raise "LEMON_SIM_UI_SECRET_KEY_BASE must be at least 64 bytes"
  end

  sim_ui_host = normalized_env.("LEMON_SIM_UI_HOST")

  if String.contains?(sim_ui_host, ["://", "/"]) do
    raise "LEMON_SIM_UI_HOST must be a hostname without a scheme or path"
  end

  if Path.type(normalized_env.("LEMON_STORE_PATH")) != :absolute do
    raise "LEMON_STORE_PATH must be an absolute path in production"
  end
end

if is_binary(sim_ui_access_token) and sim_ui_access_token != "" do
  config :lemon_sim_ui, :access_token, sim_ui_access_token
end

parse_runtime_boolean = fn name, value ->
  case value && String.downcase(value) do
    value when value in ["1", "true"] -> true
    value when value in ["0", "false"] -> false
    _ -> raise "#{name} must be true/false or 1/0"
  end
end

if launcher = normalized_env.("LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER") do
  if parse_runtime_boolean.("LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER", launcher) do
    config :lemon_sim_ui, :public_vending_launcher, true
  end
end

sim_ui_suite_roots = normalized_env.("LEMON_SIM_UI_SUITE_ROOTS")

if is_binary(sim_ui_suite_roots) do
  config :lemon_sim_ui, :suite_roots, String.split(sim_ui_suite_roots, ":", trim: true)
end

uploads_dir = normalized_env.("LEMON_WEB_UPLOADS_DIR")

if is_binary(uploads_dir) do
  config :lemon_web, :uploads_dir, uploads_dir
end

store_path = normalized_env.("LEMON_STORE_PATH")

if is_binary(store_path) do
  config :lemon_core, :store_runtime_override, backend_opts: [path: store_path]
  config :lemon_core, LemonCore.RunHistoryStore, path: store_path
  config :lemon_core, LemonCore.MemoryStore, path: store_path
  config :lemon_router, LemonRouter.RoutingFeedbackStore, path: store_path
end

control_plane_port = normalized_env.("LEMON_CONTROL_PLANE_PORT")

if is_binary(control_plane_port) do
  config :lemon_control_plane, :port, String.to_integer(control_plane_port)
end

gateway_health_port = normalized_env.("LEMON_GATEWAY_HEALTH_PORT")

if is_binary(gateway_health_port) do
  config :lemon_gateway, :health_port, String.to_integer(gateway_health_port)
end

router_health_port = normalized_env.("LEMON_ROUTER_HEALTH_PORT")

if is_binary(router_health_port) do
  config :lemon_router, :health_port, String.to_integer(router_health_port)
end

goal_judge_model = normalized_env.("LEMON_GOAL_JUDGE_MODEL")

if is_binary(goal_judge_model) do
  config :lemon_automation, :goal_judge_model, goal_judge_model
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

parse_runtime_integer = fn name, value, range ->
  case Integer.parse(to_string(value)) do
    {integer, ""} ->
      if integer in range do
        integer
      else
        raise "#{name} must be an integer from #{range.first} to #{range.last}"
      end

    _ ->
      raise "#{name} must be an integer from #{range.first} to #{range.last}"
  end
end

if max_runners = normalized_env.("LEMON_SIM_UI_MAX_CONCURRENT_RUNNERS") do
  config :lemon_sim_ui,
         :max_concurrent_runners,
         parse_runtime_integer.("LEMON_SIM_UI_MAX_CONCURRENT_RUNNERS", max_runners, 1..64)
end

if max_stored_sims = normalized_env.("LEMON_SIM_UI_MAX_STORED_SIMS") do
  config :lemon_sim_ui,
         :max_stored_simulations,
         parse_runtime_integer.("LEMON_SIM_UI_MAX_STORED_SIMS", max_stored_sims, 25..100_000)
end

hosted_rooms_enabled =
  case normalized_env.("LEMON_WEREWOLF_HOSTED_ENABLED") do
    nil -> config_env() != :prod
    value -> parse_runtime_boolean.("LEMON_WEREWOLF_HOSTED_ENABLED", value)
  end

hosted_room_create_token = normalized_env.("LEMON_WEREWOLF_HOST_CREATE_TOKEN")

if hosted_rooms_enabled and sim_ui_endpoint_enabled? do
  if is_nil(hosted_room_create_token) or byte_size(hosted_room_create_token) < 32 do
    raise "LEMON_WEREWOLF_HOST_CREATE_TOKEN must be at least 32 bytes when hosted rooms are enabled"
  end

  if (normalized_env.("LEMON_SIM_UI_URL_SCHEME") || "https") != "https" do
    raise "LEMON_SIM_UI_URL_SCHEME must be https when hosted rooms are enabled"
  end
end

config :lemon_sim_ui, :hosted_rooms_enabled, hosted_rooms_enabled

if is_binary(hosted_room_create_token) do
  config :lemon_sim_ui, :hosted_room_create_token, hosted_room_create_token
end

if hosted_room_limit = normalized_env.("LEMON_WEREWOLF_HOSTED_ROOM_LIMIT") do
  config :lemon_sim_ui,
         :hosted_room_limit,
         parse_runtime_integer.("LEMON_WEREWOLF_HOSTED_ROOM_LIMIT", hosted_room_limit, 1..500)
end

if hosted_room_retention = normalized_env.("LEMON_WEREWOLF_HOSTED_ROOM_RETENTION") do
  config :lemon_sim_ui,
         :hosted_room_retention,
         parse_runtime_integer.(
           "LEMON_WEREWOLF_HOSTED_ROOM_RETENTION",
           hosted_room_retention,
           25..5_000
         )
end

if hosted_lobby_ttl = normalized_env.("LEMON_WEREWOLF_HOSTED_LOBBY_TTL_SECONDS") do
  config :lemon_sim_ui,
         :hosted_lobby_ttl_seconds,
         parse_runtime_integer.(
           "LEMON_WEREWOLF_HOSTED_LOBBY_TTL_SECONDS",
           hosted_lobby_ttl,
           300..2_592_000
         )
end

if hosted_inactive_ttl = normalized_env.("LEMON_WEREWOLF_HOSTED_INACTIVE_TTL_SECONDS") do
  config :lemon_sim_ui,
         :hosted_inactive_ttl_seconds,
         parse_runtime_integer.(
           "LEMON_WEREWOLF_HOSTED_INACTIVE_TTL_SECONDS",
           hosted_inactive_ttl,
           3_600..31_536_000
         )
end

if hosted_ai_model = normalized_env.("LEMON_WEREWOLF_HOSTED_AI_MODEL") do
  config :lemon_sim_ui, :hosted_ai_model, hosted_ai_model
end

if hosted_ai_concurrency = normalized_env.("LEMON_WEREWOLF_HOSTED_AI_CONCURRENCY") do
  config :lemon_sim_ui,
         :hosted_ai_concurrency,
         parse_runtime_integer.(
           "LEMON_WEREWOLF_HOSTED_AI_CONCURRENCY",
           hosted_ai_concurrency,
           1..64
         )
end

# -- PhilosopherChat (multi-agent group chat) --

philosopher_chat_enabled =
  case normalized_env.("LEMON_PHILOSOPHER_CHAT_ENABLED") do
    nil -> config_env() != :prod
    value -> parse_runtime_boolean.("LEMON_PHILOSOPHER_CHAT_ENABLED", value)
  end

config :lemon_sim_ui, :philosopher_chat_enabled, philosopher_chat_enabled

if philosopher_chat_data_root = normalized_env.("LEMON_PHILOSOPHER_CHAT_DATA_ROOT") do
  config :lemon_sim_ui, :philosopher_chat_data_root, philosopher_chat_data_root
end

if philosopher_chat_ai_model = normalized_env.("LEMON_PHILOSOPHER_CHAT_AI_MODEL") do
  config :lemon_sim_ui, :philosopher_chat_ai_model, philosopher_chat_ai_model
end

if philosopher_chat_ai_concurrency =
     normalized_env.("LEMON_PHILOSOPHER_CHAT_AI_CONCURRENCY") do
  config :lemon_sim_ui,
         :philosopher_chat_ai_concurrency,
         parse_runtime_integer.(
           "LEMON_PHILOSOPHER_CHAT_AI_CONCURRENCY",
           philosopher_chat_ai_concurrency,
           1..64
         )
end

if philosopher_chat_password = normalized_env.("LEMON_PHILOSOPHER_CHAT_PASSWORD") do
  config :lemon_sim_ui, :philosopher_chat_password, philosopher_chat_password
end

if philosopher_chat_cors_origins = normalized_env.("LEMON_PHILOSOPHER_CHAT_CORS_ORIGINS") do
  config :lemon_sim_ui, :philosopher_chat_cors_origins, philosopher_chat_cors_origins
end

if philosopher_chat_thread_limit =
     normalized_env.("LEMON_PHILOSOPHER_CHAT_THREAD_LIMIT") do
  config :lemon_sim_ui,
         :philosopher_chat_thread_limit,
         parse_runtime_integer.(
           "LEMON_PHILOSOPHER_CHAT_THREAD_LIMIT",
           philosopher_chat_thread_limit,
           1..200
         )
end

arena_league_root = normalized_env.("LEMON_ARENA_LEAGUE_ROOT")

arenas =
  for {domain, domain_env} <- [
        werewolf: "WEREWOLF",
        space_station: "SPACE_STATION",
        stock_market: "STOCK_MARKET",
        survivor: "SURVIVOR",
        poker: "POKER"
      ],
      models = arena_env.(domain_env, "MODELS", System.get_env("WEREWOLF_ARENA_MODELS")),
      models != nil do
    enabled_env =
      arena_env.(domain_env, "ENABLED", System.get_env("WEREWOLF_ARENA_ENABLED")) || "1"

    player_count =
      arena_env.(domain_env, "PLAYER_COUNT", System.get_env("WEREWOLF_ARENA_PLAYER_COUNT"))

    game_delay_ms =
      arena_env.(domain_env, "GAME_DELAY_MS", System.get_env("WEREWOLF_ARENA_GAME_DELAY_MS"))

    max_game_records =
      arena_env.(
        domain_env,
        "MAX_GAME_RECORDS",
        System.get_env("WEREWOLF_ARENA_MAX_GAME_RECORDS")
      )

    league_dir =
      arena_env.(domain_env, "LEAGUE_DIR", System.get_env("WEREWOLF_LEAGUE_DIR")) ||
        (arena_league_root && Path.join(arena_league_root, "#{domain}_league"))

    opts =
      [
        enabled: parse_runtime_boolean.("LEMON_ARENA_#{domain_env}_ENABLED", enabled_env),
        models:
          models
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(fn spec ->
            case String.split(spec, ":", parts: 2) |> Enum.map(&String.trim/1) do
              [provider, model] when provider != "" and model != "" ->
                "#{provider}:#{model}"

              _ ->
                raise "LEMON_ARENA_#{domain_env}_MODELS contains invalid model spec: #{inspect(spec)}"
            end
          end)
      ] ++
        ((player_count &&
            [
              player_count:
                parse_runtime_integer.(
                  "LEMON_ARENA_#{domain_env}_PLAYER_COUNT",
                  player_count,
                  if(domain == :werewolf, do: 5..8, else: 2..32)
                )
            ]) || []) ++
        ((game_delay_ms &&
            [
              game_delay_ms:
                parse_runtime_integer.(
                  "LEMON_ARENA_#{domain_env}_GAME_DELAY_MS",
                  game_delay_ms,
                  0..600_000
                )
            ]) || []) ++
        ((max_game_records &&
            [
              max_game_records:
                parse_runtime_integer.(
                  "LEMON_ARENA_#{domain_env}_MAX_GAME_RECORDS",
                  max_game_records,
                  25..100_000
                )
            ]) || []) ++
        ((league_dir && [league_dir: league_dir]) || [])

    {domain, opts}
  end

if arenas != [] do
  if sim_ui_endpoint_enabled? do
    Enum.each(arenas, fn {domain, opts} ->
      if opts[:enabled] do
        league_dir = opts[:league_dir]

        if is_nil(league_dir) do
          raise "Enabled #{domain} arena requires LEMON_ARENA_LEAGUE_ROOT or a per-domain LEAGUE_DIR"
        end

        if Path.type(league_dir) != :absolute do
          raise "Enabled #{domain} arena league directory must be absolute"
        end
      end
    end)
  end

  config :lemon_sim_ui, :arenas, arenas
end

# Auto-loop: automatically start and restart games
auto_loop_enabled? =
  case normalized_env.("LEMON_SIM_AUTO_LOOP") do
    nil -> false
    value -> parse_runtime_boolean.("LEMON_SIM_AUTO_LOOP", value)
  end

werewolf_arena_enabled? =
  case Keyword.get(arenas, :werewolf) do
    opts when is_list(opts) ->
      Keyword.get(opts, :enabled, false) and Keyword.get(opts, :models, []) != []

    _ ->
      false
  end

if auto_loop_enabled? and werewolf_arena_enabled? do
  raise "LEMON_SIM_AUTO_LOOP cannot be combined with LEMON_ARENA_WEREWOLF_MODELS"
end

if auto_loop_enabled? do
  werewolf_players =
    case System.get_env("LEMON_SIM_WEREWOLF_PLAYERS") do
      nil -> 6
      "" -> 6
      n -> parse_runtime_integer.("LEMON_SIM_WEREWOLF_PLAYERS", n, 5..8)
    end

  config :lemon_sim_ui, :auto_loop, [
    {:werewolf, [player_count: werewolf_players]}
  ]
end

if config_env() == :prod do
  release_name = System.get_env("RELEASE_NAME")

  configure_endpoint = fn otp_app, endpoint, env_prefix, default_port, required_release ->
    required? = release_name == required_release
    secret_key_base = normalized_env.("#{env_prefix}_SECRET_KEY_BASE")

    if required? or is_binary(secret_key_base) do
      host = normalized_env.("#{env_prefix}_HOST") || "localhost"

      port =
        parse_runtime_integer.(
          "#{env_prefix}_PORT",
          System.get_env("#{env_prefix}_PORT") || Integer.to_string(default_port),
          1..65_535
        )

      url_scheme = normalized_env.("#{env_prefix}_URL_SCHEME") || "https"

      if url_scheme not in ["http", "https"] do
        raise "#{env_prefix}_URL_SCHEME must be http or https"
      end

      url_port =
        parse_runtime_integer.(
          "#{env_prefix}_URL_PORT",
          System.get_env("#{env_prefix}_URL_PORT") ||
            if(url_scheme == "https", do: "443", else: "80"),
          1..65_535
        )

      endpoint_config = [
        url: [host: host, port: url_port, scheme: url_scheme],
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
