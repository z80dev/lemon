defmodule LemonAutomation.CronCommandRunner do
  @moduledoc """
  Runs operator-owned no-agent cron commands through a supervised BEAM task.
  """

  alias LemonAutomation.{CronJob, CronRun}

  @max_output_bytes 12_000

  @spec submit(CronJob.t(), CronRun.t(), keyword()) ::
          {:ok, binary()} | {:error, binary()} | :timeout
  def submit(job, run, opts \\ [])

  def submit(%CronJob{command: command} = job, %CronRun{}, _opts) when is_binary(command) do
    command = String.trim(command)

    with :ok <- validate_command(command),
         {:ok, cwd} <- validate_cwd(job.cwd),
         {:ok, env} <- validate_env(job.env),
         {:ok, shell} <- shell_path() do
      run_port(shell, command, cwd, env, job.timeout_ms || 300_000)
    end
  end

  def submit(_job, _run, _opts), do: {:error, "command is required"}

  defp validate_command(""), do: {:error, "command is required"}
  defp validate_command(_command), do: :ok

  defp validate_cwd(nil), do: {:ok, nil}
  defp validate_cwd(""), do: {:ok, nil}

  defp validate_cwd(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error, "cwd does not exist or is not a directory"}
    end
  end

  defp validate_cwd(_cwd), do: {:error, "cwd must be a string"}

  defp validate_env(nil), do: {:ok, []}

  defp validate_env(env) when is_map(env) do
    env =
      env
      |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
      |> Enum.reject(fn {key, _value} -> String.trim(key) == "" end)

    {:ok, env}
  end

  defp validate_env(_env), do: {:error, "env must be a map"}

  defp shell_path do
    case System.find_executable("sh") do
      nil -> {:error, "sh executable not found"}
      path -> {:ok, path}
    end
  end

  defp run_port(shell, command, cwd, env, timeout_ms) do
    opts =
      [:binary, :exit_status, :stderr_to_stdout, :hide, args: ["-lc", command], env: env]
      |> maybe_put_cwd(cwd)

    port = Port.open({:spawn_executable, shell}, opts)
    collect(port, [], 0, false, monotonic_ms() + timeout_ms)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "Exit: #{inspect(reason)}"}
  end

  defp maybe_put_cwd(opts, nil), do: opts
  defp maybe_put_cwd(opts, cwd), do: [{:cd, cwd} | opts]

  defp collect(port, chunks, byte_count, truncated?, deadline_ms) do
    timeout = max(deadline_ms - monotonic_ms(), 0)

    receive do
      {^port, {:data, data}} ->
        {chunks, byte_count, truncated?} = append_output(chunks, byte_count, truncated?, data)
        collect(port, chunks, byte_count, truncated?, deadline_ms)

      {^port, {:exit_status, 0}} ->
        {:ok, output(chunks, truncated?)}

      {^port, {:exit_status, status}} ->
        {:error, "Command exited #{status}: #{output(chunks, truncated?)}"}
    after
      timeout ->
        Port.close(port)
        :timeout
    end
  end

  defp append_output(chunks, byte_count, truncated?, data) do
    remaining = @max_output_bytes - byte_count

    cond do
      remaining <= 0 ->
        {chunks, byte_count, true}

      byte_size(data) <= remaining ->
        {[data | chunks], byte_count + byte_size(data), truncated?}

      true ->
        <<prefix::binary-size(remaining), _rest::binary>> = data
        {[prefix | chunks], @max_output_bytes, true}
    end
  end

  defp output(chunks, truncated?) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> maybe_mark_truncated(truncated?)
  end

  defp maybe_mark_truncated(output, true), do: output <> "\n[output truncated]"
  defp maybe_mark_truncated(output, false), do: output

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
