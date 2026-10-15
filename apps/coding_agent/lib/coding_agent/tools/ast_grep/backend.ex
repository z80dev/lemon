defmodule CodingAgent.Tools.AstGrep.Backend do
  @moduledoc false

  import LemonAgent.Tools.AbortHelpers, only: [aborted?: 1]

  @max_output_bytes 16 * 1024 * 1024

  # A directly-owned port avoids leaving an unobserved command task behind when
  # the tool is cancelled. No shell interprets the pattern, rewrite or paths.
  def run(executable, args, cwd, signal, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, Enum.map(args, &String.to_charlist/1)},
        {:cd, String.to_charlist(cwd)},
        {:env, [{~c"NO_COLOR", ~c"1"}]}
      ])

    try do
      await(port, signal, System.monotonic_time(:millisecond) + timeout_ms, [], 0)
    after
      close(port)
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, "Cannot execute ast-grep CLI: #{Exception.message(error)}"}
  end

  def run(_executable, _args, _cwd, _signal, _timeout_ms),
    do: {:error, "ast_grep_timeout_ms must be a positive integer"}

  defp await(port, signal, deadline, chunks, bytes) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      aborted?(signal) ->
        {:error, "Operation aborted"}

      remaining <= 0 ->
        {:error, "ast-grep timed out; narrow paths or increase :ast_grep_timeout_ms"}

      true ->
        receive do
          {^port, {:data, data}} ->
            total = bytes + byte_size(data)

            if total > @max_output_bytes do
              {:error,
               "ast-grep output exceeds the 16 MiB planning limit; narrow paths or pattern. No edits were applied."}
            else
              await(port, signal, deadline, [data | chunks], total)
            end

          {^port, {:exit_status, status}} ->
            {:ok, {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}}
        after
          min(remaining, 50) -> await(port, signal, deadline, chunks, bytes)
        end
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
