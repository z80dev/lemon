defmodule LemonCore.OAuth.LocalCallbackListenerTest do
  use ExUnit.Case, async: true

  alias LemonCore.OAuth.LocalCallbackListener

  test "captures a matching localhost callback and clears its monitor" do
    port = free_port()
    redirect_uri = "http://127.0.0.1:#{port}/oauth/callback"
    assert {:ok, listener} = LocalCallbackListener.start(redirect_uri)

    assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    assert :ok =
             :gen_tcp.send(
               socket,
               "GET /oauth/callback?code=abc&state=xyz HTTP/1.1\r\nhost: localhost\r\n\r\n"
             )

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert response =~ "HTTP/1.1 200 OK"
    :ok = :gen_tcp.close(socket)

    expected = "http://127.0.0.1:#{port}/oauth/callback?code=abc&state=xyz"
    assert {:ok, ^expected} = LocalCallbackListener.wait(listener, 1_000)

    monitor_ref = listener.monitor_ref
    refute_receive {:DOWN, ^monitor_ref, :process, _pid, _reason}
  end

  test "returns immediately when the listener process dies" do
    port = free_port()
    assert {:ok, listener} = LocalCallbackListener.start("http://127.0.0.1:#{port}/callback")

    Process.exit(listener.pid, :kill)

    {elapsed_us, result} =
      :timer.tc(fn -> LocalCallbackListener.wait(listener, 2_000) end)

    assert result == {:error, {:listener_down, :killed}}
    assert elapsed_us < 250_000
    monitor_ref = listener.monitor_ref
    refute_receive {:DOWN, ^monitor_ref, :process, _pid, _reason}
  end

  test "stop terminates the listener, closes the socket, and flushes its monitor" do
    port = free_port()
    assert {:ok, listener} = LocalCallbackListener.start("http://127.0.0.1:#{port}/callback")

    pid_ref = Process.monitor(listener.pid)
    assert :ok = LocalCallbackListener.stop(listener)
    assert_receive {:DOWN, ^pid_ref, :process, _pid, :shutdown}, 1_000

    assert {:error, _reason} =
             :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100)

    monitor_ref = listener.monitor_ref
    refute_receive {:DOWN, ^monitor_ref, :process, _pid, _reason}
  end

  test "stop flushes a callback result that completed before cancellation" do
    port = free_port()
    assert {:ok, listener} = LocalCallbackListener.start("http://127.0.0.1:#{port}/callback")
    assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    assert :ok =
             :gen_tcp.send(socket, "GET /callback?code=late HTTP/1.1\r\nhost: localhost\r\n\r\n")

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert response =~ "HTTP/1.1 200 OK"
    :ok = :gen_tcp.close(socket)

    listener_ref = listener.ref
    pid_ref = Process.monitor(listener.pid)
    assert_receive {:DOWN, ^pid_ref, :process, _pid, :normal}, 1_000

    assert :ok = LocalCallbackListener.stop(listener)
    refute_receive {^listener_ref, _result}
  end

  test "returns the request error for an unexpected callback path" do
    port = free_port()
    assert {:ok, listener} = LocalCallbackListener.start("http://127.0.0.1:#{port}/callback")
    assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    assert :ok =
             :gen_tcp.send(socket, "GET /wrong HTTP/1.1\r\nhost: localhost\r\n\r\n")

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert response =~ "HTTP/1.1 404 Not Found"
    assert LocalCallbackListener.wait(listener, 1_000) == {:error, :unexpected_path}
    :ok = :gen_tcp.close(socket)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
