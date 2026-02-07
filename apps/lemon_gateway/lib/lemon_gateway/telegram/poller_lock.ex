defmodule LemonGateway.Telegram.PollerLock do
  @moduledoc false

  # Telegram getUpdates is "at least once" if you have multiple pollers. Running two pollers
  # (e.g. legacy LemonGateway transport + lemon_channels adapter) will double-submit inbound
  # messages and produce duplicate replies.
  #
  # We use a :global lock so only one poller per (account_id, token) can run in a BEAM cluster.
  #
  # In practice, users often accidentally start *two separate OS processes* (e.g. two `./bin/lemon-gateway`
  # invocations). Those OS processes are not connected as distributed Erlang nodes, so `:global` alone is
  # insufficient. To prevent duplicate replies in that scenario, we also use a best-effort on-disk lock
  # scoped to (account_id, token).

  # If a lock file is not refreshed (via `heartbeat/2`) for this long, it is treated as stale.
  #
  # This protects against PID reuse: a stale lock created by a dead lemon process can be "kept alive"
  # forever if the old OS PID is later reused by some unrelated process.
  @default_stale_ms 300_000

  @spec acquire(term(), term()) :: :ok | {:error, :locked}
  def acquire(account_id, token) do
    case :global.register_name(lock_name(account_id, token), self()) do
      :yes ->
        case acquire_file_lock(account_id, token) do
          :ok ->
            :ok

          {:error, :locked} ->
            # Release the :global lock so a different process can proceed if it owns the file lock.
            _ = :global.unregister_name(lock_name(account_id, token))
            {:error, :locked}
        end

      :no ->
        {:error, :locked}
    end
  end

  @spec release(term(), term()) :: :ok
  def release(account_id, token) do
    _ = :global.unregister_name(lock_name(account_id, token))
    _ = release_file_lock(account_id, token)
    :ok
  rescue
    _ -> :ok
  end

  @spec heartbeat(term(), term()) :: :ok
  def heartbeat(account_id, token) do
    path = lock_path(account_id, token)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         true <- lock_owned_by_self?(content) do
      # Touching mtime is our heartbeat; this is what new processes use to detect staleness.
      _ = File.touch(path)
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp lock_name(account_id, token) do
    {:lemon, :telegram_poller, normalize_account_id(account_id), token_fingerprint(token)}
  end

  defp normalize_account_id(nil), do: "default"
  defp normalize_account_id(account_id), do: to_string(account_id)

  defp token_fingerprint(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp token_fingerprint(_), do: "no_token"

  defp acquire_file_lock(account_id, token) do
    path = lock_path(account_id, token)
    _ = File.mkdir_p(Path.dirname(path))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        # Keep it simple: lock is the presence of this file. We still write metadata so we can
        # clean up stale locks after crashes.
        os_pid = System.pid() || ""
        node = to_string(node())
        erl_pid = inspect(self())
        ts = System.system_time(:millisecond)
        _ = IO.binwrite(io, "os_pid=#{os_pid}\nnode=#{node}\nerl_pid=#{erl_pid}\nts=#{ts}\n")
        _ = File.close(io)
        :ok

      {:error, :eexist} ->
        maybe_steal_stale_lock(path)

      {:error, _reason} ->
        {:error, :locked}
    end
  rescue
    _ -> {:error, :locked}
  end

  defp release_file_lock(account_id, token) do
    path = lock_path(account_id, token)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         true <- lock_owned_by_self?(content) do
      _ = File.rm(path)
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp lock_owned_by_self?(content) when is_binary(content) do
    os_pid = System.pid() || ""
    node_s = to_string(node())
    erl_pid = inspect(self())

    String.contains?(content, "os_pid=#{os_pid}\n") and
      String.contains?(content, "node=#{node_s}\n") and
      String.contains?(content, "erl_pid=#{erl_pid}\n")
  end

  defp lock_owned_by_self?(_), do: false

  defp maybe_steal_stale_lock(path) do
    case File.read(path) do
      {:ok, content} ->
        os_pid = extract_kv(content, "os_pid")
        node_s = extract_kv(content, "node")
        erl_pid_s = extract_kv(content, "erl_pid")
        lock_ts_ms = extract_ts_ms(content)
        stale_by_mtime? = stale_file?(path)

        current_os_pid = System.pid() || ""
        current_node_s = to_string(node())

        # If the lock was created by *this* OS process/node but the owning Erlang pid no longer
        # exists (e.g. brutal_kill), consider it stale and steal it.
        stale_on_this_node? =
          os_pid == current_os_pid and node_s == current_node_s and
            not erl_pid_alive_on_this_node?(erl_pid_s)

        cond do
          stale_on_this_node? ->
            steal_lock_file(path)

          stale_by_mtime? and is_binary(os_pid) and os_pid != "" and os_pid_alive?(os_pid) ->
            # If the lock file is stale but the PID is alive, it may be PID reuse. Disambiguate by
            # comparing the lock timestamp to the OS process start time.
            if is_nil(lock_ts_ms) or os_pid_started_after_lock?(os_pid, lock_ts_ms) do
              steal_lock_file(path)
            else
              # Conservative: don't steal from a still-running process (older lemon versions won't heartbeat).
              {:error, :locked}
            end

          stale_by_mtime? ->
            steal_lock_file(path)

          is_binary(os_pid) and os_pid != "" and os_pid_alive?(os_pid) ->
            {:error, :locked}

          true ->
            steal_lock_file(path)
        end

      _ ->
        {:error, :locked}
    end
  rescue
    _ -> {:error, :locked}
  end

  defp steal_lock_file(path) do
    _ = File.rm(path)

    # One retry: if we win the race, we'll acquire; otherwise we report locked.
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        os_pid = System.pid() || ""
        node = to_string(node())
        erl_pid = inspect(self())
        ts = System.system_time(:millisecond)

        _ = IO.binwrite(io, "os_pid=#{os_pid}\nnode=#{node}\nerl_pid=#{erl_pid}\nts=#{ts}\n")
        _ = File.close(io)
        :ok

      _ ->
        {:error, :locked}
    end
  rescue
    _ -> {:error, :locked}
  end

  defp extract_kv(content, key) do
    case Regex.run(~r/^#{Regex.escape(key)}=(.+)$/m, content) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp erl_pid_alive_on_this_node?(pid_s) when is_binary(pid_s) do
    with true <- String.starts_with?(pid_s, "#PID<"),
         pid <- :erlang.list_to_pid(String.to_charlist(pid_s)),
         true <- is_pid(pid) do
      Process.alive?(pid)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp erl_pid_alive_on_this_node?(_), do: false

  # `kill -0 <pid>` is a portable way to check for process existence on Unix.
  defp os_pid_alive?(pid) when is_binary(pid) do
    # Guard: pid "0" has special meaning for `kill` (process group), so never treat it as alive here.
    case Integer.parse(pid) do
      {i, _} when i > 1 ->
        case System.cmd("kill", ["-0", Integer.to_string(i)], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp lock_path(account_id, token) do
    dir =
      case System.get_env("LEMON_LOCK_DIR") do
        d when is_binary(d) and d != "" ->
          d

        _ ->
          Path.join([System.user_home!(), ".lemon", "locks"])
      end

    filename =
      "telegram_poller_#{normalize_account_id(account_id)}_#{token_fingerprint(token)}.lock"

    Path.join(dir, filename)
  end

  defp stale_file?(path) do
    stale_ms = stale_after_ms()

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path) do
      now_s = :calendar.datetime_to_gregorian_seconds(:calendar.local_time())
      mtime_s = :calendar.datetime_to_gregorian_seconds(mtime)
      max(0, now_s - mtime_s) * 1_000 > stale_ms
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp stale_after_ms do
    case System.get_env("LEMON_TELEGRAM_POLLER_LOCK_STALE_MS") do
      s when is_binary(s) and s != "" ->
        case Integer.parse(s) do
          {i, _} when i >= 0 -> i
          _ -> @default_stale_ms
        end

      _ ->
        @default_stale_ms
    end
  end

  defp extract_ts_ms(content) when is_binary(content) do
    case extract_kv(content, "ts") do
      s when is_binary(s) ->
        case Integer.parse(s) do
          {i, _} when i >= 0 -> i
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_ts_ms(_), do: nil

  defp os_pid_started_after_lock?(pid, lock_ts_ms)
       when is_binary(pid) and is_integer(lock_ts_ms) do
    # `ps -o etime=` returns `[[dd-]hh:]mm:ss` on macOS/Linux.
    case System.cmd("ps", ["-p", pid, "-o", "etime="], stderr_to_stdout: true) do
      {out, 0} ->
        etime = out |> to_string() |> String.trim()

        case parse_etime_seconds(etime) do
          {:ok, seconds} ->
            now_ms = System.system_time(:millisecond)
            start_ms = now_ms - seconds * 1_000
            # Grace window to avoid edge flaps.
            start_ms > lock_ts_ms + 10_000

          _ ->
            false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp os_pid_started_after_lock?(_pid, _lock_ts_ms), do: false

  defp parse_etime_seconds(etime) when is_binary(etime) do
    {days, time_part} =
      case String.split(etime, "-", parts: 2) do
        [a, b] ->
          case Integer.parse(String.trim(a)) do
            {d, _} when d >= 0 -> {d, String.trim(b)}
            _ -> {0, String.trim(b)}
          end

        [a] ->
          {0, String.trim(a)}
      end

    parts =
      time_part
      |> String.split(":")
      |> Enum.map(&String.trim/1)

    with true <- length(parts) in [1, 2, 3],
         nums <- Enum.map(parts, &Integer.parse/1),
         true <-
           Enum.all?(nums, fn
             {i, _} -> i >= 0
             _ -> false
           end) do
      ints = Enum.map(nums, fn {i, _} -> i end)

      seconds =
        case ints do
          [s] -> s
          [m, s] -> m * 60 + s
          [h, m, s] -> h * 3600 + m * 60 + s
        end

      {:ok, days * 86_400 + seconds}
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :invalid}
  end
end
