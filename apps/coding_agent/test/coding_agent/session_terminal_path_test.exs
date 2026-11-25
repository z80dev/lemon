defmodule CodingAgent.SessionTerminalPathTest do
  # Every way a run ends without the agent emitting its own terminal event
  # (abort during overflow recovery, a stale or failed recovery result, a
  # recovery-band block) must go through one terminal path: the pending prompt
  # ref is cleared, the terminal event is broadcast once and streams complete,
  # so the next prompt, executor turn or /compact is accepted.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias CodingAgent.Session
  alias CodingAgent.Session.{CompactionLifecycle, CompactionManager, OverflowRecovery}
  alias CodingAgent.SessionManager
  alias LemonAgent.Test.Mocks

  @overflow {:assistant_error, "context_length_exceeded"}

  defp start_session(tmp_dir) do
    manager =
      Enum.reduce(1..6, SessionManager.new(tmp_dir), fn i, acc ->
        message =
          if rem(i, 2) == 1 do
            %{"role" => "user", "content" => String.duplicate("user#{i} ", 200), "timestamp" => i}
          else
            %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => String.duplicate("answer#{i} ", 200)}],
              "stop_reason" => "stop",
              "timestamp" => i
            }
          end

        SessionManager.append_message(acc, message)
      end)

    session_file = Path.join(tmp_dir, "session.jsonl")
    :ok = SessionManager.save_to_file(session_file, manager)

    opts = [
      cwd: tmp_dir,
      workspace_dir: Path.join(tmp_dir, "workspace"),
      tools: [],
      extension_inventory: {[], []},
      mcp_tools: [],
      session_file: session_file,
      model: Mocks.mock_model(),
      stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
    ]

    start_supervised!(Supervisor.child_spec({Session, opts}, restart: :temporary))
  end

  # The state overflow recovery leaves behind while its summary task runs: the
  # agent is idle, the session still reports the run as streaming.
  defp enter_overflow_recovery(session, task_pid \\ nil) do
    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery: %OverflowRecovery.State{
            in_progress: true,
            attempted: true,
            signature: CompactionManager.session_signature(state),
            task_pid: task_pid,
            error_reason: @overflow,
            partial_state: %{messages: []}
          }
      }
    end)

    Session.get_state(session).overflow_recovery.signature
  end

  defp append_steer(session) do
    :sys.replace_state(session, fn state ->
      manager =
        SessionManager.append_message(state.session_manager, %{
          "role" => "user",
          "content" => "steer during summary",
          "timestamp" => System.system_time(:millisecond)
        })

      %{state | session_manager: manager}
    end)
  end

  defp assert_idle(session) do
    state = Session.get_state(session)
    refute state.is_streaming
    assert state.pending_prompt_timer_ref == nil
    refute state.overflow_recovery.in_progress
    state
  end

  describe "overflow recovery" do
    test "abort completes the run with a canceled event and kills the summary task",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      task = spawn(fn -> Process.sleep(:infinity) end)
      task_ref = Process.monitor(task)
      enter_overflow_recovery(session, task)
      Session.subscribe(session)

      :ok = Session.abort(session)

      assert_receive {:session_event, _, {:canceled, :assistant_aborted}, _}, 2_000
      assert_receive {:DOWN, ^task_ref, :process, ^task, _}, 2_000
      state = assert_idle(session)
      assert state.terminal_event == {:canceled, :assistant_aborted}
      refute_received {:session_event, _, {:canceled, _}, _}

      assert :ok = Session.prompt(session, "after abort")
      assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    end

    test "a journal append during the summary window still ends the run on failure",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      signature = enter_overflow_recovery(session)
      append_steer(session)
      Session.subscribe(session)

      send(session, {:overflow_recovery_result, signature, {:error, :cannot_compact}})

      assert_receive {:session_event, _, {:error, @overflow, _}, _}, 2_000
      assert_idle(session)
      assert :ok = Session.prompt(session, "next")
      assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    end

    test "a journal append during the summary window still applies the summary",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      signature = enter_overflow_recovery(session)
      [_first, second | _] = SessionManager.get_branch(Session.get_state(session).session_manager)
      append_steer(session)
      Session.subscribe(session)

      result =
        {:ok,
         %{
           summary: "recovered summary",
           first_kept_entry_id: second.id,
           tokens_before: 1_000,
           details: %{}
         }}

      send(session, {:overflow_recovery_result, signature, result})

      assert_receive {:session_event, _, {:compaction_complete, %{summary: "recovered summary"}},
                      _},
                     2_000

      assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
      state = assert_idle(session)

      # The steer appended during the window stays after the compaction point.
      messages = SessionManager.build_session_context(state.session_manager).messages
      assert Enum.any?(messages, &match?(%{"content" => "steer during summary"}, &1))
      assert :ok = Session.prompt(session, "next")
    end

    test "a result for a moved branch fails the run instead of stranding it",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      signature = enter_overflow_recovery(session)
      [first | _] = SessionManager.get_branch(Session.get_state(session).session_manager)

      :sys.replace_state(session, fn state ->
        manager =
          state.session_manager
          |> SessionManager.set_leaf_id(first.id)
          |> SessionManager.append_message(%{"role" => "user", "content" => "elsewhere"})

        %{state | session_manager: manager}
      end)

      Session.subscribe(session)
      send(session, {:overflow_recovery_result, signature, {:ok, %{}}})

      assert_receive {:session_event, _, {:error, @overflow, _}, _}, 2_000
      assert_idle(session)
      assert :ok = Session.prompt(session, "next")
    end
  end

  describe "recovery-band block" do
    test "a blocked prompt releases the session for /compact and executor turns",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)

      :sys.replace_state(session, fn state ->
        %{
          state
          | auto_compaction: %CompactionLifecycle.State{
              blocked_signature: {:blocked, state.session_manager.leaf_id}
            }
        }
      end)

      Session.subscribe(session)
      assert :ok = Session.prompt(session, "blocked")
      assert_receive {:session_event, _, {:error, :compaction_recovery_band, nil}, _}, 2_000
      state = assert_idle(session)
      assert state.terminal_event == {:error, :compaction_recovery_band, nil}

      assert :ok = GenServer.call(session, {:retain_root, 60_000})
      assert :ok = Session.compact(session, summary: "manual summary", keep_recent_tokens: 1)
    end

    test "a blocked deferred prompt after auto compaction releases the session",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)

      signature =
        :sys.replace_state(session, fn state ->
          %{
            state
            | is_streaming: true,
              pending_prompt_timer_ref: make_ref(),
              auto_compaction: %CompactionLifecycle.State{
                in_progress: true,
                signature: CompactionManager.session_signature(state),
                pending_prompt: {%LemonAi.Types.UserMessage{content: "deferred"}, nil}
              }
          }
        end).auto_compaction.signature

      Session.subscribe(session)

      send(
        session,
        {:auto_compaction_result, signature, {:error, :compaction_recovery_band}}
      )

      assert_receive {:session_event, _, {:error, :compaction_recovery_band, nil}, _}, 2_000
      assert_idle(session)
      assert :ok = GenServer.call(session, {:retain_root, 60_000})
      assert :ok = Session.compact(session, summary: "manual summary", keep_recent_tokens: 1)
    end
  end

  describe "agent event fence" do
    test "a late terminal event cannot clear is_streaming for a newly accepted prompt",
         %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir)
      Session.subscribe(session)

      # Queue, in order: the prompt, a late terminal event from an earlier run,
      # and a second prompt. The first prompt's dispatch runs after both.
      :ok = :sys.suspend(session)
      first = Task.async(fn -> Session.prompt(session, "first") end)
      wait_for_queue(session, 1)
      send(session, {:agent_event, {:canceled, :assistant_aborted}})
      second = Task.async(fn -> Session.prompt(session, "second") end)
      wait_for_queue(session, 3)
      :ok = :sys.resume(session)

      assert :ok = Task.await(first)
      assert {:error, :busy} = Task.await(second)

      assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
      refute_received {:session_event, _, {:canceled, _}, _}
      state = assert_idle(session)
      assert state.terminal_event == nil or match?({:agent_end, _}, state.terminal_event)

      user_texts =
        state.session_manager
        |> SessionManager.build_session_context()
        |> Map.fetch!(:messages)
        |> Enum.filter(&match?(%{"role" => "user"}, &1))
        |> Enum.map(&user_text(&1["content"]))

      assert "first" in user_texts
      refute "second" in user_texts
    end
  end

  defp user_text(content) when is_binary(content), do: content

  defp user_text(content) when is_list(content),
    do: Enum.map_join(content, "", &(&1["text"] || ""))

  defp wait_for_queue(pid, count) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} when n >= count ->
          {:halt, :ok}

        _ ->
          Process.sleep(5)
          {:cont, nil}
      end
    end)
  end
end
