defmodule LemonWeb.SessionParticipantsTest do
  # Every app's session lifecycle participant is registered in this umbrella
  # runtime; these tests exercise them together through SessionLifecycle.
  use ExUnit.Case, async: false

  alias CodingAgent.{SessionManager, TaskStore}
  alias LemonAgent.ModelRuntime.SessionPins

  alias LemonCore.{
    ChatStateStore,
    Introspection,
    NativeSessionOwner,
    ResumeToken,
    RunStore,
    SessionLifecycle,
    Store,
    TerminalOutbox
  }

  alias LemonCore.SessionLifecycle.Participant
  alias LemonMemory.Document
  alias LemonMemory.Store, as: MemoryStore
  alias LemonWeb.TestSupport.SessionCleanup

  defmodule FailLast do
    @behaviour LemonCore.SessionLifecycle.Participant
    def snapshot(_key, _op), do: {:ok, nil}
    def delete(_key, _op, _snapshot), do: {:error, :injected}
    def verify_deleted(_key, _op, _snapshot), do: :ok
    def restore(_key, _op, _snapshot), do: :ok
  end

  setup do
    on_exit(fn -> Participant.unregister(:test_fail_last) end)
    :ok
  end

  test "registered participants cover the session-keyed stores of every owning app" do
    names = Participant.registered(:delete) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for name <- [
          :exec_approval_grants,
          :run_diagnostics,
          :memory,
          :goals,
          :channels,
          :web,
          :router,
          :native_sessions
        ],
        do: assert(name in names)
  end

  test "delete removes memory, channel indexes, web cwd, pins, goals, router state and journals" do
    s = seed("delete")
    other = seed("delete_other")

    assert [%Document{}] = MemoryStore.search(s.word, scope: :all, limit: 10)
    assert {:ok, %{verified: true}} = SessionCleanup.delete(s.key)

    # Memory recall and search return nothing for the deleted session.
    assert MemoryStore.search(s.word, scope: :all, limit: 10) == []
    assert MemoryStore.search(s.word, scope: :session, scope_key: s.key, limit: 10) == []
    assert MemoryStore.get_by_session(s.key, limit: 10) == []
    assert {:ok, []} = MemoryStore.fetch_session_documents(s.key)

    assert gone?(s)
    refute File.exists?(s.journal)
    refute File.exists?(s.archived)
    assert residue(s) == []

    # Another session's state is untouched.
    assert present?(other)
    assert [%Document{}] = MemoryStore.search(other.word, scope: :all, limit: 10)
    assert File.exists?(other.journal)
  end

  test "diagnostics and live-run data are erased without removing a terminal decision" do
    s = seed("diagnostics")
    other = seed("diagnostics_other")

    scoped = diagnostic(s, s.key)
    unscoped = diagnostic(s, nil)
    foreign = diagnostic(s, other.key)
    other_event = diagnostic(other, other.key)

    assert {:ok, decision} = TerminalOutbox.decision(s.run_id)
    assert is_binary(decision.digest)

    assert {:ok, %{summary: %{presentation_cwd: "/tmp/participant-cwd"}}} =
             RunStore.fetch(s.run_id)

    assert {:ok, %{verified: true}} = SessionCleanup.delete(s.key)

    assert {:error, :evicted} = RunStore.fetch(s.run_id)
    assert {:ok, ^decision} = TerminalOutbox.decision(s.run_id)
    assert :ok = RunStore.finalize(s.run_id, s.summary)
    assert {:error, :evicted} = RunStore.fetch(s.run_id)
    assert {:ok, []} = RunStore.fetch_history(s.key)
    assert SessionLifecycle.get(s.key) == nil

    assert Enum.map(Introspection.list(run_id: s.run_id), & &1.event_id) == [foreign]
    assert Enum.any?(Introspection.list(run_id: other.run_id), &(&1.event_id == other_event))
    assert {:ok, %{summary: %{session_key: key}}} = RunStore.fetch(other.run_id)
    assert key == other.key
    refute scoped in Enum.map(Introspection.list(session_key: s.key), & &1.event_id)
    refute unscoped in Enum.map(Introspection.list(run_id: s.run_id), & &1.event_id)
  end

  test "delete erases stopped and archived task journals and crash residue, but not a fork" do
    s = seed("children")
    other = seed("children_other")
    assert :ok = NativeSessionOwner.bind(s.token, s.key)
    assert :ok = NativeSessionOwner.bind(other.token, other.key)

    {task_id, child} = legacy_task(s)
    nested_id = "nested-#{s.native_id}"
    nested = journal(s, nested_id, session_key: s.key, parent_session: child.id, archive: true)
    stopped = journal(s, "stopped-#{s.native_id}", session_key: s.key, parent_session: nested_id)
    old_staged = child.path <> ".deleting-123456789012"
    File.rename!(child.path, old_staged)

    # Independent forks have parentSession lineage too; they are not task
    # children and must not be deleted even if the chat resume row expires.
    fork = Path.join(s.directory, "independent-fork-#{s.native_id}.jsonl")

    assert {:ok, _} =
             SessionManager.fork_file(s.journal, fork,
               id: Path.basename(fork, ".jsonl"),
               session_key: other.key
             )

    foreign_staged = other.archived <> ".deleting-123456789012"
    File.rename!(other.archived, foreign_staged)
    assert {:ok, %{verified: true}} = SessionCleanup.delete(s.key)

    for path <- [child.path, old_staged, nested, stopped], do: refute(File.exists?(path))
    assert {:error, :not_found} = TaskStore.get(task_id)
    assert SessionPins.get(child.id) == nil
    assert NativeSessionOwner.fetch(s.token) == {:ok, nil}
    assert NativeSessionOwner.fetch(other.token) == {:ok, other.key}

    assert {:ok, %{header: %{parent_session: parent, session_key: owner}}} =
             SessionManager.load_from_file(fork)

    assert parent == s.native_id
    assert owner == other.key
    assert File.exists?(foreign_staged)
  end

  test "confirmed cleanup finds crash-staged legacy journals after canonical keys are gone" do
    s = seed("crashed_delete")
    digest = Base.encode16(:crypto.hash(:sha256, s.key), case: :lower)
    staged = s.archived <> ".deleting-#{digest}-123456789012"
    File.rename!(s.archived, staged)
    File.rm!(s.journal)
    checkpoint = journal(s, "checkpoint-#{s.native_id}", session_key: s.key)
    tmp = checkpoint <> ".tmp.123456789abc"
    File.rename!(checkpoint, tmp)
    :ok = ChatStateStore.delete(s.key)
    :ok = RunStore.delete_session(s.key)
    assert SessionLifecycle.get(s.key) == nil

    assert {:ok, %{existed: false, verified: true}} = SessionCleanup.delete(s.key)
    refute File.exists?(staged)
    refute File.exists?(tmp)
    assert SessionPins.get(s.native_id) == nil
  end

  test "a failing participant restores every app's state and keeps the session" do
    s = seed("restore")
    {task_id, child} = legacy_task(s)
    prior_staged = s.archived <> ".deleting-123456789012"
    File.cp!(s.archived, prior_staged)
    event_id = diagnostic(s, s.key)
    :ok = Participant.register(:test_fail_last, FailLast, order: 99)

    assert {:error, {:participant_delete_failed, :test_fail_last}} = SessionCleanup.delete(s.key)
    Participant.unregister(:test_fail_last)

    assert present?(s)
    assert [%Document{}] = MemoryStore.search(s.word, scope: :all, limit: 10)
    assert File.exists?(s.journal)
    assert File.exists?(s.archived)
    assert File.exists?(child.path)
    assert {:ok, %{session_id: id}, [:kept_event]} = TaskStore.get(task_id)
    assert id == child.id
    assert SessionPins.get(id)
    assert residue(s) == [Path.basename(prior_staged)]
    assert Enum.any?(Introspection.list(run_id: s.run_id), &(&1.event_id == event_id))

    assert {:ok, %{summary: %{presentation_cwd: "/tmp/participant-cwd"}}} =
             RunStore.fetch(s.run_id)

    assert SessionLifecycle.get(s.key)
    assert RunStore.history(s.key, limit: 1) != []
  end

  test "reset removes resumable channel indexes and pending compaction but keeps preferences" do
    s = seed("reset")

    assert {:ok, %{verified: true}} = SessionCleanup.reset(s.key)

    assert Store.get(:telegram_msg_session, s.msg_key) == nil
    assert Store.get(:telegram_msg_resume, s.msg_key) == nil
    assert Store.get(:discord_selected_resume, s.key) == nil
    assert Store.get(:pending_compaction, s.key) == nil

    assert Store.get(:telegram_session_model, s.key) == "model"
    assert Store.get(:web_session_cwds, s.key) == "/tmp/participant-cwd"
    assert Store.get(:goals, s.key) != nil
    assert [%Document{}] = MemoryStore.search(s.word, scope: :all, limit: 10)
  end

  defp seed(name) do
    unique = System.unique_integer([:positive])
    key = "agent:participants_#{name}_#{unique}:main"
    native_id = "native-#{name}-#{unique}"
    word = "zephyrword#{name}#{unique}"
    msg_key = {"acct-#{unique}", unique, nil, 0, 1}
    token = %ResumeToken{engine: "lemon", value: native_id}

    run_id = "run-#{name}-#{unique}"

    summary = %{
      session_key: key,
      agent_id: "participants_#{name}_#{unique}",
      origin: :web,
      prompt: "prompt",
      presentation_cwd: "/tmp/participant-cwd",
      completed: %{ok: true, answer: "answer"}
    }

    :ok = RunStore.finalize(run_id, summary)

    assert eventually(fn -> SessionLifecycle.get(key) != nil end)

    :ok =
      ChatStateStore.put(key, %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: native_id,
        updated_at: System.system_time(:millisecond)
      })

    :ok =
      MemoryStore.put_sync(%Document{
        doc_id: "mem_#{unique}",
        run_id: "run-#{name}-#{unique}",
        session_key: key,
        agent_id: "participants_#{name}_#{unique}",
        scope: :session,
        started_at_ms: System.system_time(:millisecond),
        ingested_at_ms: System.system_time(:millisecond),
        prompt_summary: "remember #{word}",
        answer_summary: "noted",
        tools_used: [],
        outcome: :ok,
        meta: %{}
      })

    :ok = Store.put(:telegram_msg_session, msg_key, key)
    :ok = Store.put(:telegram_msg_resume, msg_key, token)
    :ok = Store.put(:telegram_session_model, key, "model")
    :ok = Store.put(:discord_session_model, key, "model")
    :ok = Store.put(:discord_selected_resume, key, token)
    :ok = Store.put(:pending_compaction, key, %{reason: "test"})
    :ok = Store.put(:agent_messaging_sessions, key, %{profile_id: "p"})
    :ok = Store.put(:goals, key, %{objective: "ship it", status: "active"})
    :ok = LemonWeb.SessionCwd.remember(key, "/tmp/participant-cwd")
    :ok = SessionPins.pin(native_id, "anthropic", nil, "model")

    directory =
      Path.join([CodingAgent.Config.agent_dir(), "sessions", "--participants-#{unique}--"])

    File.mkdir_p!(Path.join(directory, "archive"))
    journal = Path.join(directory, native_id <> ".jsonl")
    archived = Path.join([directory, "archive", native_id <> ".jsonl"])
    File.write!(journal, ~s({"type":"session","id":"#{native_id}"}\n))
    File.write!(archived, ~s({"type":"session","id":"#{native_id}"}\n))

    on_exit(fn ->
      Participant.unregister(:test_fail_last)
      SessionCleanup.delete(key)
      File.rm_rf(directory)
    end)

    %{
      key: key,
      native_id: native_id,
      token: token,
      run_id: run_id,
      summary: summary,
      word: word,
      msg_key: msg_key,
      journal: journal,
      archived: archived,
      directory: directory
    }
  end

  defp diagnostic(s, session_key) do
    id = "diagnostic-#{System.unique_integer([:positive])}"
    ts = System.system_time(:millisecond)

    :ok =
      Introspection.record(:diagnostic, %{cwd: s.summary.presentation_cwd},
        event_id: id,
        session_key: session_key,
        run_id: s.run_id,
        ts_ms: ts
      )

    assert {:ok, %{event_id: ^id}} = Store.fetch(:introspection_log, {ts, id})
    on_exit(fn -> Store.delete(:introspection_log, {ts, id}) end)
    id
  end

  defp legacy_task(s) do
    id = "task-child-#{s.native_id}"
    path = journal(s, id, parent_session: s.native_id)

    task_id =
      TaskStore.new_task(%{
        session_key: s.key,
        parent_session_id: s.native_id,
        session_id: id,
        prompt: "session-private task"
      })

    :ok = TaskStore.append_event(task_id, :kept_event)
    :ok = TaskStore.finish(task_id, :stopped)
    :ok = SessionPins.pin(id, "anthropic", nil, "model")
    {task_id, %{id: id, path: path}}
  end

  defp journal(s, id, opts) do
    session =
      SessionManager.new(s.summary.presentation_cwd, Keyword.put(opts, :id, id))

    directory = if opts[:archive], do: Path.join(s.directory, "archive"), else: s.directory
    path = Path.join(directory, id <> ".jsonl")
    assert :ok = SessionManager.save_to_file(path, session)
    path
  end

  defp rows(s) do
    [
      Store.get(:telegram_msg_session, s.msg_key),
      Store.get(:telegram_msg_resume, s.msg_key),
      Store.get(:telegram_session_model, s.key),
      Store.get(:discord_session_model, s.key),
      Store.get(:discord_selected_resume, s.key),
      Store.get(:pending_compaction, s.key),
      Store.get(:agent_messaging_sessions, s.key),
      Store.get(:goals, s.key),
      Store.get(:web_session_cwds, s.key),
      SessionPins.get(s.native_id)
    ]
  end

  defp gone?(s), do: Enum.all?(rows(s), &is_nil/1)
  defp present?(s), do: Enum.all?(rows(s), &(not is_nil(&1)))

  defp residue(s) do
    for dir <- [s.directory, Path.join(s.directory, "archive")],
        name <- File.ls!(dir),
        String.contains?(name, ".deleting-"),
        do: name
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(), do: true, else: Process.sleep(10) && eventually(fun, attempts - 1)
  end
end
