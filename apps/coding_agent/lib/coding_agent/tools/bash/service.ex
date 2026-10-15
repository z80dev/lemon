defmodule CodingAgent.Tools.Bash.Service do
  @moduledoc "Named, session/project-scoped services backed by ProcessManager."

  alias CodingAgent.{MutationLock, ProcessManager, ProcessStore}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  def execute(params, command, cwd, env, signal, opts) do
    owner = Keyword.get(opts, :session_id)
    project = Path.expand(Keyword.fetch!(opts, :project_cwd))

    with :ok <- validate_owner(owner),
         {:ok, name} <- validate_name(Map.get(params, "name")),
         {:ok, ready} <- validate_ready(Map.get(params, "ready")) do
      MutationLock.with_lock({:service, owner, project, name}, fn ->
        with :ok <- stop_previous(name, owner, project) do
          launch(name, command, cwd, env, ready, signal, owner, project, opts)
        end
      end)
    end
  end

  @doc "Resolve a service name in the exact session/project, or retain a process id."
  def resolve(reference, cwd, opts) do
    owner = Keyword.get(opts, :session_id)
    project = Path.expand(cwd)

    ProcessManager.list()
    |> Enum.filter(fn {_id, record} ->
      record.owner == owner and
        match?(%{name: ^reference, project: ^project}, Map.get(record, :service))
    end)
    |> Enum.max_by(fn {_id, record} -> record.service.generation end, fn -> nil end)
    |> case do
      nil -> reference
      {id, _record} -> id
    end
  end

  defp validate_owner(owner) when is_binary(owner) and owner != "", do: :ok
  defp validate_owner(_), do: {:error, "Named services require session_id"}

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,47}\z/, name),
      do: {:ok, name},
      else: {:error, "name must be 1-48 letters, numbers, dots, underscores or hyphens"}
  end

  defp validate_name(_), do: {:error, "name must be a string"}

  defp validate_ready(nil), do: {:ok, nil}

  defp validate_ready(ready) when is_map(ready) do
    log = Map.get(ready, "log")
    port = Map.get(ready, "port")
    host = Map.get(ready, "host", "127.0.0.1")
    timeout = Map.get(ready, "timeout_s", 30)

    cond do
      not is_nil(log) and not (is_binary(log) and log != "") ->
        {:error, "ready.log must be a non-empty regex string"}

      not is_nil(port) and not (is_integer(port) and port in 1..65_535) ->
        {:error, "ready.port must be an integer in 1..65535"}

      is_nil(log) and is_nil(port) ->
        {:error, "ready requires log and/or port"}

      not (is_binary(host) and host != "" and not String.contains?(host, <<0>>)) ->
        {:error, "ready.host must be a non-empty host string"}

      not (is_number(timeout) and timeout > 0 and timeout <= 3600) ->
        {:error, "ready.timeout_s must be greater than 0 and at most 3600 seconds"}

      true ->
        case if(log, do: Regex.compile(log), else: {:ok, nil}) do
          {:ok, regex} ->
            {:ok, %{log: regex, port: port, host: host, timeout_ms: ceil(timeout * 1000)}}

          {:error, _} ->
            {:error, "ready.log must be a valid regex"}
        end
    end
  end

  defp validate_ready(_), do: {:error, "ready must be an object"}

  defp stop_previous(name, owner, project) do
    id = resolve(name, project, session_id: owner)

    case ProcessStore.get(id) do
      {:error, :not_found} ->
        :ok

      {:ok, %{termination_confirmed: true}, _} ->
        :ok

      {:ok, _, _} ->
        with :ok <- ProcessManager.kill(id, :sigkill) do
          await_stopped(id, System.monotonic_time(:millisecond) + 5_000)
        end
    end
  end

  defp await_stopped(id, deadline) do
    case ProcessStore.get(id) do
      {:ok, %{termination_confirmed: true}, _} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error,
           "Previous service #{id} termination is unconfirmed; do not automatically rerun"}
        else
          Process.sleep(20)
          await_stopped(id, deadline)
        end
    end
  end

  defp launch(name, command, cwd, env, ready, signal, owner, project, opts) do
    result =
      ProcessManager.exec(
        command: command,
        cwd: cwd,
        env: env,
        owner: owner,
        owner_pid: Keyword.get(opts, :session_pid)
      )

    case result do
      {classification, id} when classification in [:ok, :queued] ->
        register(id, name, project)

        deadline =
          System.monotonic_time(:millisecond) + if(ready, do: ready.timeout_ms, else: 30_000)

        await_ready(id, name, ready, signal, deadline)

      {:error, {:outcome_unknown, id}} ->
        register(id, name, project)

        result(
          id,
          name,
          :unknown,
          false,
          "Launch outcome unknown; inspect proc://#{id}; do not automatically rerun",
          true
        )

      {:error, reason} ->
        {:error, "Service launch failed: #{inspect(reason)}"}
    end
  end

  defp register(id, name, project) do
    ProcessStore.put_service(id, %{
      name: name,
      project: project,
      generation: System.system_time(:microsecond)
    })
  end

  defp await_ready(id, name, ready, signal, deadline) do
    {:ok, state} = ProcessManager.poll(id, lines: 1000)

    output =
      Enum.join(Enum.reverse(state.logs) ++ [Map.get(state, :partial_line, "")], "\n")
      |> CodingAgent.BashExecutor.sanitize_output()

    {output, _, _} = CodingAgent.BashExecutor.truncate_tail(output, max_bytes: 50_000)

    cond do
      signal && AbortSignal.aborted?(signal) ->
        ProcessManager.kill(id, :sigkill)
        result(id, name, :canceled, false, "Service readiness canceled.\n" <> output, true)

      state.status not in [:running, :starting, :queued] ->
        result(
          id,
          name,
          state.status,
          false,
          "Service exited before readiness (exit code #{inspect(state.exit_code)}).\n" <> output,
          true
        )

      state.status == :running and ready?(ready, output, deadline) ->
        result(
          id,
          name,
          :running,
          false,
          "Service #{name} is ready. Inspect proc://#{name}.\n" <> output,
          false
        )

      System.monotonic_time(:millisecond) >= deadline ->
        result(
          id,
          name,
          state.status,
          true,
          "Service readiness timed out; service remains managed at proc://#{name}.\n" <> output,
          true
        )

      true ->
        Process.sleep(20)
        await_ready(id, name, ready, signal, deadline)
    end
  end

  defp ready?(nil, _output, _deadline), do: true

  defp ready?(ready, output, deadline) do
    (ready.log && Regex.match?(ready.log, output)) || port_ready?(ready, deadline)
  end

  defp port_ready?(%{port: nil}, _deadline), do: false

  defp port_ready?(ready, deadline) do
    timeout = max(1, min(100, deadline - System.monotonic_time(:millisecond)))

    case :gen_tcp.connect(
           String.to_charlist(ready.host),
           ready.port,
           [:binary, active: false],
           timeout
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp result(id, name, state, timed_out, text, error) do
    %AgentToolResult{
      content: [%TextContent{text: text}],
      is_error: error,
      details: %{
        process_id: id,
        service: %{name: name, state: state, ready: not error, timed_out: timed_out}
      }
    }
  end
end
