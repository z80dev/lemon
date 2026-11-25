defmodule CodingAgent.Executor.SessionRunnerRecoveryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Executor.SessionRunner
  alias CodingAgent.Executor.SessionRunner.Emitter
  alias CodingAgent.Session.RunTranslator

  defmodule Owner do
    use GenServer, restart: :temporary
    def start_link(events), do: GenServer.start_link(__MODULE__, events)

    def init(events) do
      log =
        CodingAgent.Session.EventLog.new("session-1", "session-key", "run-1", System.tmp_dir!())

      Enum.each(events, &CodingAgent.Session.EventLog.append(log, &1))
      {:ok, log}
    end

    def handle_call(:canonical_terminal, _from, log),
      do: {:reply, CodingAgent.Session.EventLog.terminal(log), log}

    def handle_call(:context_budget, _from, messages),
      do: {:reply, {:error, :unavailable}, messages}

    def handle_call(:save, _from, messages), do: {:reply, :ok, messages}

    def handle_call({:retain_root, _ttl}, {caller, _tag}, messages) do
      send(caller, :owner_retained)
      {:reply, :ok, messages}
    end
  end

  test "overflow terminal recovers the complete owner answer exactly once, not the partial prefix" do
    owner =
      start_supervised!(
        {Owner, [{:agent_start}, text("complete canonical answer"), {:agent_end, []}]}
      )

    state = runner(owner)
    run_ref = state.run_ref
    state = %{state | translator: RunTranslator.replace_text(state.translator, "missing tail")}

    assert {:stop, :normal, state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :completed}, state)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :completed, ok: true, answer: "complete canonical answer"}}

    assert state.translator.completed_emitted
    assert_received :owner_retained
    assert Process.alive?(owner)

    # A delayed terminal cannot re-read the retained owner.

    assert {:noreply, ^state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :canceled}, state)

    assert {:noreply, ^state} =
             SessionRunner.handle_info(
               batch("session-1", :engine_action, %{}),
               state
             )

    assert {:noreply, ^state} =
             SessionRunner.handle_info(
               batch("session-1", :delta, %{text: "late delta"}),
               state
             )

    refute_received {:engine_event, ^run_ref, _}
    refute_received {:engine_delta, ^run_ref, _}
  end

  test "foreign session terminal and progress cannot select another owner's state" do
    state = runner(self())
    run_ref = state.run_ref

    assert {:noreply, ^state} =
             SessionRunner.handle_info({:session_terminal, "other-session", :completed}, state)

    assert {:noreply, ^state} =
             SessionRunner.handle_info(
               batch("other-session", :delta, %{text: "foreign"}),
               state
             )

    refute_received {:engine_event, ^run_ref, _}
    refute_received {:engine_delta, ^run_ref, _}
  end

  test "cancel terminal remains failed and keeps the owner's canonical partial answer" do
    owner =
      start_supervised!(
        {Owner, [{:agent_start}, text("canonical partial answer"), {:canceled, :user_requested}]}
      )

    state = runner(owner)
    run_ref = state.run_ref

    assert {:stop, :normal, state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :canceled}, state)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :completed, ok: false, answer: "canonical partial answer"}}

    assert state.translator.completed_emitted
    assert Process.alive?(owner)
  end

  test "cancel before this turn has an assistant message cannot recycle the preceding turn's answer" do
    owner =
      start_supervised!(
        {Owner,
         [
           {:agent_start},
           text("PREVIOUS ANSWER"),
           {:agent_end, []},
           {:agent_start},
           text("Current partial prefix"),
           {:canceled, :user_requested}
         ]}
      )

    state = runner(owner)
    run_ref = state.run_ref

    assert {:stop, :normal, state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :canceled}, state)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :completed, ok: false, answer: "Current partial prefix"}}

    assert state.translator.completed_emitted
    assert Process.alive?(owner)
  end

  test "a fenced real session retains the current loop crash instead of the preceding success" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "executor-crash-fence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    stream_fn = fn model, context, options ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 ->
          LemonAgent.Test.Mocks.mock_stream_fn_single(
            LemonAgent.Test.Mocks.assistant_message("PREVIOUS SUCCESS")
          ).(model, context, options)

        1 ->
          send(parent, {:crash_provider_waiting, self()})

          receive do
            :crash_now -> raise "current loop exploded"
          end
      end
    end

    {:ok, session} =
      CodingAgent.start_session(
        cwd: tmp_dir,
        workspace_dir: tmp_dir,
        model: LemonAgent.Test.Mocks.mock_model(),
        tools: [],
        stream_fn: stream_fn
      )

    on_exit(fn ->
      if Process.alive?(session), do: CodingAgent.SessionSupervisor.stop_session(session)
    end)

    session_id = CodingAgent.Session.get_stats(session).session_id
    _unsubscribe = CodingAgent.Session.subscribe(session)
    assert :ok = CodingAgent.Session.prompt(session, "Previous prompt")
    assert_receive {:session_event, ^session_id, {:agent_end, _}, _}, 5_000
    refute CodingAgent.Session.get_state(session).is_streaming

    # Fence this turn on lifecycle traffic before releasing the failing provider.
    _unsubscribe = CodingAgent.Session.subscribe(session, max_queue: 1, format: :canonical)
    assert :ok = CodingAgent.Session.prompt(session, "Current prompt")
    assert_receive {:crash_provider_waiting, producer}, 5_000
    on_exit(fn -> send(producer, :crash_now) end)
    owner_state = CodingAgent.Session.get_state(session)
    assert owner_state.terminal_event == nil
    [{_, _, delivery, :canonical}] = owner_state.event_listeners
    LemonCore.Bus.Delivery.resync(delivery)
    assert LemonCore.Bus.Delivery.closed?(delivery)
    send(producer, :crash_now)
    assert_receive {:session_terminal, ^session_id, :error} = terminal, 5_000

    state = runner(session)

    state = %{
      state
      | session_id: session_id,
        translator: %{state.translator | session_id: session_id}
    }

    run_ref = state.run_ref
    assert {:stop, :normal, state} = SessionRunner.handle_info(terminal, state)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :completed, ok: false, answer: "", error: error}}

    assert error =~ "current loop exploded"
    refute error =~ "PREVIOUS SUCCESS"
    assert state.translator.completed_emitted
    assert {:noreply, ^state} = SessionRunner.handle_info(terminal, state)
    refute_received {:engine_event, ^run_ref, %{__event__: :completed}}
  end

  defp text(text), do: {:message_update, {:text_delta, 0, text}}

  defp batch(session_id, type, data) do
    {:session_batch, session_id,
     LemonCore.Event.new(:session_event, %{events: [LemonCore.Event.new(type, data)]})}
  end

  defp runner(owner) do
    run_ref = make_ref()

    translator =
      RunTranslator.new(
        emitter: Emitter,
        emitter_state: %Emitter{sink_pid: self(), run_ref: run_ref, session: owner},
        engine: "lemon",
        label: "recovery-test",
        session_id: "session-1",
        cwd: System.tmp_dir!()
      )

    %SessionRunner{
      session: owner,
      session_id: "session-1",
      sink_pid: self(),
      run_ref: run_ref,
      translator: translator
    }
  end
end
