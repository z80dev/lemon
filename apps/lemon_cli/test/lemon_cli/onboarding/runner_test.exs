defmodule LemonCli.Onboarding.RunnerTest do
  use ExUnit.Case, async: false

  alias LemonAi.Models.Presets
  alias LemonCli.Onboarding.Provider
  alias LemonCli.Onboarding.Providers
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

  test "secret input disables echo before reading and restores its original state" do
    for previous_echo <- [true, false] do
      callbacks =
        secret_callbacks(previous_echo, fn prompt ->
          assert prompt == "API key: "
          assert_received {:echo, false}
          "synthetic-secret\n"
        end)

      assert Runner.read_secret("API key: ", callbacks) == "synthetic-secret\n"
      assert_received {:echo, ^previous_echo}
      assert_received {:newline, ""}
      refute_received {:info, "synthetic-secret"}
    end
  end

  test "secret input restores echo after a read exception or EOF" do
    assert_raise RuntimeError, "read failed", fn ->
      Runner.read_secret("API key: ", secret_callbacks(true, fn _ -> raise "read failed" end))
    end

    assert_received {:echo, false}
    assert_received {:echo, true}

    assert Runner.read_secret("API key: ", secret_callbacks(true, fn _ -> :eof end)) == :eof
    assert_received {:echo, false}
    assert_received {:echo, true}
  end

  test "secret input refuses a non-terminal or unavailable echo control without reading" do
    callbacks = secret_callbacks(true, fn _ -> flunk("unsafe secret read") end)
    no_tty = Map.put(callbacks, :getopts, fn -> [terminal: false, echo: false] end)

    assert_raise Mix.Error, ~r/No interactive terminal.*lemon setup --non-interactive/, fn ->
      Runner.read_secret("API key: ", no_tty)
    end

    no_echo_control = Map.put(callbacks, :setopts, fn _ -> {:error, :enotsup} end)

    assert_raise Mix.Error, ~r/Could not hide secret input.*lemon model/, fn ->
      Runner.read_secret("API key: ", no_echo_control)
    end
  end

  test "unknown authentication mode lists accepted modes" do
    spec = Providers.fetch!("anthropic")

    error = assert_raise Mix.Error, fn -> Runner.run(["--auth", "typo"], spec) end
    assert error.message =~ "oauth, api-key"
    assert error.message =~ "lemon model --help"
  end

  test "prefixed model ids explain the bare id and show valid examples", %{tmp_dir: tmp_dir} do
    spec = Providers.fetch!("openai")

    error =
      assert_raise Mix.Error, fn ->
        Runner.run(
          [
            "--non-interactive",
            "--token",
            "synthetic",
            "--set-default",
            "--model",
            "openai:gpt-5",
            "--config-path",
            Path.join(tmp_dir, "config.toml")
          ],
          spec,
          io: build_io(self(), [], [])
        )
      end

    assert error.message =~ "must not include a provider prefix"
    assert error.message =~ "Use a bare model id"

    assert error.message =~ hd(LemonAi.Models.get_models(:openai)).id or
             error.message =~ "gpt-"

    refute error.message =~ "Available:"
  end

  test "an empty model catalog gives recovery instead of an empty available list", %{
    tmp_dir: tmp_dir
  } do
    spec = Provider.api_key("unregistered_polish_provider", "Test", "Test")

    error =
      assert_raise Mix.Error, fn ->
        Runner.run(
          [
            "--non-interactive",
            "--token",
            "synthetic",
            "--set-default",
            "--model",
            "missing",
            "--config-path",
            Path.join(tmp_dir, "config.toml")
          ],
          spec,
          io: build_io(self(), [], [])
        )
      end

    assert error.message =~ "No model ids are available"
    assert error.message =~ "lemon models"
    refute error.message =~ "Available:"
  end

  defp secret_callbacks(previous_echo, gets) do
    %{
      getopts: fn -> [terminal: true, echo: previous_echo] end,
      setopts: fn opts ->
        send(self(), {:echo, opts[:echo]})
        :ok
      end,
      gets: gets,
      puts: fn message -> send(self(), {:newline, message}) end
    }
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
    spec = Providers.fetch!("openai-codex")
    assert spec.default_auth_mode == :oauth
    assert :codex_cli in spec.auth_modes
    io = build_io(self(), [], [])
    config_path = Path.join(tmp_dir, "config.toml")
    base_args = ["--config-path", config_path, "--non-interactive"]

    for label <- ["codex-cli", "codex_cli", "CODEX-CLI", "oauth", "OAUTH"] do
      assert_raise Mix.Error, fn ->
        Runner.run(base_args ++ ["--auth", label, "--token", "synthetic"], spec, io: io)
      end
    end

    for args <- [[], ["--auth", "oauth"], ["--auth", "api-key"]] do
      assert_raise Mix.Error, fn ->
        Runner.run(base_args ++ args, spec, io: io)
      end
    end

    assert_raise Mix.Error, fn ->
      Runner.run(base_args ++ ["--codex-auth-path", "never-read"], spec, io: io)
    end

    assert_raise Mix.Error, fn ->
      Runner.run(
        base_args ++ ["--auth", "codex-cli"],
        Providers.fetch!("openai"),
        io: io
      )
    end

    assert_raise Mix.Error, fn ->
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
      spec = Providers.fetch!(name)
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

    spec = Providers.fetch!("together")
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

  test "local presets probe only after consent and offer discovered IDs", %{tmp_dir: dir} do
    path = Path.join(dir, "local.toml")
    spec = Providers.fetch!(:ollama)
    io = build_io(self(), ["y", "2"], [""])

    Runner.run(["--config-path", path, "--set-default"], spec,
      io: io,
      discovery: fn kind, url, opts ->
        assert_received {:prompt, "Probe " <> _}
        assert kind == :openai_models
        assert url == Presets.base_url(:ollama)
        assert opts[:api_key] == nil
        assert opts[:timeout_ms] == 5_000
        {:ok, [%{id: "qwen3:8b"}, %{id: "llama3.2"}]}
      end
    )

    assert {:ok, config} = Toml.decode_file(path)
    assert config["defaults"]["model"] == "ollama:qwen3:8b"
    assert config["providers"]["ollama"]["auth"] == "none"
    assert LemonCore.Store.list(Secrets.table()) == []
  end

  test "declining local discovery uses manual entry without a request", %{tmp_dir: dir} do
    path = Path.join(dir, "manual.toml")

    Runner.run(
      ["--config-path", path, "--set-default"],
      Providers.fetch!("lm-studio"),
      io: build_io(self(), ["n", "manual:model"], [""]),
      discovery: fn _, _, _ -> flunk("discovery was not approved") end
    )

    assert {:ok, config} = Toml.decode_file(path)
    assert config["defaults"]["model"] == "lm_studio:manual:model"
  end

  test "unreachable and empty servers fall back to manual entry", %{tmp_dir: dir} do
    for result <- [{:error, :transport_failure}, {:ok, []}] do
      path = Path.join(dir, "fallback.toml")

      Runner.run(
        ["--config-path", path, "--set-default"],
        Providers.fetch!("llama.cpp"),
        io: build_io(self(), ["y", "local-model"], [""]),
        discovery: fn _, _, _ -> result end
      )

      assert {:ok, config} = Toml.decode_file(path)
      assert config["defaults"]["model"] == "llama_cpp:local-model"
    end
  end

  test "local non-interactive and explicit models never prompt or discover", %{tmp_dir: dir} do
    for args <- [[], ["--non-interactive"], ["--non-interactive", "--token", "local-key"]] do
      path = Path.join(dir, "flags.toml")

      io =
        build_io(self(), [], [""])
        |> Map.put(:prompt, fn _ -> flunk("flag-driven setup prompted") end)

      Runner.run(
        args ++ ["--config-path", path, "--set-default", "--model", "qwen:7b"],
        Providers.fetch!("ollama"),
        io: io,
        discovery: fn _, _, _ -> flunk("flag-driven setup discovered") end
      )

      assert {:ok, config} = Toml.decode_file(path)
      assert config["defaults"]["model"] == "ollama:qwen:7b"
    end
  end

  test "custom endpoint writes keyless or encrypted-key TOML", %{tmp_dir: dir} do
    for key <- ["", "custom-api-key"] do
      path = Path.join(dir, "custom.toml")

      Runner.run(
        ["--config-path", path, "--set-default"],
        Providers.fetch!("custom"),
        io: build_io(self(), ["my-server", "http://gpu-box:8000/v1/", "n", "qwen:32b"], [key]),
        discovery: fn _, _, _ -> flunk("custom discovery was declined") end
      )

      assert {:ok, config} = Toml.decode_file(path)
      provider = config["providers"]["my-server"]
      assert provider["api"] == "openai_completions"
      assert provider["base_url"] == "http://gpu-box:8000/v1"
      assert config["defaults"]["provider"] == "my-server"
      assert config["defaults"]["model"] == "my-server:qwen:32b"
      refute Map.has_key?(provider, "api_key")

      if key == "" do
        assert provider["auth"] == "none"
        refute Map.has_key?(provider, "api_key_secret")
      else
        refute Map.has_key?(provider, "auth")
        assert provider["api_key_secret"] == "llm_my-server_api_key"

        assert {:ok, ^key} =
                 Secrets.get("llm_my-server_api_key", prefer_env: false, env_fallback: false)

        refute File.read!(path) =~ key
      end
    end
  end

  test "custom endpoint rejects unsafe names and URLs before saving", %{tmp_dir: dir} do
    path = Path.join(dir, "invalid.toml")

    for prompts <- [
          ["openai"],
          ["bad.name"],
          ["new-server", "file:///tmp/models"],
          ["new-server", "http://user:secret@localhost/v1"]
        ] do
      assert_raise Mix.Error, fn ->
        Runner.run(["--config-path", path], Providers.fetch!("custom"),
          io: build_io(self(), prompts, [])
        )
      end

      refute File.exists?(path)
    end
  end

  test "local discovery retains the configured endpoint and uses the optional key", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "existing.toml")

    File.write!(path, """
    [providers.ollama]
    base_url = "http://gpu-box:11434/v1"
    auth = "none"
    """)

    io =
      build_io(self(), [], ["local-api-key"])
      |> Map.put(:select, fn params ->
        case params.title do
          "Probe " <> _ ->
            {:ok, true}

          "Choose Ollama Model" ->
            assert params.options == [%{label: "qwen:7b", value: "qwen:7b"}]
            {:ok, "qwen:7b"}
        end
      end)

    Runner.run(
      ["--config-path", path, "--set-default"],
      Providers.fetch!("ollama"),
      io: io,
      discovery: fn :openai_models, "http://gpu-box:11434/v1", opts ->
        assert opts[:api_key] == "local-api-key"
        {:ok, [%{id: "qwen:7b"}]}
      end
    )

    assert {:ok, config} = Toml.decode_file(path)
    assert config["providers"]["ollama"]["base_url"] == "http://gpu-box:11434/v1"
    assert config["providers"]["ollama"]["api_key_secret"] == "llm_ollama_api_key"
    refute Map.has_key?(config["providers"]["ollama"], "auth")
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
