defmodule LemonCore.Net.HTTP do
  @moduledoc """
  The one pinned outbound HTTP fetcher for guarded destinations.

  Every hop is authorized by `LemonCore.Net.Address` and the request is sent
  over a single, unpooled Mint HTTP/1.1 connection to the validated IP, while
  the Host header and TLS SNI/certificate identity stay those of the URL. DNS is
  never consulted again by the transport, so a rebind cannot move the socket.

  Redirects are never followed implicitly. With `max_redirects: 0` (the
  default) a 3xx response is returned to the caller unchanged. With a positive
  limit, `301`, `302`, `303`, `307` and `308` are followed manually and the
  next URL goes through the same parsing and address checks; credentials are
  dropped when the origin changes and `303` (and `301`/`302` after a non-GET)
  becomes a bodiless `GET`.

  No atoms, pools or processes are created per destination.

  Each hop has one deadline (`timeout_ms`) covering DNS resolution, connect,
  every socket send and the response; when it expires the connection is closed
  and `{:error, :timeout}` returned. At most #{8} informational (1xx) responses
  are accepted and all response header sections together are capped at
  64 KiB; only the final response's headers are returned.

  ## Options

    * `:headers` — request headers (`{name, value}`); `host` is always derived.
    * `:body` — request body (iodata) or `nil`.
    * `:timeout_ms` — deadline per hop covering DNS, connect, send and receive
      (default 30 000).
    * `:max_body_bytes` — response body cap (default 5 MiB); larger bodies
      return `{:error, {:body_too_large, max}}`.
    * `:max_redirects` — manual redirect limit (default 0).
    * `:allow_private` — permit private (never metadata) destinations.
    * `:allow_private_hosts` — canonical host names or IP literals permitted to
      be private, for explicitly configured local services.
    * `:resolver` — see `LemonCore.Net.Address.resolve/2`.
    * `:address` — a destination the caller already authorized (for example an
      `LemonMCP.HTTP.OriginPolicy` pin). The URL's host is not resolved and
      redirects are not followed.
    * `:peer_check` — `(socket, :tcp | :ssl -> :owned | term())`, run on the
      connected socket before any byte is sent; anything but `:owned` aborts
      with `{:error, :private_origin_not_owned}`.
    * `:ssl` — extra `:ssl` options (for example `cacerts:` in tests). Peer
      verification and hostname checking cannot be disabled.
    * `:send` — internal transport override receiving the pinned request map;
      used by tests to observe pinning without a network.
  """

  alias LemonCore.Net.Address

  @redirect_statuses [301, 302, 303, 307, 308]
  @default_timeout_ms 30_000
  @default_max_body_bytes 5 * 1024 * 1024
  @max_url_bytes 8_192
  @credential_headers ["authorization", "cookie", "proxy-authorization"]
  @max_informational_responses 8
  @max_header_bytes 65_536

  @type response :: %{
          status: 100..599,
          headers: [{String.t(), String.t()}],
          body: binary(),
          url: String.t(),
          redirects: non_neg_integer()
        }

  @type error ::
          :invalid_url
          | :invalid_host
          | :dns_resolution_failed
          | :too_many_dns_addresses
          | :destination_not_public
          | :metadata_blocked
          | :too_many_redirects
          | :redirect_loop
          | :invalid_redirect
          | :private_origin_not_owned
          | :timeout
          | :http_request_failed
          | :too_many_informational_responses
          | {:headers_too_large, pos_integer()}
          | {:body_too_large, pos_integer()}

  @spec request(atom() | String.t(), String.t(), keyword()) ::
          {:ok, response()} | {:error, error()}
  def request(method, url, opts \\ []) when is_list(opts) do
    method = method |> to_string() |> String.upcase()

    max_redirects =
      if Keyword.has_key?(opts, :address),
        do: 0,
        else: non_negative(Keyword.get(opts, :max_redirects), 0)

    with {:ok, uri} <- parse_url(url) do
      opts = Keyword.put(opts, :max_redirects, max_redirects)
      visited = MapSet.new([URI.to_string(uri)])
      do_request(method, uri, opts, Keyword.get(opts, :body), max_redirects, visited)
    end
  end

  @doc "Parses an absolute http(s) URL without credentials or fragments in the authority."
  @spec parse_url(term()) :: {:ok, URI.t()} | {:error, :invalid_url}
  def parse_url(url)
      when is_binary(url) and byte_size(url) > 0 and byte_size(url) <= @max_url_bytes do
    with false <- Regex.match?(~r/[\x00-\x20\x7f\\]/, url),
         %URI{scheme: scheme, host: host, port: port, userinfo: nil} = uri <- URI.parse(url),
         scheme when scheme in ["http", "https"] <- scheme && String.downcase(scheme),
         true <- is_binary(host) and host != "",
         true <- is_integer(port) and port in 1..65_535 do
      {:ok, %URI{uri | scheme: scheme, host: String.downcase(host), fragment: nil}}
    else
      _ -> {:error, :invalid_url}
    end
  rescue
    _ -> {:error, :invalid_url}
  end

  def parse_url(_url), do: {:error, :invalid_url}

  defp do_request(method, uri, opts, body, redirects_left, visited) do
    deadline = deadline(opts)

    with {:ok, address} <- destination(uri, opts, deadline),
         {:ok, response} <- send_pinned(method, uri, address, body, opts, deadline) do
      response =
        Map.merge(response, %{
          url: URI.to_string(uri),
          redirects: opts[:max_redirects] - redirects_left
        })

      if response.status in @redirect_statuses and opts[:max_redirects] > 0 do
        follow(method, uri, response, opts, body, redirects_left, visited)
      else
        {:ok, response}
      end
    end
  end

  defp follow(_method, _uri, _response, _opts, _body, 0, _visited),
    do: {:error, :too_many_redirects}

  defp follow(method, uri, response, opts, body, redirects_left, visited) do
    with {:ok, location} <- location(response.headers),
         {:ok, next} <- merge_location(uri, location),
         next_url = URI.to_string(next),
         :ok <- if(MapSet.member?(visited, next_url), do: {:error, :redirect_loop}, else: :ok) do
      {method, body} =
        if response.status == 303 or (response.status in [301, 302] and method != "GET"),
          do: {"GET", nil},
          else: {method, body}

      opts =
        if origin(next) == origin(uri),
          do: opts,
          else: Keyword.update(opts, :headers, [], &drop_credentials/1)

      do_request(method, next, opts, body, redirects_left - 1, MapSet.put(visited, next_url))
    end
  end

  defp location(headers) do
    case for({"location", value} <- headers, do: value) do
      [value] -> {:ok, value}
      _ -> {:error, :invalid_redirect}
    end
  end

  defp merge_location(uri, location) do
    with {:ok, target} <- URI.new(location),
         {:ok, next} <- uri |> URI.merge(target) |> URI.to_string() |> parse_url() do
      {:ok, next}
    else
      _ -> {:error, :invalid_redirect}
    end
  rescue
    _ -> {:error, :invalid_redirect}
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}),
    do: {scheme, String.downcase(host), port}

  defp drop_credentials(headers),
    do:
      Enum.reject(headers, fn {k, _} -> String.downcase(to_string(k)) in @credential_headers end)

  defp destination(uri, opts, deadline) do
    case Keyword.fetch(opts, :address) do
      {:ok, address} ->
        {:ok, address}

      :error ->
        allow? =
          Keyword.get(opts, :allow_private, false) == true or
            private_host_allowed?(uri.host, Keyword.get(opts, :allow_private_hosts, []))

        authorize_opts =
          Keyword.merge(opts, allow_private: allow?, timeout_ms: remaining(deadline))

        case Address.authorize(uri.host, authorize_opts) do
          {:ok, [address | _]} -> {:ok, address}
          {:error, :dns_timeout} -> {:error, :timeout}
          {:error, _} = error -> error
        end
    end
  end

  defp deadline(opts),
    do:
      System.monotonic_time(:millisecond) +
        positive(Keyword.get(opts, :timeout_ms), @default_timeout_ms)

  # Never zero: a zero timeout means "poll" for some socket calls.
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 1)

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp private_host_allowed?(host, allowed) when is_list(allowed) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    Enum.any?(
      allowed,
      &(is_binary(&1) and String.downcase(String.trim_trailing(&1, ".")) == host)
    )
  end

  defp private_host_allowed?(_host, _allowed), do: false

  defp send_pinned(method, uri, address, body, opts, deadline) do
    request = pinned_request(method, uri, address, body, opts, deadline)

    case Keyword.get(opts, :send, &mint_send/1).(request) do
      {:ok, %{status: status, headers: headers, body: body}}
      when is_integer(status) and is_binary(body) ->
        if byte_size(body) > request.max_body_bytes,
          do: {:error, {:body_too_large, request.max_body_bytes}},
          else: {:ok, %{status: status, headers: normalize_headers(headers), body: body}}

      {:error, reason}
      when reason in [:timeout, :private_origin_not_owned, :too_many_informational_responses] ->
        {:error, reason}

      {:error, {:body_too_large, _}} = error ->
        error

      {:error, {:headers_too_large, _}} = error ->
        error

      _ ->
        {:error, :http_request_failed}
    end
  end

  defp pinned_request(method, uri, address, body, opts, deadline) do
    %{
      method: method,
      scheme: uri.scheme,
      address: address,
      port: uri.port,
      host: uri.host,
      path: request_target(uri),
      headers: request_headers(Keyword.get(opts, :headers, [])),
      body: body,
      deadline: deadline,
      timeout_ms: remaining(deadline),
      max_body_bytes: positive(Keyword.get(opts, :max_body_bytes), @default_max_body_bytes),
      ssl: Keyword.get(opts, :ssl, []),
      peer_check: Keyword.get(opts, :peer_check)
    }
  end

  defp request_target(uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    if uri.query, do: path <> "?" <> uri.query, else: path
  end

  defp request_headers(headers) do
    headers
    |> Enum.map(fn {key, value} ->
      {key |> to_string() |> String.downcase(), to_string(value)}
    end)
    |> Enum.reject(fn {key, _} -> key in ["host", "connection"] end)
    |> Kernel.++([{"connection", "close"}])
  end

  defp normalize_headers(headers),
    do: Enum.map(headers, fn {k, v} -> {k |> to_string() |> String.downcase(), to_string(v)} end)

  # A single passive HTTP/1.1 connection per request: never pooled, never
  # reused, closed before returning. Connect, send and receive all share the
  # hop's deadline. The exchange runs in a worker that owns the socket: a send
  # into a full buffer suspends its caller on the busy port, which no socket
  # timeout interrupts, so on expiry the worker is killed, closing the socket.
  defp mint_send(request) do
    within_deadline(request.deadline, fn ->
      with {:ok, conn, ref} <- open_pinned(request) do
        try do
          receive_response(conn, ref, request.deadline, request.max_body_bytes, new_acc())
        after
          Mint.HTTP.close(conn)
        end
      end
    end)
  end

  # Runs `fun` in a worker that owns any socket it opens, killing it (and so
  # closing the socket) if the deadline passes first. A stream result is handed
  # over in two steps so the socket is never orphaned: the worker reports the
  # result while still owning the connection; only after the caller (which has
  # not timed out) acknowledges does the worker transfer ownership and confirm.
  # If the deadline fires first, the worker is killed while it still owns the
  # socket, which closes it.
  defp within_deadline(deadline, fun) do
    caller = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        caller_monitor = Process.monitor(caller)

        result =
          try do
            fun.()
          rescue
            _ -> {:error, :http_request_failed}
          end

        send(caller, {tag, result})

        # Until the caller takes the connection over, this worker owns it and
        # must close it if the caller dies or does not acknowledge in time.
        with {:ok, %{conn: conn}} <- result do
          receive do
            {^tag, :ack} ->
              case Mint.HTTP.controlling_process(conn, caller) do
                {:ok, _conn} -> send(caller, {tag, :transferred})
                _ -> Mint.HTTP.close(conn)
              end

            {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
              Mint.HTTP.close(conn)
          after
            remaining(deadline) -> Mint.HTTP.close(conn)
          end
        end
      end)

    receive do
      {^tag, {:ok, %{conn: _}} = result} ->
        send(pid, {tag, :ack})

        receive do
          {^tag, :transferred} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, :process, ^pid, _reason} ->
            {:error, :http_request_failed}
        end

      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :http_request_failed}
    after
      remaining(deadline) ->
        # The worker still owns any socket it opened; killing it closes it.
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^tag, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  # Connects to the pinned address, runs the peer check, bounds socket sends by
  # the remaining deadline and sends the request. The connection is closed on
  # every failure path.
  defp open_pinned(request) do
    scheme = if request.scheme == "https", do: :https, else: :http
    transport = if scheme == :https, do: :ssl, else: :tcp
    timeout = remaining(request.deadline)

    transport_opts =
      [
        timeout: timeout,
        send_timeout: timeout,
        send_timeout_close: true,
        inet6: tuple_size(request.address) == 8
      ] ++ if(scheme == :https, do: tls_options(request.ssl), else: [])

    case Mint.HTTP.connect(scheme, request.address, request.port,
           hostname: request.host,
           protocols: [:http1],
           mode: :passive,
           transport_opts: transport_opts
         ) do
      {:ok, conn} ->
        case start_request(conn, transport, request) do
          {:ok, conn, ref} ->
            {:ok, conn, ref}

          error ->
            Mint.HTTP.close(conn)
            error
        end

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :http_request_failed}
    end
  rescue
    _ -> {:error, :http_request_failed}
  end

  defp start_request(conn, transport, request) do
    socket = Mint.HTTP.get_socket(conn)

    cond do
      expired?(request.deadline) ->
        {:error, :timeout}

      not peer_owned?(request.peer_check, socket, transport) ->
        {:error, :private_origin_not_owned}

      set_send_timeout(socket, transport, remaining(request.deadline)) != :ok ->
        {:error, :http_request_failed}

      true ->
        case Mint.HTTP.request(
               conn,
               request.method,
               request.path,
               request.headers,
               request.body
             ) do
          {:ok, conn, ref} ->
            if expired?(request.deadline), do: {:error, :timeout}, else: {:ok, conn, ref}

          {:error, _conn, %{reason: :timeout}} ->
            {:error, :timeout}

          {:error, _conn, _reason} ->
            {:error, :http_request_failed}
        end
    end
  end

  defp set_send_timeout(socket, :tcp, timeout),
    do: :inet.setopts(socket, send_timeout: timeout, send_timeout_close: true)

  defp set_send_timeout(socket, :ssl, timeout),
    do: :ssl.setopts(socket, send_timeout: timeout, send_timeout_close: true)

  defp tls_options(extra) do
    extra = Keyword.drop(extra, [:verify, :verify_fun])

    defaults =
      if Keyword.has_key?(extra, :cacerts) or Keyword.has_key?(extra, :cacertfile),
        do: [],
        else: [cacerts: :public_key.cacerts_get()]

    defaults |> Keyword.merge(extra) |> Keyword.put(:verify, :verify_peer)
  end

  defp peer_owned?(nil, _socket, _transport), do: true

  defp peer_owned?(check, socket, transport) when is_function(check, 2),
    do: check.(socket, transport) == :owned

  defp receive_response(conn, ref, deadline, limit, acc) do
    if expired?(deadline) do
      {:error, :timeout}
    else
      case Mint.HTTP.recv(conn, 0, remaining(deadline)) do
        {:ok, conn, events} ->
          case collect(events, ref, limit, acc) do
            {:done, acc} ->
              {:ok,
               %{
                 status: acc.status,
                 headers: acc.headers,
                 body: acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
               }}

            {:more, acc} ->
              receive_response(conn, ref, deadline, limit, acc)

            {:error, _} = error ->
              error
          end

        {:error, _conn, %{reason: :timeout}, _} ->
          {:error, :timeout}

        {:error, _conn, _reason, _} ->
          {:error, :http_request_failed}
      end
    end
  end

  # Response state. Informational (1xx) responses are counted and their header
  # bytes charged against the cumulative header budget, but never stored: only
  # the final response's status and headers are kept.
  defp new_acc,
    do: %{
      status: nil,
      final?: false,
      head_done?: false,
      informational: 0,
      header_bytes: 0,
      headers: [],
      chunks: [],
      size: 0
    }

  defp collect([], _ref, _limit, acc), do: {:more, acc}

  defp collect([{:status, ref, status} | rest], ref, limit, acc) when status in 100..199 do
    informational = acc.informational + 1

    if informational > @max_informational_responses,
      do: {:error, :too_many_informational_responses},
      else: collect(rest, ref, limit, %{acc | informational: informational})
  end

  defp collect([{:status, ref, status} | rest], ref, limit, acc),
    do: collect(rest, ref, limit, %{acc | status: status, final?: true})

  defp collect([{:headers, ref, new} | rest], ref, limit, acc) do
    header_bytes =
      Enum.reduce(new, acc.header_bytes, fn {k, v}, total ->
        total + byte_size(k) + byte_size(v) + 4
      end)

    cond do
      header_bytes > @max_header_bytes ->
        {:error, {:headers_too_large, @max_header_bytes}}

      acc.final? ->
        collect(rest, ref, limit, %{
          acc
          | header_bytes: header_bytes,
            headers: acc.headers ++ new,
            head_done?: true
        })

      true ->
        collect(rest, ref, limit, %{acc | header_bytes: header_bytes})
    end
  end

  defp collect([{:data, ref, data} | rest], ref, limit, acc) do
    size = acc.size + byte_size(data)

    if size > limit,
      do: {:error, {:body_too_large, limit}},
      else: collect(rest, ref, limit, %{acc | size: size, chunks: [data | acc.chunks]})
  end

  defp collect([{:done, ref} | _], ref, _limit, %{final?: true} = acc), do: {:done, acc}
  defp collect([{:done, ref} | _], ref, _limit, _acc), do: {:error, :http_request_failed}

  defp collect([{:error, ref, _reason} | _], ref, _limit, _acc),
    do: {:error, :http_request_failed}

  defp collect([_ | rest], ref, limit, acc), do: collect(rest, ref, limit, acc)

  @type stream :: %{
          conn: term(),
          ref: reference(),
          status: 100..599,
          headers: [{String.t(), String.t()}],
          url: String.t(),
          pending: [binary()],
          done: boolean()
        }

  @doc """
  Opens a guarded streaming response (for example Server-Sent Events).

  The destination is authorized and pinned exactly as for `request/3`
  (redirects are never followed; a 3xx is returned as the stream's status), and
  `timeout_ms` bounds DNS, connect, send and the wait for the final status and
  headers. Body data is then pulled with `stream_next/2` in the calling
  process, which owns the connection and must `close_stream/1` it. Accepts the
  `request/3` options except `:max_redirects`, `:send` and `:max_body_bytes`.
  """
  @spec open_stream(atom() | String.t(), String.t(), keyword()) ::
          {:ok, stream()} | {:error, error()}
  def open_stream(method, url, opts \\ []) when is_list(opts) do
    method = method |> to_string() |> String.upcase()
    deadline = deadline(opts)

    with {:ok, uri} <- parse_url(url),
         {:ok, address} <- destination(uri, opts, deadline) do
      request = pinned_request(method, uri, address, Keyword.get(opts, :body), opts, deadline)

      # `:before_handoff` is an internal test hook run in the worker just
      # before it reports a ready stream (used to force the timeout race).
      before_handoff = Keyword.get(opts, :before_handoff, fn -> :ok end)

      within_deadline(deadline, fn ->
        with {:ok, conn, ref} <- open_pinned(request) do
          case await_head(conn, ref, deadline, new_acc()) do
            {:ok, conn, acc, chunks, done} ->
              before_handoff.()

              {:ok,
               %{
                 conn: conn,
                 ref: ref,
                 status: acc.status,
                 headers: normalize_headers(acc.headers),
                 url: URI.to_string(uri),
                 pending: chunks,
                 done: done
               }}

            error ->
              Mint.HTTP.close(conn)
              error
          end
        end
      end)
    end
  end

  @doc """
  Waits up to `timeout_ms` for more body data. Returns `{:ok, stream, chunks}`,
  `{:done, stream, chunks}` once the response ends, or `{:error, reason}`
  (`:timeout` when nothing arrives in time; the stream stays usable).
  """
  @spec stream_next(stream(), pos_integer()) ::
          {:ok, stream(), [binary()]} | {:done, stream(), [binary()]} | {:error, error()}
  def stream_next(%{pending: [_ | _] = pending} = stream, _timeout_ms),
    do: {if(stream.done, do: :done, else: :ok), %{stream | pending: []}, pending}

  def stream_next(%{done: true} = stream, _timeout_ms), do: {:done, stream, []}

  def stream_next(stream, timeout_ms) do
    case Mint.HTTP.recv(stream.conn, 0, positive(timeout_ms, @default_timeout_ms)) do
      {:ok, conn, events} ->
        case stream_events(events, stream.ref, [], false) do
          {:error, reason} -> {:error, reason}
          {chunks, true} -> {:done, %{stream | conn: conn, done: true}, chunks}
          {chunks, false} -> {:ok, %{stream | conn: conn}, chunks}
        end

      {:error, _conn, %{reason: :timeout}, _} ->
        {:error, :timeout}

      {:error, _conn, _reason, _} ->
        {:error, :http_request_failed}
    end
  end

  @doc "Closes a stream's connection."
  @spec close_stream(stream()) :: :ok
  def close_stream(%{conn: conn}) do
    _ = Mint.HTTP.close(conn)
    :ok
  end

  defp stream_events([], _ref, chunks, done), do: {Enum.reverse(chunks), done}

  defp stream_events([{:data, ref, data} | rest], ref, chunks, done),
    do: stream_events(rest, ref, [data | chunks], done)

  defp stream_events([{:done, ref} | rest], ref, chunks, _done),
    do: stream_events(rest, ref, chunks, true)

  defp stream_events([{:error, ref, _} | _], ref, _chunks, _done),
    do: {:error, :http_request_failed}

  defp stream_events([_ | rest], ref, chunks, done), do: stream_events(rest, ref, chunks, done)

  # Receives until the final status and headers are in, keeping any body data
  # that arrived in the same batch.
  defp await_head(conn, ref, deadline, acc) do
    if expired?(deadline) do
      {:error, :timeout}
    else
      case Mint.HTTP.recv(conn, 0, remaining(deadline)) do
        {:ok, conn, events} ->
          {head, body} =
            Enum.split_while(events, fn
              {:data, ^ref, _} -> false
              {:done, ^ref} -> false
              _ -> true
            end)

          case collect(head, ref, :infinity, acc) do
            {:more, %{head_done?: true} = acc} when body != [] ->
              case stream_events(body, ref, [], false) do
                {:error, _} = error -> error
                {chunks, done} -> {:ok, conn, acc, chunks, done}
              end

            {:more, %{head_done?: true} = acc} ->
              {:ok, conn, acc, [], false}

            {:more, acc} ->
              await_head(conn, ref, deadline, acc)

            {:error, _} = error ->
              error
          end

        {:error, _conn, %{reason: :timeout}, _} ->
          {:error, :timeout}

        {:error, _conn, _reason, _} ->
          {:error, :http_request_failed}
      end
    end
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, default), do: default
end
