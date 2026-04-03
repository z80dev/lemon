defmodule CodingAgent.Session.PersistenceTest do
  use ExUnit.Case, async: true

  alias AgentCore.Test.Mocks
  alias CodingAgent.Messages
  alias CodingAgent.Messages.CustomMessage
  alias CodingAgent.Session
  alias CodingAgent.Session.Persistence
  alias CodingAgent.Session.State
  alias CodingAgent.SessionManager
  alias LemonGateway.Engines.CliAdapter
  alias LemonGateway.Types.Job

  defmodule RouterPersistenceRunnerProxy do
    alias AgentCore.Test.Mocks
    alias CodingAgent.CliRunners.LemonRunner

    def start_link(opts) do
      if owner = Keyword.get(opts, :owner) do
        send(owner, {:runner_start_opts, opts})
      end

      LemonRunner.start_link(
        Keyword.put_new(
          opts,
          :stream_fn,
          Mocks.mock_stream_fn_single(Mocks.assistant_message("ack"))
        )
      )
    end

    def stream(pid), do: LemonRunner.stream(pid)
    def cancel(pid), do: LemonRunner.cancel(pid)
    def cancel(pid, reason), do: LemonRunner.cancel(pid, reason)
  end

  test "persist_message appends supported message types" do
    session_manager = SessionManager.new("/tmp")

    state = %{session_manager: session_manager}

    next_state =
      Persistence.persist_message(state, %Ai.Types.UserMessage{
        role: :user,
        content: "hello",
        timestamp: 1
      })

    assert SessionManager.entry_count(next_state.session_manager) == 1
  end

  test "restore_messages_from_session rebuilds serialized messages" do
    session_manager =
      SessionManager.new("/tmp")
      |> SessionManager.append_message(%{
        "role" => "user",
        "content" => "hello",
        "timestamp" => 1
      })

    [message] = Persistence.restore_messages_from_session(session_manager)
    assert %Ai.Types.UserMessage{content: "hello", timestamp: 1} = message
  end

  test "persist_message stores and restores async followups as custom messages" do
    session_manager = SessionManager.new("/tmp")
    state = %{session_manager: session_manager}

    message = %CustomMessage{
      custom_type: "async_followup",
      content: "task completed",
      details: %{source: :task, task_id: "task-123", run_id: "run-123"},
      timestamp: 123
    }

    next_state = Persistence.persist_message(state, message)

    [restored] = Persistence.restore_messages_from_session(next_state.session_manager)

    assert restored == %CustomMessage{
             role: :custom,
             custom_type: "async_followup",
             content: "task completed",
             display: true,
             details: %{
               "source" => :task,
               "task_id" => "task-123",
               "run_id" => "run-123"
             },
             timestamp: 123
           }
  end

  test "persisted async followups keep provenance when projected to llm messages" do
    session_manager = SessionManager.new("/tmp")
    state = %{session_manager: session_manager}

    message = %CustomMessage{
      custom_type: "async_followup",
      content: "task completed",
      details: %{
        source: :task,
        task_id: "task-123",
        run_id: "run-123",
        delivery: :steer_backlog
      },
      timestamp: 123
    }

    next_state = Persistence.persist_message(state, message)
    [restored] = Persistence.restore_messages_from_session(next_state.session_manager)
    [llm_message] = Messages.to_llm([restored])

    assert %Ai.Types.UserMessage{} = llm_message
    assert llm_message.content =~ "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"
    assert llm_message.content =~ "Source: task (ID: task-123)"
    assert llm_message.content =~ "Run: run-123"
    assert llm_message.content =~ "Delivery: steer_backlog"
    assert llm_message.content =~ "task completed"
  end

  test "save persists session file and updates session_file on state" do
    cwd =
      Path.join(System.tmp_dir!(), "coding-agent-session-#{System.unique_integer([:positive])}")

    session_manager = SessionManager.new(cwd)
    state = %{cwd: cwd, session_file: nil, session_manager: session_manager}

    assert {:ok, next_state} = Persistence.save(state)
    assert is_binary(next_state.session_file)
    assert File.exists?(next_state.session_file)

    File.rm_rf!(cwd)
  end

  @tag :tmp_dir
  test "router-delivered async followups survive save restore and llm projection", %{
    tmp_dir: tmp_dir
  } do
    async_followups = [
      %{source: :task, task_id: "task-123", run_id: "run-123", delivery: :router}
    ]

    job = %Job{
      run_id: "run-123",
      session_key: "agent:test:main",
      prompt: "[task task-123] delegated work completed",
      meta: %{model: Mocks.mock_model(), async_followups: async_followups}
    }

    assert {:ok, run_ref, %{runner_pid: _runner_pid}} =
             CliAdapter.start_run(
               RouterPersistenceRunnerProxy,
               "lemon",
               job,
               %{cwd: tmp_dir},
               self()
             )

    assert_receive {:runner_start_opts, start_opts}, 1_000
    assert start_opts[:async_followups] == async_followups

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :started, resume: %{value: session_id}}},
                   2_000

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: true}}, 2_000

    session_file = Path.join(SessionManager.get_session_dir(tmp_dir), "#{session_id}.jsonl")
    assert wait_until(fn -> File.exists?(session_file) end, 2_000)

    {:ok, loaded} = SessionManager.load_from_file(session_file)

    custom_entries =
      Enum.filter(SessionManager.entries(loaded), fn entry ->
        entry.type == :custom_message and entry.custom_type == "async_followup"
      end)

    assert length(custom_entries) == 1

    restored_messages = Persistence.restore_messages_from_session(loaded)

    [llm_followup] =
      Enum.filter(Messages.to_llm(restored_messages), fn
        %Ai.Types.UserMessage{content: content} when is_binary(content) ->
          String.contains?(content, "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]")

        _ ->
          false
      end)

    assert llm_followup.content =~ "Source: task (ID: task-123)"
    assert llm_followup.content =~ "Run: run-123"
    assert llm_followup.content =~ "Delivery: router"
    assert llm_followup.content =~ "[task task-123] delegated work completed"
  end

  @tag :tmp_dir
  test "async followup message_end dedupes persisted custom_message entries", %{tmp_dir: tmp_dir} do
    {:ok, session} =
      Session.start_link(
        cwd: tmp_dir,
        model: Mocks.mock_model(),
        stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ack"))
      )

    attrs = %{
      content: "[task task-456] delegated work completed",
      async_followups: [
        %{source: :task, task_id: "task-456", run_id: "run-456", delivery: :live}
      ],
      timestamp: 456
    }

    message = State.build_async_followup_message(attrs)

    assert :ok = Session.handle_async_followup(session, attrs)

    pending_prompt_timer_ref = Session.get_state(session).pending_prompt_timer_ref
    assert is_reference(pending_prompt_timer_ref)
    Process.cancel_timer(pending_prompt_timer_ref)

    :sys.replace_state(session, fn state ->
      %{state | pending_prompt_timer_ref: nil}
    end)

    send(session, {:agent_event, {:message_end, message}})
    send(session, {:agent_event, {:agent_end, [message]}})

    assert wait_until(fn ->
             state = Session.get_state(session)
             state.is_streaming == false and state.pending_prompt_timer_ref == nil
           end)

    assert :ok = Session.save(session)

    {:ok, loaded} =
      session
      |> Session.get_state()
      |> Map.fetch!(:session_file)
      |> SessionManager.load_from_file()

    custom_entries =
      Enum.filter(SessionManager.entries(loaded), fn entry ->
        entry.type == :custom_message and entry.custom_type == "async_followup"
      end)

    assert length(custom_entries) == 1
    assert hd(custom_entries).content == "[task task-456] delegated work completed"
  end

  defp wait_until(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline_ms) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline_ms ->
        false

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline_ms)
    end
  end
end
