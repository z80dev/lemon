defmodule LemonAi.Test.StreamServer do
  @moduledoc """
  Scripted local HTTP/1.1 server for provider transport tests.

  `start/1` takes `script`, a function of the zero-based request number that
  returns the steps for that request's response:

    * `{:status, status, body}` - a complete non-streaming response
    * `:headers` - `200` SSE response headers with chunked encoding
    * `{:chunk, iodata}` - one HTTP chunk
    * `{:sleep, ms}`
    * `:finish` - the terminating chunk (a clean end of body)
    * `:close` - close the connection without terminating the body
    * `:stall` - keep the connection open until the client closes it

  The owner receives `{:stream_server, :request, n, %{path: path, body: body}}`
  for each request and `{:stream_server, :client_closed, n}` when a stalled
  connection is closed by the client. `redirect_adapter/1` returns a Req adapter
  sending every request to the server regardless of its URL host, so providers
  with fixed HTTPS endpoints exercise a real connection.
  """

  @response_headers "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
                      "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"

  def start(script) when is_function(script, 1) do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    acceptor = spawn(fn -> accept(listener, owner, script, 0) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)
    %{port: port, url: "http://127.0.0.1:#{port}", acceptor: acceptor}
  end

  def stop(%{acceptor: acceptor}), do: Process.exit(acceptor, :kill)

  def redirect_adapter(%{port: port}) do
    fn request ->
      url = %{request.url | scheme: "http", host: "127.0.0.1", port: port}
      Req.Steps.run_finch(%{request | url: url})
    end
  end

  defp accept(listener, owner, script, n) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler = spawn(fn -> serve(owner, script, n) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        accept(listener, owner, script, n + 1)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(owner, script, n) do
    socket =
      receive do
        {:socket, socket} -> socket
      end

    request = read_request(socket, "")
    send(owner, {:stream_server, :request, n, request})
    Enum.each(script.(n), &step(socket, owner, n, &1))
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] ->
        [request_line | header_lines] = String.split(head, "\r\n")
        [_method, path | _] = String.split(request_line, " ")

        length =
          Enum.find_value(header_lines, 0, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length",
                  do: value |> String.trim() |> String.to_integer()

              _ ->
                nil
            end
          end)

        %{path: path, body: read_body(socket, body, length)}

      [_incomplete] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> data)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: body

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end

  defp step(socket, _owner, _n, {:status, status, body}) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])
  end

  defp step(socket, _owner, _n, :headers), do: :gen_tcp.send(socket, @response_headers)

  defp step(socket, _owner, _n, {:chunk, data}) do
    data = IO.iodata_to_binary(data)
    :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])
  end

  defp step(_socket, _owner, _n, {:sleep, ms}), do: Process.sleep(ms)
  defp step(socket, _owner, _n, :finish), do: :gen_tcp.send(socket, "0\r\n\r\n")
  defp step(socket, _owner, _n, :close), do: :gen_tcp.close(socket)

  defp step(socket, owner, n, :stall) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:error, :closed} -> send(owner, {:stream_server, :client_closed, n})
      _other -> :ok
    end
  end
end
