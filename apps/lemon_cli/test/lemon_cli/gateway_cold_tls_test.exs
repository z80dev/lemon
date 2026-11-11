defmodule LemonCli.GatewayColdTlsTest do
  use ExUnit.Case, async: false

  for transport <- ~w(telegram discord) do
    test "cold #{transport} setup supplies CA certificates before its first request" do
      root = Path.expand("../../../..", __DIR__)
      home = Path.join(System.tmp_dir!(), "gateway_tls_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)

      source = ~S"""
      # Only replace the HTTP boundary in this child VM; no real token or network is used.
      Code.compiler_options(ignore_module_conflict: true)
      defmodule LemonCore.Httpc do
        def request(:get, _request, http_options, []) do
          ssl = Keyword.fetch!(http_options, :ssl)
          :verify_peer = Keyword.fetch!(ssl, :verify)
          [_ | _] = Keyword.fetch!(ssl, :cacerts)
          body = ~s({"ok":true,"result":{"username":"test_bot"},"username":"test_bot"})
          {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}}
        end
      end

      false = function_exported?(:public_key, :cacerts_get, 0)
      [transport] = System.argv()
      {adapter, token, args} =
        case transport do
          "telegram" ->
            {LemonCli.Setup.Gateway.Telegram, "123:" <> String.duplicate("A", 35),
             ["--non-interactive", "--chat-id", "123"]}
          "discord" ->
            {LemonCli.Setup.Gateway.Discord, "1234567890.abcde.12345",
             ["--non-interactive", "--default-channel-id", "1234567890"]}
        end
      io = %{
        info: fn _ -> :ok end,
        error: fn msg -> raise msg end,
        secrets_status: fn -> %{configured: true} end,
        secret_get: fn _ -> {:ok, token} end,
        config_path: Path.join(System.fetch_env!("HOME"), "config.toml"),
        read_file: fn _ -> {:ok, ""} end,
        write_file: fn _, _ -> :ok end
      }
      :ok = adapter.run(args, io)
      IO.puts("TLS setup complete")
      """

      {output, status} =
        System.cmd(
          System.find_executable("elixir"),
          [
            "--erl",
            "+S 2:2",
            "-pa",
            Path.join(root, "_build/test/lib/*/ebin"),
            "-e",
            source,
            unquote(transport)
          ],
          env: [{"HOME", home}],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "TLS setup complete"
    end
  end
end
