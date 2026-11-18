defmodule LemonCore.RunHistoryCorruptionTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias LemonCore.{RunHistoryStore, SessionLifecycle}

  @session "agent:history:main"

  defp insert_raw(path, session_key, started_at_ms, run_id, blob) do
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")

    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "INSERT INTO run_history (session_key, started_at_ms, run_id, value_blob) VALUES (?1, ?2, ?3, ?4)"
      )

    :ok = Sqlite3.bind(stmt, [session_key, started_at_ms, run_id, {:blob, blob}])
    :done = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok = Sqlite3.close(conn)
  end

  defp start_history(name, tmp_dir) do
    start_supervised!(
      Supervisor.child_spec({RunHistoryStore, name: name, path: tmp_dir}, id: name)
    )
  end

  defp barrier(server), do: _ = :sys.get_state(server)

  @tag :tmp_dir
  test "an undecodable row is an error from fetch, not a silently shorter history", %{
    tmp_dir: tmp_dir
  } do
    name = :run_history_corruption_row
    start_history(name, tmp_dir)
    :ok = RunHistoryStore.put(name, @session, 1_000, "run_ok", %{summary: %{}})
    barrier(name)
    path = :sys.get_state(name).path

    # Corrupt the database at rest, then reopen it.
    stop_supervised!(name)
    insert_raw(path, @session, 2_000, "run_corrupt", <<131, 255, 0, 1>>)
    start_history(name, tmp_dir)

    assert {:error, :corrupt_history} = GenServer.call(name, {:get, @session, 50})
    assert {:error, :corrupt_history} = RunHistoryStore.fetch(name, @session, [])
  end

  @tag :tmp_dir
  test "a closed SQLite connection is an error from fetch, not an empty session", %{
    tmp_dir: tmp_dir
  } do
    name = :run_history_corruption_closed
    start_history(name, tmp_dir)

    :ok = RunHistoryStore.put(name, @session, 1_000, "run_1", %{summary: %{}})
    assert {:ok, [{"run_1", _}]} = RunHistoryStore.fetch(name, @session, [])

    %{conn: conn, stmts: stmts} = :sys.get_state(name)
    Enum.each(Map.values(stmts), &Sqlite3.release(conn, &1))
    :ok = Sqlite3.close(conn)

    assert {:error, _reason} = GenServer.call(name, {:get, @session, 50})
    assert {:error, _reason} = RunHistoryStore.fetch(name, @session, [])
  end

  @tag timeout: 60_000
  test "session deletion is not verified while run history cannot be read" do
    session_key = "agent:history:main:delete-#{System.unique_integer([:positive])}"
    :ok = RunHistoryStore.put(session_key, 1_000, "run_1", %{summary: %{}})
    barrier(RunHistoryStore)

    :ok = :sys.suspend(RunHistoryStore)

    result =
      try do
        LemonCore.TestSupport.SessionCleanup.delete(session_key)
      after
        :sys.resume(RunHistoryStore)
      end

    on_exit(fn -> RunHistoryStore.delete_session(session_key) end)

    assert {:error, _reason} = result
  end

  @tag :tmp_dir
  test "a failed SQL deletion is returned by the owner, not acknowledged as deleted", %{
    tmp_dir: tmp_dir
  } do
    name = :run_history_delete_failure
    start_history(name, tmp_dir)
    :ok = RunHistoryStore.put(name, @session, 1_000, "run_1", %{summary: %{}})
    assert {:ok, [{"run_1", _}]} = RunHistoryStore.fetch(name, @session, [])
    block_deletes(:sys.get_state(name).path, @session)

    assert {:error, :history_delete_failed} = RunHistoryStore.delete_session(name, @session)
    assert {:ok, [{"run_1", _}]} = RunHistoryStore.fetch(name, @session, [])
  end

  test "reset and delete never verify a session whose history deletion failed" do
    session_key = "agent:history:main:sqlfail-#{System.unique_integer([:positive])}"
    :ok = RunHistoryStore.put(session_key, 1_000, "run_1", %{summary: %{}})
    assert {:ok, [_]} = RunHistoryStore.fetch(session_key, limit: 1)
    path = :sys.get_state(RunHistoryStore).path
    block_deletes(path, session_key)

    on_exit(fn ->
      unblock_deletes(path, session_key)
      RunHistoryStore.delete_session(session_key)
    end)

    assert {:error, :history_delete_failed} = RunHistoryStore.delete_session(session_key)
    assert {:error, :outcome_unknown} = LemonCore.TestSupport.SessionCleanup.reset(session_key)
    assert {:error, :outcome_unknown} = LemonCore.TestSupport.SessionCleanup.delete(session_key)
    assert {:ok, [_]} = RunHistoryStore.fetch(session_key, limit: 1)
  end

  # A trigger makes the owner's DELETE of one session's rows fail with an SQL
  # error while reads, and other sessions' deletes, still work.
  defp block_deletes(path, session_key) do
    exec(path, """
    CREATE TRIGGER IF NOT EXISTS #{trigger(session_key)} BEFORE DELETE ON run_history
    WHEN OLD.session_key = '#{session_key}'
    BEGIN SELECT RAISE(ABORT, 'blocked by test'); END
    """)
  end

  defp unblock_deletes(path, session_key),
    do: exec(path, "DROP TRIGGER IF EXISTS #{trigger(session_key)}")

  defp trigger(session_key),
    do: "block_delete_" <> Base.encode16(:crypto.hash(:md5, session_key), case: :lower)

  defp exec(path, sql) do
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
    :ok = Sqlite3.execute(conn, sql)
    :ok = Sqlite3.close(conn)
  end
end
