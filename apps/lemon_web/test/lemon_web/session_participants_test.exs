defmodule LemonWeb.SessionParticipantsTest do
  # Every app's session lifecycle participant is registered in this umbrella
  # runtime; these tests exercise them together through SessionLifecycle.
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.SessionPins
  alias LemonCore.{ChatStateStore, ResumeToken, RunStore, SessionLifecycle, Store}
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

  test "a failing participant restores every app's state and keeps the session" do
    s = seed("restore")
    :ok = Participant.register(:test_fail_last, FailLast, order: 99)

    assert {:error, {:participant_delete_failed, :test_fail_last}} = SessionCleanup.delete(s.key)
    Participant.unregister(:test_fail_last)

    assert present?(s)
    assert [%Document{}] = MemoryStore.search(s.word, scope: :all, limit: 10)
    assert File.exists?(s.journal)
    assert File.exists?(s.archived)
    assert residue(s) == []
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

    :ok =
      RunStore.finalize("run-#{name}-#{unique}", %{
        session_key: key,
        agent_id: "participants_#{name}_#{unique}",
        origin: :web,
        prompt: "prompt",
        completed: %{ok: true, answer: "answer"}
      })

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
      word: word,
      msg_key: msg_key,
      journal: journal,
      archived: archived,
      directory: directory
    }
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
