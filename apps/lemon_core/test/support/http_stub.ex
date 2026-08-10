defmodule LemonCore.HttpStub do
  @moduledoc false

  # Minimal HTTP/1.1 server for the `LemonCore.Httpc` tests, speaking `:gen_tcp`
  # directly so that lemon_core gains no test-only dependency. It implements the
  # handful of httpbin.org routes those tests used to reach over the network:
  # echoing method/path/query/headers/body, arbitrary status codes, and a
  # delayed response for the timeout case.
  #
  # Bodies are JSON-ish but assembled by hand — pulling in an encoder just to
  # shape a fixture would defeat the point.

  @doc """
  Starts a listener on an ephemeral loopback port.

  Returns `{:ok, base_url, listen_socket}`. Close the socket to stop it; in-flight
  connection processes are linked to the caller and die with the test process.
  """
  @spec start() :: {:ok, String.t(), :gen_tcp.socket()}
  def start do
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
    spawn_link(fn -> accept_loop(listen_socket) end)
    {:ok, "http://127.0.0.1:#{port}", listen_socket}
  end

  @doc """
  A loopback URL that refuses connections, for the connection-error cases.
  """
  @spec refused_url() :: String.t()
  def refused_url, do: "http://127.0.0.1:1"

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> serve(socket) end)
        accept_loop(listen_socket)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket) do
    with {:ok, request_line} <- :gen_tcp.recv(socket, 0, 5_000),
         {method, target} <- parse_request_line(request_line),
         {:ok, headers} <- read_headers(socket, []) do
      body = read_body(socket, headers)
      respond(socket, method, target, headers, body)
    end

    :gen_tcp.close(socket)
  end

  defp parse_request_line(line) do
    case String.split(String.trim(line), " ") do
      [method, target | _] -> {String.upcase(method), target}
      _ -> :error
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, line} ->
        case String.trim(line) do
          "" ->
            {:ok, Enum.reverse(acc)}

          header ->
            case String.split(header, ":", parts: 2) do
              [name, value] ->
                read_headers(socket, [{String.trim(name), String.trim(value)} | acc])

              _ ->
                read_headers(socket, acc)
            end
        end

      {:error, _} ->
        {:ok, Enum.reverse(acc)}
    end
  end

  defp read_body(socket, headers) do
    case content_length(headers) do
      0 ->
        ""

      length ->
        :ok = :inet.setopts(socket, packet: :raw)

        case :gen_tcp.recv(socket, length, 5_000) do
          {:ok, body} -> body
          {:error, _} -> ""
        end
    end
  end

  defp content_length(headers) do
    headers
    |> find_header("content-length")
    |> case do
      nil -> 0
      value -> String.to_integer(String.trim(value))
    end
  rescue
    ArgumentError -> 0
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp respond(socket, method, target, headers, body) do
    {path, query} = split_target(target)

    case route(method, path, query, headers, body) do
      {:delay, seconds} ->
        Process.sleep(seconds * 1000)
        send_response(socket, method, 200, ~s({"delayed": true}))

      {status, response_body} ->
        send_response(socket, method, status, response_body)
    end
  end

  defp split_target(target) do
    case String.split(target, "?", parts: 2) do
      [path] -> {path, ""}
      [path, query] -> {path, query}
    end
  end

  defp route(method, path, query, headers, body) do
    case path do
      "/status/" <> code ->
        {String.to_integer(code), ~s({"status": #{code}})}

      "/delay/" <> seconds ->
        {:delay, String.to_integer(seconds)}

      "/headers" ->
        {200, ~s({"headers": {#{encode_headers(headers)}}})}

      "/user-agent" ->
        {200, ~s({"user-agent": "#{find_header(headers, "user-agent") || ""}"})}

      _ ->
        {200,
         ~s({"stub": "lemon_core", "method": "#{method}", "url": "#{path}", ) <>
           ~s("args": "#{query}", "data": #{inspect(body)}, ) <>
           ~s("headers": {#{encode_headers(headers)}}})}
    end
  end

  defp encode_headers(headers) do
    headers
    |> Enum.map_join(", ", fn {key, value} -> ~s("#{key}": "#{value}") end)
  end

  defp send_response(socket, method, status, body) do
    # HEAD must advertise the length it would have sent, but send no body.
    payload = if method == "HEAD", do: "", else: body

    response = [
      "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
      "Content-Type: application/json\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "X-Stub-Server: lemon_core\r\n",
      "Connection: close\r\n\r\n",
      payload
    ]

    :gen_tcp.send(socket, response)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_), do: "Status"
end
