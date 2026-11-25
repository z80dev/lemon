defmodule CodingAgent.SessionLoopCrashTest do
  @moduledoc """
  A session whose agent loop is killed mid-run leaves the busy state and
  accepts the next message.
  """
  use ExUnit.Case, async: true

  import LemonPlatformTest.Testing.AsyncHelpers

  alias CodingAgent.Session
  alias LemonAgent.Test.Mocks

  defp stream_fn(parent) do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    fn model, context, options ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        Mocks.blocking_stream_fn(Mocks.assistant_message("never"), parent, chunks: 1).(
          model,
          context,
          options
        )
      else
        Mocks.mock_stream_fn_single(Mocks.assistant_message("second")).(model, context, options)
      end
    end
  end

  test "killing the agent loop clears the busy state and accepts the next message" do
    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: Mocks.mock_model(),
        stream_fn: stream_fn(self())
      )

    on_exit(fn -> if Process.alive?(session), do: Process.exit(session, :kill) end)

    _unsubscribe = Session.subscribe(session)
    :ok = Session.prompt(session, "first")
    assert_receive {:stream_blocked, producer}, 5_000
    on_exit(fn -> send(producer, :release_stream) end)

    assert Session.get_state(session).is_streaming
    assert {:reply, {:error, :session_busy}, _state} = prepare_root_turn(session)
    agent = Session.get_state(session).agent
    %Task{pid: forwarder} = :sys.get_state(agent).running_task

    Process.exit(forwarder, :kill)

    assert_receive {:session_event, _session_id, {:error, {:loop_crashed, :killed}, _partial},
                    _meta},
                   2_000

    assert_eventually(fn -> not Session.get_state(session).is_streaming end, timeout: 2_000)

    assert {:reply, {:error, :live_session_workspace_mismatch}, _state} =
             prepare_root_turn(session)

    assert :ok = Session.prompt(session, "second")
    assert_receive {:session_event, _session_id, {:agent_end, _messages}, _meta}, 5_000
    assert_eventually(fn -> not Session.get_state(session).is_streaming end, timeout: 2_000)
  end

  # Runs the router's root-turn admission against a snapshot. The mismatched
  # workspace stops it right after the busy check, so nothing is mutated.
  defp prepare_root_turn(session) do
    Session.handle_call(
      {:prepare_root_turn, [cwd: "/nonexistent-lemon-workspace"]},
      {self(), make_ref()},
      :sys.get_state(session)
    )
  end
end
