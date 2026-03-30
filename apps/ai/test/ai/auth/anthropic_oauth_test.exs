defmodule Ai.Auth.AnthropicOAuthTest do
  use ExUnit.Case, async: false

  alias Ai.Auth.AnthropicOAuth
  alias LemonCore.{Secrets, Store}

  setup do
    {:ok, _} = Application.ensure_all_started(:ai)
    {:ok, _} = Application.ensure_all_started(:lemon_core)

    clear_secrets_table()

    tmp_dir =
      Path.join(System.tmp_dir!(), "anthropic_oauth_test_#{System.unique_integer([:positive])}")

    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)

    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    original_path = System.get_env("PATH")

    System.put_env("HOME", home_dir)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    System.delete_env("ANTHROPIC_TOKEN")
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
    System.delete_env("LEMON_ANTHROPIC_CLAUDE_PATH")

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")

      System.delete_env("ANTHROPIC_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("LEMON_ANTHROPIC_CLAUDE_PATH")
      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    :ok
  end

  test "resolve_access_token reads Claude Code credentials from ~/.claude/.credentials.json" do
    path = Path.join([System.fetch_env!("HOME"), ".claude", ".credentials.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-oat01-file-token",
          "refreshToken" => "refresh-token",
          "expiresAt" => System.system_time(:millisecond) + 3_600_000
        }
      })
    )

    assert AnthropicOAuth.resolve_access_token() == "sk-ant-oat01-file-token"
  end

  test "resolve_access_token prefers refreshable Claude Code credentials over static env token" do
    path = Path.join([System.fetch_env!("HOME"), ".claude", ".credentials.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "sk-ant-oat01-refreshable-token",
          "refreshToken" => "refresh-token",
          "expiresAt" => System.system_time(:millisecond) + 3_600_000
        }
      })
    )

    System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-static-token")

    assert AnthropicOAuth.resolve_access_token() == "sk-ant-oat01-refreshable-token"
  end

  test "login_device_flow runs claude setup-token and returns Claude credential payload" do
    script_path =
      write_fake_claude_cli(
        ~s|{"accessToken":"sk-ant-oat01-cli-token","refreshToken":"refresh-token","expiresAt":4102444800000}|
      )

    System.put_env("LEMON_ANTHROPIC_CLAUDE_PATH", script_path)

    assert {:ok, secret} =
             AnthropicOAuth.login_device_flow(
               on_progress: fn _ -> :ok end,
               on_prompt: fn _ -> flunk("expected Claude CLI flow without manual prompt") end
             )

    assert secret["type"] == "anthropic_oauth"
    assert secret["access_token"] == "sk-ant-oat01-cli-token"
    assert secret["refresh_token"] == "refresh-token"
  end

  test "oauth_headers detects claude-code version from PATH when claude is unavailable" do
    bin_dir = Path.join(System.fetch_env!("HOME"), "bin")
    File.mkdir_p!(bin_dir)
    script_path = Path.join(bin_dir, "claude-code")

    File.write!(
      script_path,
      """
      #!/bin/sh
      echo "9.9.9 (Claude Code)"
      """
    )

    File.chmod!(script_path, 0o755)
    System.put_env("PATH", bin_dir)

    headers = Map.new(AnthropicOAuth.oauth_headers())

    assert headers["user-agent"] == "claude-cli/9.9.9 (external, cli)"
    assert headers["x-app"] == "cli"
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end

  defp write_fake_claude_cli(oauth_json) do
    bin_dir = Path.join(System.fetch_env!("HOME"), "bin")
    File.mkdir_p!(bin_dir)
    script_path = Path.join(bin_dir, "claude")

    File.write!(
      script_path,
      """
      #!/bin/sh
      mkdir -p "$HOME/.claude"
      cat > "$HOME/.claude/.credentials.json" <<'EOF'
      {"claudeAiOauth":#{oauth_json}}
      EOF
      exit 0
      """
    )

    File.chmod!(script_path, 0o755)
    script_path
  end
end
