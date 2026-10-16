defmodule LemonCli.Setup.ProviderManagementEncryptedTest do
  # Real encryption + real runtime resolver, with an isolated HOME, master key,
  # JSONL Store and configuration. No credentials or state from the user; Req
  # is a fail-closed test plug, not a live provider validation.
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, ProviderNames}
  alias LemonCli.Onboarding.{Providers, Runner}
  alias LemonCli.Setup.ProviderManagement, as: Management
  alias LemonCore.{Config, Secrets, Store}
  alias LemonCore.Store.JsonlBackend
  alias LemonCli.Setup.ProviderAuth

  # Decoder barrier only: storage/encryption remain real. It pauses logout
  # after selecting the old login, before its serialized persistence patch.
  defmodule BlockingDecoder do
    def decode_secret(value) do
      send(Process.whereis(__MODULE__), {:decoding_selected_login, self()})

      receive do
        :continue -> LemonAi.Auth.KimiCodeOAuth.decode_secret(value)
      after
        5_000 -> raise "test decoder barrier timed out"
      end
    end
  end

  setup do
    Runner.ensure_required_apps!()
    :ok = Supervisor.terminate_child(LemonCore.Supervisor, Store)

    root =
      Path.join(
        System.tmp_dir!(),
        "provider_management_encrypted_#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    cwd = Path.join(root, "project")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)
    key_path = Path.join(root, "master_key")
    File.write!(key_path, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_path, 0o600)
    previous_settings = Map.new([Secrets, :paths], &{&1, Application.fetch_env(:lemon_core, &1)})

    names = [
      "HOME",
      "LEMON_SECRETS_MASTER_KEY",
      "LEMON_DEFAULT_PROVIDER",
      "LEMON_DEFAULT_MODEL"
      | Enum.flat_map(ProviderNames.all_canonical_names(), &ProviderNames.env_vars/1)
    ]

    previous_env = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(previous_env, fn {name, _} -> System.delete_env(name) end)
    System.put_env("HOME", home)
    Application.put_env(:lemon_core, :paths, home_dir: home)

    Application.put_env(:lemon_core, Secrets,
      key_providers: [:file],
      key_file: key_path,
      write_lock_wait_ms: 100
    )

    store_path = Path.join(root, "store")

    store =
      start_supervised!(%{
        id: :provider_management_encrypted_store,
        start:
          {Store, :start_link,
           [
             [
               name: Store,
               backend: JsonlBackend,
               backend_opts: [path: store_path],
               cached_tables: []
             ]
           ]},
        restart: :temporary
      })

    previous_req = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(__MODULE__, fn _ ->
      flunk("provider management must not make an HTTP request")
    end)

    on_exit(fn ->
      Req.default_options(previous_req)
      Req.Test.set_req_test_to_private(%{})
      if Process.alive?(store), do: GenServer.stop(store)

      Enum.each(previous_settings, fn
        {name, {:ok, value}} -> Application.put_env(:lemon_core, name, value)
        {name, :error} -> Application.delete_env(:lemon_core, name)
      end)

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      {:ok, _} = Supervisor.restart_child(LemonCore.Supervisor, Store)
      File.rm_rf!(root)
    end)

    target = %{id: "node:offline-test", nodeId: "offline-test", hostname: "isolated-host"}

    {:ok,
     root: root,
     home: home,
     cwd: cwd,
     store_path: store_path,
     opts: [target: target, cwd: cwd],
     config_path: Config.global_path()}
  end

  test "real API-key add/replace/default/disconnect resolves through loaded runtime config",
       ctx do
    # Runtime secret-source fallback uses the process cwd. Scope that too, so
    # neither its project config nor the canonical global path can read the repo
    # or the operator's home. Every actual store call below is the real module.
    File.cd!(ctx.cwd, fn ->
      assert {:ok, first} = Management.set_api_key("openai", "synthetic-private-first", ctx.opts)
      assert Enum.find(first.providers, &(&1.id == "openai")).status == "ready"
      config = Config.cached(ctx.cwd)
      assert %Config{} = config

      assert Credentials.resolve_provider_api_key(:openai, config.providers) ==
               "synthetic-private-first"

      name = config.providers["openai"].api_key_secret
      assert {:ok, "synthetic-private-first"} = Secrets.get(name)

      assert {:ok, second} =
               Management.set_api_key("openai", "synthetic-private-second", ctx.opts)

      assert Credentials.resolve_provider_api_key(:openai, Config.cached(ctx.cwd).providers) ==
               "synthetic-private-second"

      assert {:ok, defaults} = Management.set_default("openai", "gpt-6-sol", ctx.opts)
      assert defaults.default == %{providerId: "openai", modelId: "gpt-6-sol"}
      assert Config.cached(ctx.cwd).agent.default_provider == "openai"
      assert Config.cached(ctx.cwd).agent.default_model == "openai:gpt-6-sol"

      config_bytes = File.read!(ctx.config_path)
      journal = File.read!(Path.join(ctx.store_path, "secrets_v1.jsonl"))
      refute config_bytes =~ "synthetic-private"
      refute journal =~ "synthetic-private"
      assert journal =~ "ciphertext"
      refute Jason.encode!(second) =~ "synthetic-private"
      refute Jason.encode!(second) =~ name
      refute Jason.encode!(second) =~ ctx.root
      assert Bitwise.band(File.stat!(ctx.config_path).mode, 0o777) == 0o600

      assert {:ok, disconnected} = Management.disconnect("openai", ctx.opts)
      assert Enum.find(disconnected.providers, &(&1.id == "openai")).status == "needs_login"
      assert {:error, :not_found} = Secrets.get(name)

      assert Credentials.resolve_provider_api_key(:openai, Config.cached(ctx.cwd).providers) ==
               nil

      assert disconnected.default == defaults.default
    end)
  end

  test "explicit onboarding config is independent of unrelated runtime reload validation", ctx do
    File.mkdir_p!(Path.dirname(ctx.config_path))
    original = LemonCli.Setup.Scaffold.generate()
    File.write!(ctx.config_path, original)
    path = Path.join(ctx.root, "selected-onboarding.toml")

    File.write!(path, """
    [providers.openai]
    base_url = "http://127.0.0.1:12345/v1"
    [providers.openai.headers]
    X-Mock-Scope = "isolated-onboarding"
    """)

    previous = System.get_env("OPENAI_BASE_URL")
    System.put_env("OPENAI_BASE_URL", "http://127.0.0.1:12345/v1")

    on_exit(fn ->
      if previous,
        do: System.put_env("OPENAI_BASE_URL", previous),
        else: System.delete_env("OPENAI_BASE_URL")
    end)

    # The shared OpenAI endpoint override also creates a Codex entry, which
    # correctly requires its own auth_source. That unrelated runtime error must
    # not roll back a valid, explicitly selected onboarding file.
    assert_raise Config.ValidationError, fn -> Config.reload(ctx.cwd) end
    io = %{info: fn _ -> :ok end, error: fn _ -> :ok end}

    assert :ok =
             LemonCli.Setup.Provider.run(
               [
                 "--provider",
                 "openai",
                 "--token",
                 "synthetic-private-onboarding",
                 "--secret-name",
                 "isolated_onboarding",
                 "--config-path",
                 path,
                 "--set-default",
                 "--model",
                 "gpt-5",
                 "--non-interactive"
               ],
               io,
               live_verify: false
             )

    config = Config.load_file(path)
    assert config["providers"]["openai"]["headers"]["X-Mock-Scope"] == "isolated-onboarding"
    assert config["providers"]["openai"]["api_key_secret"] == "isolated_onboarding"
    assert config["defaults"]["model"] == "openai:gpt-5"
    assert {:ok, "synthetic-private-onboarding"} = Secrets.get("isolated_onboarding")

    assert Credentials.resolve_provider_api_key(:openai, config["providers"]) ==
             "synthetic-private-onboarding"

    refute File.read!(path) =~ "synthetic-private"
    assert File.read!(ctx.config_path) == original
    assert_raise Config.ValidationError, fn -> Config.reload(ctx.cwd) end
  end

  test "failed disconnect preserves a real-store credential's original expiry deadline",
       ctx do
    File.cd!(ctx.cwd, fn ->
      File.mkdir_p!(Path.dirname(ctx.config_path))

      original = """
      [providers.openai]
      api_key_secret = "expiring_provider_login"
      """

      File.write!(ctx.config_path, original)
      expires_at = System.system_time(:millisecond) + 1_000

      assert {:ok, _} =
               Secrets.set("expiring_provider_login", "synthetic-private-expired",
                 provider: "original_provider",
                 expires_at: expires_at
               )

      assert {:ok, "synthetic-private-expired"} = Secrets.get("expiring_provider_login")

      assert {:ok, before} =
               Store.fetch(Secrets.table(), {"default", "expiring_provider_login"})

      opts =
        Keyword.put(ctx.opts, :write_fun, fn _, _ ->
          assert {:error, :not_found} = Secrets.get("expiring_provider_login")
          Process.sleep(max(expires_at - System.system_time(:millisecond) + 1, 0))
          {:error, :synthetic_write_failure}
        end)

      assert {:error, :config_write_failed} = Management.disconnect("openai", opts)
      assert File.read!(ctx.config_path) == original

      assert {:ok, restored} =
               Store.fetch(Secrets.table(), {"default", "expiring_provider_login"})

      assert restored.expires_at == expires_at
      assert restored.provider == before.provider
      assert restored.created_at == before.created_at
      assert restored.updated_at == before.updated_at
      assert restored.usage_count == before.usage_count
      assert restored.last_used_at == before.last_used_at
      assert {:error, :expired} = Secrets.get("expiring_provider_login")

      assert {:error, :expired} =
               Secrets.resolve("expiring_provider_login", env_fallback: false)

      refute File.read!(Path.join(ctx.store_path, "secrets_v1.jsonl")) =~
               "synthetic-private-expired"
    end)
  end

  test "static expired OAuth and enabled external sources cannot trigger network or source execution",
       ctx do
    File.cd!(ctx.cwd, fn ->
      File.mkdir_p!(Path.dirname(ctx.config_path))
      marker = Path.join(ctx.root, "external-source-was-invoked")

      File.write!(ctx.config_path, """
      [providers.kimi_coding]
      auth_source = "oauth"
      api_key_secret = "expired_login"
      [secrets.sources.must-not-run]
      type = "command"
      enabled = true
      argv = ["/usr/bin/touch", "#{marker}"]
      """)

      source_config = LemonCore.Config.Secrets.resolve(Toml.decode_file!(ctx.config_path))
      assert source_config.errors == []
      assert [%{enabled: true, valid?: true}] = source_config.sources

      encoded =
        Jason.encode!(%{
          "type" => "kimi_code_oauth",
          "access_token" => "synthetic-private-expired",
          "refresh_token" => "synthetic-private-refresh",
          "expires_at_ms" => System.system_time(:millisecond) - 1
        })

      assert {:ok, _} = Secrets.set("expired_login", encoded)
      assert {:ok, listing} = Management.list(ctx.opts)
      row = Enum.find(listing.providers, &(&1.id == "kimi_coding"))
      assert row.status == "expired"
      assert row.lastValidation == nil
      assert {:ok, ^encoded} = Secrets.get("expired_login")

      assert {:ok, blocked} =
               Management.set_api_key("openai", "synthetic-private-saved", ctx.opts)

      external = Enum.find(blocked.providers, &(&1.id == "openai"))
      assert external.configurationOverrides == ["external_secret_source"]
      assert external.status == "configured"
      assert external.lastValidation == nil
      refute File.exists?(marker)
      refute Jason.encode!(listing) =~ "synthetic-private"
    end)
  end

  test "logout cannot clear an OAuth selection replaced before acquiring the config lock", ctx do
    File.cd!(ctx.cwd, fn ->
      Process.register(self(), BlockingDecoder)
      File.mkdir_p!(Path.dirname(ctx.config_path))

      File.write!(ctx.config_path, """
      [providers.kimi_coding]
      auth_source = "oauth"
      api_key_secret = "old_login"
      """)

      login =
        Jason.encode!(%{
          "type" => "kimi_code_oauth",
          "access_token" => "synthetic-private-access",
          "refresh_token" => "synthetic-private-refresh",
          "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
        })

      assert {:ok, _} = Secrets.set("old_login", login)
      assert {:ok, _} = Secrets.set("new_login", login)
      spec = %{Providers.fetch!("kimi_coding") | oauth_module: BlockingDecoder}
      io = %{info: fn _ -> :ok end, error: fn _ -> :ok end}
      logout = Task.async(fn -> ProviderAuth.logout(spec, ctx.config_path, io) end)
      assert_receive {:decoding_selected_login, decoder}

      replacement = """
      [providers.kimi_coding]
      auth_source = "oauth"
      api_key_secret = "new_login"
      """

      File.write!(ctx.config_path, replacement)
      send(decoder, :continue)
      assert :ok = Task.await(logout)
      assert File.read!(ctx.config_path) == replacement
      assert {:error, :not_found} = Secrets.get("old_login")
      assert {:ok, ^login} = Secrets.get("new_login")
    end)
  end
end
