defmodule LemonMCP.HTTP.OwnedConnection do
  @moduledoc false

  # httpc does not expose its connected socket before sending headers. Mint's
  # passive HTTP/1 connection lets us inspect the actual peer first. Never pool
  # or retry this connection: every request must establish its own ownership.
  def request(method, url, headers, body, pin, timeout, tls_opts, peer_owner) do
    scheme = if pin.scheme == "https", do: :https, else: :http
    transport = if scheme == :https, do: :ssl, else: :tcp
    family = if tuple_size(pin.address) == 8, do: :inet6, else: :inet

    transport_opts =
      Keyword.get(tls_opts, :ssl, []) ++
        [timeout: timeout, send_timeout: timeout, inet6: family == :inet6]

    case Mint.HTTP.connect(scheme, pin.address, pin.port,
           hostname: pin.host,
           protocols: [:http1],
           mode: :passive,
           transport_opts: transport_opts
         ) do
      {:ok, conn} ->
        try do
          if peer_owner.(Mint.HTTP.get_socket(conn), transport) == :owned do
            send_request(conn, method, url, headers, body, timeout)
          else
            {:error, :private_origin_not_owned}
          end
        after
          Mint.HTTP.close(conn)
        end

      {:error, _} ->
        {:error, :http_request_failed}
    end
  rescue
    _ -> {:error, :http_request_failed}
  end

  defp send_request(conn, method, url, headers, body, timeout) do
    uri = URI.parse(url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    path = if uri.query, do: path <> "?" <> uri.query, else: path
    headers = Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

    # The body's type is authoritative, as with :httpc. A second content-type
    # header joins into "application/json, application/json", which strict
    # servers (Lemon Bot among them) reject as unsupported media.
    {headers, data} =
      case body do
        nil ->
          {headers, nil}

        {type, data} ->
          headers =
            Enum.reject(headers, fn {key, _} -> String.downcase(key) == "content-type" end)

          {[{"content-type", to_string(type)} | headers], data}
      end

    deadline = System.monotonic_time(:millisecond) + timeout

    case Mint.HTTP.request(conn, method |> to_string() |> String.upcase(), path, headers, data) do
      {:ok, conn, ref} -> receive_response(conn, ref, deadline, {nil, [], []})
      {:error, _, _} -> {:error, :http_request_failed}
    end
  end

  defp receive_response(conn, ref, deadline, response) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, events} ->
        case collect(events, ref, response) do
          {:done, {status, headers, chunks}} ->
            {:ok,
             {{~c"HTTP/1.1", status, ~c""}, headers,
              chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

          {:more, response} ->
            receive_response(conn, ref, deadline, response)
        end

      {:error, _, _, _} ->
        {:error, :http_request_failed}
    end
  end

  defp collect([], _ref, response), do: {:more, response}

  defp collect([{:status, ref, status} | rest], ref, {_, headers, chunks}),
    do: collect(rest, ref, {status, headers, chunks})

  defp collect([{:headers, ref, new_headers} | rest], ref, {status, headers, chunks}),
    do: collect(rest, ref, {status, headers ++ new_headers, chunks})

  defp collect([{:data, ref, data} | rest], ref, {status, headers, chunks}),
    do: collect(rest, ref, {status, headers, [data | chunks]})

  defp collect([{:done, ref} | _], ref, response), do: {:done, response}
end
