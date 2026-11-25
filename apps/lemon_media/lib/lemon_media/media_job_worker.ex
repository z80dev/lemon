defmodule LemonMedia.MediaJobWorker do
  @moduledoc """
  Runs one media job and records redacted lifecycle metadata.
  """

  alias LemonMedia.MediaJobs

  @doc false
  @spec run(pid(), pid(), map(), keyword(), integer()) :: LemonMedia.MediaJobSupervisor.outcome()
  def run(caller, supervisor, attrs, opts, deadline) do
    # The supervised owner stays responsive while its linked runner blocks in
    # provider I/O. It must be able to kill the runner even if it traps exits.
    Process.flag(:trap_exit, true)
    caller_ref = Process.monitor(caller)
    record_opts = record_opts(opts)

    receive do
      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        cancelled(attrs, record_opts, :caller_exited)

      {:abort, ^caller} ->
        cancelled(attrs, record_opts, :aborted)

      {:EXIT, ^supervisor, reason} ->
        exit(reason)
    after
      0 ->
        if deadline <= System.monotonic_time(:millisecond) do
          cancelled(attrs, record_opts, :timeout)
        else
          task = Task.async(fn -> execute(attrs, opts, record_opts) end)
          await_runner(task, caller, caller_ref, supervisor, attrs, record_opts, deadline)
        end
    end
  end

  defp await_runner(task, caller, caller_ref, supervisor, attrs, record_opts, deadline) do
    %Task{ref: runner_ref, pid: runner} = task
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^runner_ref, result} ->
        Process.demonitor(runner_ref, [:flush])
        result

      {:DOWN, ^runner_ref, :process, ^runner, _reason} ->
        exit(:job_exited)

      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        cancel_runner(task, attrs, record_opts, :caller_exited)

      {:abort, ^caller} ->
        cancel_runner(task, attrs, record_opts, :aborted)

      {:EXIT, ^supervisor, reason} ->
        Task.shutdown(task, :brutal_kill)
        exit(reason)
    after
      remaining -> cancel_runner(task, attrs, record_opts, :timeout)
    end
  end

  defp cancel_runner(task, attrs, record_opts, reason) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> exit(:job_exited)
      nil -> cancelled(attrs, record_opts, reason)
    end
  end

  defp cancelled(attrs, record_opts, reason) do
    kind = Atom.to_string(reason)
    cancelled_attrs = Map.merge(attrs, %{status: :cancelled, error: kind, error_kind: kind})
    {:ok, job} = MediaJobs.record(cancelled_attrs, record_opts)
    {:error, {:cancelled, reason, job}}
  end

  defp execute(attrs, job_opts, record_opts) do
    running_attrs = Map.put(attrs, :status, :running)
    {:ok, _running_job} = MediaJobs.record(running_attrs, record_opts)

    case run_media_job(Keyword.get(job_opts, :runner), running_attrs) do
      {:ok, updates} ->
        completed_attrs =
          running_attrs
          |> Map.merge(attrs_map(updates))
          |> Map.put(:status, :completed)

        MediaJobs.record(completed_attrs, record_opts)

      {:error, reason} ->
        failed_attrs =
          running_attrs
          |> Map.put(:status, :failed)
          |> Map.put(:error, inspect(reason))
          |> Map.put(:error_kind, error_kind(reason))

        {:ok, failed_job} = MediaJobs.record(failed_attrs, record_opts)
        {:error, {:failed, failed_job}}
    end
  end

  defp run_media_job(runner, attrs) when is_function(runner, 1) do
    case runner.(attrs) do
      {:ok, updates} when is_map(updates) or is_list(updates) -> {:ok, updates}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_runner_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_media_job(_runner, _attrs), do: {:error, :missing_runner}

  defp record_opts(opts) do
    opts
    |> Keyword.take([:project_dir, :dir, :artifacts_dir])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(reason) when is_binary(reason), do: safe_error_label(reason)

  defp error_kind({kind, reason}) when is_atom(kind) do
    error_kind_with_detail(kind, reason)
  end

  defp error_kind({kind, _status, reason}) when is_atom(kind) do
    error_kind_with_detail(kind, reason)
  end

  defp error_kind(reason), do: reason |> inspect() |> safe_error_label()

  defp error_kind_with_detail(kind, reason) do
    kind = Atom.to_string(kind)

    case safe_error_detail(reason) do
      nil -> kind
      detail -> "#{kind}:#{detail}"
    end
  end

  defp safe_error_detail({:safe_error_kind, reason}), do: safe_error_label(reason)
  defp safe_error_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_detail(_reason), do: nil

  defp safe_error_label(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 80)
    |> case do
      "" -> nil
      label -> label
    end
  end
end
