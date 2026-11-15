defmodule CodingAgent.SessionJournalAppendTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SessionManager, as: Journal

  @moduletag :tmp_dir

  test "resuming parses the journal once across validation and initialization", %{tmp_dir: dir} do
    path = Path.join(dir, "resume.jsonl")
    assert :ok = Journal.save_to_file(path, Journal.new(dir))
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :resume ->
            result =
              CodingAgent.Session.start_link(
                cwd: dir,
                session_file: path,
                model: LemonAgent.Test.Mocks.mock_model(),
                stream_fn:
                  LemonAgent.Test.Mocks.mock_stream_fn_single(
                    LemonAgent.Test.Mocks.assistant_message("ack")
                  ),
                system_prompt: "journal regression",
                mcp_tools: [],
                extension_inventory: {[], []}
              )

            send(parent, {:resumed, result})

            receive do
              :stop ->
                case result do
                  {:ok, session} -> GenServer.stop(session)
                  _ -> :ok
                end
            end
        end
      end)

    monitor = Process.monitor(worker)
    mfa = {Journal, :load_from_file, 1}
    {:match_spec, previous_pattern} = :erlang.trace_info(mfa, :match_spec)
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(worker, true, [:call, :set_on_spawn])

    try do
      send(worker, :resume)
      assert_receive {:resumed, {:ok, _session}}, 30_000
      ref = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^ref}
      assert count_parses(0) == 1
    after
      :erlang.trace_pattern(mfa, previous_pattern, [:local])
      send(worker, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^worker, _} -> :ok
      after
        30_000 -> Process.exit(worker, :kill)
      end
    end
  end

  defp count_parses(count) do
    receive do
      {:trace, _, :call, {Journal, :load_from_file, [_]}} -> count_parses(count + 1)
    after
      0 -> count
    end
  end

  test "turn checkpoints append without replacing history and latest navigation wins", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "session.jsonl")
    session = Journal.new(dir) |> Journal.persist(path)

    try do
      session = Journal.append_message(session, %{"role" => "user", "content" => "first"})
      first = session.leaf_id
      session = Journal.append_message(session, %{"role" => "assistant", "content" => "second"})
      before = File.read!(path)
      inode = File.stat!(path).inode
      assert :ok = Journal.checkpoint(session)
      assert File.stat!(path).inode == inode
      assert String.starts_with?(File.read!(path), before)
      assert byte_size(File.read!(path)) > byte_size(before)
      session = Journal.set_leaf_id(session, first)
      assert :ok = Journal.checkpoint(session)
      assert {:ok, restored} = Journal.load_from_file(path)
      assert restored.leaf_id == first
      assert restored.header.checkpoint_entry_count == 2
      assert Journal.entry_count(restored) == 2
    after
      Journal.close(session)
    end
  end

  test "legacy header-only fixture retains its selected branch", %{tmp_dir: dir} do
    path = Path.join(dir, "legacy.jsonl")
    File.cp!(Path.join(__DIR__, "fixtures/journal_header_only.jsonl"), path)
    assert {:ok, session} = Journal.load_from_file(path)
    assert session.leaf_id == "11111111"
    assert Journal.entry_count(session) == 2
    inode = File.stat!(path).inode
    live = Journal.persist(session, path)
    assert File.stat!(path).inode == inode
    assert :ok = Journal.close(live)
  end

  test "torn final checkpoint repairs before subsequent appends", %{tmp_dir: dir} do
    path = Path.join(dir, "torn.jsonl")
    File.cp!(Path.join(__DIR__, "fixtures/journal_header_only.jsonl"), path)
    File.write!(path, "{\"type\":\"checkpoint\",", [:append])
    assert {:ok, session} = Journal.load_from_file(path)
    live = Journal.persist(session, path)

    try do
      live = Journal.append_message(live, %{"role" => "user", "content" => "after repair"})
      assert :ok = Journal.checkpoint(live)
      assert {:ok, restored} = Journal.load_from_file(path)
      assert Journal.entry_count(restored) == 3
      assert restored.leaf_id == live.leaf_id
    after
      Journal.close(live)
    end
  end

  test "append hot path does not enumerate the id map" do
    source = File.read!(Path.expand("../../lib/coding_agent/session_manager.ex", __DIR__))

    [_, append] =
      String.split(source, "def append_entry(%Session{} = session, %SessionEntry{} = entry) do",
        parts: 2
      )

    [body | _] = String.split(append, "\n  @doc", parts: 2)
    refute body =~ "Map.keys"
    refute body =~ "MapSet"
    assert body =~ "generate_unique_id(session.by_id)"
    assert source =~ "Map.has_key?(existing_set, id)"
  end
end
