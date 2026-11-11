defmodule LemonCore.Service.Command do
  @moduledoc false

  def run(executable, args, opts, extra \\ []) do
    runner = Keyword.get(opts, :command_runner, &execute/3)
    runner.(executable, args, Keyword.merge([stderr_to_stdout: true], extra))
  rescue
    _ -> {"", 127}
  catch
    :exit, _ -> {"", 127}
  end

  def ok(executable, args, opts, extra \\ []) do
    case run(executable, args, opts, extra) do
      {_, 0} -> :ok
      _ -> {:error, :service_command_failed}
    end
  end

  defp execute(executable, args, opts) do
    {input, opts} = Keyword.pop(opts, :input)
    {timeout, opts} = Keyword.pop(opts, :timeout, 180_000)

    if is_binary(input) do
      executable = System.find_executable(executable) || executable

      env =
        Enum.map(Keyword.get(opts, :env, []), fn {key, value} ->
          {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
        end)

      # The bounded reader in node join requires EOF after the one code line.
      # A pipe closes it without placing the credential in argv or environment.
      script = "IFS= read -r line || exit 2; printf '%s\\n' \"$line\" | \"$@\""

      port =
        Port.open({:spawn_executable, ~c"/bin/sh"}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: ["-c", script, "lemon-service-input", executable | args],
          env: env
        ])

      true = Port.command(port, input)
      collect(port, System.monotonic_time(:millisecond) + timeout, "")
    else
      task =
        Task.async(fn ->
          try do
            System.cmd(executable, args, opts)
          rescue
            _ -> {"", 127}
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {"", 124}
      end
    end
  end

  defp collect(port, deadline, output) do
    receive do
      {^port, {:data, bytes}} ->
        combined = output <> bytes

        bounded =
          if byte_size(combined) > 8192,
            do: binary_part(combined, byte_size(combined) - 8192, 8192),
            else: combined

        collect(port, deadline, bounded)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        Port.close(port)
        {"enrollment_outcome_unknown", 124}
    end
  end
end
