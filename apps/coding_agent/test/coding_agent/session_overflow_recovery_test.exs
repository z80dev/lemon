defmodule CodingAgent.SessionOverflowRecoveryTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Test.Mocks
  alias CodingAgent.Session
  alias CodingAgent.Session.OverflowRecovery
  alias CodingAgent.SessionManager

  defmodule SummaryProvider do
    def stream(_model, _context, _opts) do
      send(Application.fetch_env!(:coding_agent, :overflow_recovery_test_owner), :summary_request)
      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.complete(stream, Mocks.assistant_message("previous work summarized"))
      {:ok, stream}
    end
  end

  defp start_session(opts \\ []) do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "session_overflow_recovery_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(cwd, ".lemon"))

    # Memory extraction shares the summary model but is not overflow compaction.
    # Keep it out of this provider-call regression, regardless of host config.
    File.write!(Path.join(cwd, ".lemon/config.toml"), "[features]\nsession_search = \"off\"\n")

    defaults = [
      cwd: cwd,
      workspace_dir: Path.join(cwd, "workspace"),
      model: Mocks.mock_model(),
      stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
    ]

    session =
      start_supervised!(
        {Session, Keyword.merge(defaults, opts)},
        id: make_ref(),
        restart: :temporary
      )

    on_exit(fn ->
      File.rm_rf!(cwd)
      File.rm_rf!(SessionManager.get_session_dir(cwd))
    end)

    session
  end

  defp current_signature(state) do
    {
      state.session_manager.header.id,
      state.session_manager.leaf_id,
      length(SessionManager.entries(state.session_manager)),
      state.turn_index,
      state.model.provider,
      state.model.id
    }
  end

  defp mark_overflow_recovery_state(session, signature, opts \\ []) do
    attempted = Keyword.get(opts, :attempted, true)
    reason = Keyword.get(opts, :reason, {:assistant_error, "context_length_exceeded"})
    partial_state = Keyword.get(opts, :partial_state, %{from: :test})
    monitor_ref = Keyword.get(opts, :monitor_ref, nil)
    task_pid = Keyword.get(opts, :task_pid, nil)

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery: %OverflowRecovery.State{
            in_progress: true,
            attempted: attempted,
            signature: signature,
            task_pid: task_pid,
            task_monitor_ref: monitor_ref,
            error_reason: reason,
            partial_state: partial_state
          }
      }
    end)
  end

  test "typed pre-output overflow compacts once, but committed output is never replayed" do
    previous_owner = Application.get_env(:coding_agent, :overflow_recovery_test_owner)
    Application.put_env(:coding_agent, :overflow_recovery_test_owner, self())
    LemonAi.ProviderRegistry.register(:session_overflow_recovery_test, SummaryProvider)

    on_exit(fn ->
      LemonAi.ProviderRegistry.unregister(:session_overflow_recovery_test)

      if previous_owner == nil do
        Application.delete_env(:coding_agent, :overflow_recovery_test_owner)
      else
        Application.put_env(:coding_agent, :overflow_recovery_test_owner, previous_owner)
      end
    end)

    for committed <- [false, true] do
      parent = self()
      calls = :atomics.new(1, [])

      model = %{
        Mocks.mock_model()
        | api: :session_overflow_recovery_test,
          provider: :session_overflow_recovery_test
      }

      stream_fn = fn model, context, opts ->
        attempt = :atomics.add_get(calls, 1, 1)
        send(parent, {:prompt_request, committed, attempt, context.messages})

        response =
          if attempt == 2 do
            %{
              Mocks.assistant_message(if(committed, do: "already visible", else: ""))
              | stop_reason: :error,
                content:
                  if(committed,
                    do: [%LemonAi.Types.TextContent{text: "already visible"}],
                    else: []
                  ),
                error_message: "opaque provider rejection",
                error_details: %{category: :context_length, output_committed: committed}
            }
          else
            Mocks.assistant_message(if(attempt == 1, do: "seed answer", else: "recovered"))
          end

        Mocks.mock_stream_fn_single(response).(model, context, opts)
      end

      settings = %CodingAgent.SettingsManager{
        compaction_enabled: false,
        keep_recent_tokens: 1,
        model_roles: %{},
        providers: %{session_overflow_recovery_test: %{api_key: "fake-key"}},
        extension_auto_load_default_paths: false
      }

      session =
        start_session(
          model: model,
          stream_fn: stream_fn,
          settings_manager: settings,
          system_prompt: "isolated overflow regression",
          tools: []
        )

      Session.subscribe(session)
      assert :ok = Session.prompt(session, String.duplicate("old history ", 200))
      assert_receive {:session_event, _, {:agent_end, _}}, 5_000
      assert :ok = Session.prompt(session, "retry me")

      if committed do
        assert_receive {:session_event, _,
                        {:error, {:assistant_error, "opaque provider rejection"}, partial_state}},
                       5_000

        assert %{
                 error_message: "opaque provider rejection",
                 error_details: %{category: :context_length, output_committed: true},
                 content: [%LemonAi.Types.TextContent{text: "already visible"}]
               } = List.last(partial_state.new_messages)

        state = Session.get_state(session)
        assert :atomics.get(calls, 1) == 2
        refute Enum.any?(SessionManager.entries(state.session_manager), &(&1.type == :compaction))
        refute_received :summary_request
        refute_received {:session_event, _, {:compaction_start, _}}
        refute state.is_streaming
      else
        assert_receive :summary_request, 5_000
        assert_receive {:session_event, _, {:compaction_start, %{reason: :overflow}}}, 5_000
        assert_receive {:session_event, _, {:compaction_complete, _}}, 5_000
        assert_receive {:prompt_request, false, 3, messages}, 5_000

        assert Enum.any?(messages, fn
                 %{role: :user, content: "retry me"} -> true
                 _ -> false
               end)

        assert_receive {:session_event, _, {:agent_end, _}}, 5_000
        state = Session.get_state(session)
        assert :atomics.get(calls, 1) == 3

        assert Enum.count(
                 SessionManager.entries(state.session_manager),
                 &(&1.type == :compaction)
               ) == 1

        refute state.auto_compaction.in_progress
        refute state.overflow_recovery.in_progress
        refute state.is_streaming
        refute_received {:session_event, _, {:compaction_start, _}}
        refute_received {:session_event, _, {:compaction_complete, _}}
        refute_received :summary_request
      end

      assert :ok = GenServer.stop(session)
    end
  end

  test "budget and cancellation failures cannot recover from an earlier typed overflow" do
    failed = %{
      Mocks.assistant_message("")
      | stop_reason: :error,
        error_details: %{category: :context_length, output_committed: false}
    }

    state = %{is_streaming: true, overflow_recovery: %OverflowRecovery.State{}}

    for reason <- [{:budget_exceeded, %{message: "context window"}}, {:canceled, :user}] do
      assert :no_recovery = OverflowRecovery.maybe_start(state, reason, [failed], self())
    end
  end

  test "stale overflow recovery result is ignored while recovery remains in progress" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    mark_overflow_recovery_state(session, signature)

    send(session, {:overflow_recovery_result, :stale_signature, {:error, :cannot_compact}})

    state_after = Session.get_state(session)
    assert state_after.overflow_recovery.in_progress
    assert state_after.overflow_recovery.signature == signature
    assert state_after.overflow_recovery.attempted
  end

  test "failed overflow compaction finalizes session and clears recovery flags" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    mark_overflow_recovery_state(session, signature)

    send(session, {:overflow_recovery_result, signature, {:error, :cannot_compact}})

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery.in_progress
    refute state_after.overflow_recovery.attempted
    refute state_after.is_streaming
  end

  test "Chinese context overflow errors are handled normally after retry already attempted" do
    session = start_session()

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery: %{state.overflow_recovery | attempted: true}
      }
    end)

    send(
      session,
      {:agent_event, {:error, {:assistant_error, "输入过长，超出最大长度"}, %{from: :test}}}
    )

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery.in_progress
    refute state_after.overflow_recovery.attempted
    refute state_after.is_streaming
  end

  test "overflow errors are handled normally after retry already attempted" do
    session = start_session()

    :sys.replace_state(session, fn state ->
      %{
        state
        | is_streaming: true,
          overflow_recovery: %{state.overflow_recovery | attempted: true}
      }
    end)

    send(
      session,
      {:agent_event, {:error, {:assistant_error, "context_length_exceeded"}, %{from: :test}}}
    )

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery.in_progress
    refute state_after.overflow_recovery.attempted
    refute state_after.is_streaming
  end

  test "emits failure telemetry when overflow recovery fails" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)
    mark_overflow_recovery_state(session, signature)

    handler_id = "overflow-recovery-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:coding_agent, :session, :overflow_recovery, :failure],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    send(session, {:overflow_recovery_result, signature, {:error, :cannot_compact}})

    assert_receive {:telemetry_event, [:coding_agent, :session, :overflow_recovery, :failure],
                    %{count: 1}, metadata},
                   1_000

    assert metadata.session_id == state.session_manager.header.id
    assert metadata.reason =~ "cannot_compact"
  end

  test "overflow recovery task timeout finalizes session and clears task tracking" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)

    task_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor_ref = Process.monitor(task_pid)
    mark_overflow_recovery_state(session, signature, task_pid: task_pid, monitor_ref: monitor_ref)

    send(session, {:overflow_recovery_task_timeout, monitor_ref})

    state_after = Session.get_state(session)
    refute state_after.overflow_recovery.in_progress
    assert state_after.overflow_recovery.task_pid == nil
    assert state_after.overflow_recovery.task_monitor_ref == nil
    refute state_after.is_streaming

    assert_receive {:DOWN, ^monitor_ref, :process, ^task_pid,
                    {:shutdown, :overflow_recovery_timeout}},
                   1_000
  end

  test "reset cancels overflow recovery and makes late task messages stale" do
    session = start_session()
    state = Session.get_state(session)

    task_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    task_monitor = Process.monitor(task_pid)
    stale_monitor_ref = make_ref()

    :sys.replace_state(session, fn session_state ->
      %{
        session_state
        | overflow_recovery: %OverflowRecovery.State{
            in_progress: true,
            attempted: true,
            signature: current_signature(state),
            task_pid: task_pid,
            task_monitor_ref: stale_monitor_ref,
            task_timeout_ref: make_ref(),
            started_at_ms: 12,
            error_reason: :overflow,
            partial_state: %{from: :old_session}
          }
      }
    end)

    assert :ok = Session.reset(session)
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, {:shutdown, :session_reset}}, 1_000

    assert Session.get_state(session).overflow_recovery == %OverflowRecovery.State{}

    send(session, {:overflow_recovery_task_timeout, stale_monitor_ref})
    assert Session.get_state(session).overflow_recovery == %OverflowRecovery.State{}
  end

  test "session termination cancels an active overflow recovery task" do
    session = start_session()

    task_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    task_monitor = Process.monitor(task_pid)

    :sys.replace_state(session, fn state ->
      %{
        state
        | overflow_recovery: %OverflowRecovery.State{
            in_progress: true,
            task_pid: task_pid,
            task_monitor_ref: make_ref(),
            task_timeout_ref: make_ref()
          }
      }
    end)

    assert :ok = GenServer.stop(session)

    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, {:shutdown, :session_terminated}},
                   1_000
  end
end
