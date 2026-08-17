defmodule LemonCore.Update.FixtureServer do
  @moduledoc false

  # Minimal HTTP/1.1 server for `LemonCore.Update.Remote` tests, speaking
  # `:gen_tcp` directly (same technique as `LemonCore.HttpStub`) so lemon_core
  # gains no test-only dependency. Routes are supplied by the caller as a
  # `path -> response` function so each test can serve its own manifest.json
  # and fixture tarball bytes.
  #
  # A response is `{status, content_type, body}` or `{:redirect, location}`.
  # The `manifest.json` route always redirects once, exercising the same
  # 302-follow behavior GitHub's `releases/latest/download/` performs.

  @spec start((String.t() -> {pos_integer(), String.t(), binary()} | {:redirect, String.t()})) ::
          {:ok, String.t(), :gen_tcp.socket()}
  def start(router) when is_function(router, 1) do
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
    spawn_link(fn -> accept_loop(listen_socket, router) end)
    {:ok, "http://127.0.0.1:#{port}", listen_socket}
  end

  defp accept_loop(listen_socket, router) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, router) end)
        accept_loop(listen_socket, router)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, router) do
    with {:ok, request_line} <- :gen_tcp.recv(socket, 0, 5_000),
         {:ok, target} <- parse_request_line(request_line),
         {:ok, _headers} <- read_headers(socket, []) do
      {path, _query} = split_target(target)
      respond(socket, router.(path))
    end

    :gen_tcp.close(socket)
  end

  defp parse_request_line(line) do
    case String.split(String.trim(line), " ") do
      [_method, target | _] -> {:ok, target}
      _ -> :error
    end
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

  defp split_target(target) do
    case String.split(target, "?", parts: 2) do
      [path] -> {path, ""}
      [path, query] -> {path, query}
    end
  end

  defp respond(socket, {:redirect, location}) do
    response = [
      "HTTP/1.1 302 Found\r\n",
      "Location: #{location}\r\n",
      "Content-Length: 0\r\n",
      "Connection: close\r\n\r\n"
    ]

    :gen_tcp.send(socket, response)
  end

  defp respond(socket, {status, content_type, body}) do
    response = [
      "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
      "Content-Type: #{content_type}\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: close\r\n\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_), do: "Status"
end
