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

# Load voice API keys from ~/.zeebot/api_keys/ in dev
if config_env() == :dev do
  keys_dir = Path.expand("~/.zeebot/api_keys")

  parse_twilio = fn path ->
    with {:ok, content} <- File.read(path),
         [_ | _] = lines <- String.split(content, "\n") do
      sid =
        Enum.find_value(lines, fn line ->
          case String.split(line, "Account SID ", parts: 2) do
            [_, value] -> String.trim(value)
            _ -> nil
          end
        end)

      token =
        Enum.find_value(lines, fn line ->
          case String.split(line, "Auth token ", parts: 2) do
            [_, value] -> String.trim(value)
            _ -> nil
          end
        end)

      if sid && token, do: {sid, token}
    else
      _ -> nil
    end
  end

  parse_key_file = fn path ->
    with {:ok, content} <- File.read(path) do
      content
      |> String.split("\n", trim: true)
      |> List.last()
      |> case do
        nil -> nil
        key -> String.trim(key)
      end
    else
      _ -> nil
    end
  end

  voice_config =
    []
    |> then(fn acc ->
      case parse_twilio.(Path.join(keys_dir, "twilio.txt")) do
        {sid, token} ->
          [{:twilio_account_sid, sid}, {:twilio_auth_token, token} | acc]

        _ ->
          acc
      end
    end)
    |> then(fn acc ->
      case parse_key_file.(Path.join(keys_dir, "deepgram.txt")) do
        nil -> acc
        key -> [{:deepgram_api_key, key} | acc]
      end
    end)
    |> then(fn acc ->
      case parse_key_file.(Path.join(keys_dir, "elevenlabs.txt")) do
        nil -> acc
        key -> [{:elevenlabs_api_key, key} | acc]
      end
    end)

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
