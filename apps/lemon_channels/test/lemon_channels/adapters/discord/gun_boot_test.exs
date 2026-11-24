defmodule LemonChannels.Adapters.Discord.GunBootTest do
  @moduledoc """
  Nostrum is an included application, so OTP only loads its dependencies.
  lemon_channels must start `:gun` itself or every Nostrum connection exits
  with `:noproc` (#670).
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Supervisor, as: DiscordSupervisor

  test "lemon_channels declares and starts gun" do
    assert :gun in Application.spec(:lemon_channels, :applications)
    assert {:ok, _} = Application.ensure_all_started(:lemon_channels)

    started = Enum.map(Application.started_applications(), &elem(&1, 0))
    assert :gun in started
    assert is_pid(Process.whereis(:gun_sup))
  end

  test "a configured token puts the Nostrum supervisor in the adapter tree" do
    old_token = Application.get_env(:nostrum, :token)
    old_intents = Application.get_env(:nostrum, :gateway_intents)

    on_exit(fn ->
      restore(:token, old_token)
      restore(:gateway_intents, old_intents)
    end)

    assert {:ok, {_flags, children}} =
             DiscordSupervisor.init(config: %{bot_token: "fake-token"})

    assert Enum.any?(children, &match?(%{id: Nostrum.Application}, &1))
  end

  test "a gun connection with a fake token reaches an auth failure, not :noproc" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        body = ~s({"message": "401: Unauthorized", "code": 0})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 401 Unauthorized\r\ncontent-type: application/json\r\n" <>
              "content-length: #{byte_size(body)}\r\n\r\n" <> body
          )

        :gen_tcp.close(socket)
      end)

    assert {:ok, conn} = :gun.open(~c"127.0.0.1", port, %{protocols: [:http]})
    assert {:ok, :http} = :gun.await_up(conn, 5_000)

    stream =
      :gun.get(conn, "/api/v10/gateway/bot", [{"authorization", "Bot fake-token"}])

    assert {:response, :nofin, 401, _headers} = :gun.await(conn, stream, 5_000)
    :gun.close(conn)
    Task.await(server)
    :gen_tcp.close(listen)
  end

  defp restore(key, nil), do: Application.delete_env(:nostrum, key)
  defp restore(key, value), do: Application.put_env(:nostrum, key, value)
end
