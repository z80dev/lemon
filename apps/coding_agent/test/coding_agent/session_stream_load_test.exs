defmodule CodingAgent.SessionStreamLoadIssue565Test do
  use ExUnit.Case, async: true

  alias CodingAgent.SessionManager

  @moduletag :tmp_dir

  test "a journal larger than the loader heap bound streams without retaining source bytes", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "large.jsonl")
    write_large_journal(path)
    assert File.stat!(path).size > 32 * 1024 * 1024
    parent = self()

    # This is a test policy, not a product limit. Include ref-counted input
    # binaries in the VM's heap accounting: reading/splitting the whole 32 MiB
    # source cannot satisfy an 8 MiB loader bound. Retained history is tiny;
    # hundreds of large navigation records are deliberately not session state.
    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result = SessionManager.load_from_file(path)
          :erlang.garbage_collect()
          {:binary, binaries} = Process.info(self(), :binary)

          retained_bytes =
            Enum.reduce(binaries, 0, fn {_ref, bytes, _refs}, total -> total + bytes end)

          summary =
            case result do
              {:ok, session} ->
                {:ok, session.leaf_id, SessionManager.entry_count(session),
                 SessionManager.build_session_context(session), session.needs_snapshot}

              error ->
                error
            end

          send(parent, {:loaded, self(), summary, retained_bytes})
          receive do: (:stop -> :ok)
        end,
        [
          :monitor,
          {:fullsweep_after, 0},
          {:max_heap_size,
           %{
             size: div(8 * 1024 * 1024, :erlang.system_info(:wordsize)),
             kill: true,
             error_logger: false,
             include_shared_binaries: true
           }}
        ]
      )

    try do
      assert_receive {:loaded, ^worker, {:ok, "first", 2, context, false}, retained_bytes}, 30_000
      assert Enum.map(context.messages, & &1["content"]) == ["kept"]
      assert retained_bytes < 1024 * 1024
    after
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 30_000
    end
  end

  test "streaming preserves checkpoints and tolerates only an incomplete final record", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "large.jsonl")
    write_large_journal(path)
    File.write!(path, ~s({"type":"checkpoint"), [:append])
    assert {:ok, recovered} = SessionManager.load_from_file(path)
    assert recovered.leaf_id == "first"
    assert recovered.needs_snapshot
    assert SessionManager.entry_count(recovered) == 2

    File.write!(path, "\n", [:append])
    assert {:error, {:json_parse_error, _reason, _line}} = SessionManager.load_from_file(path)
  end

  test "legacy versions migrate one record at a time with compaction provenance", %{tmp_dir: dir} do
    path = Path.join(dir, "legacy.jsonl")

    records = [
      %{"type" => "session", "version" => 1, "id" => "legacy", "cwd" => dir, "timestamp" => 1},
      %{"type" => "message", "message" => %{"role" => "user", "content" => "first"}},
      %{"type" => "message", "message" => %{"role" => "hookMessage", "content" => "hook"}},
      %{"type" => "compaction", "firstKeptEntryIndex" => 1, "summary" => "summary"}
    ]

    File.write!(path, Enum.map(records, &[Jason.encode!(&1), "\n"]))
    assert {:ok, session} = SessionManager.load_from_file(path)
    [first, second, compaction] = SessionManager.entries(session)
    assert second.parent_id == first.id
    assert compaction.parent_id == second.id
    assert compaction.first_kept_entry_id == second.id
    assert second.message["role"] == "custom"
    assert session.needs_snapshot
    assert session.header.version == 3
  end

  defp write_large_journal(path) do
    header = %{
      "type" => "session",
      "version" => 3,
      "id" => "streamed",
      "cwd" => "/workspace",
      "timestamp" => 1
    }

    first = %{
      "type" => "message",
      "id" => "first",
      "timestamp" => 2,
      "message" => %{"role" => "user", "content" => "kept"}
    }

    second = %{
      "type" => "message",
      "id" => "second",
      "parentId" => "first",
      "timestamp" => 3,
      "message" => %{"role" => "assistant", "content" => "off branch"}
    }

    marker = %{
      "type" => "checkpoint",
      "activeLeafId" => "first",
      "checkpointEntryCount" => 2,
      "ignored" => String.duplicate("x", 128 * 1024)
    }

    marker_line = [Jason.encode!(marker), "\n"]
    {:ok, file} = File.open(path, [:write, :binary])

    try do
      Enum.each([header, first, second], fn record ->
        :ok = IO.binwrite(file, [Jason.encode!(record), "\n"])
      end)

      Enum.each(1..256, fn _ -> :ok = IO.binwrite(file, marker_line) end)
    after
      File.close(file)
    end
  end
end
