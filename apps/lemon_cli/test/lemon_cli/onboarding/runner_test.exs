defmodule LemonCli.Onboarding.RunnerTest do
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.Provider
  alias LemonCli.Onboarding.Runner
  alias LemonCore.Secrets

  defmodule FakeOAuth do
    def login_device_flow(opts) do
      unless Keyword.get(opts, :local_callback_listener) ==
               LemonCore.OAuth.LocalCallbackListener do
        raise "expected onboarding to provide the localhost OAuth callback listener"
      end

      if on_auth = Keyword.get(opts, :on_auth) do
        on_auth.("https://github.com/login/device", "Enter code: ABCD-EFGH")
      end

      {:ok,
       %{
         "type" => "fake_oauth",
         "access_token" => "oauth-token-123",
         "refresh_token" => "refresh-token-123"
       }}
    end

    def encode_secret(secret), do: Jason.encode!(secret)
  end

  defmodule FailingOAuth do
    def login_device_flow(_opts),
      do: {:error, {:token_exchange_failed, %{"access_token" => "private-login-token"}}}
  end

  defmodule InvalidOAuth do
    def login_device_flow(_opts), do: {:unexpected, "private-login-token"}
  end

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_onboarding_runner_#{System.unique_integer([:positive])}"
      )

    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    original_secrets_config = Application.get_env(:lemon_core, LemonCore.Secrets)
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env, :file])

    System.put_env("HOME", mock_home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())

    on_exit(fn ->
      if original_secrets_config,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, original_secrets_config),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)

      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    clear_secrets_table()

    {:ok, tmp_dir: tmp_dir}
  end

  test "writes oauth_secret for oauth providers and removes stale api_key_secret", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "config.toml")

    File.write!(
      config_path,
      """
      [providers.openai-codex]
      auth_source = "api_key"
      api_key_secret = "legacy_codex_secret"
      """
    )

    spec = %Provider{
      id: "openai-codex",
      display_name: "OpenAI Codex",
      provider_table: "providers.openai-codex",
      default_secret_name: "llm_openai_codex_api_key",
      api_key_secret_provider: "onboarding_openai_codex",
      oauth_secret_provider: "onboarding_openai_codex_oauth",
      oauth_module: FakeOAuth,
      auth_modes: [:oauth],
      default_auth_mode: :oauth,
      auth_source_by_mode: %{oauth: "oauth"},
      secret_config_key_by_mode: %{oauth: "oauth_secret", api_key: "api_key_secret"}
    }

    io = build_io(self(), ["n"], [])

    Runner.run(["--config-path", config_path], spec, io: io)

    {:ok, stored_secret} =
      Secrets.get("llm_openai_codex_api_key", prefer_env: false, env_fallback: false)

    assert stored_secret =~ "oauth-token-123"

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "openai-codex", "auth_source"]) == "oauth"

    assert get_in(config_map, ["providers", "openai-codex", "oauth_secret"]) ==
             "llm_openai_codex_api_key"

    refute get_in(config_map, ["providers", "openai-codex", "api_key_secret"])
  end

  test "device flow shows code after the browser prompt so it stays visible", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    spec = %Provider{
      id: "github_copilot",
      display_name: "GitHub Copilot",
      provider_table: "providers.github_copilot",
      default_secret_name: "llm_github_copilot_api_key",
      api_key_secret_provider: "onboarding_copilot",
      oauth_secret_provider: "onboarding_copilot_oauth",
      oauth_module: FakeOAuth,
      auth_modes: [:oauth],
      default_auth_mode: :oauth,
      auth_source_by_mode: %{oauth: "oauth"},
      secret_config_key_by_mode: %{oauth: "oauth_secret", api_key: "api_key_secret"}
    }

    io = build_io(self(), ["n"], [])

    Runner.run(["--config-path", config_path], spec, io: io)

    events = drain_events([])

    assert {:prompt, "Open this URL in your default browser now? [y/N]: "} in events

    prompt_index =
      Enum.find_index(events, fn event ->
        event == {:prompt, "Open this URL in your default browser now? [y/N]: "}
      end)

    open_index =
      Enum.find_index(events, fn event ->
        event == {:info, "Open this URL in your browser:"}
      end)

    code_index =
      Enum.find_index(events, fn event ->
        event == {:info, "Enter code: ABCD-EFGH"}
      end)

    assert is_integer(prompt_index)
    assert is_integer(open_index)
    assert is_integer(code_index)
    assert prompt_index < open_index
    assert prompt_index < code_index
  end

  test "Codex CLI import is explicit and rejects token and path conflicts", %{tmp_dir: tmp_dir} do
    spec = LemonCli.Onboarding.Providers.fetch!("openai-codex")
    assert spec.default_auth_mode == :oauth
    assert :codex_cli in spec.auth_modes
    io = build_io(self(), [], [])
    config_path = Path.join(tmp_dir, "config.toml")
    base_args = ["--config-path", config_path, "--non-interactive"]

    for label <- ["codex-cli", "codex_cli", "CODEX-CLI", "oauth", "OAUTH"] do
      assert_raise Mix.Error, ~r/Cannot combine --token/, fn ->
        Runner.run(base_args ++ ["--auth", label, "--token", "synthetic"], spec, io: io)
      end
    end

    for args <- [[], ["--auth", "oauth"], ["--auth", "api-key"]] do
      assert_raise Mix.Error, ~r/Non-interactive provider setup requires/, fn ->
        Runner.run(base_args ++ args, spec, io: io)
      end
    end

    assert_raise Mix.Error, ~r/--codex-auth-path requires --auth codex-cli/, fn ->
      Runner.run(base_args ++ ["--codex-auth-path", "never-read"], spec, io: io)
    end

    assert_raise Mix.Error, ~r/does not support codex_cli/, fn ->
      Runner.run(
        base_args ++ ["--auth", "codex-cli"],
        LemonCli.Onboarding.Providers.fetch!("openai"),
        io: io
      )
    end

    assert_raise Mix.Error, ~r/:enoent/, fn ->
      Runner.run(
        base_args ++
          ["--auth", "codex-cli", "--codex-auth-path", Path.join(tmp_dir, "missing-auth.json")],
        spec,
        io: io
      )
    end

    refute File.exists?(config_path)
    assert LemonCore.Store.list(Secrets.table()) == []
  end

  test "catalog API-key providers store the pasted key and reference it from config", %{
    tmp_dir: tmp_dir
  } do
    for {name, provider_id} <- [{"groq", "groq"}, {"vercel", "vercel_ai_gateway"}] do
      spec = LemonCli.Onboarding.Providers.fetch!(name)
      assert spec.id == provider_id
      assert spec.auth_modes == [:api_key]

      config_path = Path.join(tmp_dir, "#{provider_id}.toml")
      io = build_io(self(), ["n"], [])

      Runner.run(
        ["--config-path", config_path, "--non-interactive", "--token", "key-#{provider_id}"],
        spec,
        io: io
      )

      secret_name = "llm_#{provider_id}_api_key"

      assert {:ok, "key-" <> ^provider_id} =
               Secrets.get(secret_name, prefer_env: false, env_fallback: false)

      {:ok, config_map} = Toml.decode_file(config_path)
      assert get_in(config_map, ["providers", provider_id, "api_key_secret"]) == secret_name
    end
  end

  test "hosted presets list models with the pasted key and accept any requested id", %{
    tmp_dir: tmp_dir
  } do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    test_pid = self()

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      send(
        test_pid,
        {:models_request, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
      )

      Req.Test.json(conn, %{"data" => [%{"id" => "meta-llama/Llama-3.3-70B"}]})
    end)

    spec = LemonCli.Onboarding.Providers.fetch!("together")
    config_path = Path.join(tmp_dir, "together.toml")
    args = ["--config-path", config_path, "--non-interactive", "--token", "tg-key"]

    Runner.run(args ++ ["--set-default"], spec, io: build_io(self(), [], []))

    assert_received {:models_request, "/v1/models", ["Bearer tg-key"]}
    {:ok, config_map} = Toml.decode_file(config_path)
    assert get_in(config_map, ["defaults", "model"]) == "together:meta-llama/Llama-3.3-70B"

    assert get_in(config_map, ["providers", "together", "api_key_secret"]) ==
             "llm_together_api_key"

    Runner.run(args ++ ["--set-default", "--model", "not-listed/model"], spec,
      io: build_io(self(), [], [])
    )

    {:ok, config_map} = Toml.decode_file(config_path)
    assert get_in(config_map, ["defaults", "model"]) == "together:not-listed/model"
  end

  test "login failures never interpolate credential payloads", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "redaction.toml")

    for module <- [FailingOAuth, InvalidOAuth] do
      spec = %Provider{
        id: "fake",
        display_name: "Fake",
        provider_table: "providers.fake",
        default_secret_name: "fake-login",
        api_key_secret_provider: "fake",
        oauth_module: module,
        auth_modes: [:oauth],
        default_auth_mode: :oauth
      }

      error =
        assert_raise Mix.Error, fn ->
          Runner.run(["--config-path", config_path], spec, io: build_io(self(), [], []))
        end

      refute Exception.message(error) =~ "private-login-token"
      refute Exception.message(error) =~ "access_token"
      refute File.exists?(config_path)
      assert LemonCore.Store.list(Secrets.table()) == []
    end
  end

  defp build_io(test_pid, prompts, secrets) do
    prompt_agent = start_agent(prompts)
    secret_agent = start_agent(secrets)

    %{
      info: fn message -> send(test_pid, {:info, message}) end,
      error: fn message -> send(test_pid, {:error, message}) end,
      prompt: fn message ->
        send(test_pid, {:prompt, message})
        pop_response(prompt_agent)
      end,
      secret: fn _message -> pop_response(secret_agent) end
    }
  end

  defp pop_response(agent) do
    Agent.get_and_update(agent, fn
      [next | rest] -> {next, rest}
      [] -> {"", []}
    end)
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end

  defp start_agent(values) do
    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> values end]}
    })
  end

  defp drain_events(acc) do
    receive do
      message -> drain_events([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
