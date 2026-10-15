defmodule LemonCli.Setup.ProviderAuthStorageTest do
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.Provider
  alias LemonCore.{Secrets, Store}
  alias LemonCore.Store.JsonlBackend

  setup do
    Runner.ensure_required_apps!()
    :ok = Supervisor.terminate_child(LemonCore.Supervisor, Store)

    root =
      Path.join(System.tmp_dir!(), "provider_auth_storage_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    key_path = Path.join(root, "master_key")
    File.write!(key_path, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_path, 0o600)
    previous_settings = Application.fetch_env(:lemon_core, Secrets)
    previous_ambient = System.get_env("ANTHROPIC_API_KEY")
    Application.put_env(:lemon_core, Secrets, key_providers: [:file], key_file: key_path)
    System.put_env("ANTHROPIC_API_KEY", "private-ambient-key")

    on_exit(fn ->
      case previous_settings do
        {:ok, settings} -> Application.put_env(:lemon_core, Secrets, settings)
        :error -> Application.delete_env(:lemon_core, Secrets)
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
        :corrupt_jsonl,
        :corrupt_startup,
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
      journal = Path.join(path, "secrets_v1.jsonl")
      durable = File.read!(journal)

      case failure do
        :unavailable ->
          :ok = stop_supervised(:auth_storage_store)

        :corrupt_jsonl ->
          :ok = stop_supervised(:auth_storage_store)
          File.rm!(journal)
          start_store(path)
          File.write!(journal, durable <> "private-corrupt-payload\n")

        :corrupt_startup ->
          :ok = stop_supervised(:auth_storage_store)
          File.write!(journal, durable <> "private-corrupt-payload\n")

          assert {:error, {:backend_init_failed, {:jsonl_unavailable, :corrupt_table}}} =
                   GenServer.start(
                     Store,
                     [name: Store, backend: JsonlBackend, backend_opts: [path: path]],
                     name: Store
                   )

        :missing_master_key ->
          File.rm!(ctx.key_path)

        :wrong_master_key ->
          File.write!(ctx.key_path, Base.encode64(:crypto.strong_rand_bytes(32)))
      end

      failed_bytes = File.read!(journal)

      for flag <- ["--status", "--logout"], named? <- [false, true] do
        args = [provider, flag, "--config-path", config_path]
        args = if named?, do: args ++ ["--secret-name", "named_login"], else: args
        assert {:error, :login_read_failed} = Provider.run(args, io())
        assert File.read!(config_path) == original_config
        assert File.read!(journal) == failed_bytes
        assert_receive {:error, message}
        refute message =~ "private-"
        refute message =~ "jsonl"
        refute message =~ ctx.root
        refute_receive {:info, _}
      end
    end
  end

  for provider <- ["anthropic", "openrouter"] do
    test "#{provider} logout refuses an actual JSONL delete failure without changing authority",
         ctx do
      provider = unquote(provider)
      path = Path.join(ctx.root, "store")
      start_store(path)
      config_path = configure(ctx.root, provider)
      original_config = File.read!(config_path)
      {:ok, _} = Secrets.set("selected_login", login(provider))
      {:ok, _} = Secrets.set("named_login", login(provider))
      journal = Path.join(path, "secrets_v1.jsonl")
      durable = File.read!(journal)
      saved = journal <> ".saved"
      :ok = File.rename(journal, saved)
      File.mkdir!(journal)

      for name <- ["selected_login", "named_login"] do
        args = [provider, "--logout", "--config-path", config_path, "--secret-name", name]
        assert {:error, :login_delete_failed} = Provider.run(args, io())
        assert File.read!(config_path) == original_config
        assert File.read!(saved) == durable
        assert {:ok, _} = Secrets.get(name)
        assert_receive {:error, message}
        refute message =~ "private-"
        refute message =~ ctx.root
        refute_receive {:info, _}
      end

      :ok = File.rmdir(journal)
      :ok = File.rename(saved, journal)
      :ok = stop_supervised(:auth_storage_store)
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
    start_supervised!(%{
      id: :auth_storage_store,
      start:
        {Store, :start_link,
         [[backend: JsonlBackend, backend_opts: [path: path], cached_tables: []]]},
      restart: :temporary
    })
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
