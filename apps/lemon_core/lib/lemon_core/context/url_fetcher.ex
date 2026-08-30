defmodule LemonCore.Context.URLFetcher do
  @moduledoc """
  Bounded public-HTTP fetches for context references.

  Every hop is parsed and DNS-resolved before use. Requests connect to a
  validated IP while retaining the original Host header and TLS SNI name, so a
  later DNS rebind cannot redirect the socket to a private address. Redirects
  are followed manually and re-enter the same checks.
  """

  import Bitwise

  @default_max_bytes 8_000_000
  @default_timeout_ms 10_000
  @default_redirects 3
  @max_header_bytes 65_536
  @blocked_names MapSet.new(["localhost", "localhost.localdomain", "metadata.google.internal"])

  @spec fetch(String.t(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def fetch(url, opts \\ []) when is_binary(url) do
    initial = normalize_url(String.trim(url))
    do_fetch(initial, opts, 0, MapSet.new([initial]))
  end

  defp do_fetch(url, opts, redirect_count, visited) do
    max_redirects = positive(opts[:max_redirects], @default_redirects)

    with {:ok, uri} <- parse_uri(url),
         :ok <- reject_credentials(uri),
         {:ok, addresses} <- resolve_public(uri.host, opts),
         {:ok, response} <- request(uri, hd(addresses), opts) do
      case response do
        %{status: status, headers: headers} when status in [301, 302, 303, 307, 308] ->
          with :ok <- redirect_allowed(redirect_count, max_redirects),
               {:ok, location} <- header(headers, "location"),
               {:ok, next} <- redirect_url(uri, location),
               :ok <- reject_loop(next, visited) do
            do_fetch(next, opts, redirect_count + 1, MapSet.put(visited, next))
          end

        %{status: status, body: body, headers: headers} when status in 200..299 ->
          {:ok, body,
           %{
             final_url: redacted_url(uri),
             status: status,
             content_type: header_value(headers, "content-type"),
             redirects: redirect_count
           }}

        %{status: status} ->
          {:error, {:http_status, status}}
      end
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :invalid_url}
    end
  end

  defp reject_credentials(%URI{userinfo: nil}), do: :ok
  defp reject_credentials(%URI{userinfo: ""}), do: :ok
  defp reject_credentials(_), do: {:error, :url_credentials_forbidden}

  defp resolve_public(host, opts) do
    normalized = host |> String.trim_trailing(".") |> String.downcase()

    cond do
      MapSet.member?(@blocked_names, normalized) ->
        {:error, :ssrf_blocked}

      String.ends_with?(normalized, ".localhost") or String.ends_with?(normalized, ".local") ->
        {:error, :ssrf_blocked}

      true ->
        resolver = Keyword.get(opts, :resolve_fun, &default_resolve/1)

        case resolver.(normalized) do
          {:ok, addresses} when is_list(addresses) and addresses != [] ->
            if Enum.all?(addresses, &public_ip?/1),
              do: {:ok, addresses},
              else: {:error, :ssrf_blocked}

          _ ->
            {:error, :dns_failed}
        end
    end
  end

  defp default_resolve(host) do
    hostname = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(hostname, :inet) do
        {:ok, ips} -> ips
        _ -> []
      end

    v6 =
      case :inet.getaddrs(hostname, :inet6) do
        {:ok, ips} -> ips
        _ -> []
      end

    if v4 ++ v6 == [], do: {:error, :nxdomain}, else: {:ok, v4 ++ v6}
  end

  defp request(uri, address, opts) do
    max_bytes = positive(opts[:max_input_bytes], @default_max_bytes)
    timeout = positive(opts[:timeout_ms], @default_timeout_ms)
    host_header = host_header(uri)
    pinned_url = pinned_url(uri, address)

    request_fun =
      Keyword.get(opts, :request_fun) ||
        fn url, headers, http_options, limit ->
          socket_request(
            url,
            headers,
            http_options,
            limit,
            Keyword.get(opts, :connect_fun, &connect_socket/5)
          )
        end

    case request_fun.(
           pinned_url,
           [{~c"host", String.to_charlist(host_header)}],
           http_options(uri, timeout),
           max_bytes
         ) do
      {:ok, {{_version, status, _reason}, headers, body}} ->
        body = IO.iodata_to_binary(body)

        if byte_size(body) <= max_bytes do
          {:ok, %{status: status, headers: normalize_headers(headers), body: body}}
        else
          {:error, {:input_too_large, byte_size(body), max_bytes}}
        end

      {:error, reason} ->
        {:error, normalize_http_error(reason)}

      _ ->
        {:error, :network_error}
    end
  end

  # OTP's async `:httpc` streaming messages omit the response status once a
  # body is streamed. Use a small HTTP/1.1 socket reader instead so status and
  # redirect semantics remain authoritative while the body is capped before
  # it is accumulated.
  defp socket_request(url, headers, http_options, max_bytes, connect_fun) do
    timeout = Keyword.get(http_options, :timeout, @default_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, uri} <- parse_uri(url),
         {:ok, address} <- parse_pinned_address(uri.host),
         {:ok, request} <- encode_request(uri, headers),
         {:ok, socket} <-
           connect_fun.(
             uri.scheme,
             address,
             uri.port || default_port(uri.scheme),
             Keyword.get(http_options, :ssl, []),
             timeout
           ) do
      try do
        with :ok <- socket_send(socket, request),
             {:ok, head, remainder} <- read_head(socket, deadline, ""),
             {:ok, version, status, reason, response_headers} <- parse_head(head),
             {:ok, body} <-
               read_response_body(
                 socket,
                 status,
                 response_headers,
                 remainder,
                 max_bytes,
                 deadline
               ) do
          {:ok,
           {{String.to_charlist(version), status, String.to_charlist(reason)}, response_headers,
            body}}
        end
      after
        socket_close(socket)
      end
    end
  end

  defp connect_socket("http", address, port, _ssl_options, timeout) do
    case :gen_tcp.connect(address, port, [:binary, active: false, packet: :raw], timeout) do
      {:ok, socket} -> {:ok, {:tcp, socket}}
      error -> error
    end
  end

  defp connect_socket("https", address, port, ssl_options, timeout) do
    with {:ok, _} <- Application.ensure_all_started(:ssl) do
      options = [:binary, active: false, packet: :raw] ++ ssl_options

      case :ssl.connect(address, port, options, timeout) do
        {:ok, socket} -> {:ok, {:ssl, socket}}
        error -> error
      end
    end
  end

  defp connect_socket(_, _, _, _, _), do: {:error, :invalid_url}

  defp parse_pinned_address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      _ -> {:error, :invalid_pinned_address}
    end
  end

  defp encode_request(uri, headers) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    target = if uri.query, do: "#{path}?#{uri.query}", else: path

    if safe_request_target?(target) and
         Enum.all?(headers, fn {name, value} ->
           safe_header_name?(to_string(name)) and safe_header_value?(to_string(value))
         end) do
      header_lines = Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

      {:ok,
       IO.iodata_to_binary([
         "GET ",
         target,
         " HTTP/1.1\r\n",
         header_lines,
         "user-agent: Lemon-Context/1\r\n",
         "accept: */*\r\n",
         "accept-encoding: identity\r\n",
         "connection: close\r\n\r\n"
       ])}
    else
      {:error, :invalid_request_header}
    end
  end

  defp safe_request_target?(<<"/", _::binary>> = value),
    do: Enum.all?(:binary.bin_to_list(value), &(&1 > 32 and &1 != 127))

  defp safe_request_target?(_), do: false

  defp safe_header_name?(value) do
    value != "" and
      Enum.all?(:binary.bin_to_list(value), fn byte ->
        byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or
          byte in ~c"!#$%&'*+-.^_`|~"
      end)
  end

  defp safe_header_value?(value),
    do: Enum.all?(:binary.bin_to_list(value), &(&1 >= 32 and &1 != 127))

  defp read_head(socket, deadline, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} when index <= @max_header_bytes ->
        head = binary_part(buffer, 0, index)
        remainder_size = byte_size(buffer) - index - 4
        remainder = binary_part(buffer, index + 4, remainder_size)
        {:ok, head, remainder}

      {_index, 4} ->
        {:error, :headers_too_large}

      :nomatch when byte_size(buffer) > @max_header_bytes ->
        {:error, :headers_too_large}

      :nomatch ->
        with {:ok, chunk} <- socket_recv(socket, 0, deadline) do
          read_head(socket, deadline, buffer <> chunk)
        end
    end
  end

  defp parse_head(head) do
    case String.split(head, "\r\n") do
      [status_line | header_lines] ->
        with [version, status_text, reason] <- String.split(status_line, " ", parts: 3),
             true <- version in ["HTTP/1.0", "HTTP/1.1"],
             {status, ""} when status in 100..599 <- Integer.parse(status_text),
             {:ok, headers} <- parse_header_lines(header_lines) do
          {:ok, version, status, reason, headers}
        else
          _ -> {:error, :invalid_http_response}
        end

      _ ->
        {:error, :invalid_http_response}
    end
  end

  defp parse_header_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, headers} ->
      case String.split(line, ":", parts: 2) do
        [name, value] when name != "" ->
          {:cont, {:ok, [{String.downcase(name), String.trim(value)} | headers]}}

        _ ->
          {:halt, {:error, :invalid_http_response}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  # Redirect/error bodies are never selected, so close immediately after the
  # authoritative status and headers. This keeps even adversarial error bodies
  # out of memory while preserving the Location header needed by the caller.
  defp read_response_body(_socket, status, _headers, _remainder, _max_bytes, _deadline)
       when status < 200 or status in [204, 304] or status >= 300,
       do: {:ok, ""}

  defp read_response_body(socket, _status, headers, remainder, max_bytes, deadline) do
    transfer_encoding = header_value(headers, "transfer-encoding")

    cond do
      is_binary(transfer_encoding) and
          String.contains?(String.downcase(transfer_encoding), "chunked") ->
        read_chunked(socket, remainder, [], 0, max_bytes, deadline)

      is_binary(transfer_encoding) ->
        {:error, :unsupported_transfer_encoding}

      true ->
        case content_length(headers) do
          {:ok, length} when length <= max_bytes ->
            read_fixed(socket, remainder, length, deadline)

          {:ok, length} ->
            {:error, {:body_too_big, length}}

          :missing ->
            read_until_close(socket, [remainder], byte_size(remainder), max_bytes, deadline)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp content_length(headers) do
    values =
      for {name, value} <- headers,
          String.downcase(to_string(name)) == "content-length",
          do: to_string(value)

    case Enum.uniq(values) do
      [] ->
        :missing

      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> {:ok, length}
          _ -> {:error, :invalid_content_length}
        end

      _ ->
        {:error, :conflicting_content_length}
    end
  end

  defp read_fixed(_socket, buffer, length, _deadline) when byte_size(buffer) >= length,
    do: {:ok, binary_part(buffer, 0, length)}

  defp read_fixed(socket, buffer, length, deadline) do
    needed = length - byte_size(buffer)

    with {:ok, chunk} <- socket_recv(socket, needed, deadline) do
      read_fixed(socket, buffer <> chunk, length, deadline)
    end
  end

  defp read_until_close(_socket, _chunks, size, max_bytes, _deadline) when size > max_bytes,
    do: {:error, :body_too_big}

  defp read_until_close(socket, chunks, size, max_bytes, deadline) do
    case socket_recv(socket, 0, deadline) do
      {:ok, chunk} ->
        read_until_close(socket, [chunk | chunks], size + byte_size(chunk), max_bytes, deadline)

      {:error, :closed} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      error ->
        error
    end
  end

  defp read_chunked(socket, buffer, chunks, size, max_bytes, deadline) do
    with {:ok, line, remainder} <- read_line(socket, buffer, deadline),
         {:ok, chunk_size} <- parse_chunk_size(line),
         :ok <- chunk_size_allowed(size, chunk_size, max_bytes) do
      if chunk_size == 0 do
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      else
        with {:ok, chunk_and_crlf, rest} <-
               take_bytes(socket, remainder, chunk_size + 2, deadline),
             true <- String.ends_with?(chunk_and_crlf, "\r\n") do
          chunk = binary_part(chunk_and_crlf, 0, chunk_size)
          read_chunked(socket, rest, [chunk | chunks], size + chunk_size, max_bytes, deadline)
        else
          false -> {:error, :invalid_chunked_body}
          error -> error
        end
      end
    end
  end

  defp read_line(socket, buffer, deadline) do
    case :binary.match(buffer, "\r\n") do
      {index, 2} when index <= @max_header_bytes ->
        line = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 2, byte_size(buffer) - index - 2)
        {:ok, line, rest}

      {_index, 2} ->
        {:error, :invalid_chunked_body}

      :nomatch when byte_size(buffer) > @max_header_bytes ->
        {:error, :invalid_chunked_body}

      :nomatch ->
        with {:ok, chunk} <- socket_recv(socket, 0, deadline) do
          read_line(socket, buffer <> chunk, deadline)
        end
    end
  end

  defp parse_chunk_size(line) do
    size_text = line |> String.split(";", parts: 2) |> hd() |> String.trim()

    case Integer.parse(size_text, 16) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, :invalid_chunked_body}
    end
  end

  defp chunk_size_allowed(size, chunk_size, max_bytes) do
    if size + chunk_size <= max_bytes,
      do: :ok,
      else: {:error, {:body_too_big, size + chunk_size}}
  end

  defp take_bytes(_socket, buffer, count, _deadline) when byte_size(buffer) >= count do
    value = binary_part(buffer, 0, count)
    rest = binary_part(buffer, count, byte_size(buffer) - count)
    {:ok, value, rest}
  end

  defp take_bytes(socket, buffer, count, deadline) do
    with {:ok, chunk} <- socket_recv(socket, 0, deadline) do
      take_bytes(socket, buffer <> chunk, count, deadline)
    end
  end

  defp socket_send({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  defp socket_send({:ssl, socket}, data), do: :ssl.send(socket, data)

  defp socket_recv(socket, length, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      {:error, :timeout}
    else
      case socket do
        {:tcp, raw} -> :gen_tcp.recv(raw, length, timeout)
        {:ssl, raw} -> :ssl.recv(raw, length, timeout)
      end
    end
  end

  defp socket_close({:tcp, socket}), do: :gen_tcp.close(socket)
  defp socket_close({:ssl, socket}), do: :ssl.close(socket)

  defp http_options(uri, timeout) do
    base = [timeout: timeout, connect_timeout: timeout, autoredirect: false]

    if uri.scheme == "https" do
      ssl = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(uri.host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      Keyword.put(base, :ssl, ssl)
    else
      base
    end
  end

  defp pinned_url(uri, address) do
    host = address |> :inet.ntoa() |> List.to_string()
    host = if tuple_size(address) == 8, do: "[#{host}]", else: host
    port = uri.port || default_port(uri.scheme)
    port_suffix = if port == default_port(uri.scheme), do: "", else: ":#{port}"
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    query = if uri.query, do: "?#{uri.query}", else: ""
    "#{uri.scheme}://#{host}#{port_suffix}#{path}#{query}"
  end

  defp host_header(uri) do
    port = uri.port || default_port(uri.scheme)
    if port == default_port(uri.scheme), do: uri.host, else: "#{uri.host}:#{port}"
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end

  defp header(headers, name) do
    case header_value(headers, name) do
      nil -> {:error, :redirect_without_location}
      value -> {:ok, value}
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp redirect_url(uri, location) do
    try do
      value = uri |> URI.merge(location) |> URI.to_string() |> normalize_url()
      if value == "", do: {:error, :invalid_redirect}, else: {:ok, value}
    rescue
      _ -> {:error, :invalid_redirect}
    end
  end

  defp redirect_allowed(count, max) when count < max, do: :ok
  defp redirect_allowed(_, _), do: {:error, :redirect_limit}

  defp reject_loop(url, visited),
    do: if(MapSet.member?(visited, url), do: {:error, :redirect_loop}, else: :ok)

  defp redacted_url(%URI{} = uri),
    do: %URI{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string()

  defp normalize_url(url) do
    case URI.parse(url) do
      %URI{} = uri ->
        %URI{
          uri
          | scheme: if(uri.scheme, do: String.downcase(uri.scheme)),
            host: if(uri.host, do: String.downcase(uri.host)),
            fragment: nil
        }
        |> URI.to_string()

      _ ->
        url
    end
  end

  defp public_ip?({a, b, _c, _d}) do
    cond do
      a == 0 -> false
      a == 10 -> false
      a == 127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 100 and b in 64..127 -> false
      a >= 224 -> false
      true -> true
    end
  end

  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    public_ip?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip?({a, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      a == 0 -> false
      (a &&& 0xFE00) == 0xFC00 -> false
      (a &&& 0xFFC0) == 0xFE80 -> false
      (a &&& 0xFF00) == 0xFF00 -> false
      true -> true
    end
  end

  defp public_ip?(_), do: false

  defp normalize_http_error({:body_too_big, _}), do: :input_too_large
  defp normalize_http_error(:body_too_big), do: :input_too_large
  defp normalize_http_error(:invalid_request_header), do: :invalid_url
  defp normalize_http_error(_), do: :network_error

  defp positive(value, _default) when is_integer(value) and value >= 0, do: value
  defp positive(_, default), do: default
end
