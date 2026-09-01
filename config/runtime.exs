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
#
# :sentry is an optional dependency of lemon_core, so a build that leaves it
# out skips this block too rather than configuring a handler module that does
# not exist. LemonCore.Application drops such handlers defensively as well.
sentry_dsn = System.get_env("SENTRY_DSN")

if is_binary(sentry_dsn) and String.trim(sentry_dsn) != "" and
     Code.ensure_loaded?(Sentry.LoggerHandler) do
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

uploads_dir = normalized_env.("LEMON_WEB_UPLOADS_DIR")

if is_binary(uploads_dir) do
  config :lemon_web, :uploads_dir, uploads_dir
end

store_path = normalized_env.("LEMON_STORE_PATH")

if is_binary(store_path) do
  config :lemon_core, :store_runtime_override, backend_opts: [path: store_path]
  config :lemon_core, LemonCore.RunHistoryStore, path: store_path
  config :lemon_memory, LemonMemory.Store, path: store_path
  config :lemon_router, LemonRouter.RoutingFeedbackStore, path: store_path
end

control_plane_port = normalized_env.("LEMON_CONTROL_PLANE_PORT")

if is_binary(control_plane_port) do
  config :lemon_control_plane, :port, String.to_integer(control_plane_port)
end

control_plane_operator_token = normalized_env.("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")

if is_binary(control_plane_operator_token) do
  config :lemon_control_plane, :operator_token, control_plane_operator_token
end

control_plane_allow_unauthenticated_loopback =
  case normalized_env.("LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK") do
    nil ->
      false

    value ->
      case String.downcase(value) do
        enabled when enabled in ["1", "true"] ->
          true

        disabled when disabled in ["0", "false"] ->
          false

        _ ->
          raise "LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK must be true/false or 1/0"
      end
  end

config :lemon_control_plane,
       :allow_unauthenticated_loopback_operator,
       control_plane_allow_unauthenticated_loopback

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
end
