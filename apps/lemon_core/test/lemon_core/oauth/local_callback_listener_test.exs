defmodule LemonCore.OAuth.LocalCallbackListenerTest do
  use ExUnit.Case, async: true

  alias LemonCore.OAuth.LocalCallbackListener

  test "captures a matching localhost callback and clears its monitor" do
    port = free_port()
    redirect_uri = "http://127.0.0.1:#{port}/oauth/callback"
    assert {:ok, listener} = LocalCallbackListener.start(redirect_uri)

    assert request(port, "GET /oauth/callback?code=abc&state=xyz HTTP/1.1", "127.0.0.1:#{port}") =~
             "HTTP/1.1 200 OK"

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
      :timer.tc(fn -> LocalCallbackListener.wait(listener, 10_000) end)

    assert result == {:error, {:listener_down, :killed}}
    # Must return as soon as the listener dies instead of waiting out the 10s timeout.
    assert elapsed_us < 5_000_000
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

    assert request(port, "GET /callback?code=late HTTP/1.1", "127.0.0.1:#{port}") =~
             "HTTP/1.1 200 OK"

    listener_ref = listener.ref
    pid_ref = Process.monitor(listener.pid)
    assert_receive {:DOWN, ^pid_ref, :process, _pid, _reason}, 1_000

    assert :ok = LocalCallbackListener.stop(listener)
    refute_receive {^listener_ref, _result}
  end

  test "unrelated requests are rejected and do not end the wait" do
    port = free_port()
    host = "127.0.0.1:#{port}"

    assert {:ok, listener} =
             LocalCallbackListener.start("http://127.0.0.1:#{port}/callback",
               expected_state: "the-state"
             )

    rejected = [
      {"GET /wrong?code=x&state=the-state HTTP/1.1", host, "404"},
      {"POST /callback?code=x&state=the-state HTTP/1.1", host, "405"},
      {"GET /callback?code=x&state=the-state HTTP/1.1", "evil.example:#{port}", "400"},
      {"GET /callback?code=x&state=the-state HTTP/1.1", "127.0.0.1:1", "400"},
      {"GET /callback?code=x&state=the-state HTTP/1.1", nil, "400"},
      {"GET http://evil.example:#{port}/callback?code=x&state=the-state HTTP/1.1", host, "400"},
      {"GET /callback?code=x HTTP/1.1", host, "400"},
      {"GET /callback?code=x&state= HTTP/1.1", host, "400"},
      {"GET /callback?code=x&state=forged HTTP/1.1", host, "400"},
      {"GET /callback?code=x&state=%20the-state HTTP/1.1", host, "400"}
    ]

    for {line, host_header, status} <- rejected do
      assert request(port, line, host_header) =~ "HTTP/1.1 #{status}"
    end

    assert request(port, "GET /callback?code=good&state=the-state HTTP/1.1", host) =~
             "HTTP/1.1 200 OK"

    assert {:ok, url} = LocalCallbackListener.wait(listener, 1_000)
    assert url == "http://127.0.0.1:#{port}/callback?code=good&state=the-state"
  end

  test "absolute-form requests for the listener's own authority are accepted" do
    port = free_port()
    host = "localhost:#{port}"

    assert {:ok, listener} =
             LocalCallbackListener.start("http://localhost:#{port}/callback", expected_state: "s")

    assert request(port, "GET http://#{host}/callback?code=c&state=s HTTP/1.1", host) =~
             "HTTP/1.1 200 OK"

    assert {:ok, _url} = LocalCallbackListener.wait(listener, 1_000)
  end

  test "rejected requests leave the original deadline in force" do
    port = free_port()

    assert {:ok, listener} =
             LocalCallbackListener.start("http://127.0.0.1:#{port}/callback", expected_state: "s")

    assert request(port, "GET /callback?code=x&state=bad HTTP/1.1", "127.0.0.1:#{port}") =~
             "HTTP/1.1 400"

    {elapsed_us, result} = :timer.tc(fn -> LocalCallbackListener.wait(listener, 300) end)
    assert result == {:error, :timeout}
    assert elapsed_us >= 300_000
  end

  defp request(port, request_line, host) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    host_header = if host, do: "host: #{host}\r\n", else: ""
    :ok = :gen_tcp.send(socket, "#{request_line}\r\n#{host_header}\r\n")
    {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    :gen_tcp.close(socket)
    response
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
