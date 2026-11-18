defmodule LemonGateway.WebhookCallbackSsrfTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Transports.Webhook.{Request, Response}

  # A one-connection-per-request HTTP listener that records every request line
  # and answers with a canned response.
  defp start_listener(reply) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    test = self()

    pid =
      spawn_link(fn ->
        accept_loop(listen, test, port, reply)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    port
  end

  defp accept_loop(listen, test, port, reply) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, data} = read_head(socket, "")
        [request_line | _] = String.split(data, "\r\n")
        send(test, {:listener_hit, port, request_line})
        :ok = :gen_tcp.send(socket, reply)
        :gen_tcp.close(socket)
        accept_loop(listen, test, port, reply)

      _ ->
        :ok
    end
  end

  defp read_head(socket, buffer) do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, chunk} -> read_head(socket, buffer <> chunk)
        error -> error
      end
    end
  end

  defp run_sync_callback(callback_url, extra_ctx) do
    run_id = "run_" <> Integer.to_string(System.unique_integer([:positive]))

    run_ctx =
      Map.merge(
        %{
          integration_id: "ssrf",
          run_id: run_id,
          session_key: "agent:default:webhook:ssrf:dm:1",
          mode: :sync,
          timeout_ms: 2_000,
          callback_url: callback_url,
          metadata: %{},
          attachments: []
        },
        extra_ctx
      )

    {:ok, wait_setup, _} = Response.prepare_wait_before_submit(:sync, run_ctx, [])

    LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), %{
      type: :run_completed,
      payload: %{completed: %{ok: true, answer: "done"}, duration_ms: 1}
    })

    Response.response_for_run(Map.merge(run_ctx, wait_setup), [])
  end

  test "callback POST does not follow a redirect to another host" do
    target = start_listener("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")

    redirector =
      start_listener(
        "HTTP/1.1 303 See Other\r\nlocation: http://127.0.0.1:#{target}/internal\r\n" <>
          "content-length: 0\r\n\r\n"
      )

    assert {:ok, 200, payload} =
             run_sync_callback("http://127.0.0.1:#{redirector}/cb", %{
               callback_allow_private: true
             })

    assert_receive {:listener_hit, ^redirector, "POST /cb HTTP/1.1"}, 2_000
    refute_receive {:listener_hit, ^target, _}, 500
    assert %{status: "failed"} = payload.callback
  end

  test "callback delivery re-checks the destination and never connects to a private host" do
    port = start_listener("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")

    # Private hosts were not approved: a callback that resolves private at
    # delivery time (DNS rebinding after submission) must not be contacted.
    assert {:ok, 200, payload} = run_sync_callback("http://127.0.0.1:#{port}/cb", %{})

    refute_receive {:listener_hit, ^port, _}, 500
    assert %{status: "failed"} = payload.callback
  end

  test "DNS failure is not treated as a public callback host" do
    for resolver <- [
          fn _ -> {:error, :nxdomain} end,
          fn _ -> {:error, :timeout} end,
          fn _ -> {:ok, []} end,
          fn _ -> raise "resolver down" end
        ] do
      assert {:error, :invalid_callback_url} =
               Request.validate_callback_url("https://callback.example/cb", false,
                 dns_resolver: resolver
               )
    end
  end

  test "metadata, alias, mapped and 6to4 callback hosts are rejected" do
    public = fn _ -> {:ok, [{93, 184, 216, 34}]} end

    for url <- [
          "http://2852039166/cb",
          "http://0xA9FEA9FE/cb",
          "http://0251.0376.0251.0376/cb",
          "http://[::ffff:169.254.169.254]/cb",
          "http://[64:ff9b::a9fe:a9fe]/cb",
          "http://[2002:a9fe:a9fe::]/cb",
          "http://[2002:0a00:0001::1]/cb",
          "http://metadata.google.internal/cb"
        ] do
      assert {:error, :invalid_callback_url} =
               Request.validate_callback_url(url, false, dns_resolver: public),
             url
    end

    # Approving private callback hosts never approves cloud metadata.
    for url <- [
          "http://169.254.169.254/cb",
          "http://2852039166/cb",
          "http://[2002:a9fe:a9fe::]/cb"
        ] do
      assert {:error, :invalid_callback_url} =
               Request.validate_callback_url(url, true, dns_resolver: public),
             url
    end

    rebound = fn _ -> {:ok, [{93, 184, 216, 34}, {0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 0}]} end

    assert {:error, :invalid_callback_url} =
             Request.validate_callback_url("https://callback.example/cb", false,
               dns_resolver: rebound
             )
  end
end
