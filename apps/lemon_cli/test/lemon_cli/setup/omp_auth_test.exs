defmodule LemonCli.Setup.OmpAuthTest do
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.{Providers, Runner}
  alias LemonCli.Setup.{Provider, ProviderAuth}
  alias LemonCore.Secrets

  setup do
    Runner.ensure_required_apps!()
    dir = Path.join(System.tmp_dir!(), "lemon_cli_omp_#{System.unique_integer([:positive])}")
    home = Path.join(dir, "home")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(home)
    File.mkdir_p!(bin)

    previous =
      Map.new(~w(HOME PATH LEMON_SECRETS_MASTER_KEY KIMI_API_KEY), &{&1, System.get_env(&1)})

    secrets_config = Application.get_env(:lemon_core, Secrets)
    System.put_env("HOME", home)
    System.put_env("PATH", bin <> ":" <> (previous["PATH"] || "/usr/bin:/bin"))
    System.delete_env("KIMI_API_KEY")
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, Secrets, key_providers: [:env])
    clear_secrets()
    {:ok, _} = Secrets.set("untouched_kimi_login", "synthetic-existing-login")
    stored = LemonCore.Store.list(Secrets.table())
    System.delete_env("LEMON_SECRETS_MASTER_KEY")
    Application.put_env(:lemon_core, Secrets, key_providers: [])

    token =
      Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false) <>
        "." <>
        Base.url_encode64(Jason.encode!(%{"exp" => System.system_time(:second) + 3_600}),
          padding: false
        ) <> ".c3ludGhldGljLXNpZ25hdHVyZQ"

    omp = Path.join(bin, "omp")
    calls = Path.join(dir, "calls")

    File.write!(omp, """
    #!/bin/sh
    printf '%s\\n' "$*" >> '#{calls}'
    if [ "$#" -eq 2 ] && [ "$1" = token ] && [ "$2" = kimi-code ]; then
      printf '%s\\n' '#{token}'
    else
      exit 91
    fi
    """)

    File.chmod!(omp, 0o700)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if secrets_config,
        do: Application.put_env(:lemon_core, Secrets, secrets_config),
        else: Application.delete_env(:lemon_core, Secrets)

      clear_secrets()
      File.rm_rf!(dir)
    end)

    {:ok,
     dir: dir,
     config_path: Path.join(dir, "config.toml"),
     omp: omp,
     calls: calls,
     token: token,
     stored: stored}
  end

  test "non-interactive omp onboarding discovers the absolute executable without storing tokens",
       ctx do
    File.write!(ctx.config_path, """
    # keep this comment
    [providers.kimi_coding]
    auth_source = "oauth"
    api_key_secret = "untouched_kimi_login"
    oauth_secret = "untouched_kimi_login"
    api_key = "stale-inline-key"
    """)

    assert :ok =
             Runner.run(
               [
                 "--auth",
                 "omp",
                 "--non-interactive",
                 "--no-set-default",
                 "--config-path",
                 ctx.config_path
               ],
               Providers.fetch!("kimi_coding"),
               io: io()
             )

    assert {:ok, config} = Toml.decode_file(ctx.config_path)
    assert config["providers"]["kimi_coding"] == %{"auth_source" => "omp", "omp_path" => ctx.omp}
    assert File.read!(ctx.config_path) =~ "# keep this comment"
    refute File.read!(ctx.config_path) =~ ctx.token
    assert LemonCore.Store.list(Secrets.table()) == ctx.stored
    assert File.read!(ctx.calls) == "token kimi-code\n"
    output = output()
    assert output =~ "reuses omp's Kimi Code login"
    refute output =~ ctx.token
  end

  test "interactive picker offers omp without requiring encrypted secrets", ctx do
    io =
      Map.put(io(), :select, fn params ->
        assert params.title == "Choose Kimi Code Authentication"
        assert %{value: :omp, label: label} = Enum.find(params.options, &(&1.value == :omp))
        assert label =~ "omp's Kimi Code login"
        {:ok, :omp}
      end)

    assert :ok =
             Runner.run(
               ["--no-set-default", "--config-path", ctx.config_path],
               Providers.fetch!("kimi-code"),
               io: io
             )

    assert File.read!(ctx.calls) == "token kimi-code\n"
    assert LemonCore.Store.list(Secrets.table()) == ctx.stored
  end

  test "omp setup checks only token readiness even when live verification is requested", ctx do
    assert :ok =
             Provider.run(
               [
                 "--provider",
                 "kimi-code",
                 "--auth",
                 "omp",
                 "--non-interactive",
                 "--set-default",
                 "--model",
                 "kimi-for-coding",
                 "--config-path",
                 ctx.config_path
               ],
               io(),
               live_verify: true,
               verifier: fn _ -> flunk("omp setup must not send a models request") end
             )

    assert {:ok, config} = Toml.decode_file(ctx.config_path)
    assert config["defaults"]["provider"] == "kimi_coding"
    assert config["providers"]["kimi_coding"]["omp_path"] == ctx.omp
    assert LemonCore.Store.list(Secrets.table()) == ctx.stored

    assert Enum.all?(
             String.split(File.read!(ctx.calls), "\n", trim: true),
             &(&1 == "token kimi-code")
           )
  end

  test "status bypasses unreadable encrypted logins and logout leaves omp and stored logins alone",
       ctx do
    write_config(ctx)
    original_omp = File.read!(ctx.omp)
    System.put_env("KIMI_API_KEY", "ignored-environment-key")

    test_pid = self()

    usage = fn token, opts ->
      send(test_pid, {:usage_token, token, opts})

      {:ok,
       [
         %{
           id: "5h",
           label: "5h window",
           used_fraction: 0.76,
           resets_at: ~U[2026-11-12 04:34:22Z]
         },
         %{id: "month", label: "month", used_fraction: 0.5697, resets_at: nil}
       ]}
    end

    assert :ok =
             Provider.run(
               ["kimi-code", "--status", "--config-path", ctx.config_path],
               io(),
               kimi_usage: usage
             )

    output = output()
    assert output =~ "Auth source: omp (reuses omp's Kimi Code login)"
    assert output =~ "Credentials usable: yes"
    assert output =~ "Usage: 5h window: 76% used, resets 04:34Z; month: 57% used"
    assert_received {:usage_token, token, [base_url: nil]}
    assert token == ctx.token
    assert output =~ "ignored while auth_source = \"omp\""
    refute output =~ ctx.token
    refute output =~ "ignored-environment-key"
    assert File.read!(ctx.calls) == "token kimi-code\n"

    assert :ok = Provider.run(["kimi-code", "--logout", "--config-path", ctx.config_path], io())
    assert {:ok, config} = Toml.decode_file(ctx.config_path)
    refute Map.has_key?(config["providers"]["kimi_coding"], "auth_source")
    refute Map.has_key?(config["providers"]["kimi_coding"], "omp_path")
    assert config["providers"]["kimi_coding"]["api_key_secret"] == "untouched_kimi_login"
    assert File.read!(ctx.omp) == original_omp
    assert File.read!(ctx.calls) == "token kimi-code\n"
    assert LemonCore.Store.list(Secrets.table()) == ctx.stored
    assert output() =~ "omp's Kimi Code login is unchanged"
  end

  test "mixed-case omp selection preserves the real stored OAuth login and secret-name case",
       ctx do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, Secrets, key_providers: [:env])
    secret_name = "MixedCase_KimiOAuth"

    login =
      Jason.encode!(%{
        "type" => "kimi_code_oauth",
        "access_token" => "synthetic-stored-kimi-access",
        "refresh_token" => "synthetic-stored-kimi-refresh",
        "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
      })

    assert {:ok, _} = Secrets.set(secret_name, login)
    stored = LemonCore.Store.list(Secrets.table())

    File.write!(ctx.config_path, """
    [defaults]
    provider = "kimi_coding"
    model = "k3.1-pro"
    [providers.kimi_coding]
    auth_source = " OMP "
    omp_path = #{Jason.encode!(ctx.omp)}
    api_key_secret = "#{secret_name}"
    oauth_secret = "#{secret_name}"
    """)

    assert :ok =
             Provider.run(["kimi-code", "--status", "--config-path", ctx.config_path], io(),
               kimi_usage: fn _, _ -> {:error, {:http_error, 429}} end
             )

    status = output()
    assert status =~ "Auth source: omp (reuses omp's Kimi Code login)"
    assert status =~ "Stored login: managed by omp"
    assert status =~ "Credentials usable: yes"
    assert status =~ "Usage: unavailable (HTTP 429)"
    refute status =~ "synthetic-stored-kimi"

    assert %{provider: %{complete: true}, secrets: %{source: :not_required}} =
             LemonCore.Setup.Readiness.status(config_path: ctx.config_path)

    assert :ok = Provider.run(["kimi-code", "--logout", "--config-path", ctx.config_path], io())

    assert Toml.decode_file!(ctx.config_path)["providers"]["kimi_coding"] == %{
             "api_key_secret" => secret_name,
             "oauth_secret" => secret_name
           }

    assert LemonCore.Store.list(Secrets.table()) == stored
    assert {:ok, ^login} = Secrets.get(secret_name, prefer_env: false, env_fallback: false)

    assert {:error, :not_found} =
             Secrets.get(String.downcase(secret_name), prefer_env: false, env_fallback: false)
  end

  test "explicit model readiness check uses omp without a model request", ctx do
    write_config(ctx, " OMP ")

    setup = %{
      provider: %{
        provider: "kimi_coding",
        model: "kimi-for-coding",
        complete: true,
        reason: nil
      }
    }

    assert %{state: :saved, reason: :check_unavailable} =
             LemonCli.Setup.ModelReadiness.check(
               config_path: ctx.config_path,
               setup_state: setup,
               verifier: fn _ -> flunk("omp model readiness must not send a model probe") end
             )

    assert File.read!(ctx.calls) == "token kimi-code\n"
  end

  test "static provider projection never executes omp or reads encrypted login", ctx do
    assert %{status: "configured", configured: true, last_validation: nil} =
             ProviderAuth.static_status("kimi_coding", %{
               "auth_source" => " OMP ",
               "omp_path" => ctx.omp
             })

    refute File.exists?(ctx.calls)
  end

  test "doctor live omp check resolves the token without invoking a models endpoint", ctx do
    config = %{
      agent: %{default_provider: "kimi_coding"},
      providers: %{"kimi_coding" => %{"auth_source" => " OMP ", "omp_path" => ctx.omp}}
    }

    [{"providers.live", check}] =
      LemonCli.Doctor.Providers.live_checks(
        config: config,
        provider_live_input: fn _ -> flunk("omp doctor must not build a model probe") end,
        provider_live_check: fn _ -> flunk("omp doctor must not send a model probe") end
      )

    assert %{status: :pass} = check.()
    assert File.read!(ctx.calls) == "token kimi-code\n"
  end

  test "failed omp token cannot fall back to a stored or environment key", ctx do
    write_config(ctx)
    File.write!(ctx.omp, "#!/bin/sh\nprintf '%s\\n' 'private-omp-failure' >&2\nexit 1\n")
    System.put_env("KIMI_API_KEY", "ignored-environment-key")
    before = File.read!(ctx.config_path)

    assert :ok = Provider.run(["kimi-code", "--status", "--config-path", ctx.config_path], io())
    status = output()
    assert status =~ "Credentials usable: no"
    refute status =~ "private-omp-failure"

    error =
      assert_raise Mix.Error, fn ->
        Runner.run(
          [
            "--auth",
            "omp",
            "--non-interactive",
            "--no-set-default",
            "--config-path",
            ctx.config_path
          ],
          Providers.fetch!("kimi_coding"),
          io: io()
        )
      end

    assert error.message =~ "/login"
    refute error.message =~ "private-omp-failure"
    assert File.read!(ctx.config_path) == before
    assert LemonCore.Store.list(Secrets.table()) == ctx.stored
  end

  test "API-key cutover removes stale omp_path and omp rejects --token", ctx do
    write_config(ctx)
    content = File.read!(ctx.config_path)
    spec = Providers.fetch!("kimi_coding")
    patched = Runner.update_provider_auth_config(content, spec, :api_key, "new_key")
    assert {:ok, config} = Toml.decode(patched)

    assert config["providers"]["kimi_coding"] == %{
             "auth_source" => "api_key",
             "api_key_secret" => "new_key"
           }

    assert_raise Mix.Error, ~r/Cannot combine --token with --auth omp/, fn ->
      Runner.run(["--auth", "omp", "--token", "never-store-this", "--non-interactive"], spec,
        io: io()
      )
    end

    assert File.read!(ctx.config_path) == content
    assert LemonCore.Store.list(Secrets.table()) == ctx.stored
  end

  defp write_config(ctx, auth_source \\ "omp") do
    File.write!(ctx.config_path, """
    [providers.kimi_coding]
    auth_source = #{Jason.encode!(auth_source)}
    omp_path = #{Jason.encode!(ctx.omp)}
    api_key_secret = "untouched_kimi_login"
    """)
  end

  defp io do
    pid = self()

    %{
      info: fn text -> send(pid, {:output, text}) end,
      error: fn text -> send(pid, {:output, text}) end,
      prompt: fn _ -> flunk("unexpected prompt") end,
      secret: fn _ -> flunk("omp must not prompt for a secret") end,
      interactive?: fn -> true end
    }
  end

  defp output(acc \\ []) do
    receive do
      {:output, text} -> output([text | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp clear_secrets do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
