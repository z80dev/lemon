defmodule CodingAgent.SessionIndexIssue565Test do
  use ExUnit.Case, async: false

  alias CodingAgent.{Config, SessionIndex, SessionManager}
  alias CodingAgent.SessionManager.SessionEntry
  alias Exqlite.Sqlite3

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_agent_dir = Application.fetch_env(:coding_agent, :agent_dir)
    old_override = System.get_env("LEMON_AGENT_DIR")
    Application.put_env(:coding_agent, :agent_dir, tmp_dir)
    System.delete_env("LEMON_AGENT_DIR")

    on_exit(fn ->
      case old_agent_dir do
        {:ok, value} -> Application.put_env(:coding_agent, :agent_dir, value)
        :error -> Application.delete_env(:coding_agent, :agent_dir)
      end

      if old_override,
        do: System.put_env("LEMON_AGENT_DIR", old_override),
        else: System.delete_env("LEMON_AGENT_DIR")
    end)

    cwd = Path.join(tmp_dir, "workspace")
    %{cwd: cwd, directory: Config.sessions_dir(cwd)}
  end

  test "listing N unchanged journals opens zero journal files, including after append and finalize",
       ctx do
    sessions =
      for number <- 1..24 do
        path = Path.join(ctx.directory, "session-#{number}.jsonl")

        session =
          SessionManager.new(ctx.cwd, id: "session-#{number}")
          |> SessionManager.persist(path)
          |> SessionManager.append_entry(SessionEntry.session_info("Title #{number}"))
          |> SessionManager.append_message(%{"role" => "user", "content" => "hello"})

        assert :ok = SessionManager.checkpoint(session)
        assert :ok = SessionManager.close(session)
        session
      end

    {{:ok, rows}, opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert length(rows) == length(sessions)
    assert Enum.sort(Enum.map(rows, & &1.title)) == Enum.sort(for n <- 1..24, do: "Title #{n}")
    assert journal_opens(opens) == []
    assert File.regular?(SessionIndex.path(ctx.directory))
  end

  test "a deleted index rebuilds titles and activity, then stops reopening journals", ctx do
    path = Path.join(ctx.directory, "one.jsonl")

    session =
      SessionManager.new(ctx.cwd, id: "one")
      |> SessionManager.persist(path)
      |> SessionManager.append_entry(SessionEntry.session_info("Rebuilt title"))

    assert :ok = SessionManager.checkpoint(session)
    assert :ok = SessionManager.close(session)
    assert {:ok, [before]} = SessionManager.list_sessions(ctx.cwd)
    File.rm!(SessionIndex.path(ctx.directory))

    {{:ok, [after_rebuild]}, first_opens} =
      trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)

    assert after_rebuild == before
    assert journal_opens(first_opens) == [path]
    {{:ok, [_]}, second_opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert journal_opens(second_opens) == []
  end

  test "external append, atomic replacement and journal deletion reconcile only changed rows",
       ctx do
    first = save_session(ctx, "first", "Original")
    second = save_session(ctx, "second", "Other")
    assert {:ok, [_, _]} = SessionManager.list_sessions(ctx.cwd)

    File.write!(
      first,
      Jason.encode!(%{
        "type" => "sessionInfo",
        "name" => "External title",
        "timestamp" => 4_000_000_000_000
      }) <> "\n",
      [:append]
    )

    {{:ok, rows}, opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert journal_opens(opens) == [first]
    assert hd(rows).title == "External title"
    assert hd(rows).updated_at == 4_000_000_000_000

    replacement = Path.join(ctx.directory, "replacement.tmp")

    File.write!(
      replacement,
      Jason.encode!(%{
        "type" => "session",
        "version" => 3,
        "id" => "replacement",
        "cwd" => ctx.cwd,
        "timestamp" => 123
      }) <> "\n"
    )

    File.rename!(replacement, first)
    {{:ok, rows}, opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert journal_opens(opens) == [first]
    assert Enum.find(rows, &(&1.path == first)).id == "replacement"
    assert Enum.find(rows, &(&1.path == first)).title == nil

    File.rm!(second)
    {{:ok, [remaining]}, opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert remaining.id == "replacement"
    assert journal_opens(opens) == []
  end

  test "index and schema corruption rebuild without changing authoritative journals", ctx do
    path = save_session(ctx, "one", "Kept")
    before = File.read!(path)
    index_path = SessionIndex.path(ctx.directory)
    File.write!(index_path, "not a SQLite database")
    assert {:ok, [%{id: "one", title: "Kept"}]} = SessionManager.list_sessions(ctx.cwd)

    {:ok, conn} = Sqlite3.open(index_path)

    try do
      assert :ok = Sqlite3.execute(conn, "DROP TABLE journals")
      assert :ok = Sqlite3.execute(conn, "CREATE TABLE journals (wrong_column TEXT)")
    after
      Sqlite3.close(conn)
    end

    assert {:ok, [%{id: "one", title: "Kept"}]} = SessionManager.list_sessions(ctx.cwd)
    assert File.read!(path) == before
  end

  test "cache failure never repeats or rejects a successful journal write", ctx do
    File.mkdir_p!(SessionIndex.path(ctx.directory))
    path = Path.join(ctx.directory, "one.jsonl")
    parent = self()

    assert :ok =
             SessionIndex.mutate(path, :checkpoint, fn ->
               send(parent, :writer_ran)
               File.write(path, "journal bytes")
             end)

    assert_receive :writer_ran
    refute_receive :writer_ran, 0
    assert File.read!(path) == "journal bytes"
    assert {:error, :unsafe_index} = SessionManager.list_sessions(ctx.cwd)
  end

  test "legacy append and title clearing update the index immediately", ctx do
    path = save_session(ctx, "one", "Named")
    assert :ok = SessionManager.append_to_file(path, SessionEntry.session_info(nil))
    {{:ok, [%{title: nil}]}, opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert journal_opens(opens) == []
  end

  test "ISO-8601 journal timestamps remain discoverable and activity stays numeric", ctx do
    File.mkdir_p!(ctx.directory)
    path = Path.join(ctx.directory, "legacy-time.jsonl")
    header_ms = System.system_time(:millisecond) + 86_400_000
    activity_ms = header_ms + 86_400_000
    header_time = header_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    activity_time = activity_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    header = %{
      "type" => "session",
      "version" => 3,
      "id" => "legacy-time",
      "cwd" => ctx.cwd,
      "timestamp" => header_time
    }

    title = %{
      "type" => "sessionInfo",
      "id" => "title",
      "name" => "Legacy title",
      "timestamp" => activity_time
    }

    File.write!(path, [Jason.encode!(header), "\n", Jason.encode!(title), "\n"])
    File.touch!(path, 1_600_000_000)
    assert {:ok, [indexed]} = SessionManager.list_sessions(ctx.cwd)
    assert indexed.timestamp == header_time
    assert indexed.updated_at == activity_ms
    assert indexed.title == "Legacy title"

    assert {:ok, loaded} = SessionManager.load_from_file(path)
    assert :ok = SessionManager.save_to_file(path, loaded)
    assert {:ok, [saved]} = SessionManager.list_sessions(ctx.cwd)
    assert saved == indexed

    File.rm!(SessionIndex.path(ctx.directory))
    assert {:ok, [^saved]} = SessionManager.list_sessions(ctx.cwd)
  end

  test "invalid and symlink journals never reopen on a warm listing", ctx do
    File.mkdir_p!(ctx.directory)
    bad = Path.join(ctx.directory, "invalid.jsonl")
    File.write!(bad, "invalid header\n")
    outside = Path.join(ctx.cwd, "outside.jsonl")
    File.mkdir_p!(ctx.cwd)
    File.write!(outside, "external data")
    File.ln_s!(outside, Path.join(ctx.directory, "link.jsonl"))
    assert {:ok, []} = SessionManager.list_sessions(ctx.cwd)
    {{:ok, []}, opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert journal_opens(opens) == []
    assert File.read!(outside) == "external data"
  end

  test "concurrent directory writers preserve every index row", ctx do
    tasks =
      for n <- 1..12, do: Task.async(fn -> save_session(ctx, "parallel-#{n}", "Title #{n}") end)

    Enum.each(tasks, &Task.await(&1, 30_000))
    {{:ok, rows}, opens} = trace_opens(fn -> SessionManager.list_sessions(ctx.cwd) end)
    assert length(rows) == 12
    assert journal_opens(opens) == []
  end

  test "nested index removal retains outer directory admission", ctx do
    path = save_session(ctx, "one", "Title")
    key = {SessionIndex, node(), Path.expand(ctx.directory)}

    SessionIndex.with_directory_lock(ctx.directory, fn ->
      assert :ok = SessionIndex.remove(path)
      assert false == try_directory_admission(key)
    end)

    assert true == try_directory_admission(key)
  end

  defp try_directory_admission(key) do
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        acquired? = :global.set_lock({key, self()}, [node()], 0)
        if acquired?, do: :global.del_lock({key, self()}, [node()])
        send(parent, {:admission, self(), acquired?})
      end)

    assert_receive {:admission, ^worker, acquired?}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    acquired?
  end

  defp save_session(ctx, id, title) do
    path = Path.join(ctx.directory, id <> ".jsonl")

    session =
      SessionManager.new(ctx.cwd, id: id)
      |> SessionManager.append_entry(SessionEntry.session_info(title))

    assert :ok = SessionManager.save_to_file(path, session)
    path
  end

  defp trace_opens(fun) do
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run ->
            send(parent, {:result, self(), fun.()})
            receive do: (:stop -> :ok)
        end
      end)

    mfa = {:file, :open, 2}
    {:match_spec, previous} = :erlang.trace_info(mfa, :match_spec)
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(worker, true, [:call, :set_on_spawn])

    try do
      send(worker, :run)
      assert_receive {:result, ^worker, result}, 30_000
      barrier = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^barrier}, 30_000
      {result, collect_opens([])}
    after
      :erlang.trace_pattern(mfa, previous, [:local])
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 30_000
    end
  end

  defp collect_opens(acc) do
    receive do
      {:trace, _pid, :call, {:file, :open, [path, _modes]}} ->
        collect_opens([IO.chardata_to_string(path) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp journal_opens(opens), do: Enum.filter(opens, &String.ends_with?(&1, ".jsonl"))
end
