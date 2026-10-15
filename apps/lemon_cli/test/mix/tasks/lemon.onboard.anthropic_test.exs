defmodule Mix.Tasks.Lemon.Onboard.AnthropicTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Secrets
  alias Mix.Tasks.Lemon.Onboard.Anthropic

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_onboard_anthropic_#{System.unique_integer([:positive])}"
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

  test "stores token and updates providers config", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    output =
      capture_io(fn ->
        Anthropic.run([
          "--non-interactive",
          "--token",
          "anthropic-token-123",
          "--config-path",
          config_path
        ])
      end)

    assert output =~ "Anthropic onboarding complete."

    assert {:ok, "anthropic-token-123"} =
             Secrets.get("llm_anthropic_api_key_raw", prefer_env: false, env_fallback: false)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "anthropic", "auth_source"]) == "api_key"

    assert get_in(config_map, ["providers", "anthropic", "api_key_secret"]) ==
             "llm_anthropic_api_key_raw"

    refute Map.has_key?(config_map, "defaults")
  end

  test "sets defaults when --set-default is enabled", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    capture_io(fn ->
      Anthropic.run([
        "--non-interactive",
        "--token",
        "anthropic-token-123",
        "--config-path",
        config_path,
        "--set-default",
        "--model",
        "claude-sonnet-4-20250514"
      ])
    end)

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "anthropic", "auth_source"]) == "api_key"

    assert get_in(config_map, ["providers", "anthropic", "api_key_secret"]) ==
             "llm_anthropic_api_key_raw"

    assert get_in(config_map, ["defaults", "provider"]) == "anthropic"
    assert get_in(config_map, ["defaults", "model"]) == "anthropic:claude-sonnet-4-20250514"
  end

  test "subscription sign-in accepts a pasted claude setup-token", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")
    # Keep the loopback redirect port busy so sign-in uses the copy-code prompt.
    port_holder = :gen_tcp.listen(53_692, [:binary, active: false, ip: {127, 0, 0, 1}])

    output =
      capture_io("n\nsk-ant-oat01-setup-token\n", fn ->
        io = Map.put(LemonCli.Onboarding.Runner.default_io(), :interactive?, fn -> true end)

        Mix.Tasks.Lemon.Onboard.run_with_io(
          ["anthropic", "--auth", "oauth", "--no-set-default", "--config-path", config_path],
          io
        )
      end)

    with {:ok, socket} <- port_holder, do: :gen_tcp.close(socket)

    assert output =~ "https://claude.ai/oauth/authorize?"
    assert output =~ "Paste the authorization code Anthropic shows"
    assert output =~ "Anthropic onboarding complete."

    assert {:ok, secret_value} =
             Secrets.get("llm_anthropic_api_key", prefer_env: false, env_fallback: false)

    assert {:ok, secret} = Jason.decode(secret_value)
    assert secret["type"] == "anthropic_oauth"
    assert secret["source"] == "setup_token"
    assert secret["access_token"] == "sk-ant-oat01-setup-token"

    {:ok, config_map} = Toml.decode_file(config_path)

    assert get_in(config_map, ["providers", "anthropic", "auth_source"]) == "oauth"

    assert get_in(config_map, ["providers", "anthropic", "oauth_secret"]) ==
             "llm_anthropic_api_key"
  end

  test "raises for unknown explicit model", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    assert_raise Mix.Error, ~r/Unknown model/, fn ->
      capture_io(fn ->
        Anthropic.run([
          "--non-interactive",
          "--token",
          "anthropic-token-123",
          "--config-path",
          config_path,
          "--set-default",
          "--model",
          "not-a-real-model"
        ])
      end)
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
