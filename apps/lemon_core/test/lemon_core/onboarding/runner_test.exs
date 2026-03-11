defmodule LemonCore.Onboarding.RunnerTest do
  use ExUnit.Case, async: false

  alias LemonCore.Onboarding.Provider
  alias LemonCore.Onboarding.Runner
  alias LemonCore.Secrets

  defmodule FakeOAuth do
    def login_device_flow(opts) do
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

    System.put_env("HOME", mock_home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())

    on_exit(fn ->
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
