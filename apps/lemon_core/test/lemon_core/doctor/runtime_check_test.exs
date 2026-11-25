defmodule LemonCore.Doctor.RuntimeCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Checks.Runtime

  test "doctor fails unsupported Elixir versions with upgrade guidance" do
    for version <- ["1.20.4", "1.19.5", "1.20.5-rc.1", "invalid"] do
      check = elixir_check(version)
      assert check.status == :fail
      assert check.message =~ version
      assert check.message =~ "requires Elixir 1.20.5 or newer"
      assert check.remediation =~ "Upgrade Elixir"
    end
  end

  test "doctor accepts the minimum and newer Elixir versions" do
    for version <- ["1.20.5", "1.20.6", "1.21.0"] do
      check = elixir_check(version)
      assert check.status == :pass
      assert check.message =~ version
    end
  end

  test "doctor names the expected applications a running runtime is missing" do
    body = ~s({"ok":false,"profile":"runtime_full","missing":["lemon_automation"]})
    {port, server} = serve_once("HTTP/1.1 503 Service Unavailable", body)

    checks = Runtime.run(env: %LemonCore.Runtime.Env{control_port: port, web_port: port})
    Task.await(server)
    by_name = Map.new(checks, &{&1.name, &1})

    assert by_name["runtime.control_port"].status == :pass
    assert by_name["runtime.apps"].status == :fail
    assert by_name["runtime.apps"].message =~ "lemon_automation"
  end

  defp elixir_check(version) do
    Runtime.run(elixir_version: version)
    |> Enum.find(&(&1.name == "runtime.elixir"))
  end

  # Answers one HTTP request on an ephemeral loopback port with `status` and `body`.
  defp serve_once(status, body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(socket, "#{status}\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}")

        :gen_tcp.close(socket)
      end)

    {port, server}
  end
end
