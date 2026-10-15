defmodule LemonCore.BrowserProvider.Command do
  @moduledoc """
  Bounded argv-only subprocesses for passive browser-provider probes.

  A separate, unlinked owner monitors the caller and owns the OS port. Killing
  a resolver callback therefore cannot orphan its command. Timeout, output
  overflow, and caller death kill the command's process tree before closing the
  port. Output is private to probes and must not enter diagnostics.

  `:input` is written verbatim (line-oriented helpers need a trailing newline).
  `:env` overrides selected inherited variables. `:accept_nonzero` returns a map
  with `:output` and `:status` instead of treating a nonzero exit as an error.
  """

  alias LemonCore.Secrets.SourceRunner

  @spec run([String.t()], keyword()) ::
          {:ok, binary() | %{output: binary(), status: integer()}} | {:error, atom()}
  def run(argv, opts \\ []) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner_monitor = Process.monitor(caller)
        result = execute(argv, opts, owner_monitor)
        send(caller, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :spawn_failed}
    end
  end

  defp execute([program | args], opts, owner_monitor) when is_binary(program) and is_list(args) do
    timeout = Keyword.get(opts, :timeout_ms, 2_000)
    max_output = Keyword.get(opts, :max_output_bytes, 65_536)
    input = Keyword.get(opts, :input, "")
    env = Keyword.get(opts, :env, %{})

    accept_nonzero = Keyword.get(opts, :accept_nonzero, false)

    with true <- is_integer(timeout) and timeout > 0 and is_integer(max_output) and max_output > 0,
         true <- is_binary(input) and Enum.all?(args, &valid_argument?/1),
         true <- valid_env?(env),
         {:ok, executable} <- SourceRunner.resolve_executable(program) do
      receive do
        {:DOWN, ^owner_monitor, :process, _, _} ->
          {:error, :cancelled}
      after
        0 ->
          port =
            Port.open({:spawn_executable, String.to_charlist(executable)}, [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:args, Enum.map(args, &String.to_charlist/1)},
              {:env,
               Enum.map(env, fn {key, value} ->
                 {String.to_charlist(key), String.to_charlist(value)}
               end)}
            ])

          try do
            if input != "", do: Port.command(port, input)
            deadline = System.monotonic_time(:millisecond) + timeout
            collect(port, deadline, max_output, [], 0, owner_monitor, accept_nonzero)
          after
            close(port)
          end
      end
    else
      false -> {:error, :invalid_config}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :spawn_failed}
  end

  defp execute(_, _, _), do: {:error, :invalid_config}

  defp valid_argument?(arg), do: is_binary(arg) and not String.contains?(arg, "\0")

  defp valid_env?(env) when is_map(env) do
    Enum.all?(env, fn {key, value} ->
      is_binary(key) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) and
        valid_argument?(value)
    end)
  end

  defp valid_env?(_), do: false

  defp collect(port, deadline, limit, chunks, size, owner_monitor, accept_nonzero) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > limit do
          terminate(port)
          {:error, :output_too_large}
        else
          collect(port, deadline, limit, [data | chunks], size, owner_monitor, accept_nonzero)
        end

      {^port, {:exit_status, status}} ->
        cond do
          accept_nonzero -> {:ok, %{output: output(chunks), status: status}}
          status == 0 -> {:ok, output(chunks)}
          true -> {:error, :exit_nonzero}
        end

      {:DOWN, ^owner_monitor, :process, _, _} ->
        terminate(port)
        {:error, :cancelled}
    after
      remaining ->
        terminate(port)
        {:error, :timeout}
    end
  end

  defp output(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp terminate(port) do
    # OTP's Unix child setup creates a new process group/session before exec.
    # Signal that group directly: a ps snapshot can time out or miss children
    # during spawn, leaving a live diagnostic subprocess behind. Also signal
    # the PID in case cancellation arrived before child setup made the group.
    with {:os_pid, pid} when pid > 1 <- Port.info(port, :os_pid),
         {:ok, kill} <- SourceRunner.resolve_executable("/bin/kill") do
      System.cmd(kill, ["-KILL", "--", "-#{pid}", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    close(port)
  rescue
    _ -> close(port)
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
