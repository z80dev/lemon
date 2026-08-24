defmodule LemonControlPlane.ManifestStub do
  @moduledoc false

  # Minimal HTTP/1.1 server for `update.run` tests: serves a single fixed
  # response for every GET request. `LemonCore.Update.Remote` (the module
  # `update.run` is built on) has its own richer fixture server for its own
  # test suite; this one only needs to stand in for a manifest.json host.

  @spec start(binary()) :: {:ok, String.t(), :gen_tcp.socket()}
  def start(body) when is_binary(body) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        packet: :line,
        active: false,
        reuseaddr: true,
        backlog: 16
      ])

    {:ok, port} = :inet.port(listen_socket)
    spawn_link(fn -> accept_loop(listen_socket, body) end)
    {:ok, "http://127.0.0.1:#{port}", listen_socket}
  end

  defp accept_loop(listen_socket, body) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, body) end)
        accept_loop(listen_socket, body)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, body) do
    with {:ok, _request_line} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, _headers} <- read_headers(socket, []) do
      response = [
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: #{byte_size(body)}\r\n",
        "Connection: close\r\n\r\n",
        body
      ]

      :gen_tcp.send(socket, response)
    end

    :gen_tcp.close(socket)
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} ->
        case String.trim(line) do
          "" -> {:ok, Enum.reverse(acc)}
          header -> read_headers(socket, [header | acc])
        end

      {:error, _} ->
        {:ok, Enum.reverse(acc)}
    end
  end
end
