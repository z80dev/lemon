defmodule LemonOmp.SubagentTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  setup do
    use_fake_omp()
    key = "agent:omp-child:#{System.unique_integer([:positive])}"
    {:ok, owner: %{kind: :agent, session_key: key}, scope: [owner: {:session_key, key}]}
  end

  defp start!(ctx, prompt) do
    ws = workspace!()
    assert {:ok, wire} = LemonOmp.start(%{cwd: ws, prompt: prompt}, owner: ctx.owner)
    {ws, wire["id"]}
  end

  test "progress subscriptions expose sanitized nested task progress", ctx do
    {ws, id} = start!(ctx, "SUBAGENTS HOLD")
    wire = await_wire(id, &(get_in(&1, ["subagents", Access.at(0), "toolCalls"]) == 2))
    assert [sub] = wire["subagents"]
    assert sub["id"] == "child-1"
    assert sub["agent"] == "explore"
    assert sub["status"] == "running"
    assert sub["description"] == "Tiny child"
    assert sub["activity"] == "Running write — Create sub.txt"
    assert sub["toolCalls"] == 2
    assert sub["model"] == "fake/child"
    assert sub["index"] == 0
    assert sub["parentToolCallId"] == "task-1"
    assert sub["durationMs"] == 42
    assert sub["lastText"] == "earlier output\nlatest output"
    assert sub["recentTools"] == [%{"name" => "read", "endedAt" => 999}]

    assert sub["usage"] == %{
             "tokens" => 120,
             "cost" => 0.001,
             "contextTokens" => 200,
             "contextWindow" => 10_000
           }

    assert {:ok, summary} = LemonOmp.summary(id, ctx.scope)
    assert summary =~ "Subagents: explore (running) — Running write — Create sub.txt"

    assert Enum.any?(
             received(ws),
             &(&1["type"] == "set_subagent_subscription" and &1["level"] == "progress")
           )

    refute Enum.any?(received(ws), &(&1["level"] == "events"))
  end

  test "terminal lifecycle retains final output and usage", ctx do
    {_ws, id} = start!(ctx, "SUBAGENTS")
    assert {:ok, wire, :settled} = LemonOmp.wait(id, 5000, ctx.scope)
    assert [sub] = wire["subagents"]
    assert sub["status"] == "completed"
    assert sub["activity"] == nil
    assert sub["lastText"] == "Created sub.txt"
    assert sub["durationMs"] == 100
    assert sub["endedAt"] >= sub["startedAt"]
    assert sub["usage"]["tokens"] == 150
    assert sub["usage"]["cost"] == 0.002
    assert LemonOmp.Projection.summary(wire) =~ "explore (completed) — Created sub.txt"
  end

  test "drill-down returns a sanitized transcript tail and safe cursor metadata", ctx do
    {ws, id} = start!(ctx, "SUBAGENTS")
    assert {:ok, _wire, :settled} = LemonOmp.wait(id, 5000, ctx.scope)
    assert {:ok, transcript} = LemonOmp.subagent(id, "child-1", ctx.scope)
    assert length(transcript["messages"]) == 20
    assert hd(transcript["messages"])["text"] =~ "message 41 "
    assert List.last(transcript["messages"])["role"] == "toolResult"
    assert List.last(transcript["messages"])["toolName"] == "write"
    assert List.last(transcript["messages"])["text"] =~ "message 60 "
    assert Enum.all?(transcript["messages"], &(String.length(&1["text"]) == 2000))
    assert transcript["fromByte"] == 0
    assert transcript["nextByte"] == 12_345
    assert transcript["reset"] == false
    refute Jason.encode!(transcript) =~ "\u202e"
    refute Jason.encode!(transcript) =~ "\\u001b"
    refute Jason.encode!(transcript) =~ "not exposed"
    refute Map.has_key?(transcript, "sessionFile")
    refute Map.has_key?(transcript, "entries")
    assert {:ok, max_tail} = LemonOmp.subagent(id, "child-1", Keyword.put(ctx.scope, :limit, 100))
    assert length(max_tail["messages"]) == 50
    assert hd(max_tail["messages"])["text"] =~ "message 11 "
    assert {:ok, one} = LemonOmp.subagent(id, "child-1", Keyword.put(ctx.scope, :limit, 1))
    assert length(one["messages"]) == 1
    commands = Enum.filter(received(ws), &(&1["type"] == "get_subagent_messages"))
    assert length(commands) == 3
    assert Enum.all?(commands, &(&1["subagentId"] == "child-1" and is_binary(&1["id"])))
    assert commands |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 3
    refute Enum.any?(commands, &Map.has_key?(&1, "sessionFile"))
  end

  test "unknown children are rejected and owner scoping prevents any RPC", ctx do
    {ws, id} = start!(ctx, "SUBAGENTS HOLD")

    assert {:error, :not_found} =
             LemonOmp.subagent(id, "child-1", owner: {:session_key, "foreign"})

    refute Enum.any?(received(ws), &(&1["type"] == "get_subagent_messages"))
    assert {:error, {:rejected, "Unknown subagent"}} = LemonOmp.subagent(id, "missing", ctx.scope)
    assert {:error, :invalid_params} = LemonOmp.subagent(id, "", ctx.scope)

    assert {:error, :invalid_params} =
             LemonOmp.subagent(id, String.duplicate("x", 129), ctx.scope)

    assert {:error, :not_found} = LemonOmp.subagent("omp_missing", "child-1", ctx.scope)
    assert {:ok, _} = LemonOmp.close(id, ctx.scope)
    assert {:error, :not_running} = LemonOmp.subagent(id, "child-1", ctx.scope)

    assert {:error, :not_found} =
             LemonOmp.subagent(id, "child-1", owner: {:session_key, "foreign"})
  end

  test "silence is outcome unknown and process exit fails a pending query closed", ctx do
    put_app_env(:command_timeout_ms, 100)
    {ws, id} = start!(ctx, "SUBAGENTS HOLD")
    assert {:error, :outcome_unknown} = LemonOmp.subagent(id, "silent", ctx.scope)
    assert Enum.count(received(ws), &(&1["type"] == "get_subagent_messages")) == 1
    assert {:error, :not_running} = LemonOmp.subagent(id, "exit", ctx.scope)
    assert {:error, :not_running} = LemonOmp.subagent(id, "child-1", ctx.scope)
  end
end
