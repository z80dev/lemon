defmodule LemonCore.Doctor.RuntimeCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.Checks.Runtime

  # The packaged lemon_core declares an Elixir floor below the application's;
  # its own runtime check must not fail on any toolchain it admits (#730). The
  # application floor is LemonCli.Doctor.Toolchain's.
  test "the runtime check passes the build identity and judges no toolchain" do
    checks = Runtime.run([])

    assert %{status: :pass, message: "Lemon " <> _} =
             Enum.find(checks, &(&1.name == "runtime.build"))

    refute Enum.any?(checks, &(&1.name == "runtime.elixir"))
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
