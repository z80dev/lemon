defmodule CodingAgent.Tools.ExecuteCodePersistentTest do
  use ExUnit.Case, async: false

  alias CodingAgent.BashExecutor
  alias CodingAgent.Tools.ExecuteCode
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias CodingAgent.Tools.ExecuteCodePersistentTest.{FakePythonRepl, FakeRpcServer}

  @state CodingAgent.Tools.ExecuteCodePersistentTest.State
  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    if System.find_executable("python3") == nil do
      {:skip, "persistent key construction requires python3"}
    else
      test_pid = self()
      {:ok, _state} = Agent.start_link(fn -> initial_state(test_pid) end, name: @state)

      on_exit(fn ->
        if pid = Process.whereis(@state), do: Agent.stop(pid)
      end)

      %{cwd: cwd}
    end
  end

  test "retains a reused kernel and resets it before a cell", %{cwd: cwd} do
    set_response({:ok, %{output: "answer", state_retained: true, kernel_reused: true}})

    result = execute(cwd, %{"script" => "print(answer)", "reset" => true})

    # The per-cell bridge is private at creation: both the base and the rpc
    # directory are exactly 0700, stat'd inside the fake server while the cell
    # still owns them (the after-block removes the base before execute
    # returns), and the base is gone once the cell is over.
    assert_received {:rpc_started, bridge_ctx, modes}
    assert {:ok, base_stat} = modes.base
    assert Bitwise.band(base_stat.mode, 0o777) == 0o700
    assert {:ok, rpc_stat} = modes.rpc
    assert Bitwise.band(rpc_stat.mode, 0o777) == 0o700

    bridge_base = Path.dirname(bridge_ctx.rpc_dir)

    assert text(result) == "answer"
    assert result.details.persistent
    assert result.details.kernel_reused
    assert result.details.reset_performed
    assert result.details.state_retained
    refute File.exists?(bridge_base)
    assert_receive {:reset, _key, owner, _opts}
    assert owner == self()
    assert_receive {:execute, request}
    assert request.helper_source =~ "def _configure"
    assert request.code =~ "from lemon_tools import"
  end

  test "ordinary Python exceptions retain state rather than falling back", %{cwd: cwd} do
    set_response({
      :error,
      %{
        reason: :exception,
        state_retained: true,
        kernel_reused: true,
        output: "Traceback",
        exception: %{name: "ValueError", message: "bad value"}
      }
    })

    result = execute(cwd, %{"script" => "raise ValueError('bad value')"})

    assert result.details.persistent
    assert result.details.state_retained
    assert result.details.kernel_reused
    refute Map.has_key?(result.details, :fallback_reason)
    assert text(result) =~ "ValueError"
    assert text(result) =~ "Traceback"
  end

  test "timeouts discard state and are not retried", %{cwd: cwd} do
    set_response({
      :error,
      %{reason: :timeout, state_retained: false, kernel_reused: false, output: "partial"}
    })

    result = execute(cwd, %{"script" => "while True: pass", "timeout_ms" => 1_000})

    assert result.details.persistent
    refute result.details.state_retained
    assert text(result) =~ "timed out"
    assert_receive {:execute, _request}
    refute_receive {:fallback_runner, _command}
  end

  test "abort preserves RPC statistics and the resulting trust classification", %{cwd: cwd} do
    set_response(:block)

    set_stats(%{
      calls: 1,
      denied: 0,
      errors: 0,
      bytes: 8,
      tools_used: MapSet.new(["webfetch"]),
      seen_ids: MapSet.new([1])
    })

    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        opts = [
          settings_manager: settings(),
          session_id: "session-1",
          session_pid: self(),
          agent_id: "agent-1",
          python_repl: FakePythonRepl,
          rpc_server: FakeRpcServer,
          python_repl_registry: self()
        ]

        ExecuteCode.execute("call-1", %{"script" => "mutate()"}, signal, nil, cwd, opts)
      end)

    assert_receive {:execute, _request}
    assert_receive {:rpc_started, %{signal: cell_signal}, _modes}
    refute cell_signal == signal

    :ok = AbortSignal.abort(signal)

    result = Task.await(task, 5_000)
    assert result.details.persistent
    refute result.details.state_retained
    assert result.trust == :untrusted
    assert text(result) =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    assert result.details.rpc_calls == 1
    assert result.details.rpc_tools == ["webfetch"]
    assert AbortSignal.aborted?(cell_signal)
    assert_receive {:rpc_aborted, _server}
    assert text(result) =~ "Script cancelled."
  end

  test "outer execute caller death kills its linked facade task", %{cwd: cwd} do
    outer =
      spawn(fn ->
        opts = [
          settings_manager: settings(),
          session_id: "session-1",
          session_pid: self(),
          agent_id: "agent-1",
          python_repl: FakePythonRepl,
          rpc_server: FakeRpcServer,
          python_repl_registry: self()
        ]

        ExecuteCode.execute("call-1", %{"script" => "mutate()"}, nil, nil, cwd, opts)
      end)

    assert_receive {:facade_pid, facade}
    assert_receive {:execute, _request}
    assert_receive {:rpc_started, %{rpc_dir: rpc_dir}}
    base = Path.dirname(rpc_dir)

    monitor = Process.monitor(facade)

    Process.exit(outer, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^facade, _reason}, 5_000
    assert :ok = await_absent(base)
  end

  test "worker crashes never replay active code in a new interpreter", %{cwd: cwd} do
    set_response({:error, %{reason: :worker_exit, state_retained: false, kernel_reused: false}})

    result = execute(cwd, %{"script" => "mutate()"})

    assert result.details.persistent
    refute result.details.state_retained
    assert text(result) =~ "worker_exit"
    assert_receive {:execute, _request}
    refute_receive {:execute, _request}
    refute_receive {:fallback_runner, _command}
  end

  test "missing session scope falls back before a kernel is started", %{cwd: cwd} do
    result =
      ExecuteCode.execute(
        "call-1",
        %{"script" => "print('fallback')"},
        nil,
        nil,
        cwd,
        fallback_opts()
      )

    assert text(result) == "fallback"
    refute result.details.persistent
    assert result.details.fallback_reason == :missing_session_scope
    assert_receive {:fallback_runner, _command}
    refute_receive {:execute, _request}
  end

  for reason <- [:capacity_exhausted, :registry_unavailable, :startup_failed] do
    test "#{reason} falls back only before a session cell starts and preserves reset metadata", %{
      cwd: cwd
    } do
      set_response({:error, %{reason: unquote(reason), state_retained: false}})

      result = execute(cwd, %{"script" => "print('fallback')", "reset" => true}, fallback_opts())

      refute result.details.persistent
      assert result.details.fallback_reason == unquote(reason)
      assert result.details.reset_performed
      assert_receive {:reset, _key, _owner, _opts}
      assert_receive {:execute, _request}
      assert_receive {:fallback_runner, _command}
    end
  end

  for reason <- [:registry_unavailable, :stop_failed] do
    test "reset #{reason} falls back before a session cell starts", %{cwd: cwd} do
      set_reset({:error, %{reason: unquote(reason)}})

      result = execute(cwd, %{"script" => "print('fallback')", "reset" => true}, fallback_opts())

      refute result.details.persistent
      assert result.details.fallback_reason == unquote(reason)
      refute result.details.reset_performed
      assert_receive {:reset, _key, _owner, _opts}
      assert_receive {:fallback_runner, _command}
      refute_receive {:execute, _request}
    end
  end

  test "reset failures after an admission boundary are errors, not fallbacks", %{cwd: cwd} do
    set_reset({:error, %{reason: :queue_full}})

    result = execute(cwd, %{"script" => "queued()", "reset" => true}, fallback_opts())

    assert result.details.persistent
    assert result.details.reason == {:reset_failed, :queue_full}
    assert_receive {:reset, _key, _owner, _opts}
    refute_receive {:execute, _request}
    refute_receive {:fallback_runner, _command}
  end

  test "a full kernel queue is an error, not a fallback", %{cwd: cwd} do
    set_response({:error, %{reason: :queue_full, state_retained: true, kernel_reused: true}})

    result = execute(cwd, %{"script" => "queued()"}, fallback_opts())

    assert result.details.persistent
    assert result.details.state_retained
    assert text(result) =~ "queue_full"
    refute_receive {:fallback_runner, _command}
  end

  test "keys change with scope agent helpers and preserve no private identity in details", %{
    cwd: cwd
  } do
    set_response({:ok, %{output: "one", state_retained: true, kernel_reused: false}})
    _ = execute(cwd, %{"script" => "print(1)"})
    assert_receive {:execute, first}

    set_response({:ok, %{output: "two", state_retained: true, kernel_reused: false}})

    result =
      execute(cwd, %{"script" => "print(2)"},
        session_id: "other-session",
        agent_id: "other-agent",
        settings_manager: settings(%{tools: ["read"]})
      )

    assert_receive {:execute, second}
    refute first.key.digest == second.key.digest
    assert second.key.scope_id == "other-session"
    assert second.key.agent_id == "other-agent"
    assert second.key.helpers == ["read"]

    refute Map.has_key?(result.details, :key)
    refute Map.has_key?(result.details, :session_id)
    refute Map.has_key?(result.details, :agent_id)
    refute Map.has_key?(result.details, :token)
    refute Map.has_key?(result.details, :bridge)
  end

  test "per-cell RPC statistics and web trust are retained", %{cwd: cwd} do
    set_stats(%{
      calls: 2,
      denied: 1,
      errors: 0,
      bytes: 88,
      tools_used: MapSet.new(["read", "webfetch"]),
      seen_ids: MapSet.new([1, 2])
    })

    set_response({:ok, %{output: "internet", state_retained: true, kernel_reused: true}})
    result = execute(cwd, %{"script" => "print(webfetch('https://example.test'))"})

    assert result.trust == :untrusted
    assert text(result) =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    assert result.details.rpc_calls == 2
    assert result.details.rpc_denied == 1
    assert result.details.rpc_bytes == 88
    assert result.details.rpc_tools == ["read", "webfetch"]
  end

  defp execute(cwd, params, extra \\ []) do
    opts =
      [
        settings_manager: settings(),
        session_id: "session-1",
        session_pid: self(),
        agent_id: "agent-1",
        python_repl: FakePythonRepl,
        rpc_server: FakeRpcServer,
        python_repl_registry: self(),
        clock: fn -> System.monotonic_time(:millisecond) end
      ]
      |> Keyword.merge(extra)

    ExecuteCode.execute("call-1", params, nil, nil, cwd, opts)
  end

  defp fallback_opts do
    [
      settings_manager: settings(),
      python_repl: FakePythonRepl,
      rpc_server: FakeRpcServer,
      script_runner: fn command, _cwd, _opts ->
        test_pid = Agent.get(@state, & &1.test_pid)
        send(test_pid, {:fallback_runner, command})

        {:ok,
         %BashExecutor.Result{
           output: "fallback",
           exit_code: 0,
           cancelled: false,
           truncated: false
         }}
      end
    ]
  end

  defp settings(overrides \\ %{}) do
    %{tools: %{execute_code: Map.merge(%{enabled: true, kernel_mode: "session"}, overrides)}}
  end

  defp set_response(response), do: Agent.update(@state, &Map.put(&1, :response, response))
  defp set_reset(reset), do: Agent.update(@state, &Map.put(&1, :reset, reset))
  defp set_stats(stats), do: Agent.update(@state, &Map.put(&1, :stats, stats))

  defp initial_state(test_pid) do
    %{
      test_pid: test_pid,
      response: {:ok, %{output: "ok", state_retained: true, kernel_reused: false}},
      reset: {:ok, %{reset_performed: true}},
      stats: %{
        calls: 0,
        denied: 0,
        errors: 0,
        bytes: 0,
        tools_used: MapSet.new(),
        seen_ids: MapSet.new()
      }
    }
  end

  defp await_absent(path, attempts \\ 100)

  defp await_absent(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      Process.sleep(10)
      await_absent(path, attempts - 1)
    else
      :ok
    end
  end

  defp await_absent(path, 0), do: flunk("bridge directory was not removed: #{path}")

  defp text(%AgentToolResult{content: [%TextContent{text: text} | _]}), do: text

  defmodule FakePythonRepl do
    @state CodingAgent.Tools.ExecuteCodePersistentTest.State

    def reset(key, owner_pid, opts) do
      state = Agent.get(@state, & &1)
      send(state.test_pid, {:reset, key, owner_pid, opts})
      state.reset
    end

    def execute(request) do
      state = Agent.get(@state, & &1)
      send(state.test_pid, {:facade_pid, self()})
      send(state.test_pid, {:execute, request})

      case state.response do
        :block -> Process.sleep(:infinity)
        response -> response
      end
    end
  end

  defmodule FakeRpcServer do
    @state CodingAgent.Tools.ExecuteCodePersistentTest.State

    def start_link(ctx) do
      state = Agent.get(@state, & &1)
      send(state.test_pid, {:rpc_started, ctx, bridge_modes(ctx.rpc_dir)})
      {:ok, make_ref()}
    end

    defp bridge_modes(rpc_dir) do
      %{base: File.stat(Path.dirname(rpc_dir)), rpc: File.stat(rpc_dir)}
    end

    def abort(server) do
      state = Agent.get(@state, & &1)
      send(state.test_pid, {:rpc_aborted, server})
      :ok
    end

    def stats(_server), do: Agent.get(@state, & &1.stats)

    def stop(server) do
      state = Agent.get(@state, & &1)
      send(state.test_pid, {:rpc_stopped, server})
      :ok
    end
  end
end
