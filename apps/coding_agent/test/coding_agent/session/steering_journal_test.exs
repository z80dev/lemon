defmodule CodingAgent.Session.SteeringJournalTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.SessionManager
  alias LemonAgent.Test.Mocks

  @moduletag :tmp_dir

  test "acceptance and withdrawal are durable before their acknowledgements", %{tmp_dir: dir} do
    session = start_session(dir)

    assert {:ok, %{id: "withdraw-me", accepted_after_turn: 0}} =
             Session.steer(session, "queued correction", id: "withdraw-me", return_receipt: true)

    path = Session.get_state(session).session_file
    assert {:ok, journal} = SessionManager.load_from_file(path)
    assert [accepted] = accepted_entries(journal)
    assert accepted.data["id"] == "withdraw-me"
    assert accepted.data["acceptedAfterTurn"] == 0
    assert accepted.data["message"]["content"] == "queued correction"

    assert :ok = Session.steer(session, "queued correction", id: "withdraw-me")

    assert {:error, :id_conflict} =
             Session.steer(session, "different correction", id: "withdraw-me")

    assert {:ok, [_]} = Session.pending_steers(session)
    assert :ok = Session.withdraw_steer(session, "withdraw-me")
    assert {:error, :not_found} = Session.withdraw_steer(session, "withdraw-me")
    assert {:ok, []} = Session.pending_steers(session)
    assert {:ok, journal} = SessionManager.load_from_file(path)

    assert Enum.any?(
             SessionManager.entries(journal),
             &(&1.custom_type == "lemon.input_withdrawn")
           )

    assert length(accepted_entries(journal)) == 1

    stop_session(session)
    restored = start_session(dir, path)
    assert :ok = Session.replay_pending_inputs(restored)
    assert {:ok, []} = Session.pending_steers(restored)
    refute LemonAgent.Agent.get_state(Session.get_state(restored).agent).is_streaming
    refute_received {:model_call, _, _}
  end

  test "kill after acknowledged steering restores and consumes the input exactly once", %{
    tmp_dir: dir
  } do
    session = start_session(dir)
    assert {:ok, _unsubscribe} = Session.subscribe_prompt(session, "initial work")
    assert_receive {:model_call, _first_call, _}, 5_000
    assert_receive {:session_event, _, {:turn_start}, _}, 5_000
    state = Session.get_state(session)
    assert state.turn_index == 1

    assert {:ok, %{id: "survivor", accepted_after_turn: 1}} =
             Session.steer(session, "durable correction", id: "survivor", return_receipt: true)

    kill_session(session)
    restored = start_session(dir, state.session_file)

    assert {:ok, [%{id: "survivor", text: "durable correction"}]} =
             Session.pending_steers(restored)

    assert :ok = Session.replay_pending_inputs(restored)
    assert :ok = Session.replay_pending_inputs(restored)
    refute LemonAgent.Agent.get_state(Session.get_state(restored).agent).is_streaming
    refute_received {:model_call, _, _}

    assert {:ok, _unsubscribe} = Session.subscribe_prompt(restored, "resume explicitly")
    id = Session.get_state(restored).session_manager.header.id
    calls = finish_run(id)
    assert Enum.any?(calls, &(count_model_text(&1.messages, "durable correction") == 1))
    assert Enum.all?(calls, &(count_model_text(&1.messages, "durable correction") <= 1))
    assert count_text(Session.get_messages(restored), "durable correction") == 1
    assert {:ok, []} = Session.pending_steers(restored)

    stop_session(restored)
    again = start_session(dir, state.session_file)
    assert {:ok, []} = Session.pending_steers(again)
    assert count_text(Session.get_messages(again), "durable correction") == 1
  end

  test "binding survives a crash before the consuming model returns", %{tmp_dir: dir} do
    session = start_session(dir)
    assert {:ok, _} = Session.subscribe_prompt(session, "first")
    assert_receive {:model_call, first_call, _}, 5_000
    assert :ok = Session.steer(session, "already bound", id: "bound")
    send(first_call, :finish_model)
    assert_receive {:model_call, _second_call, context}, 5_000
    assert count_model_text(context.messages, "already bound") == 1

    assert_receive {:session_event, _, {:message_end, %{id: "bound", content: "already bound"}},
                    _},
                   5_000

    assert {:error, :not_found} = Session.withdraw_steer(session, "bound")
    state = Session.get_state(session)
    assert {:ok, []} = Session.pending_steers(session)

    kill_session(session)
    restored = start_session(dir, state.session_file)
    assert {:ok, []} = Session.pending_steers(restored)
    assert count_text(Session.get_messages(restored), "already bound") == 1
    refute LemonAgent.Agent.get_state(Session.get_state(restored).agent).is_streaming
    refute_received {:model_call, _, _}
  end

  test "atomic subscription sees the earliest event and follow-up acceptance starts idle work", %{
    tmp_dir: dir
  } do
    session = start_session(dir)
    assert {:ok, unsubscribe} = Session.subscribe_prompt(session, "one")
    id = Session.get_state(session).session_manager.header.id
    assert_receive {:session_event, ^id, {:agent_start}, _}, 5_000
    assert [_] = finish_run(id)

    assert {:ok, %{id: "follow", accepted_after_turn: 1}} =
             Session.follow_up(session, "two", id: "follow", return_receipt: true)

    assert [_] = finish_run(id)
    assert count_text(Session.get_messages(session), "two") == 1
    assert {:ok, journal} = SessionManager.load_from_file(Session.get_state(session).session_file)
    assert Enum.any?(accepted_entries(journal), &(&1.data["kind"] == "follow_up"))
    unsubscribe.()
  end

  test "a rejected atomic prompt does not install a subscription", %{tmp_dir: dir} do
    session = start_session(dir)
    assert :ok = Session.prompt(session, "blocked")
    assert_receive {:model_call, _call, _}, 5_000
    before = Session.get_state(session).event_listeners
    assert {:error, :busy} = Session.subscribe_prompt(session, "not accepted")
    assert Session.get_state(session).event_listeners == before
    assert {:error, :busy} = Session.replay_pending_inputs(session)
  end

  test "an acknowledged follow-up survives owner death and replays once", %{tmp_dir: dir} do
    session = start_session(dir)
    assert {:ok, _} = Session.subscribe_prompt(session, "initial")
    assert_receive {:model_call, _, _}, 5_000
    assert_receive {:session_event, _, {:turn_start}, _}, 5_000
    assert :ok = Session.follow_up(session, "durable follow-up", id: "surviving-follow-up")
    state = Session.get_state(session)
    assert :queue.len(state.follow_up_queue) == 1

    kill_session(session)
    restored = start_session(dir, state.session_file)
    assert :queue.len(Session.get_state(restored).follow_up_queue) == 1
    assert :ok = Session.replay_pending_inputs(restored)
    assert {:ok, _} = Session.subscribe_prompt(restored, "resume")
    id = Session.get_state(restored).session_manager.header.id
    finish_run(id)
    assert count_text(Session.get_messages(restored), "durable follow-up") == 1
  end

  test "navigation cannot lose pending acceptance or resurrect a withdrawal", %{tmp_dir: dir} do
    session = start_session(dir)
    initial = Session.get_state(session)
    assert :ok = Session.steer(session, "keep across navigation", id: "keep")
    assert :ok = Session.steer(session, "withdraw across navigation", id: "withdraw")
    assert :ok = Session.withdraw_steer(session, "withdraw")
    assert :ok = Session.navigate_tree(session, initial.session_manager.leaf_id)
    stop_session(session)

    restored = start_session(dir, initial.session_file)
    assert {:ok, [%{id: "keep"}]} = Session.pending_steers(restored)
    assert {:error, :not_found} = Session.withdraw_steer(restored, "withdraw")
  end

  test "a provisional binding without a consumed message remains replayable", %{tmp_dir: dir} do
    session = start_session(dir)
    assert :ok = Session.steer(session, "not consumed", id: "provisional")
    send(session, {:agent_event, {:input_bound, ["provisional"]}})
    state = Session.get_state(session)
    assert state.input_journal["provisional"].status == :binding
    assert {:ok, []} = Session.pending_steers(session)

    kill_session(session)
    restored = start_session(dir, state.session_file)
    assert {:ok, [%{id: "provisional"}]} = Session.pending_steers(restored)
    assert count_text(Session.get_messages(restored), "not consumed") == 0
  end

  test "a reserved prompt is queued if the agent has already started its next run", %{
    tmp_dir: dir
  } do
    session = start_session(dir)
    assert {:ok, _} = Session.subscribe_prompt(session, "first")
    assert_receive {:model_call, first_call, _}, 5_000
    assert_receive {:session_event, _, {:turn_start}, _}, 5_000

    # Reproduce the state visible between the prior terminal notification and
    # the already-started Agent's next :agent_start notification.
    :sys.replace_state(session, &%{&1 | is_streaming: false})
    assert :ok = Session.prompt(session, "reserved second prompt")
    assert_receive {:session_event, _, {:input_accepted, %{kind: :follow_up}}, _}, 5_000
    send(first_call, :finish_model)
    id = Session.get_state(session).session_manager.header.id
    finish_run(id)
    assert count_text(Session.get_messages(session), "reserved second prompt") == 1
  end

  test "stale prompt dispatch cannot consume a newer reservation" do
    state = %Session{pending_prompt_timer_ref: make_ref()}
    old_ref = make_ref()
    message = Mocks.user_message("stale")
    assert {:noreply, ^state} = Session.handle_info({:do_prompt, old_ref, message, ""}, state)

    assert {:noreply, ^state} =
             Session.handle_info({:dispatch_prompt, old_ref, message, ""}, state)
  end

  test "operator steering prepares file commands only after invocation authorization", %{
    tmp_dir: dir
  } do
    command_dir = Path.join(dir, ".lemon/commands")
    File.mkdir_p!(command_dir)
    File.write!(Path.join(command_dir, "steering-regression.md"), "Review $ARGUMENTS")
    session = start_session(dir)
    assert {:ok, _} = Session.subscribe_prompt(session, "hold")
    assert_receive {:model_call, _, _}, 5_000
    key = Session.get_state(session).session_key

    assert {:error, :not_found} =
             CodingAgent.ControlPlaneProvider.session_steer(
               key,
               "wrong-run",
               "/steering-regression auth",
               "rejected"
             )

    assert {:ok, %{id: "expanded"}} =
             CodingAgent.ControlPlaneProvider.session_steer(
               key,
               "steering-run",
               "/steering-regression auth",
               "expanded"
             )

    assert :ok = Session.steer(session, "/steering-regression auth", id: "literal")

    assert {:ok, [%{text: "Review auth"}, %{text: "/steering-regression auth"}]} =
             Session.pending_steers(session)

    :sys.replace_state(session, fn state ->
      %{state | tool_opts: Keyword.put(state.tool_opts, :native_managed_context, true)}
    end)

    assert {:error, :forbidden} =
             CodingAgent.ControlPlaneProvider.session_steer(
               key,
               "steering-run",
               "private invocation",
               "forbidden"
             )
  end

  @tag :capture_log
  test "a journal append failure is never acknowledged", %{tmp_dir: dir} do
    session = start_session(dir)
    state = Session.get_state(session)
    monitor = Process.monitor(session)

    :sys.replace_state(session, fn state ->
      :ok = :file.close(state.session_manager.append_device)
      state
    end)

    assert catch_exit(Session.steer(session, "not durable", id: "failed"))
    assert_receive {:DOWN, ^monitor, :process, ^session, _}, 5_000
    assert {:ok, journal} = SessionManager.load_from_file(state.session_file)
    assert accepted_entries(journal) == []
  end

  defp start_session(dir, path \\ nil) do
    path = path || Path.join(dir, "session.jsonl")

    unless File.exists?(path),
      do: :ok = SessionManager.save_to_file(path, SessionManager.new(dir))

    parent = self()
    reply = Mocks.mock_stream_fn_single(Mocks.assistant_message("ack"))

    stream_fn = fn model, context, options ->
      send(parent, {:model_call, self(), context})

      receive do
        :finish_model -> reply.(model, context, options)
      end
    end

    {:ok, session} =
      Session.start_link(
        cwd: dir,
        session_file: path,
        run_id: "steering-run",
        session_key: "agent:steering-tests:main",
        register: true,
        workspace_dir: Path.join(dir, "workspace"),
        system_prompt: "Steering journal regression",
        model: Mocks.mock_model(),
        thinking_level: :off,
        stream_fn: stream_fn,
        tools: [],
        mcp_tools: [],
        extension_inventory: {[], []}
      )

    Process.unlink(session)
    on_exit(fn -> if Process.alive?(session), do: stop_session(session) end)
    session
  end

  defp accepted_entries(journal) do
    Enum.filter(SessionManager.entries(journal), &(&1.custom_type == "lemon.input_accepted"))
  end

  defp count_text(messages, text), do: Enum.count(messages, &(Map.get(&1, :content) == text))

  # Model-bound steering may include volatile recall. The event and restored
  # transcript still have to match the exact user text without normalization.
  defp count_model_text(messages, text) do
    Enum.count(messages, fn
      %{role: :user, content: content} = message when is_binary(content) ->
        case Regex.run(~r/\[lemon:recalled-context id=([0-9a-f]{32})\]/, content) do
          [_, marker] -> Session.strip_recalled_context(message, marker).content == text
          nil -> content == text
        end

      _ ->
        false
    end)
  end

  defp finish_run(id, calls \\ []) do
    receive do
      {:model_call, call, context} ->
        send(call, :finish_model)
        finish_run(id, [context | calls])

      {:session_event, ^id, {:agent_end, _}, _} ->
        Enum.reverse(calls)

      {:session_event, ^id, {:error, reason, _}, _} ->
        flunk("unexpected session error: #{inspect(reason)}")

      {:session_event, ^id, _, _} ->
        finish_run(id, calls)
    after
      5_000 -> flunk("session did not reach its deterministic terminal boundary")
    end
  end

  defp kill_session(session) do
    agent = Session.get_state(session).agent
    monitor = Process.monitor(session)
    agent_monitor = Process.monitor(agent)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :killed}, 5_000
    assert_receive {:DOWN, ^agent_monitor, :process, ^agent, _}, 5_000
  end

  defp stop_session(session) do
    monitor = Process.monitor(session)
    GenServer.stop(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, _}, 5_000
  end
end
