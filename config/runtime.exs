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

uploads_dir = System.get_env("LEMON_WEB_UPLOADS_DIR")

if is_binary(uploads_dir) and uploads_dir != "" do
  config :lemon_web, :uploads_dir, uploads_dir
end

# Load voice API keys from ~/.lemon/secrets/ in dev
if config_env() == :dev do
  secrets_dir = Path.expand("~/.lemon/secrets")

  read_secret = fn name ->
    case File.read(Path.join(secrets_dir, name)) do
      {:ok, content} -> String.trim(content)
      _ -> nil
    end
  end

  voice_config =
    [
      twilio_account_sid: read_secret.("twilio_account_sid"),
      twilio_auth_token: read_secret.("twilio_auth_token"),
      deepgram_api_key: read_secret.("deepgram_api_key"),
      elevenlabs_api_key: read_secret.("elevenlabs_api_key")
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)

  if voice_config != [] do
    config :lemon_gateway, voice_config
  end
end

if config_env() == :prod do
  host = System.get_env("LEMON_WEB_HOST") || "localhost"
  port = String.to_integer(System.get_env("LEMON_WEB_PORT") || "4080")

  secret_key_base = System.fetch_env!("LEMON_WEB_SECRET_KEY_BASE")

  endpoint_config = [
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base
  ]

  endpoint_config =
    if System.get_env("PHX_SERVER") in ["1", "true", "TRUE"] do
      Keyword.put(endpoint_config, :server, true)
    else
      endpoint_config
    end

  config :lemon_web, LemonWeb.Endpoint, endpoint_config
end
