defmodule CodingAgent.ExecutionNode.HostCommand do
  @moduledoc false

  # Execute only worker-selected inspection programs, never shell interpolation.
  # Keep timeout/output boundaries before accumulation; never return diagnostics.
  def run(name, args, opts \\ []) when is_binary(name) and is_list(args) do
    case System.find_executable(name) do
      nil ->
        {:error, :not_installed}

      executable ->
        task = Task.async(fn -> execute(executable, args, opts) end)
        timeout = Keyword.get(opts, :timeout_ms, 2_000)

        case Task.yield(task, timeout + 100) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, :inspection_timeout}
        end
    end
  end

  defp execute(executable, args, opts) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:env, [{~c"LC_ALL", ~c"C"}]}
      ])

    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 2_000)

    try do
      if input = Keyword.get(opts, :input), do: Port.command(port, input)
      receive_output(port, [], 0, Keyword.get(opts, :max_bytes, 65_536), deadline)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> {:error, :inspection_unavailable}
  end

  defp receive_output(port, chunks, bytes, limit, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when bytes + byte_size(data) <= limit ->
        receive_output(port, [data | chunks], bytes + byte_size(data), limit, deadline)

      {^port, {:data, _}} ->
        {:error, :inspection_output_limit}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()}

      {^port, {:exit_status, _}} ->
        {:error, :inspection_failed}
    after
      timeout -> {:error, :inspection_timeout}
    end
  end
end
