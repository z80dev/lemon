defmodule Mix.Tasks.Lemon.OnboardTest do
  use ExUnit.Case, async: false

  alias LemonCore.Secrets
  alias LemonCore.Onboarding.Providers
  alias Mix.Tasks.Lemon.Onboard

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_onboard_top_level_#{System.unique_integer([:positive])}"
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

  test "interactive provider picker supports api-key providers", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")
    io = build_io(self(), ["1", "n"], ["anthropic-token-123"])

    Onboard.run_with_io(["--config-path", config_path], io)

    assert {:ok, "anthropic-token-123"} =
             Secrets.get("llm_anthropic_api_key", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "anthropic", "auth_source"]) == "api_key"

    assert get_in(config_map, ["providers", "anthropic", "api_key_secret"]) ==
             "llm_anthropic_api_key"
  end

  test "interactive provider picker supports hybrid providers", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")
    io = build_io(self(), ["3", "2", "n"], ["codex-token-123"])

    Onboard.run_with_io(["--config-path", config_path], io)

    assert {:ok, "codex-token-123"} =
             Secrets.get("llm_openai_codex_api_key", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "openai-codex", "auth_source"]) == "api_key"

    assert get_in(config_map, ["providers", "openai-codex", "api_key_secret"]) ==
             "llm_openai_codex_api_key"
  end

  test "selector callback can drive provider onboarding without numeric prompts", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "config.toml")

    io =
      build_io(
        self(),
        [],
        ["codex-token-123"],
        [Providers.fetch!("codex"), :api_key, false]
      )

    Onboard.run_with_io(["--config-path", config_path], io)

    assert {:ok, "codex-token-123"} =
             Secrets.get("llm_openai_codex_api_key", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "openai-codex", "auth_source"]) == "api_key"
  end

  test "explicit gemini provider arg routes through top-level onboarding", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    Onboard.run_with_io(
      [
        "gemini",
        "--auth",
        "api_key",
        "--token",
        ~s({"token":"gemini-token-123","projectId":"proj-123"}),
        "--config-path",
        config_path
      ],
      build_io(self(), [], [])
    )

    assert {:ok, ~s({"token":"gemini-token-123","projectId":"proj-123"})} =
             Secrets.get("llm_google_gemini_cli_api_key", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "google_gemini_cli", "auth_source"]) == "api_key"

    assert get_in(config_map, ["providers", "google_gemini_cli", "api_key_secret"]) ==
             "llm_google_gemini_cli_api_key"
  end

  test "explicit z.ai provider arg routes through top-level onboarding", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    Onboard.run_with_io(
      [
        "z.ai",
        "--token",
        "zai-token-123",
        "--config-path",
        config_path
      ],
      build_io(self(), [], [])
    )

    assert {:ok, "zai-token-123"} =
             Secrets.get("llm_zai_api_key", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "zai", "auth_source"]) == "api_key"
    assert get_in(config_map, ["providers", "zai", "api_key_secret"]) == "llm_zai_api_key"
  end

  test "explicit minimax provider arg routes through top-level onboarding", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    Onboard.run_with_io(
      [
        "minimax",
        "--token",
        "minimax-token-123",
        "--config-path",
        config_path
      ],
      build_io(self(), [], [])
    )

    assert {:ok, "minimax-token-123"} =
             Secrets.get("llm_minimax_api_key", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "minimax", "auth_source"]) == "api_key"

    assert get_in(config_map, ["providers", "minimax", "api_key_secret"]) ==
             "llm_minimax_api_key"
  end

  defp build_io(test_pid, prompts, secrets, selects \\ []) do
    prompt_agent = start_agent(prompts)
    secret_agent = start_agent(secrets)
    select_agent = start_agent(selects)

    %{
      info: fn message -> send(test_pid, {:info, message}) end,
      error: fn message -> send(test_pid, {:error, message}) end,
      prompt: fn _message -> pop_response(prompt_agent) end,
      secret: fn _message -> pop_response(secret_agent) end,
      select: fn _params ->
        case pop_response(select_agent) do
          nil -> {:error, :not_available}
          value -> value
        end
      end
    }
  end

  defp pop_response(agent) do
    Agent.get_and_update(agent, fn
      [next | rest] -> {next, rest}
      [] -> {nil, []}
    end)
  end

  defp start_agent(values) do
    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> values end]}
    })
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
