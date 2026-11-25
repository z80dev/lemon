defmodule CodingAgent.Session.ToolIntentRecoveryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.Persistence
  alias CodingAgent.Session.ToolIntentGate
  alias CodingAgent.SessionManager
  alias CodingAgent.ToolIntent
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  @moduletag :tmp_dir

  defmodule JournalOwner do
    use GenServer

    def init({dir, parent, assistant?}) do
      session = SessionManager.new(dir)

      session =
        if assistant?, do: SessionManager.append_message(session, assistant()), else: session

      session = SessionManager.persist(session, Path.join(dir, "session.jsonl"))

      {:ok,
       %{
         session_manager: session,
         tool_opts: [],
         pending_tool_intents: %{},
         is_streaming: true,
         parent: parent
       }}
    end

    def handle_call({:record_tool_intent, _, _, _} = request, from, state) do
      result = CodingAgent.Session.handle_call(request, from, state)
      send(state.parent, {:intent_request_handled, self()})
      result
    end

    def handle_call(:pending, _from, state), do: {:reply, state.pending_tool_intents, state}

    def handle_call(:append_assistant, _from, state) do
      session = SessionManager.append_message(state.session_manager, assistant())
      state = ToolIntentGate.flush(%{state | session_manager: session})
      {:reply, :ok, state}
    end

    def handle_info({:lemon_abort, signal, _}, state),
      do: {:noreply, ToolIntentGate.cancel_signal(state, signal)}

    def handle_info({:tool_intent_wait_expired, ref}, state),
      do: {:noreply, ToolIntentGate.cancel(state, ref, :assistant_not_recorded)}

    def handle_info({:DOWN, ref, :process, _, _}, state) do
      state = ToolIntentGate.cancel(state, ref, :caller_down)
      send(state.parent, {:intent_caller_down_handled, self()})
      {:noreply, state}
    end

    def assistant do
      %{
        "role" => "assistant",
        "content" => [
          %{"type" => "tool_call", "id" => "call", "name" => "eval", "arguments" => %{}}
        ],
        "timestamp" => 1
      }
    end
  end

  test "worker arriving before message_end waits without blocking the owner", %{tmp_dir: dir} do
    owner = owner(dir, false)
    worker = worker(owner)
    assert_receive {:intent_request_handled, ^owner}
    assert map_size(GenServer.call(owner, :pending)) == 1
    refute_received :executed
    refute File.read!(Path.join(dir, "session.jsonl")) =~ "lemon.tool_intent"

    assert :ok = GenServer.call(owner, :append_assistant)
    assert_receive :executed
    assert %AgentToolResult{is_error: false} = Task.await(worker)
    assert GenServer.call(owner, :pending) == %{}
    {:ok, loaded} = SessionManager.load_from_file(Path.join(dir, "session.jsonl"))
    assert [assistant, intent] = SessionManager.entries(loaded)
    assert assistant.type == :message
    assert intent.custom_type == "lemon.tool_intent"
  end

  for kind <- [:abort, :redirect] do
    test "#{kind} while deferred refuses execution", %{tmp_dir: dir} do
      owner = owner(dir, false)
      signal = AbortSignal.new()
      worker = worker(owner, signal)
      assert_receive {:intent_request_handled, ^owner}
      assert map_size(GenServer.call(owner, :pending)) == 1

      cancel_signal(signal, unquote(kind))

      assert %AgentToolResult{is_error: true, details: %{outcome: :not_started}} =
               Task.await(worker)

      assert GenServer.call(owner, :pending) == %{}
      assert :ok = GenServer.call(owner, :append_assistant)
      refute_received :executed
      refute File.read!(Path.join(dir, "session.jsonl")) =~ "lemon.tool_intent"
    end
  end

  test "a missing assistant entry has a bounded refusal", %{tmp_dir: dir} do
    owner = owner(dir, false)
    worker = worker(owner)
    assert_receive {:intent_request_handled, ^owner}
    [{ref, pending}] = Map.to_list(GenServer.call(owner, :pending))
    assert Process.read_timer(pending.timer) in 0..5_000
    send(owner, {:tool_intent_wait_expired, ref})
    assert %AgentToolResult{is_error: true} = Task.await(worker)
    refute_received :executed
  end

  test "owner crash while deferred refuses execution", %{tmp_dir: dir} do
    owner = owner(dir, false)
    worker = worker(owner)
    assert_receive {:intent_request_handled, ^owner}
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

    assert %AgentToolResult{is_error: true, details: %{outcome: :not_started}} =
             Task.await(worker)

    refute_received :executed
  end

  test "caller death removes its deferred request", %{tmp_dir: dir} do
    owner = owner(dir, false)
    worker = worker(owner)
    Process.unlink(worker.pid)
    assert_receive {:intent_request_handled, ^owner}
    Process.exit(worker.pid, :kill)

    assert_receive {:DOWN, ref, :process, pid, :killed}
                   when ref == worker.ref and pid == worker.pid

    assert_receive {:intent_caller_down_handled, ^owner}
    assert GenServer.call(owner, :pending) == %{}
    assert :ok = GenServer.call(owner, :append_assistant)
    refute_received :executed
    refute File.read!(Path.join(dir, "session.jsonl")) =~ "lemon.tool_intent"
  end

  for phase <- [:before_intent, :after_intent] do
    test "kill #{phase} restores truthful outcome", %{tmp_dir: dir} do
      owner = owner(dir, true)
      parent = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          recorder = fn data ->
            if unquote(phase) == :before_intent do
              send(parent, :at_kill_point)

              receive do
                :continue -> :ok
              end
            end

            GenServer.call(owner, {:record_tool_intent, data, nil, nil})
          end

          tool = %AgentTool{
            name: "eval",
            effect: :external,
            execute: fn _, _, _, _ ->
              send(parent, :at_kill_point)

              receive do
                :continue -> %AgentToolResult{}
              end
            end
          }

          ToolIntent.wrap(tool, tool_intent_recorder: recorder).execute.("call", %{}, nil, nil)
        end)

      assert_receive :at_kill_point
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
      owner_monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

      assert {:ok, session} = SessionManager.load_from_file(Path.join(dir, "session.jsonl"))

      assert [%LemonAi.Types.AssistantMessage{}, result] =
               Persistence.restore_messages_from_session(session)

      expected = if unquote(phase) == :before_intent, do: :not_started, else: :unknown
      assert result.details.outcome == expected

      if expected == :unknown do
        assert hd(result.content).text =~ "nested tool effects are also unknown"
        [assistant | _] = SessionManager.entries(session)
        rewound = %{session | leaf_id: assistant.id}
        [_, repaired] = Persistence.restore_messages_from_session(rewound)
        assert repaired.details.outcome == :unknown
      end
    end
  end

  defp owner(dir, assistant?) do
    {:ok, owner} = GenServer.start(JournalOwner, {dir, self(), assistant?})
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    owner
  end

  defp cancel_signal(signal, :abort), do: AbortSignal.abort(signal)
  defp cancel_signal(signal, :redirect), do: AbortSignal.request_redirect(signal)

  defp worker(owner, signal \\ nil) do
    parent = self()

    Task.async(fn ->
      tool = %AgentTool{
        name: "eval",
        effect: :external,
        execute: fn _, _, _, _ ->
          send(parent, :executed)
          %AgentToolResult{}
        end
      }

      ToolIntent.wrap(tool, session_pid: owner).execute.("call", %{}, signal, nil)
    end)
  end
end
