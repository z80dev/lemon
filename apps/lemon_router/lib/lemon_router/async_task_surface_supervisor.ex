defmodule LemonRouter.AsyncTaskSurfaceSupervisor do
  @moduledoc """
  Dynamic supervisor wrapper for router-owned async task surfaces.
  """

  @start_retry_wait_ms 20
  @max_start_retries 50

  @spec ensure_started(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(surface_id, opts \\ []) when is_binary(surface_id) do
    do_ensure_started(surface_id, opts, @max_start_retries)
  end

  defp do_ensure_started(surface_id, opts, retries_left) do
    case LemonRouter.AsyncTaskSurface.whereis(surface_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        spec =
          {LemonRouter.AsyncTaskSurface, Keyword.merge(opts, surface_id: surface_id)}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            handle_existing_child(surface_id, pid, opts, retries_left)

          {:error, {:already_present, _child_spec}} ->
            handle_already_present(surface_id, opts, retries_left)

          other ->
            other
        end
    end
  end

  defp handle_existing_child(surface_id, pid, opts, retries_left) do
    if reusable_surface_pid?(surface_id, pid) do
      {:ok, pid}
    else
      wait_and_retry(surface_id, pid, opts, retries_left)
    end
  end

  defp handle_already_present(surface_id, opts, retries_left) do
    case LemonRouter.AsyncTaskSurface.whereis(surface_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        wait_and_retry(surface_id, nil, opts, retries_left)
    end
  end

  defp reusable_surface_pid?(surface_id, pid),
    do: Process.alive?(pid) and LemonRouter.AsyncTaskSurface.whereis(surface_id) == pid

  defp wait_and_retry(surface_id, pid, opts, retries_left) when retries_left > 0 do
    wait_for_surface_exit(pid)
    do_ensure_started(surface_id, opts, retries_left - 1)
  end

  defp wait_and_retry(surface_id, _pid, _opts, 0) do
    case LemonRouter.AsyncTaskSurface.whereis(surface_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :surface_start_timeout}
    end
  end

  defp wait_for_surface_exit(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @start_retry_wait_ms -> :ok
    end

    Process.demonitor(ref, [:flush])
  end

  defp wait_for_surface_exit(nil) do
    Process.sleep(@start_retry_wait_ms)
  end
end
