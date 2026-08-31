defmodule LemonCore.Secrets.SourceRunner do
  @moduledoc """
  Bounded argv-only runner for secret-manager CLIs.

  The child receives a minimal environment, stdin is closed, stdout and stderr
  are captured together and never surfaced, and the port is closed on timeout
  or output overflow. Callers receive only stable error kinds.
  """

  @base_env ~w(HOME USERPROFILE SYSTEMROOT PATH TMPDIR TEMP LANG LC_ALL XDG_CONFIG_HOME XDG_DATA_HOME)

  @type error_kind :: LemonCore.Secrets.Source.error_kind()

  @spec run([String.t()], keyword()) ::
          {:ok, %{output: binary(), byte_count: non_neg_integer()}} | {:error, error_kind()}
  def run([program | args], opts) when is_binary(program) and is_list(args) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    max_output_bytes = Keyword.fetch!(opts, :max_output_bytes)
    extra_env = Keyword.get(opts, :env, %{})

    with {:ok, executable} <- resolve_executable(program),
         {:ok, env} <- minimal_env(extra_env),
         {:ok, port} <- open_port(executable, args, env) do
      collect(port, timeout_ms, max_output_bytes)
    end
  end

  def run(_argv, _opts), do: {:error, :invalid_config}

  @spec executable_available?(String.t()) :: boolean()
  def executable_available?(program) when is_binary(program) do
    match?({:ok, _path}, resolve_executable(program))
  end

  def executable_available?(_program), do: false

  @spec resolve_executable(String.t()) :: {:ok, String.t()} | {:error, :binary_missing}
  def resolve_executable(program) do
    program = String.trim(program)

    resolved =
      cond do
        program == "" -> nil
        Path.type(program) == :absolute -> program
        String.contains?(program, ["/", "\\"]) -> nil
        true -> System.find_executable(program)
      end

    if is_binary(resolved) and File.regular?(resolved) and executable?(resolved) do
      {:ok, resolved}
    else
      {:error, :binary_missing}
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{access: access}} ->
        access in [:read_write, :read, :write] and executable_mode?(path)

      _ ->
        false
    end
  end

  defp executable_mode?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp minimal_env(extra_env) when is_map(extra_env) do
    if Enum.all?(extra_env, fn {key, value} -> safe_env_name?(key) and safe_env_value?(value) end) do
      inherited = Map.take(System.get_env(), @base_env)
      desired = Map.merge(inherited, extra_env) |> Map.put_new("NO_COLOR", "1")

      removals =
        System.get_env()
        |> Map.keys()
        |> Enum.reject(&Map.has_key?(desired, &1))
        |> Enum.map(fn key -> {String.to_charlist(key), false} end)

      additions =
        Enum.map(desired, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)

      {:ok, removals ++ additions}
    else
      {:error, :invalid_config}
    end
  end

  defp minimal_env(_extra_env), do: {:error, :invalid_config}

  defp safe_env_name?(value) when is_binary(value),
    do: Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, value)

  defp safe_env_name?(_), do: false

  defp safe_env_value?(value) when is_binary(value), do: not String.contains?(value, "\0")
  defp safe_env_value?(_), do: false

  defp open_port(executable, args, env) do
    if Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, "\0"))) do
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            {:args, Enum.map(args, &String.to_charlist/1)},
            {:env, env}
          ]
        )

      {:ok, port}
    else
      {:error, :invalid_config}
    end
  rescue
    _ -> {:error, :spawn_failed}
  end

  defp collect(port, timeout_ms, max_output_bytes) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, deadline, max_output_bytes, [], 0)
  end

  defp collect(port, deadline, max_output_bytes, chunks, byte_count) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        new_byte_count = byte_count + byte_size(data)

        if new_byte_count > max_output_bytes do
          close_port(port)
          {:error, :output_too_large}
        else
          collect(port, deadline, max_output_bytes, [data | chunks], new_byte_count)
        end

      {^port, {:exit_status, 0}} ->
        {:ok,
         %{output: chunks |> Enum.reverse() |> IO.iodata_to_binary(), byte_count: byte_count}}

      {^port, {:exit_status, _status}} ->
        {:error, :exit_nonzero}
    after
      remaining ->
        close_port(port)
        {:error, :timeout}
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
