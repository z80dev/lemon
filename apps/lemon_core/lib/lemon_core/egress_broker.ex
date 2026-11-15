defmodule LemonCore.EgressBroker do
  @moduledoc """
  Run-private, default-deny CONNECT proxy for enforced terminal sandboxes.

  `start_link/1` takes a private `:directory`, exact DNS `{host, port}` pairs in
  `:allowlist`, and optional host-keyed `:bindings` containing a secret reference,
  header name and prefix. Only trusted host code may supply these options.
  `info/1` exposes only the Unix socket and public CA paths. `:owner` defaults to
  the caller; its death closes the broker and all connections. The exclusively
  owned directory may contain the caller's public adapter and is removed on
  shutdown, including forced broker death. Private keys and resolved credentials
  never go to disk. The public CA is shared for one host VM boot.

  Unbound destinations are opaque TCP tunnels. Bound destinations use verified
  upstream TLS and HTTP/1.1 interception, with exactly one request per connection.
  Only origin-form request targets and an exact matching Host are accepted.
  Bodies are buffered before forwarding: Content-Length, plain chunked encoding
  without extensions/trailers, and close-delimited responses are supported.
  Pipelining, Expect, informational responses, upgrades, compression and ambiguous
  framing fail closed. No HTTP/2 is advertised. These restrictions intentionally
  exclude unbounded streaming APIs. Client copies of the bound header are removed.

  Responses are decoded, stripped of hop-by-hop headers, and literal credential
  bytes are redacted before generating new framing. A final whole-wire check
  prevents even generated status/framing bytes from reproducing a credential;
  if that cannot be represented safely, the connection closes without a response.
  This does not detect transformed credentials or reflections across responses.

  Limits are `:header_bytes` (32 KiB, also caps chunk metadata), `:body_bytes`
  (8 MiB), `:timeout` (15 seconds for the entire connection), and
  `:max_connections` (32). `:secrets_opts` is forwarded to `Secrets.resolve/2`.
  `:upstream_tls` may customize only `:cacerts`, `:cacertfile`, and `:depth`;
  peer/hostname verification cannot be disabled. Errors/status omit private state.
  """

  use GenServer

  alias LemonCore.EgressBroker.Certificates
  alias LemonCore.Secrets

  @hop_headers ~w(connection keep-alive proxy-connection proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @reserved_headers @hop_headers ++
                      ~w(host content-length content-encoding accept-encoding expect)
  @token ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/
  @host_label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.put_new(opts, :owner, self()))
  end

  @spec info(GenServer.server()) :: %{socket_path: String.t(), ca_path: String.t()}
  def info(server), do: GenServer.call(server, :info)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    try do
      config = configuration(opts)
      prepare_directory(config.directory)
      broker = self()

      # This independent reaper also runs when terminate/2 cannot (exit :kill).
      directory = config.directory

      reaper =
        spawn(fn ->
          ref = Process.monitor(broker)

          receive do
            {:DOWN, ^ref, :process, ^broker, _reason} -> File.rm_rf(directory)
          end
        end)

      ca = Certificates.boot()
      ca_path = Path.join(config.directory, "ca.pem")
      socket_path = Path.join(config.directory, "proxy.sock")
      :ok = File.write(ca_path, ca.pem, [:exclusive])
      :ok = File.chmod(ca_path, 0o644)

      listener =
        ok!(
          :gen_tcp.listen(0, [
            :binary,
            ifaddr: {:local, String.to_charlist(socket_path)},
            active: false,
            packet: :raw,
            backlog: config.max_connections,
            buffer: 8192
          ])
        )

      :ok = File.chmod(socket_path, 0o600)
      acceptor = spawn_link(fn -> accept_loop(listener, broker) end)

      {:ok,
       %{
         config: Map.put(config, :ca, ca),
         info: %{socket_path: socket_path, ca_path: ca_path},
         listener: listener,
         acceptor: acceptor,
         reaper: reaper,
         owner: Process.monitor(config.owner),
         workers: %{}
       }}
    catch
      _, _ -> {:stop, :egress_broker_unavailable}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  def handle_call(:admit, _from, state) do
    if map_size(state.workers) < state.config.max_connections do
      config = state.config
      pid = spawn_link(fn -> connection_worker(config) end)
      timer = Process.send_after(self(), {:expire, pid}, config.timeout)
      {:reply, {:ok, pid}, %{state | workers: Map.put(state.workers, pid, timer)}}
    else
      {:reply, :full, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{acceptor: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    case Map.pop(state.workers, pid) do
      {nil, _} ->
        {:noreply, state}

      {timer, workers} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | workers: workers}}
    end
  end

  def handle_info({:expire, pid}, state) do
    if Map.has_key?(state.workers, pid), do: Process.exit(pid, :shutdown)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)
    stop_worker(state.acceptor)

    Enum.each(state.workers, fn {pid, timer} ->
      Process.cancel_timer(timer)
      stop_worker(pid)
    end)

    File.rm_rf(state.config.directory)
    stop_worker(state.reaper)
    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp stop_worker(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp configuration(opts) do
    directory = Keyword.fetch!(opts, :directory)
    ensure!(is_binary(directory) and Path.type(directory) == :absolute)
    owner = Keyword.fetch!(opts, :owner)
    ensure!(is_pid(owner))
    allowlist = Keyword.get(opts, :allowlist, [])
    ensure!(is_list(allowlist))

    allowlist =
      MapSet.new(allowlist, fn {host, port} ->
        ensure!(valid_host?(host) and valid_port?(port))
        {host, port}
      end)

    bindings = Keyword.get(opts, :bindings, %{})
    ensure!(is_map(bindings))

    bindings =
      Map.new(bindings, fn {host, binding} ->
        ensure!(valid_host?(host) and Enum.any?(allowlist, fn {name, _} -> name == host end))
        %{secret: secret, header: header, prefix: prefix} = binding
        ensure!(is_binary(secret) and byte_size(secret) > 0)
        ensure!(is_binary(header) and Regex.match?(@token, header))
        header = String.downcase(header)
        ensure!(header not in @reserved_headers and header != "accept")
        ensure!(is_binary(prefix) and safe_value?(prefix))
        {host, %{secret: secret, header: header, prefix: prefix}}
      end)

    upstream_tls = Keyword.get(opts, :upstream_tls, [])
    ensure!(Keyword.keyword?(upstream_tls))
    ensure!(Enum.all?(Keyword.keys(upstream_tls), &(&1 in [:cacerts, :cacertfile, :depth])))
    secrets_opts = Keyword.get(opts, :secrets_opts, [])
    ensure!(Keyword.keyword?(secrets_opts))

    %{
      directory: directory,
      owner: owner,
      allowlist: allowlist,
      bindings: bindings,
      upstream_tls: upstream_tls,
      secrets_opts: secrets_opts,
      header_bytes: positive_option(opts, :header_bytes, 32_768),
      body_bytes: positive_option(opts, :body_bytes, 8_388_608),
      timeout: positive_option(opts, :timeout, 15_000),
      max_connections: positive_option(opts, :max_connections, 32)
    }
  end

  defp positive_option(opts, name, default) do
    value = Keyword.get(opts, name, default)
    ensure!(is_integer(value) and value > 0)
    value
  end

  defp prepare_directory(directory) do
    case File.mkdir(directory) do
      :ok ->
        :ok

      {:error, :eexist} ->
        ensure!(match?({:ok, %{type: :directory}}, File.lstat(directory)))

      _ ->
        throw(:reject)
    end

    :ok = File.chmod(directory, 0o700)
  end

  defp accept_loop(listener, broker) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case GenServer.call(broker, :admit, :infinity) do
          {:ok, worker} ->
            case :gen_tcp.controlling_process(socket, worker) do
              :ok ->
                send(worker, {:socket, socket})

              _ ->
                :gen_tcp.close(socket)
                Process.exit(worker, :shutdown)
            end

          :full ->
            :gen_tcp.close(socket)
        end

        accept_loop(listener, broker)

      _ ->
        :ok
    end
  end

  defp connection_worker(config) do
    receive do
      {:socket, socket} ->
        deadline = System.monotonic_time(:millisecond) + config.timeout
        reader = reader(:gen_tcp, socket, deadline, config)

        try do
          {head, reader} = read_head(reader)
          {line, headers} = parse_head(head)
          ["CONNECT", authority, "HTTP/1.1"] = String.split(line, " ")
          target = parse_authority(authority, nil)
          ensure!(host_header(headers) == target)
          ensure!(framing(headers) in [:none, {:length, 0}])
          validate_headers(headers)
          ensure!(reader.buffer == "")

          if MapSet.member?(config.allowlist, target) do
            connect(socket, target, config, deadline)
          else
            send_error(:gen_tcp, socket, 403)
          end
        catch
          _, _ -> send_error(:gen_tcp, socket, 400)
        after
          :gen_tcp.close(socket)
        end
    end
  end

  defp connect(client, {host, port}, config, deadline) do
    case Map.fetch(config.bindings, host) do
      :error ->
        upstream =
          ok!(
            :gen_tcp.connect(
              String.to_charlist(host),
              port,
              [
                :binary,
                active: false,
                packet: :raw,
                send_timeout: remaining(deadline),
                send_timeout_close: true
              ],
              remaining(deadline)
            )
          )

        try do
          :ok = :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
          :ok = :inet.setopts(client, active: :once)
          :ok = :inet.setopts(upstream, active: :once)
          tunnel(client, upstream, deadline)
        after
          :gen_tcp.close(upstream)
        end

      {:ok, binding} ->
        leaf = Certificates.leaf(config.ca, host)
        :ok = :gen_tcp.send(client, "HTTP/1.1 200 Connection Established\r\n\r\n")

        tls =
          ok!(
            :ssl.handshake(
              client,
              [
                cert: leaf.cert,
                key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, leaf.key)},
                active: false,
                mode: :binary,
                verify: :verify_none,
                versions: [:"tlsv1.2", :"tlsv1.3"],
                log_level: :none
              ],
              remaining(deadline)
            )
          )

        try do
          bound_request(tls, {host, port}, binding, config, deadline)
        catch
          _, _ -> :ok
        after
          :ssl.close(tls)
        end
    end
  end

  defp tunnel(client, upstream, deadline) do
    receive do
      {:tcp, ^client, data} ->
        :ok = :gen_tcp.send(upstream, data)
        :ok = :inet.setopts(client, active: :once)
        tunnel(client, upstream, deadline)

      {:tcp, ^upstream, data} ->
        :ok = :gen_tcp.send(client, data)
        :ok = :inet.setopts(upstream, active: :once)
        tunnel(client, upstream, deadline)

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :ok
    after
      remaining(deadline) -> :ok
    end
  end

  defp bound_request(client, target, binding, config, deadline) do
    reader = reader(:ssl, client, deadline, config)
    {head, reader} = read_head(reader)
    {line, headers} = parse_head(head)
    [method, path, "HTTP/1.1"] = String.split(line, " ")
    ensure!(Regex.match?(@token, method) and method != "CONNECT")
    ensure!(String.starts_with?(path, "/") and not String.starts_with?(path, "//"))
    ensure!(not String.contains?(path, "#") and printable?(path))
    ensure!(host_header(headers) == target)
    validate_headers(headers)

    frame =
      case framing(headers) do
        :none -> {:length, 0}
        other -> other
      end

    {body, reader} = read_body(reader, frame, false)
    ensure!(reader.buffer == "")

    {:ok, secret, _source} = Secrets.resolve(binding.secret, config.secrets_opts)
    ensure!(is_binary(secret) and byte_size(secret) > 0 and safe_value?(secret))
    ensure!(byte_size(secret) + byte_size(binding.prefix) <= config.header_bytes)

    try do
      request = request_wire(method, path, headers, body, binding, secret)
      {request_head, _} = :binary.match(request, "\r\n\r\n")
      ensure!(request_head + 4 <= config.header_bytes)
      {host, port} = target

      upstream =
        ok!(
          :ssl.connect(
            String.to_charlist(host),
            port,
            upstream_options(host, config.upstream_tls),
            remaining(deadline)
          )
        )

      try do
        :ok = :ssl.send(upstream, request)
        response = response_wire(upstream, method, secret, config, deadline)
        safe_send(client, response, secret)
      after
        :ssl.close(upstream)
      end
    catch
      _, _ -> safe_send(client, error_response(502), secret)
    end
  end

  defp upstream_options(host, custom) do
    trust =
      if Keyword.has_key?(custom, :cacerts) or Keyword.has_key?(custom, :cacertfile),
        do: custom,
        else: Keyword.put(custom, :cacerts, :public_key.cacerts_get())

    trust ++
      [
        verify: :verify_peer,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        active: false,
        mode: :binary,
        versions: [:"tlsv1.2", :"tlsv1.3"],
        alpn_advertised_protocols: ["http/1.1"],
        log_level: :none
      ]
  end

  defp request_wire(method, path, headers, body, binding, secret) do
    headers =
      headers
      |> Enum.reject(fn {name, _} ->
        name in @hop_headers or name in [binding.header, "accept-encoding", "content-length"]
      end)
      |> Kernel.++([
        {binding.header, binding.prefix <> secret},
        {"accept-encoding", "identity"},
        {"content-length", Integer.to_string(byte_size(body))},
        {"connection", "close"}
      ])

    IO.iodata_to_binary([method, " ", path, " HTTP/1.1\r\n", header_wire(headers), "\r\n", body])
  end

  defp response_wire(upstream, method, secret, config, deadline) do
    reader = reader(:ssl, upstream, deadline, config)
    {head, reader} = read_head(reader)
    {line, headers} = parse_head(head)
    [_, code] = Regex.run(~r/\AHTTP\/1\.[01] ([0-9]{3})(?: [\x20-\x7E]*)?\z/, line)
    status = String.to_integer(code)
    ensure!(status >= 200 and status <= 599)
    validate_headers(headers)
    frame = framing(headers)
    no_body = method == "HEAD" or status in [204, 304]
    {body, reader} = read_body(reader, frame, no_body)
    ensure!(reader.buffer == "")
    body = redact(body, secret, config.body_bytes)

    headers =
      headers
      |> Enum.reject(fn {name, _} ->
        name in @hop_headers or name == "content-length" or
          :binary.match(name, secret) != :nomatch
      end)
      |> Enum.map(fn {name, value} -> {name, redact(value, secret, config.header_bytes)} end)
      |> Kernel.++([
        {"content-length", Integer.to_string(byte_size(body))},
        {"connection", "close"}
      ])

    head = IO.iodata_to_binary(["HTTP/1.1 ", code, " \r\n", header_wire(headers), "\r\n"])
    ensure!(byte_size(head) <= config.header_bytes)
    head <> body
  end

  defp header_wire(headers),
    do: Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

  defp validate_headers(headers) do
    ensure!(values(headers, "upgrade") == [] and values(headers, "expect") == [])
    ensure!(values(headers, "trailer") == [])
    ensure!(Enum.all?(values(headers, "content-encoding"), &(String.downcase(&1) == "identity")))

    ensure!(
      Enum.all?(values(headers, "connection"), fn value ->
        value
        |> String.downcase()
        |> String.split(",")
        |> Enum.all?(&(String.trim(&1) in ["close", "keep-alive"]))
      end)
    )
  end

  defp framing(headers) do
    case {values(headers, "content-length"), values(headers, "transfer-encoding")} do
      {[], []} ->
        :none

      {[length], []} ->
        ensure!(byte_size(length) <= 20 and Regex.match?(~r/\A[0-9]+\z/, length))
        {:length, String.to_integer(length)}

      {[], [encoding]} ->
        ensure!(String.downcase(encoding) == "chunked")
        :chunked

      _ ->
        throw(:reject)
    end
  end

  defp host_header(headers) do
    [host] = values(headers, "host")
    parse_authority(host, 443)
  end

  defp parse_authority(value, default_port) do
    {host, port} =
      case String.split(value, ":") do
        [host] when is_integer(default_port) ->
          {host, default_port}

        [host, port] ->
          ensure!(byte_size(port) <= 5 and Regex.match?(~r/\A[1-9][0-9]*\z/, port))
          {host, String.to_integer(port)}

        _ ->
          throw(:reject)
      end

    host = String.downcase(host)
    ensure!(valid_host?(host) and valid_port?(port))
    {host, port}
  end

  defp valid_host?(host) when is_binary(host) do
    byte_size(host) in 1..253 and host == String.downcase(host) and
      Enum.all?(String.split(host, "."), &Regex.match?(@host_label, &1)) and
      not match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp valid_host?(_), do: false
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535

  defp parse_head(head) do
    [line | lines] = :binary.split(head, "\r\n", [:global])
    ensure!(printable?(line))

    headers =
      Enum.map(lines, fn header ->
        {index, 1} = :binary.match(header, ":")
        name = binary_part(header, 0, index)
        value = binary_part(header, index + 1, byte_size(header) - index - 1)
        ensure!(Regex.match?(@token, name) and safe_value?(value))
        {String.downcase(name), String.trim(value)}
      end)

    {line, headers}
  end

  defp values(headers, name), do: for({^name, value} <- headers, do: value)

  defp printable?(value) do
    value != "" and Enum.all?(:binary.bin_to_list(value), &(&1 in 32..126))
  end

  defp safe_value?(value),
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 == 9 or &1 in 32..126))

  defp reader(transport, socket, deadline, config) do
    %{
      transport: transport,
      socket: socket,
      deadline: deadline,
      buffer: "",
      header_bytes: config.header_bytes,
      body_bytes: config.body_bytes
    }
  end

  defp read_head(reader), do: read_until(reader, "\r\n\r\n", reader.header_bytes)

  defp read_until(reader, separator, limit) do
    case :binary.match(reader.buffer, separator) do
      {index, size} ->
        ensure!(index + size <= limit)
        value = binary_part(reader.buffer, 0, index)
        rest = binary_part(reader.buffer, index + size, byte_size(reader.buffer) - index - size)
        {value, %{reader | buffer: rest}}

      :nomatch ->
        ensure!(byte_size(reader.buffer) < limit)
        data = ok!(receive_data(reader))
        read_until(%{reader | buffer: reader.buffer <> data}, separator, limit)
    end
  end

  defp read_body(reader, _frame, true), do: {"", reader}

  defp read_body(reader, {:length, size}, false) do
    ensure!(size <= reader.body_bytes)
    read_exact(reader, size)
  end

  defp read_body(reader, :chunked, false), do: read_chunks(reader, [], 0, 0)
  defp read_body(reader, :none, false), do: read_closed(reader, [], 0)

  defp read_chunks(reader, chunks, total, metadata) do
    {line, reader} = read_until(reader, "\r\n", reader.header_bytes - metadata)
    ensure!(byte_size(line) in 1..16 and Regex.match?(~r/\A[0-9A-Fa-f]+\z/, line))
    size = String.to_integer(line, 16)
    metadata = metadata + byte_size(line) + 4
    ensure!(metadata <= reader.header_bytes and total + size <= reader.body_bytes)
    {chunk, reader} = read_exact(reader, size)
    {ending, reader} = read_exact(reader, 2)
    ensure!(ending == "\r\n")

    if size == 0 do
      {IO.iodata_to_binary(Enum.reverse(chunks)), reader}
    else
      read_chunks(reader, [chunk | chunks], total + size, metadata)
    end
  end

  defp read_exact(reader, size), do: read_exact(reader, size, [])

  defp read_exact(reader, size, chunks) when byte_size(reader.buffer) >= size do
    <<value::binary-size(^size), rest::binary>> = reader.buffer
    {IO.iodata_to_binary(Enum.reverse([value | chunks])), %{reader | buffer: rest}}
  end

  defp read_exact(reader, size, chunks) do
    data = ok!(receive_data(reader))

    read_exact(%{reader | buffer: data}, size - byte_size(reader.buffer), [reader.buffer | chunks])
  end

  defp read_closed(reader, chunks, total) do
    total = total + byte_size(reader.buffer)
    ensure!(total <= reader.body_bytes)
    chunks = [reader.buffer | chunks]

    case receive_data(reader) do
      {:ok, data} -> read_closed(%{reader | buffer: data}, chunks, total)
      {:error, :closed} -> {IO.iodata_to_binary(Enum.reverse(chunks)), %{reader | buffer: ""}}
      _ -> throw(:reject)
    end
  end

  defp receive_data(reader),
    do: reader.transport.recv(reader.socket, 0, remaining(reader.deadline))

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp ensure!(true), do: :ok
  defp ensure!(_), do: throw(:reject)
  defp ok!({:ok, value}), do: value
  defp ok!(_), do: throw(:reject)

  defp redact(value, secret, limit) do
    ensure!(byte_size(value) <= limit)
    expansion = byte_size("[REDACTED]") - byte_size(secret)
    if expansion > 0, do: check_redaction_size(value, secret, expansion, byte_size(value), limit)
    :binary.replace(value, secret, "[REDACTED]", [:global])
  end

  defp check_redaction_size(value, secret, expansion, size, limit) do
    case :binary.match(value, secret) do
      :nomatch ->
        :ok

      {offset, length} ->
        ensure!(size + expansion <= limit)
        rest = binary_part(value, offset + length, byte_size(value) - offset - length)
        check_redaction_size(rest, secret, expansion, size + expansion, limit)
    end
  end

  defp safe_send(client, response, secret) do
    if :binary.match(response, secret) == :nomatch, do: :ssl.send(client, response)
  end

  defp send_error(transport, socket, status), do: transport.send(socket, error_response(status))

  defp error_response(status),
    do: "HTTP/1.1 #{status} \r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
end
