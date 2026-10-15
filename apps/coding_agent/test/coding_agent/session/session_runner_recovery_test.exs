defmodule CodingAgent.Executor.SessionRunnerRecoveryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.SessionRunner
  alias CodingAgent.Executor.SessionRunner.Emitter
  alias CodingAgent.Session.RunTranslator

  defmodule Owner do
    use GenServer, restart: :temporary
    def start_link(messages), do: GenServer.start_link(__MODULE__, messages)
    def init(messages), do: {:ok, messages}
    def handle_call(:get_messages, _from, messages), do: {:reply, messages, messages}

    def handle_call(:context_budget, _from, messages),
      do: {:reply, {:error, :unavailable}, messages}

    def handle_call(:save, _from, messages), do: {:reply, :ok, messages}
  end

  test "overflow terminal recovers the complete owner answer exactly once, not the partial prefix" do
    owner =
      start_supervised!({Owner, [%{role: :assistant, content: "complete canonical answer"}]})

    state = runner(owner)
    run_ref = state.run_ref
    state = %{state | translator: %{state.translator | accumulated_text: "missing tail"}}

    assert {:noreply, state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :completed}, state)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :completed, ok: true, answer: "complete canonical answer"}}

    assert state.translator.completed_emitted

    # Even after owner teardown, a delayed terminal cannot re-read or revive it.
    refute Process.alive?(owner)

    assert {:noreply, ^state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :canceled}, state)

    assert {:noreply, ^state} =
             SessionRunner.handle_info(
               {:session_event, "session-1", {:tool_execution_start, "late", "bash", %{}}},
               state
             )

    assert {:noreply, ^state} =
             SessionRunner.handle_info(
               {:session_event, "session-1", {:message_update, %{}, "late delta"}},
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
               {:session_event, "other-session", {:message_update, %{}, "foreign"}},
               state
             )

    refute_received {:engine_event, ^run_ref, _}
    refute_received {:engine_delta, ^run_ref, _}
  end

  test "cancel terminal remains failed and keeps the owner's canonical partial answer" do
    owner = start_supervised!({Owner, [%{role: :assistant, content: "canonical partial answer"}]})
    state = runner(owner)
    run_ref = state.run_ref

    assert {:noreply, state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :canceled}, state)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :completed, ok: false, answer: "canonical partial answer"}}

    assert state.translator.completed_emitted
    refute Process.alive?(owner)
  end

  test "cancel before this turn has an assistant message cannot recycle the preceding turn's answer" do
    owner =
      start_supervised!(
        {Owner,
         [
           %{role: :user, content: "Previous prompt"},
           %{role: :assistant, content: "PREVIOUS ANSWER"},
           %{role: :user, content: "Current prompt"}
         ]}
      )

    state = runner(owner)
    run_ref = state.run_ref

    state = %{
      state
      | translator: %{state.translator | accumulated_text: "Current partial prefix"}
    }

    assert {:noreply, state} =
             SessionRunner.handle_info({:session_terminal, "session-1", :canceled}, state)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :completed, ok: false, answer: "Current partial prefix"}}

    assert state.translator.completed_emitted
    refute Process.alive?(owner)
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
