defmodule LemonControlPlane.Methods.UsageRecordsTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.Methods.UsageRecords
  alias LemonCore.{UsageLedger, UsageStore}

  defp record(cost, known) do
    run = "usage-rpc-#{LemonCore.Id.uuid()}"
    at = System.system_time(:millisecond)
    entry = UsageLedger.entry(run, "agent:bot:usage-rpc", %{completed_at_ms: at,
      completed: %{usage: %{input: 7, output: 3, total_tokens: 10, cost: cost, price_known: known}},
      meta: %{agent_id: "bot", model: "openai:gpt-5", user_id: "not-native-authority"},
      prompt: "private prompt", cwd: "/private/path", credentials: "private credential"})
    native = UsageLedger.occurrence_record(entry)
    assert :ok = UsageStore.put_occurrence(native)
    on_exit(fn -> LemonCore.Store.delete(:usage_occurrences, native.id) end)
    {run, at}
  end

  test "returns only canonical native identity and actual price projection" do
    {run, at} = record(0.0, true)
    assert {:ok, result} = UsageRecords.handle(%{"fromMs" => at, "toMs" => at + 1, "runId" => run}, %{})
    assert [row] = result["records"]
    assert row["runId"] == run
    assert row["agentId"] == "bot"
    assert row["sessionKey"] == "agent:bot:usage-rpc"
    assert row["costUsd"] == 0.0
    assert row["priceKnown"] == true
    assert row["atMs"] == at
    assert row["totalTokens"] == 10
    assert result["nextCursor"] == nil
    assert is_boolean(result["incomplete"])
    refute inspect(result) =~ "private"
    refute inspect(result) =~ "not-native-authority"
  end

  test "unknown price is null and incomplete, not a fabricated free run" do
    {run, at} = record(0.0, false)
    assert {:ok, %{"records" => [row], "incomplete" => true}} =
      UsageRecords.handle(%{"fromMs" => at, "toMs" => at + 1, "runId" => run}, %{})
    assert row["costUsd"] == nil
    refute row["priceKnown"]
  end

  test "invalid range and cursor are errors" do
    assert {:error, _} = UsageRecords.handle(%{"fromMs" => 10, "toMs" => 10}, %{})
    assert {:error, _} = UsageRecords.handle(%{"fromMs" => 0, "toMs" => 10, "cursor" => "invalid"}, %{})
  end
end
