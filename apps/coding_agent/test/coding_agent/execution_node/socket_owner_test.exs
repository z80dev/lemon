defmodule CodingAgent.ExecutionNode.SocketOwnerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.Socket

  test "stop terminates the socket and cancels its timer during long reconnect backoff" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, client} = :gen_tcp.accept(listener, 2_000)
        receive_headers(client, "")
        send(parent, {:handshake_waiting, self()})

        receive do
          :refuse_handshake ->
            :ok = :gen_tcp.send(client, "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n")
            :gen_tcp.close(client)
        end
      end)

    {:ok, socket} =
      Socket.start_link(
        owner: self(),
        url: "ws://127.0.0.1:#{port}/ws",
        connect_params: %{},
        connect_failures: 7,
        ping_interval_ms: 0
      )

    Process.unlink(socket)
    on_exit(fn -> if Process.alive?(socket), do: GenServer.stop(socket) end)
    server_pid = server.pid
    assert_receive {:handshake_waiting, ^server_pid}, 2_000
    %{transport: transport} = :sys.get_state(socket)
    :erlang.trace(socket, true, [:receive])

    try do
      send(server.pid, :refuse_handshake)
      assert_receive {:trace, ^socket, :receive, {:EXIT, ^transport, _}}, 2_000
      %{transport: nil, timer: {timer, _token}} = :sys.get_state(socket)
      assert Process.read_timer(timer) > 40_000
      monitor = Process.monitor(socket)
      assert :ok = Socket.stop(socket)
      assert_receive {:DOWN, ^monitor, :process, ^socket, :normal}, 1_000
      assert Process.read_timer(timer) == false
    after
      if Process.alive?(socket), do: :erlang.trace(socket, false, [:receive])
    end

    Task.await(server)
  end

  defp receive_headers(socket, accumulated) do
    if String.contains?(accumulated, "\r\n\r\n") do
      :ok
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
      receive_headers(socket, accumulated <> data)
    end
  end
end
