defmodule LemonCore.LoopbackListener do
  @moduledoc """
  Checks whether a loopback TCP listener belongs to the current OS user.

  Linux inspects listening sockets in `/proc/net/tcp{,6}`. macOS and BSD use
  `lsof` restricted to the current uid, then probe for a foreign listener when
  no owned socket is found. Unsupported or inaccessible inspection fails closed.
  Wildcard listeners are included because they can also receive loopback traffic.
  Ownership is checked afresh; only the process uid is cached.
  """

  @type ownership :: :owned | :foreign | :absent | :unverifiable
  @uid_key {__MODULE__, :uid}

  @spec owned_by_self?(integer()) :: ownership()
  def owned_by_self?(port), do: owned_by_self?(port, [])

  @doc false
  def owned_by_self?(port, opts) when is_integer(port) and port in 1..65_535 do
    with {:ok, uid} <- uid(opts) do
      case Keyword.get(opts, :os_type, :os.type()) do
        {:unix, :linux} ->
          linux(port, uid, Keyword.get(opts, :proc_root, "/proc"))

        {:unix, os} when os in [:darwin, :freebsd, :openbsd, :netbsd, :dragonfly] ->
          lsof(port, uid, opts)

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

  def owned_by_self?(_, _), do: :unverifiable

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

  defp linux(port, uid, root) do
    with {:ok, v4} <- proc_listeners(Path.join(root, "net/tcp"), port),
         {:ok, v6} <- proc_listeners(Path.join(root, "net/tcp6"), port, true) do
      owners = v4 ++ v6

      cond do
        Enum.any?(owners, &(&1 != uid)) -> :foreign
        owners != [] -> :owned
        true -> :absent
      end
    else
      _ -> :unverifiable
    end
  end

  defp proc_listeners(path, port, optional? \\ false) do
    case File.read(path) do
      {:ok, data} -> parse_proc(data, port)
      {:error, :enoent} when optional? -> {:ok, []}
      _ -> {:error, :unreadable}
    end
  end

  defp parse_proc(data, port) do
    case String.split(data, "\n", trim: true) do
      [header | rows] ->
        if String.contains?(header, "local_address") and String.contains?(header, "uid") do
          Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, owners} ->
            case String.split(row) do
              [_slot, local, _remote, state, _queue, _timer, _retransmit, uid | _] ->
                with [address, hex_port] <- String.split(local, ":"),
                     {local_port, ""} <- Integer.parse(hex_port, 16),
                     {owner, ""} when owner >= 0 <- Integer.parse(uid),
                     {:ok, bytes} <- Base.decode16(address, case: :mixed),
                     true <- byte_size(bytes) in [4, 16] do
                  if state == "0A" and local_port == port and loopback_or_wildcard?(bytes) do
                    {:cont, {:ok, [owner | owners]}}
                  else
                    {:cont, {:ok, owners}}
                  end
                else
                  _ -> {:halt, {:error, :invalid_proc}}
                end

              _ ->
                {:halt, {:error, :invalid_proc}}
            end
          end)
        else
          {:error, :invalid_proc}
        end

      _ ->
        {:error, :invalid_proc}
    end
  end

  defp loopback_or_wildcard?(bytes) do
    address =
      for <<word::native-unsigned-integer-size(32) <- bytes>>, into: <<>>, do: <<word::32>>

    case address do
      <<127, _, _, _>> -> true
      <<0::32>> -> true
      <<0::128>> -> true
      <<0::120, 1>> -> true
      <<0::80, 0xFFFF::16, 127, _, _, _>> -> true
      _ -> false
    end
  end

  defp lsof(port, uid, opts) do
    command = Keyword.get(opts, :command, &System.cmd/3)
    args = ["-nP", "-a", "-u", Integer.to_string(uid), "-iTCP:#{port}", "-sTCP:LISTEN", "-t"]

    case command.("/usr/sbin/lsof", args, stderr_to_stdout: false) do
      {output, 0} ->
        pids = String.split(output)

        if pids != [] and Enum.all?(pids, &Regex.match?(~r/\A[0-9]+\z/, &1)),
          do: :owned,
          else: :unverifiable

      {"", 1} ->
        probe = Keyword.get(opts, :probe, &probe/1)
        probe.(port)

      _ ->
        :unverifiable
    end
  end

  defp probe(port) do
    results =
      for address <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
        case :gen_tcp.connect(address, port, [:binary, active: false], 250) do
          {:ok, socket} ->
            :gen_tcp.close(socket)
            :foreign

          {:error, reason} when reason in [:econnrefused, :eafnosupport, :eprotonosupport] ->
            :absent

          _ ->
            :unverifiable
        end
      end

    cond do
      :foreign in results -> :foreign
      :unverifiable in results -> :unverifiable
      true -> :absent
    end
  end
end
