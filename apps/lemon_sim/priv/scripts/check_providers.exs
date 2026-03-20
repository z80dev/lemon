config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

IO.puts("=== Configured Providers ===")
IO.inspect(config.providers, pretty: true, limit: :infinity)

IO.puts("\n=== Resolving API keys ===")

for provider_name <- ["kimi", "kimi_coding", "openrouter", "openai-codex"] do
  cfg = LemonCore.Config.Providers.get_provider(config.providers, provider_name)
  has_key = is_binary(cfg[:api_key]) and cfg[:api_key] != ""
  has_secret = is_binary(cfg[:api_key_secret])

  status = cond do
    provider_name == "openai-codex" ->
      case LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token() do
        token when is_binary(token) and token != "" -> "OK (OAuth)"
        _ -> "MISSING"
      end
    has_key -> "OK (direct key)"
    has_secret ->
      case LemonCore.Secrets.resolve(cfg[:api_key_secret], env_fallback: true) do
        {:ok, v, _} when is_binary(v) and v != "" -> "OK (secret: #{cfg[:api_key_secret]})"
        _ -> "FAILED to resolve #{cfg[:api_key_secret]}"
      end
    true -> "NOT CONFIGURED"
  end

  IO.puts("  #{provider_name}: #{status}")
end
