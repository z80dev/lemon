defmodule LemonCli.Setup.ProviderManagementTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonCli.Setup.ProviderManagement, as: Management
  alias LemonCore.Config

  # Deliberate in-memory storage mock for deterministic failure/compensation
  # tests. The separate encrypted integration test uses the real Secrets/Store.
  defmodule MockSecrets do
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{values: %{}, failures: %{}} end, name: __MODULE__)

    def values, do: Agent.get(__MODULE__, & &1.values)
    def seed(name, value), do: Agent.update(__MODULE__, &put_in(&1, [:values, name], value))

    def fail(operation, count \\ 1),
      do: Agent.update(__MODULE__, &put_in(&1, [:failures, operation], count))

    def fail_after_write(operation),
      do: Agent.update(__MODULE__, &Map.put(&1, :after_write, operation))

    def get(name), do: operation(:get, fn values -> {Map.fetch(values, name), values} end)

    def snapshot(name), do: get(name)

    def restore(name, value), do: set(name, value, [])

    def set(name, value, _opts),
      do: operation(:set, fn values -> {{:ok, %{}}, Map.put(values, name, value)} end)

    def delete(name), do: operation(:delete, fn values -> {:ok, Map.delete(values, name)} end)

    defp operation(operation, fun) do
      Agent.get_and_update(__MODULE__, fn state ->
        if Map.get(state.failures, operation, 0) > 0 do
          {{:error, {:private_upstream, "must-not-escape"}},
           update_in(state, [:failures, operation], &(&1 - 1))}
        else
          {result, values} = fun.(state.values)
          result = if result == :error, do: {:error, :not_found}, else: result

          if Map.get(state, :after_write) == operation do
            {{:error, {:private_upstream, "must-not-escape"}},
             state |> Map.put(:values, values) |> Map.put(:after_write, nil)}
          else
            {result, %{state | values: values}}
          end
        end
      end)
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "provider_management_#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    cwd = Path.join(root, "project")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)
    previous_paths = Application.fetch_env(:lemon_core, :paths)

    previous_env =
      Map.new(
        [
          "HOME",
          "LEMON_DEFAULT_PROVIDER",
          "LEMON_DEFAULT_MODEL"
          | Enum.flat_map(ProviderNames.all_canonical_names(), &ProviderNames.env_vars/1)
        ],
        &{&1, System.get_env(&1)}
      )

    Enum.each(previous_env, fn {name, _} -> System.delete_env(name) end)
    System.put_env("HOME", home)
    Application.put_env(:lemon_core, :paths, home_dir: home)
    start_supervised!(MockSecrets)
    previous_req = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Req.Test.stub(__MODULE__, fn _ -> flunk("static listing must not make an HTTP request") end)

    on_exit(fn ->
      Req.default_options(previous_req)
      Req.Test.set_req_test_to_private(%{})

      case previous_paths do
        {:ok, value} -> Application.put_env(:lemon_core, :paths, value)
        :error -> Application.delete_env(:lemon_core, :paths)
      end

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(root)
    end)

    target = %{id: "controller:test-target", nodeId: nil, hostname: "test-machine"}
    config_path = Config.global_path()

    opts = [
      target: target,
      config_path: config_path,
      cwd: cwd,
      secrets: MockSecrets,
      reload_fun: fn -> :ok end
    ]

    {:ok, root: root, cwd: cwd, config_path: config_path, opts: opts, target: target}
  end

  test "listing covers all canonical runtime providers and real device grants", ctx do
    assert {:ok, listing} = Management.list(ctx.opts)
    assert listing.target == ctx.target
    runtime_defaults = LemonCore.Config.Agent.resolve(%{})

    assert listing.default == %{
             providerId: ProviderNames.canonical_name(runtime_defaults.default_provider),
             modelId: runtime_defaults.default_model
           }

    assert Enum.map(listing.providers, & &1.id) == ProviderNames.all_canonical_names()

    for id <- ~w(openai_codex github_copilot kimi_coding xai) do
      assert "device_code" in row(listing, id).methods
    end

    for id <- ~w(anthropic openrouter google_antigravity google_gemini_cli) do
      refute "device_code" in row(listing, id).methods
      assert "api_key" in row(listing, id).methods
    end

    for id <- ~w(google_vertex amazon_bedrock bedrock_converse_stream) do
      assert row(listing, id).methods == ["unsupported"]
    end

    refute File.exists?(ctx.config_path)
    assert MockSecrets.values() == %{}
  end

  test "API key add/replace and disconnect preserve defaults, profiles, pools and unrelated credentials",
       ctx do
    original = """
    # retained comment
    [defaults]
    provider = "anthropic"
    model = "anthropic:claude-sonnet-5-5"
    [profiles.personal]
    provider = "anthropic"
    [providers.anthropic]
    api_key_secret = "unrelated"
    [runtime.provider_routing.credential_pools.burst.credentials]
    anthropic = ["secret:unrelated"]
    """

    write(ctx.config_path, original)
    MockSecrets.seed("unrelated", "unrelated-private")
    before = Toml.decode!(original)

    assert {:ok, first} = Management.set_api_key("openai", "private-first", ctx.opts)
    assert row(first, "openai").status == "ready"
    assert %{ready: true, kind: "resolver", atMs: at} = row(first, "openai").lastValidation
    assert is_integer(at)
    name = Toml.decode_file!(ctx.config_path)["providers"]["openai"]["api_key_secret"]
    assert MockSecrets.values()[name] == "private-first"
    refute File.read!(ctx.config_path) =~ "private-first"
    assert {:ok, second} = Management.set_api_key("openai", "private-second", ctx.opts)
    assert MockSecrets.values()[name] == "private-second"
    refute Jason.encode!(second) =~ "private-"
    refute Jason.encode!(second) =~ name
    refute Jason.encode!(second) =~ ctx.root

    assert {:ok, disconnected} = Management.disconnect("openai", ctx.opts)
    assert row(disconnected, "openai").status == "needs_login"
    refute Map.has_key?(MockSecrets.values(), name)
    after_config = Toml.decode_file!(ctx.config_path)
    assert after_config["defaults"] == before["defaults"]
    assert after_config["profiles"] == before["profiles"]
    assert after_config["runtime"] == before["runtime"]
    assert after_config["providers"]["anthropic"] == before["providers"]["anthropic"]
    assert MockSecrets.values()["unrelated"] == "unrelated-private"
    assert File.read!(ctx.config_path) =~ "# retained comment"
  end

  test "project consumers prevent global secret deletion and replacement before mutation", ctx do
    assert {:ok, _} = Management.set_api_key("openai", "original-mock-key", ctx.opts)
    original = File.read!(ctx.config_path)
    name = Toml.decode!(original)["providers"]["openai"]["api_key_secret"]
    original_secrets = MockSecrets.values()

    for project <- [
          """
          [providers.anthropic]
          api_key_secret = "#{name}"
          """,
          """
          [providers.openai]
          api_key_secret = "#{name}"
          """,
          """
          [runtime.provider_routing.credential_pools.shared.credentials]
          anthropic = ["secret:#{name}"]
          """
        ] do
      project_path = Config.project_path(ctx.cwd)
      write(project_path, project)

      assert {:error, :shared_credential} = Management.disconnect("openai", ctx.opts)

      assert {:error, :shared_credential} =
               Management.set_api_key("openai", "replacement-mock-key", ctx.opts)

      assert File.read!(ctx.config_path) == original
      assert File.read!(project_path) == project
      assert MockSecrets.values() == original_secrets
    end
  end

  test "switching from OAuth clears stale selectors but preserves endpoint settings", ctx do
    write(ctx.config_path, """
    [providers.anthropic]
    auth_source = "oauth"
    oauth_secret = "old_named_login"
    api_key = "obsolete-inline-private"
    api_key_env = "OLD_AUTH_KEY"
    base_url = "https://example.invalid"
    """)

    MockSecrets.seed("old_named_login", "retained-named-private")
    assert {:ok, listing} = Management.set_api_key("anthropic", "replacement-private", ctx.opts)
    cfg = Toml.decode_file!(ctx.config_path)["providers"]["anthropic"]
    assert cfg["auth_source"] == "api_key"
    assert cfg["api_key_secret"]
    assert cfg["base_url"] == "https://example.invalid"
    refute Map.has_key?(cfg, "oauth_secret")
    refute Map.has_key?(cfg, "api_key")
    refute Map.has_key?(cfg, "api_key_env")
    assert MockSecrets.values()["old_named_login"] == "retained-named-private"
    refute Jason.encode!(listing) =~ "private"
  end

  test "encrypted import-env entries precede configured API keys without external resolution",
       ctx do
    assert {:ok, _} = Management.set_api_key("openai", "saved-private", ctx.opts)
    MockSecrets.seed("OPENAI_API_KEY", "imported-private")
    assert {:ok, listing} = Management.list(ctx.opts)
    assert row(listing, "openai").status == "configured"
    assert row(listing, "openai").lastValidation == nil
    assert row(listing, "openai").environmentOverrides == ["OPENAI_API_KEY"]
    refute Jason.encode!(listing) =~ "private"
  end

  test "default setting is separate, canonical, and never provisions credentials", ctx do
    write(ctx.config_path, "[profiles.personal]\nmodel = \"openai:gpt-5\"\n")
    assert {:ok, listing} = Management.set_default("openai_codex", "gpt-6-sol", ctx.opts)
    assert listing.default == %{providerId: "openai_codex", modelId: "gpt-6-sol"}
    config = Toml.decode_file!(ctx.config_path)

    assert config["defaults"] == %{
             "provider" => "openai-codex",
             "model" => "openai-codex:gpt-6-sol"
           }

    assert config["profiles"]["personal"]["model"] == "openai:gpt-5"
    assert MockSecrets.values() == %{}
  end

  test "default projection follows project then environment precedence while mutations stay global",
       ctx do
    write(ctx.config_path, """
    [defaults]
    provider = "openai"
    model = "openai:global-model"
    [profiles.personal]
    model = "openai:profile-model"
    """)

    project = """
    [defaults]
    provider = "openai-codex"
    model = "openai-codex:project-model"
    """

    write(Config.project_path(ctx.cwd), project)
    assert {:ok, projected} = Management.list(ctx.opts)
    assert projected.default == %{providerId: "openai_codex", modelId: "project-model"}

    System.put_env("LEMON_DEFAULT_PROVIDER", "zai")
    System.put_env("LEMON_DEFAULT_MODEL", "zai:environment-model")
    assert {:ok, environment} = Management.list(ctx.opts)
    assert environment.default == %{providerId: "zai", modelId: "environment-model"}
    assert {:ok, changed} = Management.set_default("anthropic", "saved-model", ctx.opts)
    assert changed.default == environment.default
    config = Toml.decode_file!(ctx.config_path)
    assert config["defaults"] == %{"provider" => "anthropic", "model" => "anthropic:saved-model"}
    assert config["profiles"]["personal"]["model"] == "openai:profile-model"
    assert File.read!(Config.project_path(ctx.cwd)) == project
    assert MockSecrets.values() == %{}

    System.put_env("LEMON_DEFAULT_MODEL", String.duplicate("m", 257))
    assert {:ok, bounded} = Management.list(ctx.opts)
    assert bounded.default == %{providerId: "zai", modelId: nil}
    System.put_env("LEMON_DEFAULT_PROVIDER", "not-a-runtime-provider")
    assert {:ok, invalid_provider} = Management.list(ctx.opts)
    assert invalid_provider.default == %{providerId: nil, modelId: nil}
  end

  test "environment/project/pool precedence is explicit and never falsely attests the saved key",
       ctx do
    assert {:ok, _} = Management.set_api_key("openai", "saved-private", ctx.opts)
    System.put_env("OPENAI_API_KEY", "environment-private")
    assert {:ok, environment} = Management.list(ctx.opts)
    assert row(environment, "openai").environmentOverrides == ["OPENAI_API_KEY"]
    assert row(environment, "openai").status == "configured"
    assert row(environment, "openai").lastValidation == nil
    System.delete_env("OPENAI_API_KEY")

    write(Config.project_path(ctx.cwd), "[providers.openai]\napi_key_secret = \"project-key\"\n")
    assert {:ok, project} = Management.list(ctx.opts)
    assert row(project, "openai").configurationOverrides == ["project_configuration"]
    assert row(project, "openai").lastValidation == nil
    File.rm!(Config.project_path(ctx.cwd))

    File.write!(
      ctx.config_path,
      "\n[runtime.provider_routing.credential_pools.extra.credentials]\nopenai = [\"secret:other\"]\n",
      [:append]
    )

    assert {:ok, pool} = Management.list(ctx.opts)
    assert row(pool, "openai").configurationOverrides == ["credential_pool"]
    assert row(pool, "openai").status == "configured"
    assert row(pool, "openai").lastValidation == nil
    refute Jason.encode!(pool) =~ "saved-private"
    refute Jason.encode!(pool) =~ "environment-private"
  end

  test "disconnect refuses shared secret references without touching config or pool", ctx do
    write(ctx.config_path, """
    [providers.openai]
    api_key_secret = "shared"
    [runtime.provider_routing.credential_pools.extra.credentials]
    openai = ["secret:shared"]
    """)

    MockSecrets.seed("shared", "shared-private")
    before = File.read!(ctx.config_path)
    assert {:error, :shared_credential} = Management.disconnect("openai", ctx.opts)
    assert File.read!(ctx.config_path) == before
    assert MockSecrets.values() == %{"shared" => "shared-private"}
  end

  test "static listing distinguishes fresh, near-expiry and expired OAuth without refresh", ctx do
    now = System.system_time(:millisecond)

    write(
      ctx.config_path,
      "[providers.kimi_coding]\nauth_source = \"oauth\"\napi_key_secret = \"login\"\n"
    )

    secret = %{
      "type" => "kimi_code_oauth",
      "access_token" => "access-private",
      "refresh_token" => "refresh-private",
      "expires_at_ms" => now + 3_600_000
    }

    MockSecrets.seed("login", Jason.encode!(secret))
    assert {:ok, fresh} = Management.list(ctx.opts)
    assert row(fresh, "kimi_coding").status == "ready"
    assert row(fresh, "kimi_coding").lastValidation.ready

    near = Jason.encode!(%{secret | "expires_at_ms" => now + 60_000})
    MockSecrets.seed("login", near)
    assert {:ok, due} = Management.list(ctx.opts)
    assert row(due, "kimi_coding").status == "configured"
    assert row(due, "kimi_coding").lastValidation == nil
    assert MockSecrets.values()["login"] == near

    expired = Jason.encode!(%{secret | "expires_at_ms" => now - 1})
    MockSecrets.seed("login", expired)
    assert {:ok, listing} = Management.list(ctx.opts)
    assert row(listing, "kimi_coding").status == "expired"
    assert row(listing, "kimi_coding").lastValidation == nil
    assert MockSecrets.values()["login"] == expired
    refute Jason.encode!(listing) =~ "private"
  end

  test "validation rejects alias/unsupported providers, invalid targets and bounded key/model inputs before mutation",
       ctx do
    assert {:error, :invalid_provider} = Management.set_api_key("codex", "private", ctx.opts)

    assert {:error, :unsupported_method} =
             Management.set_api_key("google_vertex", "private", ctx.opts)

    assert {:error, :invalid_target} =
             Management.set_api_key("openai", "private", Keyword.delete(ctx.opts, :target))

    for value <- [nil, "", " \t", <<255>>, "bad\0value", String.duplicate("é", 8_193)] do
      assert {:error, :invalid_api_key} = Management.set_api_key("openai", value, ctx.opts)
    end

    for model <- [nil, "", "bad\nmodel", String.duplicate("m", 257)] do
      assert {:error, :invalid_model} = Management.set_default("openai", model, ctx.opts)
    end

    assert MockSecrets.values() == %{}
    refute File.exists?(ctx.config_path)
    assert {:ok, _} = Management.set_api_key("openai", String.duplicate("é", 8_192), ctx.opts)
  end

  test "invalid, oversized and symlinked config fail closed before secret writes", ctx do
    write(ctx.config_path, "[private-invalid")
    assert {:error, :invalid_config} = Management.set_api_key("openai", "private", ctx.opts)
    write(ctx.config_path, String.duplicate(" ", 1_048_577))
    assert {:error, :config_read_failed} = Management.set_api_key("openai", "private", ctx.opts)
    File.rm!(ctx.config_path)
    other = Path.join(ctx.root, "other.toml")
    write(other, "")
    File.ln_s!(other, ctx.config_path)
    assert {:error, :config_read_failed} = Management.set_api_key("openai", "private", ctx.opts)
    assert MockSecrets.values() == %{}
  end

  test "read/write/delete failures return stable atoms without secret-bearing upstream errors",
       ctx do
    MockSecrets.fail(:get)
    assert {:error, :secret_read_failed} = Management.set_api_key("openai", "private", ctx.opts)
    MockSecrets.fail(:set)
    assert {:error, :secret_write_failed} = Management.set_api_key("openai", "private", ctx.opts)
    refute File.exists?(ctx.config_path)
    assert {:ok, _} = Management.set_api_key("openai", "private", ctx.opts)
    before = File.read!(ctx.config_path)
    secrets = MockSecrets.values()
    MockSecrets.fail(:delete)
    assert {:error, :secret_delete_failed} = Management.disconnect("openai", ctx.opts)
    assert File.read!(ctx.config_path) == before
    assert MockSecrets.values() == secrets
  end

  test "persist-then-error restores the attempted replacement or deletion too", ctx do
    assert {:ok, _} = Management.set_api_key("openai", "original-private", ctx.opts)
    before = File.read!(ctx.config_path)
    secrets = MockSecrets.values()

    MockSecrets.fail_after_write(:set)

    assert {:error, :secret_write_failed} =
             Management.set_api_key("openai", "replacement-private", ctx.opts)

    assert File.read!(ctx.config_path) == before
    assert MockSecrets.values() == secrets

    MockSecrets.fail_after_write(:delete)
    assert {:error, :secret_delete_failed} = Management.disconnect("openai", ctx.opts)
    assert File.read!(ctx.config_path) == before
    assert MockSecrets.values() == secrets
  end

  test "config write failure compensates both new and replaced encrypted values", ctx do
    fail_opts =
      Keyword.put(ctx.opts, :write_fun, fn _, _ -> {:error, {"private", "upstream"}} end)

    assert {:error, :config_write_failed} =
             Management.set_api_key("openai", "private-new", fail_opts)

    assert MockSecrets.values() == %{}
    refute File.exists?(ctx.config_path)
    assert {:ok, _} = Management.set_api_key("openai", "private-old", ctx.opts)
    before = File.read!(ctx.config_path)
    secrets = MockSecrets.values()

    assert {:error, :config_write_failed} =
             Management.set_api_key("openai", "private-replacement", fail_opts)

    assert File.read!(ctx.config_path) == before
    assert MockSecrets.values() == secrets
  end

  test "reload failure restores config and secrets and failed compensation is explicit", ctx do
    assert {:ok, _} = Management.set_api_key("openai", "private-old", ctx.opts)
    before = File.read!(ctx.config_path)
    secrets = MockSecrets.values()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    reload = fn ->
      Agent.get_and_update(calls, fn n ->
        {if(n == 0, do: {:error, :private}, else: :ok), n + 1}
      end)
    end

    assert {:error, :reload_failed} =
             Management.set_api_key(
               "openai",
               "private-replacement",
               Keyword.put(ctx.opts, :reload_fun, reload)
             )

    assert File.read!(ctx.config_path) == before
    assert MockSecrets.values() == secrets
    Agent.stop(calls)

    MockSecrets.fail(:delete)
    fail_opts = Keyword.put(ctx.opts, :write_fun, fn _, _ -> {:error, :private} end)
    assert {:error, :rollback_failed} = Management.set_api_key("zai", "private-new", fail_opts)
    assert File.read!(ctx.config_path) == before
  end

  test "per-config lock prevents lost updates between concurrent providers", ctx do
    caller = self()

    write_fun = fn path, content ->
      send(caller, {:writing, self()})

      receive do
        :continue -> File.write(path, content)
      after
        5_000 -> {:error, :timeout}
      end
    end

    File.mkdir_p!(Path.dirname(ctx.config_path))

    first =
      Task.async(fn ->
        Management.set_api_key(
          "openai",
          "first-private",
          Keyword.put(ctx.opts, :write_fun, write_fun)
        )
      end)

    assert_receive {:writing, writer}
    second = Task.async(fn -> Management.set_api_key("zai", "second-private", ctx.opts) end)
    send(writer, :continue)
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = Task.await(second)
    config = Toml.decode_file!(ctx.config_path)
    assert config["providers"]["openai"]["api_key_secret"]
    assert config["providers"]["zai"]["api_key_secret"]
  end

  test "listing propagates unreadable encrypted storage rather than inventing absence", ctx do
    MockSecrets.fail(:get)
    assert {:error, :secret_read_failed} = Management.list(ctx.opts)
    assert MockSecrets.values() == %{}
    refute File.exists?(ctx.config_path)
  end

  defp row(listing, id), do: Enum.find(listing.providers, &(&1.id == id))

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
