# Run from the umbrella root: mix run --no-start scripts/provider_auth_store_truth_smoke.exs
# Offline, no ExUnit: real public model commands, encrypted secrets and SQLite files.
defmodule LemonScripts.ProviderAuthStoreTruthSmoke do
  alias LemonCli.{CLI, Onboarding.Runner, Setup.Provider}
  alias LemonCore.{Secrets, Store}
  alias LemonCore.Store.SqliteBackend

  def main do
    root =
      Path.join(System.tmp_dir!(), "auth_store_truth_smoke_#{System.unique_integer([:positive])}")

    check!(Process.whereis(LemonCore.Supervisor) == nil, "use a fresh mix run --no-start process")
    File.mkdir_p!(root)
    previous_home = System.get_env("HOME")
    previous_ambient = System.get_env("ANTHROPIC_API_KEY")
    settings = Application.fetch_env(:lemon_core, Secrets)
    store_settings = Application.fetch_env(:lemon_core, :store_runtime_override)
    System.put_env("HOME", root)
    System.put_env("ANTHROPIC_API_KEY", "private-ambient-key")

    Application.put_env(:lemon_core, :store_runtime_override,
      backend: SqliteBackend,
      backend_opts: [path: Path.join(root, "bootstrap_store")],
      cached_tables: []
    )

    try do
      Runner.ensure_required_apps!()
      :ok = Supervisor.terminate_child(LemonCore.Supervisor, Store)

      for provider <- ["anthropic", "openrouter"],
          failure <- [:unavailable, :unopenable_startup, :corrupt_value, :missing_key, :wrong_key] do
        scenario(root, provider, failure)
      end

      Enum.each(["anthropic", "openrouter"], &delete_failure(root, &1))
      IO.puts("provider auth store truth: 12 isolated consumer scenarios passed")
    after
      stop_store()
      restore_setting(Secrets, settings)
      restore_setting(:store_runtime_override, store_settings)
      restore_env("HOME", previous_home)
      restore_env("ANTHROPIC_API_KEY", previous_ambient)
      File.rm_rf!(root)
    end
  end

  defp scenario(root, provider, failure) do
    dir = Path.join(root, "#{provider}_#{failure}")
    path = Path.join(dir, "store")
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "master_key")
    key_bytes = Base.encode64(:crypto.strong_rand_bytes(32))
    File.write!(key_path, key_bytes)
    File.chmod!(key_path, 0o600)
    Application.put_env(:lemon_core, Secrets, key_providers: [:file], key_file: key_path)
    :ok = start_store(path)
    config_path = Path.join(dir, "config.toml")
    config_key = if provider == "openrouter", do: "api_key_secret", else: "oauth_secret"

    original_config = """
    # selected OAuth authority must survive unreadable storage
    [providers.#{provider}]
    auth_source = "oauth"
    #{config_key} = "selected_login"
    """

    File.write!(config_path, original_config)
    value = login(provider)
    {:ok, _} = Secrets.set("selected_login", value)
    {:ok, _} = Secrets.set("named_login", value)
    database = Path.join(path, "store.sqlite3")
    stop_store()
    durable = File.read!(database)
    :ok = start_store(path)

    case failure do
      :unavailable ->
        stop_store()

      :unopenable_startup ->
        stop_store()
        File.rename!(database, database <> ".saved")
        File.mkdir!(database)

        {:error, {:backend_init_failed, {:sqlite_init_failed, ^database, _}}} =
          GenServer.start(Store, store_opts(path), name: Store)

      :corrupt_value ->
        execute_sql(path, """
        UPDATE lemon_store_kv SET value_blob = x'707269766174652d636f7272757074'
        WHERE table_name = 'secrets_v1'
        """)

      :missing_key ->
        File.rm!(key_path)

      :wrong_key ->
        File.write!(key_path, Base.encode64(:crypto.strong_rand_bytes(32)))
    end

    failed_bytes = database_bytes(path)

    for flag <- ["--status", "--logout"], name <- [nil, "named_login"] do
      args = command(provider, config_path, flag, name)
      {:error, :login_read_failed} = Provider.run(args, io())
      messages = drain_messages()
      check!(Enum.any?(messages, fn {kind, _} -> kind == :error end), "missing command refusal")

      check!(
        Enum.all?(messages, fn {kind, _} -> kind == :error end),
        "reported login state on failure"
      )

      Enum.each(messages, fn {_, text} ->
        check!(!String.contains?(text, ["private-", "sqlite", dir]), "unbounded error projection")
      end)

      1 = CLI.run(["model" | args])
      check!(File.read!(config_path) == original_config, "failure changed selected authority")
      check!(database_bytes(path) == failed_bytes, "failure changed durable login bytes")
    end

    # Repair storage/key authority, then prove both accounts remain and logout is isolated.
    stop_store()
    File.write!(key_path, key_bytes)
    File.chmod!(key_path, 0o600)
    if File.dir?(database), do: File.rmdir!(database)
    File.write!(database, durable)
    :ok = start_store(path)
    {:ok, ^value} = Secrets.get("selected_login")
    {:ok, ^value} = Secrets.get("named_login")
    0 = CLI.run(["model" | command(provider, config_path, "--status", "named_login")])
    0 = CLI.run(["model" | command(provider, config_path, "--logout", "named_login")])
    {:error, :not_found} = Secrets.get("named_login")
    {:ok, ^value} = Secrets.get("selected_login")
    check!(File.read!(config_path) == original_config, "named logout changed selected authority")
    0 = CLI.run(["model" | command(provider, config_path, "--status", "named_login")])
    0 = CLI.run(["model" | command(provider, config_path, "--logout", "named_login")])
    check!(File.read!(config_path) == original_config, "named absence changed selected authority")
    0 = CLI.run(["model" | command(provider, config_path, "--logout", nil)])
    {:error, :not_found} = Secrets.get("selected_login")
    File.write!(config_path, original_config)
    0 = CLI.run(["model" | command(provider, config_path, "--status", nil)])
    check!(File.read!(config_path) == original_config, "status mutated stale settings")
    0 = CLI.run(["model" | command(provider, config_path, "--logout", nil)])
    cfg = Toml.decode!(File.read!(config_path))["providers"][provider]
    check!(!Map.has_key?(cfg, "auth_source"), "confirmed absence retained stale auth source")
    check!(!Map.has_key?(cfg, "oauth_secret"), "confirmed absence retained stale OAuth reference")
    stop_store()
  end

  defp delete_failure(root, provider) do
    dir = Path.join(root, "#{provider}_delete_failure")
    path = Path.join(dir, "store")
    File.mkdir_p!(dir)
    key_path = Path.join(dir, "master_key")
    File.write!(key_path, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_path, 0o600)
    Application.put_env(:lemon_core, Secrets, key_providers: [:file], key_file: key_path)
    :ok = start_store(path)
    config_path = Path.join(dir, "config.toml")
    config_key = if provider == "openrouter", do: "api_key_secret", else: "oauth_secret"

    original_config =
      "[providers.#{provider}]\nauth_source = \"oauth\"\n#{config_key} = \"selected_login\"\n"

    File.write!(config_path, original_config)
    value = login(provider)
    {:ok, _} = Secrets.set("selected_login", value)
    {:ok, _} = Secrets.set("named_login", value)

    execute_sql(path, """
    CREATE TRIGGER fail_secret_delete BEFORE DELETE ON lemon_store_kv
    WHEN OLD.table_name = 'secrets_v1'
    BEGIN SELECT RAISE(ABORT, 'private-delete-failure'); END;
    """)

    for name <- [nil, "named_login"] do
      args = command(provider, config_path, "--logout", name)
      {:error, :login_delete_failed} = Provider.run(args, io())
      [{:error, message}] = drain_messages()
      check!(!String.contains?(message, ["private-", "sqlite", dir]), "unbounded delete error")
      1 = CLI.run(["model" | args])

      check!(
        File.read!(config_path) == original_config,
        "delete failure changed selected authority"
      )

      {:ok, ^value} = Secrets.get("selected_login")
      {:ok, ^value} = Secrets.get("named_login")
    end

    execute_sql(path, "DROP TRIGGER fail_secret_delete")
    stop_store()
    :ok = start_store(path)
    {:ok, ^value} = Secrets.get("selected_login")
    {:ok, ^value} = Secrets.get("named_login")
    stop_store()
  end

  defp execute_sql(path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(path, "store.sqlite3"))

    try do
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  defp database_bytes(path) do
    database = Path.join(path, "store.sqlite3")

    if File.dir?(database) do
      File.read!(database <> ".saved")
    else
      wal =
        case File.read(database <> "-wal") do
          {:ok, bytes} -> bytes
          {:error, :enoent} -> <<>>
        end

      File.read!(database) <> wal
    end
  end

  defp store_opts(path),
    do: [name: Store, backend: SqliteBackend, backend_opts: [path: path], cached_tables: []]

  defp start_store(path) do
    {:ok, _} = GenServer.start(Store, store_opts(path), name: Store)
    :ok
  end

  defp stop_store do
    if pid = Process.whereis(Store) do
      :ok = SqliteBackend.close(:sys.get_state(pid).backend_state)
      GenServer.stop(pid)
    end

    :ok
  end

  defp command(provider, config_path, flag, name) do
    args = [provider, flag, "--config-path", config_path]
    if name, do: args ++ ["--secret-name", name], else: args
  end

  defp login("openrouter"), do: "private-minted-key"

  defp login("anthropic") do
    Jason.encode!(%{
      "type" => "anthropic_oauth",
      "access_token" => "private-access-token",
      "refresh_token" => "private-refresh-token",
      "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
    })
  end

  defp io do
    pid = self()

    %{
      info: fn message -> send(pid, {:auth_smoke, :info, message}) end,
      error: fn message -> send(pid, {:auth_smoke, :error, message}) end,
      prompt: fn _ -> raise "unexpected interactive prompt" end,
      secret: fn _ -> raise "unexpected interactive secret prompt" end
    }
  end

  defp drain_messages(acc \\ []) do
    receive do
      {:auth_smoke, kind, message} -> drain_messages([{kind, message} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp check!(true, _message), do: :ok
  defp check!(false, message), do: raise(message)
  defp restore_setting(key, {:ok, value}), do: Application.put_env(:lemon_core, key, value)
  defp restore_setting(key, :error), do: Application.delete_env(:lemon_core, key)
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

LemonScripts.ProviderAuthStoreTruthSmoke.main()
