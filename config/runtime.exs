import Config

# Load telegram config from TOML file at runtime
# This runs before applications start, so the config is available to supervisors

gateway_toml_path = Path.expand("~/.lemon/gateway.toml")

if File.exists?(gateway_toml_path) do
  case Toml.decode_file(gateway_toml_path) do
    {:ok, toml} ->
      telegram_config = toml["telegram"] || %{}

      if telegram_config["bot_token"] do
        config :lemon_gateway, :telegram,
          bot_token: telegram_config["bot_token"],
          allowed_chat_ids: telegram_config["allowed_chat_ids"],
          poll_interval_ms: telegram_config["poll_interval_ms"] || 1000,
          debounce_ms: telegram_config["debounce_ms"] || 1000,
          allow_queue_override: telegram_config["allow_queue_override"] || false
      end

    {:error, reason} ->
      IO.puts("[runtime.exs] Failed to parse #{gateway_toml_path}: #{inspect(reason)}")
  end
end
