defmodule LemonCli.GatewayColdStartTest do
  use ExUnit.Case, async: false

  for transport <- ~w(telegram discord) do
    test "cold #{transport} setup starts the secrets store without starting the runtime" do
      output =
        cold_run("""
        nil = Process.whereis(LemonCore.Store)
        {:error, :store_unavailable} = LemonCore.Secrets.status()
        1 = LemonCli.CLI.run(["gateway", "setup", "#{unquote(transport)}", "--non-interactive"])
        true = is_pid(Process.whereis(LemonCore.Store))
        nil = Process.whereis(LemonGateway.Supervisor)
        nil = Process.whereis(LemonRouter.Supervisor)
        IO.puts("cold gateway complete")
        """)

      assert output =~ "Bot token not found in encrypted secrets"
      assert output =~ "cold gateway complete"
      refute output =~ "BadMapError"
    end
  end

  test "gateway help does not start the store" do
    cold_run("""
    nil = Process.whereis(LemonCore.Store)
    0 = LemonCli.CLI.run(["gateway", "setup", "telegram", "--help"])
    nil = Process.whereis(LemonCore.Store)
    """)
  end

  defp cold_run(source) do
    root = Path.expand("../../../..", __DIR__)

    home =
      Path.join(System.tmp_dir!(), "lemon_gateway_cold_#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    # Use a fresh VM rather than stopping applications shared by the umbrella suite.
    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        [
          "--erl",
          "+S 2:2",
          "-pa",
          Path.join(root, "_build/test/lib/*/ebin"),
          "-e",
          "Mix.start(); Mix.env(:test); " <> source
        ],
        env: [
          {"HOME", home},
          {"LEMON_STORE_PATH", Path.join(home, "store")},
          {"LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32))}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end
end
