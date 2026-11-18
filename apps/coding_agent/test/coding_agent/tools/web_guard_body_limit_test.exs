defmodule CodingAgent.Tools.WebGuardBodyLimitTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Tools.WebGuard

  # Serves one chunked response; `chunks` are sent in order. With `finish?:
  # false` the final chunk is withheld and the socket is held open.
  defp serve_chunked(chunks, finish?) do
    parent = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
          )

        for chunk <- chunks do
          send(parent, {:chunk, chunk})

          :ok =
            :gen_tcp.send(
              socket,
              Integer.to_string(byte_size(chunk), 16) <> "\r\n" <> chunk <> "\r\n"
            )
        end

        if finish? do
          :gen_tcp.send(socket, "0\r\n\r\n")
          :gen_tcp.close(socket)
        else
          Process.sleep(10_000)
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    "http://127.0.0.1:#{port}/"
  end

  test "halts on the first chunk exceeding the limit without waiting for the rest" do
    url = serve_chunked(["123", "456"], false)

    assert {:error, {:body_too_large, %{max_body_bytes: 5}}} =
             WebGuard.guarded_get(url,
               allow_private_network: true,
               max_body_bytes: 5,
               timeout_ms: 5_000
             )

    assert_received {:chunk, "123"}
    assert_received {:chunk, "456"}
  end

  test "assembles ordered chunks exactly at the cap" do
    url = serve_chunked(["12", "345"], true)

    assert {:ok, %{status: 200, body: "12345"}, _} =
             WebGuard.guarded_get(url, allow_private_network: true, max_body_bytes: 5)
  end

  test "default is five MiB and injected transport responses are also bounded" do
    send_fn = fn request ->
      assert request.max_body_bytes == 5 * 1024 * 1024
      {:ok, %{status: 200, headers: [], body: :binary.copy("a", 5 * 1024 * 1024 + 1)}}
    end

    assert {:error, {:body_too_large, %{max_body_bytes: 5_242_880}}} =
             WebGuard.guarded_get("https://8.8.8.8", send: send_fn)
  end
end
