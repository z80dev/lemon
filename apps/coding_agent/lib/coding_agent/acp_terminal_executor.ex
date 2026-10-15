defmodule CodingAgent.ACPTerminalExecutor do
  @moduledoc """
  Foreground shell execution in an ACP client's native terminal.

  A guardian survives tool-worker cancellation long enough to kill and release
  the client terminal, including allocations which finish after cancellation.
  Client snapshots are bounded. If the client discarded output, results say so
  rather than claiming a complete local spill file exists.
  """
  alias CodingAgent.BashExecutor
  alias LemonAgent.AbortSignal

  @snapshot_bytes 1_048_576
  @request_timeout 60_000
  @poll_ms 250

  def execute(command, cwd, opts) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner = Process.monitor(caller)
        reply = fn result -> send(caller, {ref, result}) end

        case run(command, cwd, opts, owner, reply) do
          :already_replied -> :ok
          result -> reply.(result)
        end
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :acp_terminal_failed}
    end
  end

  defp run(command, cwd, opts, owner, reply) do
    run_id = Keyword.fetch!(opts, :run_id)
    {shell, shell_args} = BashExecutor.get_shell_config()
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout)
    signal = Keyword.get(opts, :signal)

    create =
      async_request(
        run_id,
        "terminal/create",
        %{
          "command" => shell,
          "args" => shell_args ++ [command],
          "cwd" => cwd,
          "outputByteLimit" => @snapshot_bytes
        }
        |> put_env(Keyword.get(opts, :env, %{}))
      )

    case await_create(create, owner, signal, deadline) do
      {:ok, %{"terminalId" => terminal_id}} when is_binary(terminal_id) and terminal_id != "" ->
        terminal(run_id, terminal_id, opts, owner, deadline)

      {:stopped, reason} ->
        reply.({:ok, result(%{output: "", truncated: false}, nil, reason, nil)})
        cleanup_late_create(create, run_id)
        :already_replied

      _ ->
        {:error, :acp_terminal_create_failed}
    end
  end

  # ACP `terminal/create` takes extra variables as `[%{name, value}]`.
  defp put_env(params, env) when map_size(env) == 0, do: params

  defp put_env(params, env) do
    entries =
      env
      |> Enum.sort()
      |> Enum.map(fn {name, value} -> %{"name" => name, "value" => value} end)

    Map.put(params, "env", entries)
  end

  defp await_create({pid, ref}, owner, signal, deadline) do
    case stopped(owner, signal, deadline) do
      nil ->
        receive do
          {^ref, response} -> response
          {:DOWN, ^owner, :process, _pid, _} -> {:stopped, :cancelled}
        after
          25 -> await_create({pid, ref}, owner, signal, deadline)
        end

      reason ->
        {:stopped, reason}
    end
  end

  defp cleanup_late_create({pid, ref}, run_id) do
    # Remain the request recipient until allocation finishes, avoiding a race
    # between cancellation and a just-delivered terminal/create response.
    receive do
      {^ref, {:ok, %{"terminalId" => id}}} -> cleanup(run_id, id, true)
      {^ref, _failure} -> :ok
    after
      @request_timeout + 1_000 -> Process.exit(pid, :kill)
    end
  end

  defp terminal(run_id, id, opts, owner, deadline) do
    on_terminal = Keyword.get(opts, :on_terminal)
    wait = async_request(run_id, "terminal/wait_for_exit", %{"terminalId" => id}, :infinity)

    state = %{
      run_id: run_id,
      id: id,
      opts: opts,
      owner: owner,
      deadline: deadline,
      wait: wait,
      poll: nil,
      next_poll: System.monotonic_time(:millisecond),
      output: "",
      truncated: false
    }

    try do
      if is_function(on_terminal, 1), do: on_terminal.(id)
      {state, exit_code, reason} = loop(state)
      if reason != :exited, do: request(run_id, "terminal/kill", %{"terminalId" => id}, 1_000)

      snapshot =
        case request(run_id, "terminal/output", %{"terminalId" => id}, 2_000) do
          {:ok, output} -> snapshot(output)
          _ -> %{output: state.output, truncated: state.truncated}
        end

      {:ok, result(snapshot, exit_code, reason, id)}
    after
      stop_request(wait)
      # release also kills a still-running command if an earlier callback raised.
      cleanup(run_id, id, true)
    end
  end

  defp loop(state) do
    case stopped(state.owner, Keyword.get(state.opts, :signal), state.deadline) do
      nil -> receive_terminal(maybe_poll(state))
      reason -> {state, nil, reason}
    end
  end

  defp receive_terminal(state) do
    {_pid, wait_ref} = state.wait
    owner = state.owner

    receive do
      {^wait_ref, {:ok, exit}} ->
        {state, exit["exitCode"], :exited}

      {^wait_ref, _} ->
        {state, nil, :cancelled}

      {:DOWN, ^wait_ref, :process, _pid, _} ->
        {state, nil, :cancelled}

      {:DOWN, ^owner, :process, _pid, _} ->
        {state, nil, :cancelled}

      {ref, response} when is_reference(ref) ->
        case state.poll do
          {_pid, ^ref} ->
            state =
              case response do
                {:ok, output} -> update_snapshot(state, snapshot(output))
                _ -> state
              end

            loop(%{state | poll: nil, next_poll: System.monotonic_time(:millisecond) + @poll_ms})

          _ ->
            loop(state)
        end

      {:DOWN, _ref, :process, _pid, _} ->
        loop(state)
    after
      25 -> loop(state)
    end
  end

  defp maybe_poll(%{poll: nil} = state) do
    if System.monotonic_time(:millisecond) >= state.next_poll do
      %{
        state
        | poll: async_request(state.run_id, "terminal/output", %{"terminalId" => state.id}, 2_000)
      }
    else
      state
    end
  end

  defp maybe_poll(state), do: state

  defp update_snapshot(state, current) do
    chunk =
      if String.starts_with?(current.output, state.output),
        do:
          binary_part(
            current.output,
            byte_size(state.output),
            byte_size(current.output) - byte_size(state.output)
          ),
        else: current.output

    callback = Keyword.get(state.opts, :on_chunk)
    if chunk != "" and is_function(callback, 1), do: callback.(chunk)
    %{state | output: current.output, truncated: current.truncated}
  end

  defp snapshot(output) do
    text = Map.get(output, "output", "")

    %{
      output: if(is_binary(text), do: BashExecutor.sanitize_output(text), else: ""),
      truncated: Map.get(output, "truncated", false) == true
    }
  end

  defp result(snapshot, exit_code, reason, id) do
    {output, truncated, _} = BashExecutor.truncate_tail(snapshot.output)

    path =
      if truncated and not snapshot.truncated do
        path = Path.join(System.tmp_dir!(), "lemon-acp-terminal-#{LemonCore.Id.uuid()}.log")

        File.open!(path, [:write, :exclusive], fn io ->
          File.chmod!(path, 0o600)
          :ok = IO.binwrite(io, snapshot.output)
        end)

        path
      end

    %BashExecutor.Result{
      output: output,
      exit_code: exit_code,
      cancelled: reason == :cancelled,
      timed_out: reason == :timed_out,
      truncated: truncated or snapshot.truncated,
      full_output_path: path,
      terminal_id: id,
      client_output_truncated: snapshot.truncated
    }
  end

  defp stopped(owner, signal, deadline) do
    receive do
      {:DOWN, ^owner, :process, _pid, _} -> :cancelled
    after
      0 ->
        cond do
          signal && AbortSignal.aborted?(signal) -> :cancelled
          System.monotonic_time(:millisecond) >= deadline -> :timed_out
          true -> nil
        end
    end
  end

  defp async_request(run_id, method, params, timeout \\ @request_timeout) do
    caller = self()
    tag = make_ref()

    pid =
      spawn(fn ->
        response = request(run_id, method, params, timeout)
        send(caller, {tag, response})
      end)

    {pid, tag}
  end

  defp stop_request({pid, _ref}), do: Process.exit(pid, :kill)

  defp cleanup(run_id, id, kill?) do
    if kill?, do: request(run_id, "terminal/kill", %{"terminalId" => id}, 1_000)
    request(run_id, "terminal/release", %{"terminalId" => id}, 1_000)
    :ok
  end

  defp request(run_id, method, params, timeout) do
    case LemonCore.ACPClientBridge.request(run_id, method, params, timeout) do
      {:ok, %{"result" => result}} when is_map(result) -> {:ok, result}
      {:ok, %{"result" => nil}} -> {:ok, %{}}
      {:ok, %{"error" => _}} -> {:error, :client_request_failed}
      {:ok, result} when is_map(result) -> {:ok, result}
      _ -> {:error, :client_request_failed}
    end
  end
end
