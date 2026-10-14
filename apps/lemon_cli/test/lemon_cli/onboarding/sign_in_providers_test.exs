defmodule LemonCli.Onboarding.SignInProvidersTest do
  # Mutates HOME, process env, Req's global default plug and the shared secrets table.
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.{Providers, Runner}
  alias LemonCli.Setup.Provider, as: SetupProvider
  alias LemonCore.Secrets

  defmodule FakeCodexDevice do
    def login_device_code(opts) do
      Keyword.fetch!(opts, :on_auth).("https://auth.openai.com/codex/device", "Enter code: AB-12")

      {:ok,
       %{
         "type" => "openai_codex_oauth",
         "access_token" => "codex-at",
         "refresh_token" => "codex-rt",
         "expires_at_ms" => System.system_time(:millisecond) + 3_600_000,
         "account_id" => "acct"
       }}
    end

    def login_device_flow(_opts), do: raise("browser flow must not run for --auth device")
    def encode_secret(secret), do: Jason.encode!(secret)
  end

  defmodule FakeKeySignIn do
    def login_device_flow(opts) do
      Keyword.fetch!(opts, :on_auth).("https://openrouter.ai/auth?callback_url=x", "Sign in")
      {:ok, "sk-or-v1-minted"}
    end
  end

  @env ~w(HOME LEMON_SECRETS_MASTER_KEY XAI_API_KEY KIMI_API_KEY MOONSHOT_API_KEY OPENROUTER_API_KEY KIMI_CODE_OAUTH_HOST KIMI_OAUTH_HOST)

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sign_in_providers_#{System.unique_integer([:positive])}")

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    Runner.ensure_required_apps!()

    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    previous_secrets = Application.get_env(:lemon_core, LemonCore.Secrets)
    previous_req = Req.default_options()

    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env, :file])
    Enum.each(@env, &System.delete_env/1)
    System.put_env("HOME", home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    clear_secrets_table()

    on_exit(fn ->
      Req.default_options(previous_req)
      Req.Test.set_req_test_to_private(%{})

      if previous_secrets,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, previous_secrets),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, config_path: Path.join(tmp_dir, "config.toml")}
  end

  test "openai-codex --auth device stores the Codex login as oauth_secret, non-interactively",
       %{config_path: config_path} do
    spec = %{Providers.fetch!("openai-codex") | oauth_module: FakeCodexDevice}
    assert :device in spec.auth_modes

    Runner.run(["--config-path", config_path, "--auth", "device", "--non-interactive"], spec,
      io: io()
    )

    {:ok, stored} =
      Secrets.get("llm_openai_codex_api_key", prefer_env: false, env_fallback: false)

    assert Jason.decode!(stored)["type"] == "openai_codex_oauth"

    config = Toml.decode_file!(config_path)
    assert config["providers"]["openai-codex"]["auth_source"] == "oauth"
    assert config["providers"]["openai-codex"]["oauth_secret"] == "llm_openai_codex_api_key"

    output = output()
    assert output =~ "Enter code: AB-12"
    assert output =~ "Authentication: device"
    refute output =~ "codex-at"

    assert_raise Mix.Error, ~r/Cannot combine --token with --auth device/, fn ->
      Runner.run(["--config-path", config_path, "--auth", "device", "--token", "t"], spec,
        io: io()
      )
    end
  end

  test "openrouter browser sign-in stores the minted key as a plain API key",
       %{config_path: config_path} do
    spec = %{Providers.fetch!("openrouter") | oauth_module: FakeKeySignIn}
    assert spec.default_auth_mode == :oauth

    Runner.run(["--config-path", config_path, "--auth", "oauth"], spec, io: io(["n", "n"]))

    assert {:ok, "sk-or-v1-minted"} =
             Secrets.get("llm_openrouter_api_key", prefer_env: false, env_fallback: false)

    config = Toml.decode_file!(config_path)
    assert config["providers"]["openrouter"]["api_key_secret"] == "llm_openrouter_api_key"
    assert config["providers"]["openrouter"]["auth_source"] == "api_key"

    assert :ok = SetupProvider.run(["openrouter", "--status", "--config-path", config_path], io())
    status = output()
    assert status =~ "Stored API key: llm_openrouter_api_key (set"
    assert status =~ "Credentials usable: yes"
    refute status =~ "sk-or-v1-minted"

    assert :ok = SetupProvider.run(["openrouter", "--logout", "--config-path", config_path], io())

    assert {:error, _} =
             Secrets.get("llm_openrouter_api_key", prefer_env: false, env_fallback: false)

    refute Toml.decode_file!(config_path)["providers"]["openrouter"]["api_key_secret"]
  end

  test "xai sign-in runs the real device flow and references the login as api_key_secret",
       %{config_path: config_path} do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{"token_endpoint" => "https://auth.x.ai/oauth2/token"})

        "/oauth2/device/code" ->
          Req.Test.json(conn, %{
            "device_code" => "dc",
            "user_code" => "GROK-1",
            "verification_uri" => "https://accounts.x.ai/device"
          })

        "/oauth2/token" ->
          Req.Test.json(conn, %{
            "access_token" => "xai-at",
            "refresh_token" => "xai-rt",
            "expires_in" => 3600
          })

        "/oauth2/userinfo" ->
          Req.Test.json(conn, %{"sub" => "u1", "email" => "me@example.com"})
      end
    end)

    Runner.run(["--config-path", config_path, "--auth", "oauth"], Providers.fetch!("xai"),
      io: io(["n", "n"])
    )

    {:ok, stored} = Secrets.get("llm_xai_api_key", prefer_env: false, env_fallback: false)
    assert %{"type" => "xai_oauth", "account_email" => "me@example.com"} = Jason.decode!(stored)

    config = Toml.decode_file!(config_path)

    assert config["providers"]["xai"] == %{
             "api_key_secret" => "llm_xai_api_key",
             "auth_source" => "oauth"
           }

    assert output() =~ "Enter code: GROK-1"
  end

  test "kimi_coding status ignores KIMI_API_KEY while signed in; logout removes the login",
       %{config_path: config_path} do
    {:ok, _} =
      Secrets.set(
        "llm_kimi_coding_api_key",
        Jason.encode!(%{
          "type" => "kimi_code_oauth",
          "access_token" => "kimi-at",
          "refresh_token" => "kimi-rt",
          "expires_at_ms" => System.system_time(:millisecond) + 2 * 3_600_000
        })
      )

    File.write!(config_path, """
    [providers.kimi_coding]
    auth_source = "oauth"
    api_key_secret = "llm_kimi_coding_api_key"
    """)

    System.put_env("KIMI_API_KEY", "sk-kimi-ambient")

    assert :ok = SetupProvider.run(["kimi-code", "--status", "--config-path", config_path], io())
    status = output()
    assert status =~ "Stored login: llm_kimi_coding_api_key (refreshable login)"
    assert status =~ "Access token: expires in 1h"
    assert status =~ "KIMI_API_KEY: set, ignored while auth_source = \"oauth\""
    assert status =~ "Credentials usable: yes"
    refute status =~ "kimi-at"

    assert :ok =
             SetupProvider.run(["kimi_coding", "--logout", "--config-path", config_path], io())

    assert {:error, _} =
             Secrets.get("llm_kimi_coding_api_key", prefer_env: false, env_fallback: false)

    assert Toml.decode_file!(config_path)["providers"]["kimi_coding"] == %{}
  end

  test "github_copilot --status reads the stored device login", %{config_path: config_path} do
    {:ok, _} =
      Secrets.set(
        "llm_github_copilot_api_key",
        Jason.encode!(%{
          "type" => "github_copilot_oauth",
          "access_token" => "copilot-at",
          "refresh_token" => "gh-token",
          "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
        })
      )

    File.write!(config_path, """
    [providers.github_copilot]
    api_key_secret = "llm_github_copilot_api_key"
    """)

    assert :ok = SetupProvider.run(["copilot", "--status", "--config-path", config_path], io())
    status = output()
    assert status =~ "Stored login: llm_github_copilot_api_key (refreshable login)"
    refute status =~ "copilot-at"
  end

  defp io(prompts \\ []) do
    pid = self()
    {:ok, agent} = Agent.start_link(fn -> prompts end)

    %{
      info: fn message -> send(pid, {:out, message}) end,
      error: fn message -> send(pid, {:out, message}) end,
      prompt: fn message ->
        send(pid, {:out, message})

        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {"", []}
        end)
      end,
      secret: fn _ -> "" end
    }
  end

  defp output(acc \\ []) do
    receive do
      {:out, message} -> output([message | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
