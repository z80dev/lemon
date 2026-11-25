Code.require_file("../../../../lemon_platform_test/test/support/crash_model.exs", __DIR__)

defmodule CodingAgent.Session.CrashModelTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.Persistence
  alias CodingAgent.SessionManager
  alias LemonAgent.Loop.TranscriptValidator
  alias LemonAi.Types.{AssistantMessage, ToolCall, ToolResultMessage}
  alias LemonPlatformTest.Testing.CrashModel

  @moduletag :crash_model
  @moduletag :tmp_dir
  @seed 555_001

  test "JournalPrefix and TranscriptValid survive arbitrary byte cuts", %{tmp_dir: dir} do
    for {{operations, selector}, index} <- Enum.with_index(traces()) do
      path = Path.join(dir, "prefix-#{index}.jsonl")
      {writer, header_size, _synced} = write_trace(path, operations)
      bytes = File.read!(path)
      offsets = [header_size + 1, header_size + rem(selector, byte_size(bytes) - header_size + 1)]
      CrashModel.crash!(writer)

      for offset <- Enum.uniq(offsets) do
        File.write!(path, binary_part(bytes, 0, offset))
        assert_recovery(path, binary_part(bytes, 0, offset))
      end
    end
  end

  test "IntentTruth never renders a synced external intent as not started", %{tmp_dir: dir} do
    for {{operations, selector}, index} <- Enum.with_index(traces()) do
      path = Path.join(dir, "intent-#{index}.jsonl")
      {writer, _header_size, synced} = write_trace(path, operations)
      bytes = File.read!(path)
      CrashModel.crash!(writer)

      # Always include total loss of the unsynced result, plus an arbitrary tear.
      for offset <- Enum.uniq([synced, synced + rem(selector, byte_size(bytes) - synced + 1)]) do
        File.write!(path, binary_part(bytes, 0, offset))
        messages = assert_recovery(path, binary_part(bytes, 0, offset))
        result = Enum.find(messages, &match?(%ToolResultMessage{tool_call_id: "external"}, &1))
        assert %ToolResultMessage{} = result

        if offset < byte_size(bytes) - 1 do
          assert result.details.outcome == :unknown, "IntentTruth: #{inspect(operations)}"
        end
      end
    end
  end

  defp traces do
    generator =
      StreamData.tuple({
        StreamData.list_of(StreamData.member_of([:planned, :intent, :result]),
          min_length: 1,
          max_length: 6
        ),
        StreamData.integer(0..1_000_000)
      })

    CrashModel.samples(generator, @seed)
  end

  defp write_trace(path, operations) do
    parent = self()

    writer =
      start_supervised!({Task, fn -> write_journal(parent, path, operations) end}, id: make_ref())

    assert_receive {:trace_written, ^writer, header_size, synced}, 5_000
    {writer, header_size, synced}
  end

  defp write_journal(parent, path, operations) do
    session = SessionManager.new("/crash-model", id: "model") |> SessionManager.persist(path)
    header_size = File.stat!(path).size

    session =
      operations
      |> Enum.with_index()
      |> Enum.reduce(session, fn {operation, index}, session ->
        append_call(session, "call-#{index}", operation)
      end)

    session = append_call(session, "external", :planned)
    call_leaf = session.leaf_id

    {:ok, session} =
      SessionManager.record_tool_intent(session, %{
        "toolCallId" => "external",
        "effect" => "external"
      })

    # Navigation may hide an intent from the selected message branch, but
    # must never erase its execution history.
    session = SessionManager.set_leaf_id(session, call_leaf)
    synced = File.stat!(path).size
    _session = append_result(session, "external")
    send(parent, {:trace_written, self(), header_size, synced})

    receive do
      :stop -> :ok
    end
  end

  defp append_call(session, id, operation) do
    session =
      session
      |> SessionManager.append_message(%{"role" => "user", "content" => id, "timestamp" => 1})
      |> SessionManager.append_message(%{
        "role" => "assistant",
        "timestamp" => 2,
        "content" => [
          %{
            "type" => "tool_call",
            "id" => id,
            "name" => "bash",
            "arguments" => %{"command" => id}
          }
        ]
      })

    session =
      if operation in [:intent, :result] do
        {:ok, session} =
          SessionManager.record_tool_intent(session, %{"toolCallId" => id, "effect" => "external"})

        session
      else
        session
      end

    if operation == :result, do: append_result(session, id), else: session
  end

  defp append_result(session, id) do
    SessionManager.append_message(session, %{
      "role" => "tool_result",
      "tool_call_id" => id,
      "tool_name" => "bash",
      "content" => [%{"type" => "text", "text" => "finished #{id}"}],
      "timestamp" => 3
    })
  end

  defp assert_recovery(path, prefix) do
    records = decoded_records(prefix)
    expected_ids = for %{"id" => id, "type" => type} <- records, type != "session", do: id

    recovery = SessionManager.load_from_file(path)
    assert match?({:ok, _session}, recovery), "JournalPrefix: complete prefix could not reopen"
    {:ok, session} = recovery

    ids = Enum.map(SessionManager.entries(session), & &1.id)
    assert ids == expected_ids, "JournalPrefix: recovered entries differ from complete records"
    assert map_size(session.by_id) == length(Enum.uniq(ids)), "JournalPrefix: duplicate IDs"

    messages = Persistence.restore_messages_from_session(session)
    assert TranscriptValidator.validate(messages) == :ok, "TranscriptValid: invalid transcript"

    calls =
      for %{"message" => %{"role" => "assistant", "content" => content}} <- records,
          %{"type" => "tool_call", "id" => id} <- content,
          do: id

    restored_calls =
      for %AssistantMessage{content: content} <- messages, %ToolCall{id: id} <- content, do: id

    assert restored_calls == calls, "TranscriptValid: recovery silently discarded tool calls"
    results = for %ToolResultMessage{} = result <- messages, do: result

    assert Enum.map(results, & &1.tool_call_id) == calls,
           "TranscriptValid: missing/duplicate results"

    intents =
      for %{"customType" => "lemon.tool_intent", "data" => %{"toolCallId" => id}} <- records,
          into: MapSet.new(),
          do: id

    completed =
      for %{"message" => %{"role" => "tool_result", "tool_call_id" => id}} <- records,
          into: MapSet.new(),
          do: id

    for result <- results, not MapSet.member?(completed, result.tool_call_id) do
      expected = if MapSet.member?(intents, result.tool_call_id), do: :unknown, else: :not_started
      assert result.details.outcome == expected, "IntentTruth: journal intent was misclassified"
    end

    messages
  end

  defp decoded_records(prefix) do
    prefix
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, record} -> [record]
        {:error, _} -> []
      end
    end)
  end
end
