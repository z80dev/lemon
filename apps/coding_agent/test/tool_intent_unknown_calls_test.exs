defmodule CodingAgent.ToolIntentUnknownCallsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ToolIntent

  @moduletag :tmp_dir

  test "lists unresolved intents and omits durable completed calls", %{tmp_dir: dir} do
    path = journal(dir, [intent("pending", "bash"), intent("done", "write"), result("done")])
    assert {:ok, [%{id: "pending", name: "bash"}]} = ToolIntent.unknown_calls(path)
  end

  test "scoped nested intents remain unknown independently of their completed parent", %{
    tmp_dir: dir
  } do
    path =
      journal(dir, [
        intent("eval", "eval"),
        intent("eval/wasm/bash", "bash", %{"parentToolCallId" => "eval/wasm"}),
        intent("eval/wasm", "wasm", %{"parentToolCallId" => "eval"}),
        result("eval")
      ])

    assert {:ok, [%{id: "eval/wasm/bash", name: "bash"}, %{id: "eval/wasm", name: "wasm"}]} =
             ToolIntent.unknown_calls(path)
  end

  test "deduplicates IDs and exposes no intent arguments or digests", %{tmp_dir: dir} do
    entry =
      intent("one", "bash", %{
        "arguments" => %{"secret" => "hidden"},
        "argumentDigest" => "digest"
      })

    assert {:ok, [%{id: "one", name: "bash"}]} =
             ToolIntent.unknown_calls(journal(dir, [entry, entry]))
  end

  test "synthetic unknown outcomes do not resolve intents", %{tmp_dir: dir} do
    path =
      journal(dir, [
        intent("one", "bash"),
        result("one", %{"outcome" => "unknown", "restored_session_repair" => true})
      ])

    assert {:ok, [%{id: "one", name: "bash"}]} = ToolIntent.unknown_calls(path)
  end

  test "caps the operator projection at the first 100 distinct unresolved IDs", %{tmp_dir: dir} do
    path = journal(dir, Enum.map(1..105, &intent(Integer.to_string(&1), "bash")))
    assert {:ok, calls} = ToolIntent.unknown_calls(path)
    assert length(calls) == 100
    assert List.first(calls) == %{id: "1", name: "bash"}
    assert List.last(calls) == %{id: "100", name: "bash"}
  end

  test "unavailable and malformed journals return errors", %{tmp_dir: dir} do
    assert {:error, :enoent} = ToolIntent.unknown_calls(Path.join(dir, "missing"))
    path = Path.join(dir, "invalid.jsonl")
    File.write!(path, "not json\n")
    assert {:error, _} = ToolIntent.unknown_calls(path)

    assert {:error, :invalid_tool_intent} =
             ToolIntent.unknown_calls(journal(dir, [intent("one", nil)]))
  end

  test "provider rejects unsupported tokens without resuming anything" do
    assert {:error, :invalid_resume_token} =
             CodingAgent.ControlPlaneProvider.interrupted_tool_calls("/unused", nil)

    assert {:error, :invalid_resume_token} =
             CodingAgent.ControlPlaneProvider.interrupted_tool_calls(
               "/unused",
               LemonCore.ResumeToken.new("other", "session")
             )
  end

  defp journal(dir, entries) do
    path = Path.join(dir, "session.jsonl")
    header = %{"type" => "session", "version" => 3, "id" => "session", "cwd" => dir}

    records =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        Map.merge(entry, %{"id" => "entry-#{index}", "timestamp" => index})
      end)

    File.write!(path, Enum.map_join([header | records], "\n", &Jason.encode!/1) <> "\n")
    path
  end

  defp intent(id, name, extra \\ %{}) do
    %{
      "type" => "custom",
      "customType" => "lemon.tool_intent",
      "data" => Map.merge(%{"toolCallId" => id, "tool" => name}, extra)
    }
  end

  defp result(id, details \\ %{}) do
    %{
      "type" => "message",
      "message" => %{"role" => "tool_result", "tool_call_id" => id, "details" => details}
    }
  end
end
