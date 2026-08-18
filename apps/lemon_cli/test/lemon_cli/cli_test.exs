defmodule LemonCli.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCore.Secrets

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_cli_runtime_#{System.unique_integer([:positive])}"
      )

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")

    System.put_env("HOME", home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    clear_secrets_table()

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "dispatches setup without a Mix shell" do
    output =
      capture_io(fn ->
        assert CLI.run(["setup", "gateway", "--non-interactive"]) == 0
      end)

    assert output =~ "Available gateway transports"
  end

  test "forwards model provider arguments to onboarding", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    output =
      capture_io(fn ->
        assert CLI.run([
                 "model",
                 "--provider",
                 "openai",
                 "--token",
                 "runtime-cli-token",
                 "--secret-name",
                 "runtime_cli_test_token",
                 "--set-default",
                 "--model",
                 "gpt-5",
                 "--config-path",
                 config_path
               ]) == 0
      end)

    assert output =~ "OpenAI onboarding complete."
    {:ok, secret} = Secrets.get("runtime_cli_test_token", prefer_env: false, env_fallback: false)
    assert secret == "runtime-cli-token"

    {:ok, config} = Toml.decode_file(config_path)
    assert get_in(config, ["providers", "openai", "api_key_secret"]) == "runtime_cli_test_token"
    assert get_in(config, ["defaults", "provider"]) == "openai"
    assert get_in(config, ["defaults", "model"]) == "openai:gpt-5"
  end

  test "reports unknown commands as a user-facing usage error" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["not-a-command"]) == 2
      end)

    assert error =~ "Unknown command: not-a-command"
    assert error =~ "Usage: lemon <command> [options]"
    assert error =~ "Run `lemon <command> --help` for command options."
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
