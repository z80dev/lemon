defmodule CodingAgent.CoordinatorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Coordinator
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent}

  @moduletag :tmp_dir

  defmodule ControlledSession do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      test_pid = Keyword.fetch!(opts, :test_pid)
      test_ref = Process.monitor(test_pid)
      session_id = "controlled-session-#{System.unique_integer([:positive])}"
      send(test_pid, {:session_starting, self(), session_id})

      state = %{
        test_pid: test_pid,
        test_ref: test_ref,
        session_id: session_id,
        subscriber: nil,
        prompt_error: Keyword.get(opts, :prompt_error),
        gate_prompt: Keyword.get(opts, :gate_prompt, false),
        gate_cleanup: Keyword.get(opts, :gate_cleanup, false)
      }

      if Keyword.get(opts, :gate_start, false) do
        receive do
          :release_start -> {:ok, state}
          {:DOWN, ^test_ref, :process, ^test_pid, _reason} -> {:stop, :normal}
        end
      else
        {:ok, state}
      end
    end

    @impl true
    def handle_call(:get_stats, _from, state) do
      {:reply, %{session_id: state.session_id}, state}
    end

    def handle_call({:subscribe, subscriber, :direct, _opts}, _from, state) do
      session = self()
      unsubscribe = fn -> GenServer.cast(session, {:unsubscribe, subscriber}) end
      send(state.test_pid, {:session_subscribed, self(), subscriber})
      {:reply, unsubscribe, %{state | subscriber: subscriber}}
    end

    def handle_call({:prompt, text, _opts}, _from, state) do
      send(state.test_pid, {:session_prompted, self(), text})

      cond do
        state.gate_prompt ->
          receive do
            :release_prompt ->
              reply = if state.prompt_error, do: {:error, state.prompt_error}, else: :ok
              {:reply, reply, state}

            {:DOWN, ref, :process, _pid, _reason} when ref == state.test_ref ->
              {:stop, :normal, state}
          end

        state.prompt_error ->
          {:reply, {:error, state.prompt_error}, state}

        true ->
          {:reply, :ok, state}
      end
    end

    @impl true
    def handle_cast(:abort, state) do
      send(state.test_pid, {:session_aborted, self()})
      {:noreply, state}
    end
    def handle_cast({:unsubscribe, _subscriber}, state), do: {:noreply, state}

    @impl true
    def handle_info({:complete, text}, state) do
      message = %LemonAi.Types.AssistantMessage{
        content: [%LemonAi.Types.TextContent{text: text}]
      }

      send(state.subscriber, {:session_event, state.session_id, {:agent_end, [message]}})
      {:noreply, state}
    end

    def handle_info({:fail, reason}, state) do
      send(state.subscriber, {:session_event, state.session_id, {:error, reason, []}})
      {:noreply, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{test_ref: ref} = state) do
      {:stop, :normal, state}
    end

    @impl true
    def terminate(_reason, state) do
      send(state.test_pid, {:session_cleanup_started, self()})

      if state.gate_cleanup && Process.alive?(state.test_pid) do
        receive do
          :release_cleanup -> :ok
          {:DOWN, ref, :process, _pid, _reason} when ref == state.test_ref -> :ok
        end
      end

      :ok
    end
  end

  defp mock_model do
    %Model{
      id: "coordinator-controlled-model",
      name: "Coordinator Controlled Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096
    }
  end

  defp coordinator_opts(tmp_dir, overrides \\ []) do
    Keyword.merge([cwd: tmp_dir, model: mock_model(), default_timeout: 5_000], overrides)
  end

  defp start_coordinator(tmp_dir, opts \\ []) do
    start_supervised!({Coordinator, coordinator_opts(tmp_dir, opts)})
  end

  defp start_controlled_coordinator(tmp_dir, session_opts \\ [], coordinator_opts \\ []) do
    coordinator = start_coordinator(tmp_dir, coordinator_opts)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    test_pid = self()

    starter = fn _opts ->
      child_spec = %{
        id: make_ref(),
        start: {ControlledSession, :start_link, [Keyword.put(session_opts, :test_pid, test_pid)]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      }

      DynamicSupervisor.start_child(supervisor, child_spec)
    end

    :sys.replace_state(coordinator, &%{&1 | session_starter: starter})
    coordinator
  end

  defp run_async(coordinator, specs, opts \\ []) do
    test_pid = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        try do
          results = Coordinator.run_subagents(coordinator, specs, opts)
          send(test_pid, {:results, ref, results})
        catch
          :exit, reason -> send(test_pid, {:caller_exit, ref, reason})
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    ref
  end

  defp track_session(pid) do
    ref = Process.monitor(pid)

    on_exit(fn ->
      cleanup_ref = Process.monitor(pid)
      send(pid, :release_start)
      send(pid, :release_prompt)
      send(pid, :release_cleanup)

      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :shutdown, 5_000)
        catch
          :exit, _ -> Process.exit(pid, :kill)
        end
      end

      receive do
        {:DOWN, ^cleanup_ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> flunk("controlled session did not exit during teardown")
      end
    end)

    ref
  end

  defp started_session(prompt) do
    assert_receive {:session_prompted, pid, ^prompt}, 1_000
    ref = track_session(pid)
    assert_receive {:session_starting, ^pid, session_id}, 1_000
    assert_receive {:session_subscribed, ^pid, subscriber}, 1_000
    assert is_pid(subscriber)
    assert subscriber != self()
    {pid, ref, session_id, subscriber}
  end

  describe "start_link/1" do
    test "starts with cwd and model", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(tmp_dir)
      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []
    end

    test "starts with custom name", %{tmp_dir: tmp_dir} do
      name = :"coordinator_test_#{System.unique_integer([:positive])}"
      start_coordinator(tmp_dir, name: name)
      assert Coordinator.list_active(name) == []
    end

    test "fails without required options" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = Coordinator.start_link(model: mock_model())
      assert {:error, _} = Coordinator.start_link(cwd: System.tmp_dir!())
    end

    test "accepts thinking level and default timeout", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(tmp_dir, thinking_level: :high, default_timeout: 60_000)
      state = :sys.get_state(coordinator)
      assert state.thinking_level == :high
      assert state.default_timeout == 60_000
    end
  end

  describe "run_subagent/2" do
    test "returns the visible assistant answer", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      parent = self()

      spawn(fn ->
        send(parent, {:single_result, Coordinator.run_subagent(coordinator, prompt: "Hello")})
      end)

      {pid, ref, _session_id, _worker} = started_session("Hello")
      send(pid, {:complete, "Visible answer"})
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:single_result, {:ok, "Visible answer"}}, 1_000
      assert Coordinator.list_active(coordinator) == []
    end

    test "returns the provider failure to the caller", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      parent = self()

      spawn(fn ->
        send(parent, {:single_result, Coordinator.run_subagent(coordinator, prompt: "Fail")})
      end)

      {pid, ref, _session_id, _worker} = started_session("Fail")
      send(pid, {:fail, :provider_unavailable})
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:single_result, {:error, {:error, :provider_unavailable}}}, 1_000
    end

    test "returns an error for an unknown subagent", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)

      assert {:error, {:error, "Unknown subagent: nonexistent_agent"}} =
               Coordinator.run_subagent(coordinator, prompt: "Hello", subagent: "nonexistent_agent")

      refute_receive {:session_starting, _, _}
      assert Coordinator.list_active(coordinator) == []
    end

    test "rejects an empty prompt without admitting a session", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)

      assert {:error, {:error, "Prompt must be a non-empty string"}} =
               Coordinator.run_subagent(coordinator, prompt: "")

      refute_receive {:session_starting, _, _}
      assert Coordinator.list_active(coordinator) == []
    end

    test "a rejected prompt cleans up its admitted session", %{tmp_dir: tmp_dir} do
      coordinator =
        start_controlled_coordinator(tmp_dir, prompt_error: :already_streaming, gate_prompt: true)
      call = run_async(coordinator, [%{prompt: "Rejected prompt"}])
      {pid, ref, session_id, _worker} = started_session("Rejected prompt")
      send(pid, :release_prompt)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call,
                      [%{status: :error, error: :already_streaming, session_id: ^session_id}]},
                     1_000
      assert Coordinator.list_active(coordinator) == []
    end

    test "an admission failure returns its error and leaves no active ID", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(tmp_dir)
      :sys.replace_state(coordinator, &%{&1 | session_starter: fn _opts -> {:error, :admission_failed} end})

      assert [%{status: :error, result: nil, error: :admission_failed, session_id: nil}] =
               Coordinator.run_subagents(coordinator, [%{prompt: "Admission failure"}])

      assert Coordinator.list_active(coordinator) == []
    end

    test "standalone linked admission still returns its completed result", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(tmp_dir)
      test_pid = self()
      starter = fn _opts -> ControlledSession.start_link(test_pid: test_pid) end
      :sys.replace_state(coordinator, &%{&1 | session_starter: starter})

      call = run_async(coordinator, [%{prompt: "Linked admission"}])
      {pid, ref, session_id, _worker} = started_session("Linked admission")
      send(pid, {:complete, "linked answer"})
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call,
                      [%{status: :completed, result: "linked answer", session_id: ^session_id}]},
                     1_000
      assert Coordinator.list_active(coordinator) == []
    end
  end

  describe "run_subagents/3" do
    test "runs concurrently and retains spec order across out-of-order completion and failures", %{
      tmp_dir: tmp_dir
    } do
      coordinator = start_controlled_coordinator(tmp_dir)

      call = run_async(coordinator, [
        %{prompt: "First"},
        %{prompt: "Invalid", subagent: "nonexistent_subagent"},
        %{prompt: "Third"}
      ])

      {first, first_ref, first_id, first_worker} = started_session("First")
      {third, third_ref, third_id, third_worker} = started_session("Third")
      assert first_worker != third_worker
      %{active_subagents: active} = :sys.get_state(coordinator)
      assert Enum.any?(active, fn {_id, subagent} -> subagent.pid == first end)
      assert Enum.any?(active, fn {_id, subagent} -> subagent.pid == third end)
      send(third, {:complete, "third answer"})
      assert_receive {:DOWN, ^third_ref, :process, ^third, :shutdown}, 1_000
      refute_receive {:results, ^call, _}
      send(first, {:complete, "first answer"})
      assert_receive {:DOWN, ^first_ref, :process, ^first, :shutdown}, 1_000

      assert_receive {:results, ^call, [first_result, invalid_result, third_result]}, 1_000
      assert %{status: :completed, result: "first answer", error: nil, session_id: ^first_id} = first_result
      assert %{status: :error, error: "Unknown subagent: nonexistent_subagent", session_id: nil} = invalid_result
      assert %{status: :completed, result: "third answer", error: nil, session_id: ^third_id} = third_result
      assert length(Enum.uniq(Enum.map([first_result, invalid_result, third_result], & &1.id))) == 3
      assert Coordinator.list_active(coordinator) == []
    end

    test "empty specs return empty results", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      assert Coordinator.run_subagents(coordinator, []) == []
      refute_receive {:session_starting, _, _}
    end

    test "a second caller can run while another batch is active", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      first_call = run_async(coordinator, [%{prompt: "First caller"}])
      {first, first_ref, _, _} = started_session("First caller")
      second_call = run_async(coordinator, [%{prompt: "Second caller"}])
      {second, second_ref, _, _} = started_session("Second caller")
      send(second, {:complete, "second"})
      assert_receive {:DOWN, ^second_ref, :process, ^second, :shutdown}, 1_000
      assert_receive {:results, ^second_call, [%{status: :completed, result: "second"}]}, 1_000
      refute_receive {:results, ^first_call, _}
      send(first, {:complete, "first"})
      assert_receive {:DOWN, ^first_ref, :process, ^first, :shutdown}, 1_000
      assert_receive {:results, ^first_call, [%{status: :completed, result: "first"}]}, 1_000
    end
  end

  describe "timeout handling" do
    test "zero timeout does not admit a session", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      assert [%{status: :timeout, result: nil, error: :timeout, session_id: nil}] =
               Coordinator.run_subagents(coordinator, [%{prompt: "Never start"}], timeout: 0)
      refute_receive {:session_starting, _, _}
      assert Coordinator.list_active(coordinator) == []
    end

    test "execution timeout cleans up a running session", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      call = run_async(coordinator, [%{prompt: "Timeout"}])
      {pid, ref, session_id, _worker} = started_session("Timeout")
      %{batches: batches} = :sys.get_state(coordinator)
      [batch_ref] = Map.keys(batches)
      send(coordinator, {:batch_timeout, batch_ref})
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call, [%{status: :timeout, result: nil, error: :timeout, session_id: ^session_id}]}, 1_000
      assert Coordinator.list_active(coordinator) == []
    end

    test "the default deadline includes session admission", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir, gate_start: true)
      call = run_async(coordinator, [%{prompt: "Admission timeout"}])
      assert_receive {:session_starting, pid, _session_id}, 1_000
      ref = track_session(pid)
      [id] = Coordinator.list_active(coordinator)
      %{batches: batches} = :sys.get_state(coordinator)
      [batch_ref] = Map.keys(batches)
      assert %{timer: timer} = Map.fetch!(batches, batch_ref)
      assert Process.read_timer(timer) > 0
      # Deliver the real deadline message at the controlled admission boundary.
      send(coordinator, {:batch_timeout, batch_ref})
      assert [^id] = Coordinator.list_active(coordinator)
      send(pid, :release_start)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call, [%{id: ^id, status: :timeout, error: :timeout, session_id: nil}]}, 1_000
      refute_receive {:session_prompted, ^pid, _}
      assert Coordinator.list_active(coordinator) == []
    end
  end

  describe "abort_all/1" do
    test "aborts every running subagent and returns cancellation results", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      call = run_async(coordinator, [%{prompt: "Task 1"}, %{prompt: "Task 2"}], timeout: 10_000)
      {first, first_ref, first_id, _} = started_session("Task 1")
      {second, second_ref, second_id, _} = started_session("Task 2")
      assert length(Coordinator.list_active(coordinator)) == 2
      assert :ok = Coordinator.abort_all(coordinator)
      assert_receive {:session_aborted, ^first}, 1_000
      assert_receive {:session_aborted, ^second}, 1_000
      assert_receive {:DOWN, ^first_ref, :process, ^first, :shutdown}, 1_000
      assert_receive {:DOWN, ^second_ref, :process, ^second, :shutdown}, 1_000
      assert_receive {:results, ^call, [first_result, second_result]}, 2_000
      assert %{status: :aborted, result: nil, error: :aborted, session_id: ^first_id} = first_result
      assert %{status: :aborted, result: nil, error: :aborted, session_id: ^second_id} = second_result
      assert Coordinator.list_active(coordinator) == []
    end

    test "cancels blocked admission without losing its late session", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir, gate_start: true, gate_cleanup: true)
      call = run_async(coordinator, [%{prompt: "Blocked startup"}])
      assert_receive {:session_starting, pid, _session_id}, 1_000
      ref = track_session(pid)
      [id] = Coordinator.list_active(coordinator)
      assert :ok = Coordinator.abort_all(coordinator)
      assert [^id] = Coordinator.list_active(coordinator)
      send(pid, :release_start)
      assert_receive {:session_cleanup_started, ^pid}, 1_000
      assert_receive {:session_aborted, ^pid}, 1_000
      assert [^id] = Coordinator.list_active(coordinator)
      refute_receive {:session_subscribed, ^pid, _}
      refute_receive {:session_prompted, ^pid, _}
      send(pid, :release_cleanup)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call, [%{id: ^id, status: :aborted, error: :aborted, result: nil}]}, 2_000
      assert Coordinator.list_active(coordinator) == []
    end

    test "remains responsive while the synchronous prompt handshake is blocked", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir, gate_prompt: true, gate_cleanup: true)
      call = run_async(coordinator, [%{prompt: "Blocked prompt"}])
      {pid, ref, session_id, _worker} = started_session("Blocked prompt")
      [id] = Coordinator.list_active(coordinator)
      assert :ok = Coordinator.abort_all(coordinator)
      assert [^id] = Coordinator.list_active(coordinator)
      send(pid, :release_prompt)
      assert_receive {:session_cleanup_started, ^pid}, 1_000
      assert_receive {:session_aborted, ^pid}, 1_000
      assert [^id] = Coordinator.list_active(coordinator)
      send(pid, :release_cleanup)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call, [%{id: ^id, status: :aborted, error: :aborted, session_id: ^session_id}]}, 2_000
      assert Coordinator.list_active(coordinator) == []
    end

    test "handles the asynchronous cancellation message", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      call = run_async(coordinator, [%{prompt: "Async abort"}])
      {pid, ref, _, _} = started_session("Async abort")
      send(coordinator, :abort_all)
      assert_receive {:session_aborted, ^pid}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call, [%{status: :aborted, error: :aborted}]}, 1_000
      assert Coordinator.list_active(coordinator) == []
    end

    test "returns ok when nothing is active", %{tmp_dir: tmp_dir} do
      coordinator = start_coordinator(tmp_dir)
      assert :ok = Coordinator.abort_all(coordinator)
    end
  end

  describe "crash handling" do
    test "reports an actual session crash and remains usable", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      call = run_async(coordinator, [%{prompt: "Crash"}])
      {pid, ref, session_id, _worker} = started_session("Crash")
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
      assert_receive {:results, ^call, [%{status: :error, result: nil, error: {:crashed, :killed}, session_id: ^session_id}]}, 1_000
      assert Process.alive?(coordinator)
      assert Coordinator.list_active(coordinator) == []
      assert [%{status: :error, error: "Unknown subagent: invalid"}] =
               Coordinator.run_subagents(coordinator, [%{prompt: "Retry", subagent: "invalid"}])
    end

    test "a worker crash cleans up the session it owns", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir)
      call = run_async(coordinator, [%{prompt: "Worker crash"}])
      {pid, ref, session_id, worker} = started_session("Worker crash")
      # Ensure the coordinator has observed admission before crashing its owner.
      %{active_subagents: active} = :sys.get_state(coordinator)
      assert Enum.any?(active, fn {_id, subagent} -> subagent.pid == pid end)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:results, ^call, [%{status: :error, error: {:crashed, :killed}, session_id: ^session_id}]}, 1_000
      assert Coordinator.list_active(coordinator) == []
    end

    test "coordinator death cancels a still-starting session", %{tmp_dir: tmp_dir} do
      coordinator = start_controlled_coordinator(tmp_dir, gate_start: true)
      call = run_async(coordinator, [%{prompt: "Owner dies"}])
      assert_receive {:session_starting, pid, _session_id}, 1_000
      ref = track_session(pid)
      %{active_subagents: active} = :sys.get_state(coordinator)
      [{_id, %{worker_pid: worker}}] = Map.to_list(active)
      worker_ref = Process.monitor(worker)
      GenServer.stop(coordinator)
      send(pid, :release_start)
      assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
      assert_receive {:caller_exit, ^call, _reason}, 1_000
      refute_receive {:session_prompted, ^pid, _}
    end
  end

  test "result extraction ignores thinking and uses the last assistant text", %{tmp_dir: tmp_dir} do
    coordinator = start_controlled_coordinator(tmp_dir)
    call = run_async(coordinator, [%{prompt: "Visible output"}])
    {pid, ref, session_id, worker} = started_session("Visible output")
    messages = [
      %AssistantMessage{content: [%TextContent{text: "earlier"}]},
      %AssistantMessage{content: [%LemonAi.Types.ThinkingContent{thinking: "private"}, %TextContent{text: "visible"}]}
    ]
    send(worker, {:session_event, session_id, {:agent_end, messages}})
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 1_000
    assert_receive {:results, ^call, [%{status: :completed, result: "visible", error: nil, session_id: ^session_id} = result]}, 1_000
    assert Map.keys(result) |> Enum.sort() == [:error, :id, :result, :session_id, :status]
    assert is_binary(result.id)
  end
end
