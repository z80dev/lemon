defmodule CodingAgent.Session.PromptAdmissionTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias CodingAgent.Session
  alias LemonAgent.Test.Mocks
  alias LemonCore.Bus

  setup %{tmp_dir: tmp_dir} do
    on_exit(fn -> File.rm_rf!(CodingAgent.SessionManager.get_session_dir(tmp_dir)) end)
    :ok
  end

  test "streaming? reads a scalar without asking the agent", %{tmp_dir: tmp_dir} do
    session = start_session(tmp_dir)
    agent = Session.get_state(session).agent
    :ok = :sys.suspend(agent)

    try do
      assert Session.streaming?(session) === false
      :sys.replace_state(session, &%{&1 | is_streaming: true})
      assert Session.streaming?(session) === true
      :sys.replace_state(session, &%{&1 | is_streaming: false})
    after
      :sys.resume(agent)
    end
  end

  test "acceptance marks the deferred turn busy before any agent events", %{tmp_dir: tmp_dir} do
    session =
      start_session(tmp_dir,
        stream_fn: Mocks.blocking_stream_fn(Mocks.assistant_message("done"), self())
      )

    unsubscribe = Session.subscribe(session)
    :ok = :sys.suspend(session)

    # Queue these calls before resuming the owner. The deferred dispatch cannot
    # overtake the scalar read or competing admission, regardless of scheduling.
    {prompt, streaming, competing} =
      try do
        {
          :gen_server.send_request(session, {:prompt, "Accepted prompt", []}),
          :gen_server.send_request(session, :streaming?),
          :gen_server.send_request(session, {:prompt, "Rejected prompt", []})
        }
      after
        :sys.resume(session)
      end

    assert {:reply, :ok} = :gen_server.wait_response(prompt, 5_000)
    assert {:reply, true} = :gen_server.wait_response(streaming, 5_000)
    assert {:reply, {:error, :busy}} = :gen_server.wait_response(competing, 5_000)
    assert_receive {:stream_blocked, producer}, 5_000
    on_exit(fn -> send(producer, :release_stream) end)

    assert Session.streaming?(session)
    assert {:error, :busy} = Session.prompt(session, "Also rejected")
    send(producer, :release_stream)
    assert_receive {:session_event, _, {:agent_end, _}, _cursor}, 5_000

    refute Session.streaming?(session)
    assert Session.get_stats(session).turn_count == 1

    assert [%{role: :user, content: "Accepted prompt"}] =
             session |> Session.get_messages() |> Enum.filter(&(&1.role == :user))

    unsubscribe.()
  end

  for mode <- [:preempting, :non_preempting, :request, :redirect] do
    @mode mode
    test "#{mode} steering notifies waiters after queue admission", %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      agent = Session.get_state(session).agent
      topic = "session_coord:#{:erlang.pid_to_list(session)}"
      :ok = Bus.subscribe(topic)

      admission =
        case @mode do
          :preempting -> Session.steer(session, "Queued input")
          :non_preempting -> Session.steer(session, "Queued input", preempt: false)
          :request -> Session.request_steering(session, "Queued input", self())
          :redirect -> Session.redirect(session, "Queued input")
        end

      assert_receive {:session_coord, :steering_changed}, 5_000
      agent_state = :sys.get_state(agent)
      assert length(agent_state.steering_queue ++ agent_state.follow_up_queue) == 1

      if @mode == :request do
        assert :injected = Session.await_steering(admission)
      else
        assert admission == :ok
      end

      :ok = Bus.unsubscribe(topic)
    end
  end

  test "steering a dead owner is resolved by its monitor" do
    {session, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}

    assert {:pending, ^session, _, _} =
             pending = Session.request_steering(session, "Queued input", self())

    assert :outcome_unknown = Session.await_steering(pending)
  end

  defp start_session(tmp_dir, overrides \\ []) do
    opts =
      Keyword.merge(
        [
          cwd: tmp_dir,
          workspace_dir: tmp_dir,
          session_mode: :chat,
          tools: [],
          mcp_tools: [],
          extension_inventory: {[], []},
          project_memory_capture: false,
          model: Mocks.mock_model(),
          stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("done"))
        ],
        overrides
      )

    start_supervised!(Supervisor.child_spec({Session, opts}, restart: :temporary))
  end
end
