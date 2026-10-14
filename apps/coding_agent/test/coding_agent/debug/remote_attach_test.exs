defmodule CodingAgent.Debug.RemoteAttachTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Debug.{Client, Protocol, SessionServer}

  @moduletag :tmp_dir

  test "port attach uses the existing DAP endpoint and disconnects without owning its target", %{
    tmp_dir: cwd
  } do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        serve(socket, [], "", nil, parent)
      end)

    key = "remote-dap-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = SessionServer.whereis(key),
        do: DynamicSupervisor.terminate_child(CodingAgent.Debug.Supervisor, pid)

      :gen_tcp.close(listener)
      Process.exit(peer.pid, :kill)
    end)

    adapter = %{
      name: "debugpy",
      connect_mode: :remote,
      host: "127.0.0.1",
      port: port,
      attach_defaults: %{},
      command: nil,
      args: []
    }

    assert {:ok, %{state: :stopped}} =
             SessionServer.call(
               key,
               %{
                 action: "attach",
                 adapter: adapter,
                 cwd: cwd,
                 port: port,
                 host: "127.0.0.1",
                 pid: nil
               },
               timeout_ms: 5_000
             )

    assert_receive {:remote_attach, %{"connect" => %{"host" => "127.0.0.1", "port" => ^port}}}
    client = :sys.get_state(SessionServer.whereis(key)).session.client
    assert Client.os_pid(client) == nil
    assert {:ok, _} = SessionServer.call(key, %{action: "terminate"}, timeout_ms: 5_000)
    assert_receive {:remote_disconnect, %{"terminateDebuggee" => false}}
    assert Task.await(peer, 5_000) == :closed
    refute_received :remote_terminate
    assert {:ok, ^port} = :inet.port(listener)
  end

  defp serve(socket, [], buffer, attach, parent) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        {messages, rest, _junk} = Protocol.decode(buffer <> data)
        serve(socket, messages, rest, attach, parent)

      {:error, :closed} ->
        :closed
    end
  end

  defp serve(socket, [request | remaining], buffer, attach, parent) do
    attach =
      case request["command"] do
        "initialize" ->
          reply(socket, request, %{
            "supportsConfigurationDoneRequest" => true,
            "supportsTerminateRequest" => true
          })

          attach

        "attach" ->
          send(parent, {:remote_attach, request["arguments"]})
          event(socket, "initialized", %{})
          request

        "configurationDone" ->
          reply(socket, request, %{})
          reply(socket, attach, %{})
          event(socket, "stopped", %{"reason" => "entry", "threadId" => 1})
          attach

        "disconnect" ->
          send(parent, {:remote_disconnect, request["arguments"]})
          reply(socket, request, %{})
          attach

        "terminate" ->
          send(parent, :remote_terminate)
          reply(socket, request, %{})
          attach

        _ ->
          reply(socket, request, %{"threads" => [], "stackFrames" => []})
          attach
      end

    serve(socket, remaining, buffer, attach, parent)
  end

  defp reply(socket, request, body),
    do:
      :gen_tcp.send(
        socket,
        Protocol.encode(%{
          "seq" => 1,
          "type" => "response",
          "request_seq" => request["seq"],
          "command" => request["command"],
          "success" => true,
          "body" => body
        })
      )

  defp event(socket, name, body),
    do:
      :gen_tcp.send(
        socket,
        Protocol.encode(%{
          "seq" => 1,
          "type" => "event",
          "event" => name,
          "body" => body
        })
      )
end
