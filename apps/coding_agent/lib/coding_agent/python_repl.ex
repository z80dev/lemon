defmodule CodingAgent.PythonRepl do
  @moduledoc """
  Public boundary for persistent Python execution.

  Validation and allocation failures are mapped here. `execute/1` requires a
  positive integer `:timeout_ms`; callers must clamp it against the configured
  `execute_code` timeout before invoking this boundary. After allocation, a cell
  is dispatched exactly once: an exited worker is reported, never retried in a
  replacement namespace.
  """

  alias CodingAgent.PythonRepl.{Key, Registry}

  @spec execute(map() | keyword()) :: {:ok, map()} | {:error, map()}
  def execute(opts) when is_map(opts) or is_list(opts) do
    opts = Map.new(opts)
    registry = Map.get(opts, :registry, Registry)

    with {:ok, key} <- key(opts[:key]),
         {:ok, owner} <- owner(opts[:owner_pid]),
         {:ok, request} <- request(opts),
         {:ok, timeout} <- timeout(opts[:timeout_ms]),
         {:ok, allocation} <- acquire(registry, opts, key, owner) do
      try do
        execute_once(allocation, request, timeout)
      after
        release(registry, allocation.lease)
      end
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  def execute(_), do: {:error, error(:invalid_request)}

  @spec reset(term(), pid(), keyword()) :: {:ok, map()} | {:error, map()}
  def reset(value, owner_pid, opts \\ []) when is_list(opts) do
    with {:ok, key} <- key(value), {:ok, owner} <- owner(owner_pid) do
      try do
        case Registry.reset(Keyword.get(opts, :registry, Registry), key, owner) do
          {:error, :stop_failed} -> {:error, error(:stop_failed)}
          result -> result
        end
      catch
        :exit, _ -> {:error, error(:registry_unavailable)}
      end
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @spec detach_owner(pid(), keyword()) :: :ok | {:error, map()}
  def detach_owner(owner_pid, opts \\ []) when is_list(opts) do
    with {:ok, owner} <- owner(owner_pid) do
      try do
        case Registry.detach_owner(Keyword.get(opts, :registry, Registry), owner) do
          {:error, :stop_failed} -> {:error, error(:stop_failed)}
          result -> result
        end
      catch
        :exit, _ -> {:error, error(:registry_unavailable)}
      end
    else
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @spec snapshot(GenServer.server()) :: {:ok, map()} | {:error, :registry_unavailable}
  def snapshot(registry \\ Registry) do
    try do
      {:ok, Registry.snapshot(registry)}
    catch
      :exit, _ -> {:error, :registry_unavailable}
    end
  end

  defp acquire(registry, opts, key, owner) do
    worker_opts =
      opts
      |> Map.take([:runner_path, :helper_source, :max_queued_cells, :max_output_bytes])
      |> Map.to_list()

    try do
      case Registry.acquire(registry, key, owner, worker_opts) do
        {:ok, allocation} -> {:ok, allocation}
        {:error, :capacity_exhausted} -> {:error, :capacity_exhausted}
        {:error, {:startup_failed, _detail}} -> {:error, :startup_failed}
        {:error, _reason} -> {:error, :registry_unavailable}
      end
    catch
      :exit, _ -> {:error, :registry_unavailable}
    end
  end

  defp release(registry, lease) do
    try do
      _ = Registry.release(registry, lease)
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp execute_once(%{pid: pid, session_mod: session_mod, reused?: reused}, request, timeout) do
    try do
      case session_mod.execute(pid, request, timeout) do
        {:ok, result} when is_map(result) -> {:ok, Map.put(result, :kernel_reused, reused)}
        {:error, result} when is_map(result) -> {:error, Map.put(result, :kernel_reused, reused)}
        other -> other
      end
    catch
      :exit, {:noproc, _} ->
        {:error, %{reason: :worker_unavailable, state_retained: false, kernel_reused: reused}}

      :exit, _ ->
        {:error, %{reason: :worker_exit, state_retained: false, kernel_reused: reused}}
    end
  end

  defp key(%Key{} = value), do: {:ok, value}
  defp key(_), do: {:error, :invalid_key}
  defp owner(value) when is_pid(value), do: {:ok, value}
  defp owner(_), do: {:error, :invalid_owner}

  defp request(opts) do
    request = Map.take(opts, [:code, :cwd, :bridge])

    if is_binary(request[:code]) and request.code != "",
      do: {:ok, request},
      else: {:error, :invalid_request}
  end

  defp timeout(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp timeout(_), do: {:error, :invalid_request}
  defp error(reason), do: %{reason: reason, state_retained: false}
end
