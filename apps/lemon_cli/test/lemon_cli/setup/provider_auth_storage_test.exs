defmodule LemonCli.Setup.ProviderAuthStorageTest do
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.Provider
  alias LemonCore.{Secrets, Store}
  alias LemonCore.Store.SqliteBackend

  setup do
    Runner.ensure_required_apps!()
    :ok = Supervisor.terminate_child(LemonCore.Supervisor, Store)

    root =
      Path.join(System.tmp_dir!(), "provider_auth_storage_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    key_path = Path.join(root, "master_key")
    File.write!(key_path, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_path, 0o600)
    previous_settings = Application.fetch_env(:lemon_core, :secrets)
    previous_ambient = System.get_env("ANTHROPIC_API_KEY")
    Application.put_env(:lemon_core, :secrets, key_providers: [:file], key_file: key_path)
    System.put_env("ANTHROPIC_API_KEY", "private-ambient-key")

    on_exit(fn ->
      case previous_settings do
        {:ok, settings} -> Application.put_env(:lemon_core, :secrets, settings)
        :error -> Application.delete_env(:lemon_core, :secrets)
      end

      if previous_ambient,
        do: System.put_env("ANTHROPIC_API_KEY", previous_ambient),
        else: System.delete_env("ANTHROPIC_API_KEY")

      {:ok, _} = Supervisor.restart_child(LemonCore.Supervisor, Store)
      File.rm_rf!(root)
    end)

    {:ok, root: root, key_path: key_path}
  end

  for failure <- [
        :unavailable,
        :corrupt_sqlite,
        :unopenable_startup,
        :missing_master_key,
        :wrong_master_key
      ],
      provider <- ["anthropic", "openrouter"] do
    test "#{provider} status/logout refuse #{failure} without losing selected authority", ctx do
      provider = unquote(provider)
      failure = unquote(failure)
      path = Path.join(ctx.root, "store")
      start_store(path)
      config_path = configure(ctx.root, provider)
      original_config = File.read!(config_path)
      {:ok, _} = Secrets.set("selected_login", login(provider))
      {:ok, _} = Secrets.set("named_login", login(provider))
      database = Path.join(path, "store.sqlite3")

      case failure do
        :unavailable ->
          stop_store()

        :corrupt_sqlite ->
          execute_sql(path, """
          UPDATE lemon_store_kv SET value_blob = x'707269766174652d636f7272757074'
          WHERE table_name = 'secrets_v1'
          """)

        :unopenable_startup ->
          stop_store()
          File.rename!(database, database <> ".saved")
          File.mkdir!(database)

          assert {:error, {:backend_init_failed, {:sqlite_init_failed, ^database, _}}} =
                   GenServer.start(
                     Store,
                     [name: Store, backend: SqliteBackend, backend_opts: [path: path]],
                     name: Store
                   )

        :missing_master_key ->
          File.rm!(ctx.key_path)

        :wrong_master_key ->
          File.write!(ctx.key_path, Base.encode64(:crypto.strong_rand_bytes(32)))
      end

      failed_bytes = database_bytes(path)

      for flag <- ["--status", "--logout"], named? <- [false, true] do
        args = [provider, flag, "--config-path", config_path]
        args = if named?, do: args ++ ["--secret-name", "named_login"], else: args
        assert {:error, :login_read_failed} = Provider.run(args, io())
        assert File.read!(config_path) == original_config
        assert database_bytes(path) == failed_bytes
        assert_receive {:error, message}
        refute message =~ "private-"
        refute message =~ "sqlite"
        refute message =~ ctx.root
        refute_receive {:info, _}
      end
    end
  end

  for provider <- ["anthropic", "openrouter"] do
    test "#{provider} logout refuses an actual SQLite delete failure without changing authority",
         ctx do
      provider = unquote(provider)
      path = Path.join(ctx.root, "store")
      start_store(path)
      config_path = configure(ctx.root, provider)
      original_config = File.read!(config_path)
      {:ok, _} = Secrets.set("selected_login", login(provider))
      {:ok, _} = Secrets.set("named_login", login(provider))

      execute_sql(path, """
      CREATE TRIGGER fail_secret_delete BEFORE DELETE ON lemon_store_kv
      WHEN OLD.table_name = 'secrets_v1'
      BEGIN SELECT RAISE(ABORT, 'private-delete-failure'); END;
      """)

      for name <- ["selected_login", "named_login"] do
        args = [provider, "--logout", "--config-path", config_path, "--secret-name", name]
        assert {:error, :login_delete_failed} = Provider.run(args, io())
        assert File.read!(config_path) == original_config
        assert {:ok, _} = Secrets.get("selected_login")
        assert {:ok, _} = Secrets.get(name)
        assert_receive {:error, message}
        refute message =~ "private-"
        refute message =~ ctx.root
        refute_receive {:info, _}
      end

      execute_sql(path, "DROP TRIGGER fail_secret_delete")
      stop_store()
      start_store(path)
      assert {:ok, _} = Secrets.get("selected_login")
      assert {:ok, _} = Secrets.get("named_login")
    end
  end

  test "confirmed absence permits stale-setting removal but named absence preserves selection",
       ctx do
    path = Path.join(ctx.root, "store")
    start_store(path)
    config_path = configure(ctx.root, "anthropic")
    original_config = File.read!(config_path)
    {:ok, _} = Secrets.set("selected_login", login("anthropic"))

    assert :ok = Provider.run(command(config_path, "--status", "absent_login"), io())
    assert :ok = Provider.run(command(config_path, "--logout", "absent_login"), io())
    assert File.read!(config_path) == original_config
    assert {:ok, _} = Secrets.get("selected_login")

    assert :ok = Provider.run(command(config_path, "--logout", "selected_login"), io())
    assert {:error, :not_found} = Secrets.get("selected_login")
    File.write!(config_path, original_config)
    assert :ok = Provider.run(command(config_path, "--status", "selected_login"), io())
    assert File.read!(config_path) == original_config
    assert :ok = Provider.run(command(config_path, "--logout", "selected_login"), io())
    config = Toml.decode!(File.read!(config_path))
    refute Map.has_key?(config["providers"]["anthropic"], "auth_source")
    refute Map.has_key?(config["providers"]["anthropic"], "oauth_secret")
  end

  defp start_store(path) do
    pid =
      start_supervised!(%{
        id: :auth_storage_store,
        start:
          {Store, :start_link,
           [[backend: SqliteBackend, backend_opts: [path: path], cached_tables: []]]},
        restart: :temporary
      })

    backend_state = :sys.get_state(pid).backend_state
    on_exit({:sqlite, pid}, fn -> SqliteBackend.close(backend_state) end)
    pid
  end

  defp stop_store do
    pid = Process.whereis(Store)
    :ok = SqliteBackend.close(:sys.get_state(pid).backend_state)
    on_exit({:sqlite, pid}, fn -> :ok end)
    :ok = stop_supervised(:auth_storage_store)
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

  defp execute_sql(path, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(Path.join(path, "store.sqlite3"))

    try do
      :ok = Exqlite.Sqlite3.execute(conn, sql)
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  defp configure(root, provider) do
    path = Path.join(root, "config.toml")
    key = if provider == "openrouter", do: "api_key_secret", else: "oauth_secret"

    File.write!(path, """
    # retain selected authority
    [providers.#{provider}]
    auth_source = "oauth"
    #{key} = "selected_login"
    """)

    path
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

  defp command(config_path, flag, name),
    do: ["anthropic", flag, "--config-path", config_path, "--secret-name", name]

  defp io do
    pid = self()

    %{
      info: fn message -> send(pid, {:info, message}) end,
      error: fn message -> send(pid, {:error, message}) end,
      prompt: fn _ -> raise "unexpected interactive prompt" end,
      secret: fn _ -> raise "unexpected interactive secret prompt" end
    }
  end
end
