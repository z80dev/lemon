defmodule CodingAgent.Tools.Bash.Managed do
  @moduledoc false

  alias CodingAgent.{BashExecutor, ProcessManager, ProcessStore}
  alias LemonAgent.AbortSignal

  def execute(command, cwd, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout)

    launch =
      [
        command: command,
        cwd: cwd,
        env: Keyword.fetch!(opts, :env),
        owner: Keyword.get(opts, :session_id),
        owner_pid: Keyword.get(opts, :session_pid)
      ] ++ Keyword.take(opts, [:before_start])

    case ProcessManager.exec(launch) do
      {status, id} when status in [:ok, :queued] ->
        await_owned(id, deadline, opts)

      {:error, {:outcome_unknown, id}} ->
        # Admission can yield while the one launch is still starting. Reconcile
        # that identity; this is neither a foreground timeout nor permission to retry.
        await_owned(id, deadline, opts)

      error ->
        error
    end
  end

  defp await_owned(id, deadline, opts) do
    caller = self()

    guard =
      spawn(fn ->
        ref = Process.monitor(caller)

        receive do
          :release -> Process.demonitor(ref, [:flush])
          {:DOWN, ^ref, :process, ^caller, _} -> ProcessManager.kill(id)
        end
      end)

    try do
      await(id, deadline, opts, 0)
    after
      send(guard, :release)
    end
  end

  defp await(id, deadline, opts, offset) do
    case snapshot(id) do
      {:ok, snapshot} ->
        {output, offset} = preview(snapshot, opts, offset)

        cond do
          Keyword.get(opts, :signal) && AbortSignal.aborted?(Keyword.fetch!(opts, :signal)) ->
            ProcessManager.kill(id)
            {:ok, result(snapshot, output, true)}

          snapshot.status == :lost ->
            {:uncertain, id, snapshot, output}

          snapshot.status not in [:running, :starting, :queued] ->
            {:ok, result(snapshot, output, false)}

          System.monotonic_time(:millisecond) >= deadline ->
            {:detached, id, snapshot, output}

          true ->
            Process.sleep(20)
            await(id, deadline, opts, offset)
        end

      {:error, :not_found} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:detached, id, %{status: :queued}, ""}
        else
          Process.sleep(20)
          await(id, deadline, opts, offset)
        end

      error ->
        error
    end
  end

  defp snapshot(id) do
    # A child still in init cannot answer calls. Its store snapshot lets the
    # foreground deadline expire without blocking on a GenServer call timeout.
    case ProcessStore.get(id) do
      {:ok, %{status: status} = record, lines} when status in [:starting, :queued] ->
        {:ok, Map.put(record, :lines, lines)}

      _ ->
        ProcessManager.read_output(id, peek: true)
    end
  end

  defp preview(snapshot, opts, offset) do
    # Keep reads bounded, but advance the streaming cursor through the whole
    # captured artifact rather than stopping at the presentation head.
    case open_preview(Map.get(snapshot, :full_output_path)) do
      {:ok, file} ->
        try do
          data = IO.binread(file, 50_000)
          output = if is_binary(data), do: BashExecutor.sanitize_output(data), else: ""
          offset = stream_output(file, Keyword.get(opts, :on_chunk), offset)
          {output, offset}
        after
          File.close(file)
        end

      _ ->
        {Enum.join(snapshot.lines, "\n"), offset}
    end
  end

  defp stream_output(_file, nil, offset), do: offset

  defp stream_output(file, callback, offset) do
    case :file.pread(file, offset, 50_000) do
      {:ok, chunk} ->
        callback.(BashExecutor.sanitize_output(chunk))
        stream_output(file, callback, offset + byte_size(chunk))

      _ ->
        offset
    end
  end

  defp open_preview(nil), do: {:error, :not_started}
  defp open_preview(path), do: File.open(path, [:read, :binary])

  defp result(%{full_output_path: path} = snapshot, _output, cancelled)
       when is_binary(path) do
    BashExecutor.captured_result(
      path,
      if(cancelled, do: nil, else: Map.get(snapshot, :exit_code)),
      cancelled
    )
  end

  defp result(snapshot, output, cancelled) do
    %BashExecutor.Result{
      output: output,
      exit_code: if(cancelled, do: nil, else: Map.get(snapshot, :exit_code)),
      cancelled: cancelled,
      truncated: false
    }
  end
end
