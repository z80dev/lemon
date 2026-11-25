defmodule LemonCli.CredentialReadinessAgreementTest do
  # Doctor, the status RPC, first-run readiness, the web provider snapshot and
  # `lemon setup model` must give one answer for every credential form, from
  # the one presence-mode predicate. Real encryption, an isolated HOME, master
  # key, SQLite Store and config; nothing from the operator's machine.
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, ModelCatalog, ProviderNames, ProviderStatus}
  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.ModelReadiness
  alias LemonCore.{Config, Secrets, Store}
  alias LemonCore.Store.SqliteBackend

  @ambient ~w(HOME LEMON_SECRETS_MASTER_KEY GOOGLE_APPLICATION_CREDENTIALS
              GOOGLE_APPLICATION_CREDENTIALS_JSON AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
              AWS_PROFILE CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_TOKEN OMP_AUTH_BROKER_TOKEN
              OMP_AUTH_GATEWAY_TOKEN LEMON_AGREEMENT_POOL_KEY)

  setup do
    Runner.ensure_required_apps!()
    :ok = Supervisor.terminate_child(LemonCore.Supervisor, Store)

    root =
      Path.join(System.tmp_dir!(), "readiness_agreement_#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    cwd = Path.join(root, "project")
    File.mkdir_p!(home)
    File.mkdir_p!(cwd)

    [key_a, key_b] =
      for name <- ~w(key_a key_b) do
        path = Path.join(root, name)
        File.write!(path, Base.encode64(:crypto.strong_rand_bytes(32)))
        File.chmod!(path, 0o600)
        path
      end

    names =
      @ambient ++ Enum.flat_map(ProviderNames.all_canonical_names(), &ProviderNames.env_vars/1)

    previous_env = Map.new(names, &{&1, System.get_env(&1)})
    previous_settings = Map.new([:secrets, :paths], &{&1, Application.fetch_env(:lemon_core, &1)})
    Enum.each(previous_env, fn {name, _} -> System.delete_env(name) end)
    System.put_env("HOME", home)
    Application.put_env(:lemon_core, :paths, home_dir: home)
    Application.put_env(:lemon_core, :secrets, key_providers: [:file], key_file: key_a)

    store =
      start_supervised!(%{
        id: :readiness_agreement_store,
        start:
          {Store, :start_link,
           [
             [
               name: Store,
               backend: SqliteBackend,
               backend_opts: [path: Path.join(root, "store")],
               cached_tables: []
             ]
           ]},
        restart: :temporary
      })

    backend_state = :sys.get_state(store).backend_state

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
      :ok = SqliteBackend.close(backend_state)

      Enum.each(previous_settings, fn
        {name, {:ok, value}} -> Application.put_env(:lemon_core, name, value)
        {name, :error} -> Application.delete_env(:lemon_core, name)
      end)

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      LemonCore.ConfigCache.clear()
      {:ok, _} = Supervisor.restart_child(LemonCore.Supervisor, Store)
      File.rm_rf!(root)
    end)

    {:ok, cwd: cwd, key_b: key_b, config_path: Config.global_path()}
  end

  # Config validation requires an explicit Codex auth source.
  defp codex_auth("openai_codex"), do: ~s(auth_source = "api_key")
  defp codex_auth(_provider), do: ""

  defp write_config(ctx, provider, table \\ "", extra \\ "") do
    name = ProviderNames.config_name(provider) || provider

    File.mkdir_p!(Path.dirname(ctx.config_path))

    File.write!(ctx.config_path, """
    [defaults]
    provider = "#{name}"
    model = "agreement-model"

    [providers."#{name}"]
    #{table}
    #{extra}
    """)

    LemonCore.ConfigCache.clear()
    name
  end

  # Every surface's answer for the default provider.
  defp answers(ctx, provider) do
    File.cd!(ctx.cwd, fn ->
      config = Config.load(ctx.cwd, cache: false)

      doctor =
        LemonCore.Doctor.Checks.Providers.run(project_dir: ctx.cwd)
        |> Enum.find(&(&1.name == "providers.credentials"))

      status = Enum.find(ProviderStatus.summary(config), & &1["default"])

      web =
        ProviderStatus.snapshot(%{"projectDir" => ctx.cwd, "provider" => provider})
        |> Map.fetch!("providers")
        |> hd()

      readiness = LemonCore.Setup.Readiness.status(config_path: ctx.config_path)

      cli =
        ModelReadiness.status(
          config_path: ctx.config_path,
          cwd: ctx.cwd,
          setup_state: readiness
        )

      %{
        doctor: doctor.status == :pass,
        status: status["credential"] in ["present", "not_required"],
        web: web["credentialReady"] == true,
        readiness: readiness.provider.credential_ready,
        cli: cli.state == :saved
      }
    end)
  end

  defp assert_agree(ctx, provider, expected, label) do
    answers = answers(ctx, provider)

    assert answers == Map.new(answers, fn {surface, _} -> {surface, expected} end),
           "#{label}: #{inspect(answers)}"
  end

  test "every provider environment variable is ready on every surface", ctx do
    for provider <- ProviderNames.all_canonical_names(),
        not ProviderNames.keyless?(provider),
        var <- ProviderNames.env_vars(provider) do
      name = write_config(ctx, provider, codex_auth(provider))
      System.put_env(var, "agreement-#{var}")
      assert_agree(ctx, name, true, "#{provider} via #{var}")
      System.delete_env(var)
      assert_agree(ctx, name, false, "#{provider} unset")
    end
  end

  test "stored keys under the default secret name, api_key_secret and a pool agree", ctx do
    for provider <- ~w(openai zai openrouter minimax groq anthropic) do
      default = ProviderNames.default_secret_name(provider)
      name = write_config(ctx, provider, codex_auth(provider))
      assert_agree(ctx, name, false, "#{provider} empty")

      {:ok, _} = Secrets.set(default, "stored-#{provider}")
      assert_agree(ctx, name, true, "#{provider} default secret")
      :ok = Secrets.delete(default)

      {:ok, _} = Secrets.set("agreement_#{provider}", "stored-#{provider}")
      name = write_config(ctx, provider, ~s(api_key_secret = "agreement_#{provider}"))
      assert_agree(ctx, name, true, "#{provider} api_key_secret")
      :ok = Secrets.delete("agreement_#{provider}")
    end

    System.put_env("LEMON_AGREEMENT_POOL_KEY", "pool-key")

    name =
      write_config(ctx, "openai", "", """
      [runtime.provider_routing]
      default_pool = "main"
      [runtime.provider_routing.credential_pools.main.credentials]
      openai = ["env:LEMON_AGREEMENT_POOL_KEY"]
      """)

    assert_agree(ctx, name, true, "pool credential")
  end

  test "an undecryptable secret is not usable on any surface", ctx do
    {:ok, _} = Secrets.set("agreement_openai", "stored-openai")
    name = write_config(ctx, "openai", ~s(api_key_secret = "agreement_openai"))
    assert_agree(ctx, name, true, "decryptable")

    Application.put_env(:lemon_core, :secrets, key_providers: [:file], key_file: ctx.key_b)
    assert {:error, _} = Secrets.get("agreement_openai")

    assert Credentials.credential_readiness(
             "openai",
             Config.load(ctx.cwd, cache: false).providers
           ) == :unusable

    assert_agree(ctx, name, false, "undecryptable")
  end

  test "presence mode never decrypts, refreshes, runs a source or touches usage", ctx do
    login =
      Jason.encode!(%{
        "type" => "kimi_code_oauth",
        "access_token" => "access-private",
        "refresh_token" => "refresh-private",
        "expires_at_ms" => System.system_time(:millisecond) - 60_000
      })

    {:ok, _} = Secrets.set("agreement_login", login)
    {:ok, _} = Secrets.set("llm_openai_api_key", "stored-openai")

    write_config(
      ctx,
      "kimi_coding",
      ~s(auth_source = "oauth"\napi_key_secret = "agreement_login")
    )

    providers = Config.load(ctx.cwd, cache: false).providers

    traced = [
      LemonCore.Secrets.Crypto,
      LemonCli.Secrets.KeyRotation,
      LemonCore.Secrets.External,
      LemonCore.Secrets.Usage,
      LemonAi.Auth.OAuthSecretResolver,
      LemonAi.Auth.KimiCodeOAuth,
      Req
    ]

    Enum.each(traced, &Code.ensure_loaded!/1)
    Enum.each(traced, &:erlang.trace_pattern({&1, :_, :_}, true, [:local]))
    :erlang.trace(self(), true, [:call])

    try do
      assert Credentials.credential_readiness("kimi_coding", providers) == :ready
      assert Credentials.credential_readiness("openai", providers) == :ready
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(traced, &:erlang.trace_pattern({&1, :_, :_}, false, [:local]))
    end

    calls =
      Stream.repeatedly(fn ->
        receive do
          {:trace, _pid, :call, {mod, fun, args}} -> {mod, fun, length(args)}
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    assert calls == []
    assert {:ok, ^login} = Secrets.get("agreement_login")
  end

  test "Codex and Gemini CLI availability agree across the catalog, CLI and control plane",
       ctx do
    cases = [
      {"openai_codex", ~s(auth_source = "oauth"), fn -> nil end, false},
      {"openai_codex", ~s(auth_source = "oauth"),
       fn -> Secrets.set("llm_openai_codex_api_key", "codex-login") end, true},
      {"openai_codex", ~s(auth_source = "api_key"),
       fn -> System.put_env("CHATGPT_TOKEN", "codex-env") end, true},
      {"google_gemini_cli", "",
       fn -> System.put_env("GOOGLE_GENERATIVE_AI_API_KEY", "google-only") end, false},
      {"google_gemini_cli", "",
       fn -> System.put_env("GOOGLE_GEMINI_CLI_API_KEY", "gemini-cli") end, true}
    ]

    for {provider, table, arrange, expected} <- cases do
      arrange.()
      name = write_config(ctx, provider, table)
      assert_agree(ctx, name, expected, "#{provider} #{table}")

      # The picker filters providers with the same predicate. Codex models are
      # additionally listed only from authenticated discovery, so its listing is
      # not a readiness answer; Gemini CLI's static models are.
      if provider == "google_gemini_cli" do
        catalog? =
          File.cd!(ctx.cwd, fn ->
            ModelCatalog.available_models(
              config: Config.load(ctx.cwd, cache: false),
              discover_custom: false
            )
            |> Enum.any?(&(ProviderNames.canonical_name(&1.provider) == provider))
          end)

        assert catalog? == expected, "catalog #{provider} #{table}"
      end

      for var <- ~w(CHATGPT_TOKEN GOOGLE_GENERATIVE_AI_API_KEY GOOGLE_GEMINI_CLI_API_KEY),
          do: System.delete_env(var)

      _ = Secrets.delete("llm_openai_codex_api_key")
    end
  end
end
