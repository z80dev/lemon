defmodule LemonCore.LoopbackListener do
  @moduledoc """
  Inspects loopback TCP ownership, failing closed when evidence is unavailable.

  Listener checks match the destination address, family and port (including that
  family's wildcard bind). They are preflight only. Credential senders must use
  `peer_owned_by_self?/2` on the established socket: its reverse four-tuple
  identifies the peer, not a replacement listener on the same port. Linux uses
  the kernel socket uid in `/proc/net/tcp{,6}`; macOS/BSD use uid-filtered `lsof`
  records with exact endpoints. Only the current process uid is cached.
  """

  @type ownership :: :owned | :foreign | :absent | :unverifiable
  @uid_key {__MODULE__, :uid}

  @spec owned_by_self?({:inet.ip_address(), :inet.port_number()}, keyword()) :: ownership()
  def owned_by_self?(destination, opts \\ []) do
    inspect_owner(destination, nil, opts)
  end

  @doc """
  Checks the server side of an established TCP/TLS socket, never its listener.

  A just-connected socket can still sit in the server's accept queue, where it
  belongs to no process and inspection finds no owner; a busy server would then
  be refused. Inspection is retried until the socket is accepted, for at most
  `:accept_wait_ms` (default 1000). Only positive evidence yields `:owned`.
  """
  @spec peer_owned_by_self?(term(), :tcp | :ssl, keyword()) :: ownership()
  def peer_owned_by_self?(socket, transport, opts \\ []) do
    module = if transport == :ssl, do: :ssl, else: :inet

    with {:ok, local} <- module.sockname(socket),
         {:ok, remote} <- module.peername(socket) do
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :accept_wait_ms, 1_000)
      await_owned(local, remote, opts, deadline, 10)
    else
      _ -> :unverifiable
    end
  rescue
    _ -> :unverifiable
  catch
    _, _ -> :unverifiable
  end

  defp await_owned(local, remote, opts, deadline, delay) do
    case connection_owned_by_self?(local, remote, opts) do
      :owned ->
        :owned

      result ->
        if System.monotonic_time(:millisecond) + delay > deadline do
          result
        else
          Process.sleep(delay)
          await_owned(local, remote, opts, deadline, min(delay * 2, 100))
        end
    end
  end

  @doc false
  def connection_owned_by_self?(local, remote, opts \\ []) do
    inspect_owner(remote, local, opts)
  end

  defp inspect_owner({address, port} = destination, peer, opts)
       when is_tuple(address) and is_integer(port) and port in 1..65_535 do
    with true <- literal_loopback?(address |> :inet.ntoa() |> to_string()),
         {:ok, uid} <- uid(opts) do
      case Keyword.get(opts, :os_type, :os.type()) do
        {:unix, :linux} ->
          linux(destination, peer, uid, opts)

        {:unix, os} when os in [:darwin, :freebsd, :openbsd, :netbsd, :dragonfly] ->
          lsof(destination, peer, uid, opts)

        _ ->
          :unverifiable
      end
    else
      _ -> :unverifiable
    end
  rescue
    _ -> :unverifiable
  catch
    _, _ -> :unverifiable
  end

  defp inspect_owner(_, _, _), do: :unverifiable

  @doc "Returns true only for a literal loopback IP host, without resolving DNS."
  @spec literal_loopback?(term()) :: boolean()
  def literal_loopback?(host) when is_binary(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, high, _}} -> div(high, 256) == 127
      _ -> false
    end
  end

  def literal_loopback?(_), do: false

  defp uid(opts) do
    case Keyword.fetch(opts, :uid) do
      {:ok, uid} when is_integer(uid) and uid >= 0 -> {:ok, uid}
      {:ok, _} -> {:error, :invalid_uid}
      :error -> cached_uid()
    end
  end

  defp cached_uid do
    case :persistent_term.get(@uid_key, nil) do
      nil ->
        with {output, 0} <- System.cmd("id", ["-u"], stderr_to_stdout: true),
             {uid, ""} when uid >= 0 <- Integer.parse(String.trim(output)) do
          :persistent_term.put(@uid_key, uid)
          {:ok, uid}
        else
          _ -> {:error, :uid_unavailable}
        end

      uid ->
        {:ok, uid}
    end
  end

  defp linux({address, _} = destination, peer, uid, opts) do
    file = if tuple_size(address) == 4, do: "tcp", else: "tcp6"
    path = Path.join([Keyword.get(opts, :proc_root, "/proc"), "net", file])

    with {:ok, data} <- File.read(path),
         [header | rows] <- String.split(data, "\n", trim: true),
         true <- String.contains?(header, "local_address") and String.contains?(header, "uid"),
         {:ok, owners} <- proc_owners(rows, destination, peer) do
      cond do
        Enum.any?(owners, &(&1 != uid)) -> :foreign
        owners != [] -> :owned
        true -> :absent
      end
    else
      _ -> :unverifiable
    end
  end

  defp proc_owners(rows, destination, peer) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, owners} ->
      with [_slot, local, remote, state, _queue, _timer, _retransmit, uid, _timeout, inode | _] <-
             String.split(row),
           {:ok, local} <- proc_endpoint(local),
           {:ok, remote} <- proc_endpoint(remote),
           true <- tuple_size(elem(local, 0)) == tuple_size(elem(destination, 0)),
           true <- tuple_size(elem(remote, 0)) == tuple_size(elem(destination, 0)),
           true <- Regex.match?(~r/\A[0-9A-F]{2}\z/, state),
           {owner, ""} when owner >= 0 <- Integer.parse(uid),
           {inode, ""} when inode >= 0 <- Integer.parse(inode) do
        matches =
          if is_nil(peer),
            do: state == "0A" and listener_matches?(local, destination),
            else: state == "01" and local == destination and remote == peer and inode > 0

        {:cont, {:ok, if(matches, do: [owner | owners], else: owners)}}
      else
        _ -> {:halt, {:error, :invalid_proc}}
      end
    end)
  end

  defp proc_endpoint(encoded) do
    with [address, port] <- String.split(encoded, ":"),
         {port, ""} when port in 0..65_535 <- Integer.parse(port, 16),
         {:ok, bytes} <- Base.decode16(address, case: :mixed),
         true <- byte_size(bytes) in [4, 16] do
      network =
        for <<word::native-unsigned-integer-size(32) <- bytes>>, into: <<>>, do: <<word::32>>

      case network do
        <<a, b, c, d>> ->
          {:ok, {{a, b, c, d}, port}}

        <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> ->
          {:ok, {{a, b, c, d, e, f, g, h}, port}}

        _ ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp listener_matches?({bind, port}, {address, port}) do
    bind == address or
      (tuple_size(bind) == tuple_size(address) and
         bind |> Tuple.to_list() |> Enum.all?(&(&1 == 0)))
  end

  defp listener_matches?(_, _), do: false

  defp lsof({address, port} = destination, peer, uid, opts) do
    command = Keyword.get(opts, :command, &System.cmd/3)
    family = if tuple_size(address) == 4, do: "4", else: "6"
    host = address |> :inet.ntoa() |> to_string()
    host = if family == "6", do: "[#{host}]", else: host
    state = if is_nil(peer), do: "LISTEN", else: "ESTABLISHED"

    args = [
      "-nP",
      "-a",
      "-u",
      Integer.to_string(uid),
      "-i#{family}TCP@#{host}:#{port}",
      "-sTCP:#{state}",
      "-Fftn"
    ]

    case command.("/usr/sbin/lsof", args, stderr_to_stdout: false) do
      {output, 0} ->
        # Validate the whole field stream, not just an owned-looking substring.
        valid? =
          Regex.match?(
            ~r/\A(?:p[0-9]+\n(?:f[0-9]+\ntIPv[46]\nn[^\r\n]+\n)+)+\z/,
            output
          )

        records = Regex.scan(~r/\nf[0-9]+\ntIPv([46])\nn([^\r\n]+)/, output)

        if valid? and Enum.any?(records, &lsof_matches?(&1, family, destination, peer)),
          do: :owned,
          else: :unverifiable

      {"", 1} when is_nil(peer) ->
        Keyword.get(opts, :probe, &probe/1).(destination)

      {"", 1} ->
        :foreign

      _ ->
        :unverifiable
    end
  end

  defp lsof_matches?([_, record_family, name], family, destination, peer) do
    expected = endpoint_name(destination)

    record_family == family and
      if is_nil(peer),
        do: name == expected or name == "*:#{elem(destination, 1)}",
        else: name == expected <> "->" <> endpoint_name(peer)
  end

  defp endpoint_name({address, port}) do
    host = address |> :inet.ntoa() |> to_string()
    if tuple_size(address) == 8, do: "[#{host}]:#{port}", else: "#{host}:#{port}"
  end

  defp probe({address, port}) do
    family = if tuple_size(address) == 8, do: :inet6, else: :inet

    case :gen_tcp.connect(address, port, [family, :binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :foreign

      {:error, reason} when reason in [:econnrefused, :eafnosupport, :eprotonosupport] ->
        :absent

      _ ->
        :unverifiable
    end
  end
end
