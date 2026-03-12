config = LemonCore.Config.Modular.load(project_dir: File.cwd!())
cfg = LemonCore.Config.Providers.get_provider(config.providers, "github_copilot")
IO.puts("Config: #{inspect(cfg)}")

case cfg[:api_key_secret] do
  nil -> IO.puts("No api_key_secret configured")
  secret ->
    IO.puts("Secret name: #{secret}")
    result = LemonCore.Secrets.resolve(secret, env_fallback: true)
    case result do
      {:ok, val, source} -> IO.puts("Resolved: #{String.slice(val, 0, 8)}... (source: #{source})")
      {:error, reason} -> IO.puts("Failed: #{inspect(reason)}")
    end
end
