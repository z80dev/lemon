defmodule CodingAgent.SessionAutoCompactionAsyncTest do
  use ExUnit.Case, async: true

  alias AgentCore.Test.Mocks
  alias CodingAgent.Session
  alias CodingAgent.SessionManager

  defp start_session(opts \\ []) do
    cwd =
      Path.join(
        System.tmp_dir!(),
        "session_auto_compaction_async_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(cwd)

    defaults = [
      cwd: cwd,
      model: Mocks.mock_model(),
      stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
    ]

    {:ok, session} = Session.start_link(Keyword.merge(defaults, opts))
    session
  end

  defp mark_auto_compaction_in_progress(session, signature) do
    :sys.replace_state(session, fn state ->
      state
      |> Map.put(:auto_compaction_signature, signature)
      |> Map.put(:auto_compaction_in_progress, true)
    end)
  end

  defp auto_compaction_in_progress?(state) do
    Map.get(state, :auto_compaction_in_progress) == true
  end

  defp trigger_auto_compaction_result(session, signature, result) do
    send(session, {:auto_compaction_result, signature, {:ok, result}})
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

  test "stale auto_compaction_result is ignored and does not mutate session_manager" do
    session = start_session()

    send(session, {:agent_event, {:message_end, Mocks.user_message("hello")}})
    before = Session.get_state(session)
    signature = current_signature(before)

    mark_auto_compaction_in_progress(session, signature)

    stale_result = %{
      summary: "stale summary",
      first_kept_entry_id: before.session_manager.leaf_id,
      tokens_before: 123,
      details: %{source: "stale"}
    }

    trigger_auto_compaction_result(session, :stale_signature, stale_result)
    state = Session.get_state(session)

    assert SessionManager.entries(state.session_manager) ==
             SessionManager.entries(before.session_manager)

    assert auto_compaction_in_progress?(state)
  end

  test "matching auto_compaction_result appends compaction entry and clears in-progress state" do
    session = start_session()

    send(session, {:agent_event, {:message_end, Mocks.user_message("before compact")}})
    send(session, {:agent_event, {:message_end, Mocks.assistant_message("answer")}})

    state_before = Session.get_state(session)

    initial_compaction_count =
      Enum.count(SessionManager.entries(state_before.session_manager), &(&1.type == :compaction))

    signature = current_signature(state_before)
    mark_auto_compaction_in_progress(session, signature)

    result = %{
      summary: "auto summary",
      first_kept_entry_id: state_before.session_manager.leaf_id,
      tokens_before: 456,
      details: %{source: "auto"}
    }

    trigger_auto_compaction_result(session, signature, result)

    state_after = Session.get_state(session)

    compactions =
      Enum.filter(SessionManager.entries(state_after.session_manager), &(&1.type == :compaction))

    assert length(compactions) == initial_compaction_count + 1

    last_compaction = List.last(compactions)
    assert last_compaction.summary == "auto summary"
    assert last_compaction.first_kept_entry_id == state_before.session_manager.leaf_id
    assert last_compaction.tokens_before == 456

    refute auto_compaction_in_progress?(state_after)
  end

  test "session remains responsive to get_stats and health_check while auto compaction is in progress" do
    session = start_session()
    mark_auto_compaction_in_progress(session, "sig-in-progress")

    stats_task = Task.async(fn -> Session.get_stats(session) end)
    health_task = Task.async(fn -> Session.health_check(session) end)

    stats = Task.await(stats_task, 200)
    health = Task.await(health_task, 200)

    assert is_map(stats)
    assert Map.has_key?(stats, :session_id)

    assert is_map(health)
    assert Map.has_key?(health, :status)
    assert Map.has_key?(health, :session_id)
  end

  test "auto compaction timeout clears in-progress state and task tracking" do
    session = start_session()
    state = Session.get_state(session)
    signature = current_signature(state)

    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    monitor_ref = Process.monitor(task_pid)

    :sys.replace_state(session, fn current ->
      current
      |> Map.put(:auto_compaction_signature, signature)
      |> Map.put(:auto_compaction_in_progress, true)
      |> Map.put(:auto_compaction_task_pid, task_pid)
      |> Map.put(:auto_compaction_task_monitor_ref, monitor_ref)
    end)

    send(session, {:auto_compaction_task_timeout, monitor_ref})

    state_after = Session.get_state(session)
    refute state_after.auto_compaction_in_progress
    assert state_after.auto_compaction_task_pid == nil
    assert state_after.auto_compaction_task_monitor_ref == nil
  end
end
