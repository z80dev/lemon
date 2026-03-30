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
    original_claude_path = System.get_env("LEMON_ANTHROPIC_CLAUDE_PATH")

    System.put_env("HOME", mock_home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      if original_claude_path,
        do: System.put_env("LEMON_ANTHROPIC_CLAUDE_PATH", original_claude_path),
        else: System.delete_env("LEMON_ANTHROPIC_CLAUDE_PATH")

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

  test "supports Claude Code OAuth onboarding", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")
    script_path = write_fake_claude_cli(tmp_dir)
    System.put_env("LEMON_ANTHROPIC_CLAUDE_PATH", script_path)

    output =
      capture_io(fn ->
        Anthropic.run([
          "--auth",
          "oauth",
          "--config-path",
          config_path
        ])
      end)

    assert output =~ "Anthropic onboarding complete."

    assert {:ok, secret_value} =
             Secrets.get("llm_anthropic_api_key", prefer_env: false, env_fallback: false)

    assert {:ok, secret} = Jason.decode(secret_value)
    assert secret["type"] == "anthropic_oauth"
    assert secret["access_token"] == "sk-ant-oat01-cli-token"

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

  defp write_fake_claude_cli(tmp_dir) do
    bin_dir = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin_dir)
    script_path = Path.join(bin_dir, "claude")

    File.write!(
      script_path,
      """
      #!/bin/sh
      mkdir -p "$HOME/.claude"
      cat > "$HOME/.claude/.credentials.json" <<'EOF'
      {"claudeAiOauth":{"accessToken":"sk-ant-oat01-cli-token","refreshToken":"refresh-token","expiresAt":4102444800000}}
      EOF
      exit 0
      """
    )

    File.chmod!(script_path, 0o755)
    script_path
  end
end
