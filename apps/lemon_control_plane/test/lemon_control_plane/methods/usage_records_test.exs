defmodule LemonControlPlane.Methods.UsageRecordsTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.Methods.UsageRecords
  alias LemonCore.{UsageLedger, UsageStore}

  defp record(cost, known) do
    run = "usage-rpc-#{LemonCore.Id.uuid()}"
    at = System.system_time(:millisecond)

    entry =
      UsageLedger.entry(run, "agent:bot:usage-rpc", %{
        completed_at_ms: at,
        completed: %{
          usage: %{input: 7, output: 3, total_tokens: 10, cost: cost, price_known: known}
        },
        meta: %{agent_id: "bot", model: "openai:gpt-5", user_id: "not-native-authority"},
        prompt: "private prompt",
        cwd: "/private/path",
        credentials: "private credential"
      })

    native = UsageLedger.occurrence_record(entry)
    assert :ok = UsageStore.put_occurrence(native)
    on_exit(fn -> LemonCore.Store.delete(:usage_occurrences, native.id) end)
    {run, at}
  end

  test "returns only canonical native identity and actual price projection" do
    {run, at} = record(0.0, true)

    assert {:ok, result} =
             UsageRecords.handle(%{"fromMs" => at, "toMs" => at + 1, "runId" => run}, %{})

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

    assert {:error, _} =
             UsageRecords.handle(%{"fromMs" => 0, "toMs" => 10, "cursor" => "invalid"}, %{})
  end

  test "run JSON sums complete requests but never substitutes zero for missing counters" do
    complete = %{
      input: 70,
      output: 30,
      cache_read: 20,
      cache_write: 10,
      total_tokens: 130,
      cost: 0.2,
      price_known: true
    }

    partial = %{
      input: nil,
      output: 30,
      cache_read: 20,
      cache_write: nil,
      total_tokens: 130,
      cost: nil,
      price_known: false
    }

    sparse = %{input: 12, output: 3, cost: 0.25}

    for {usages, expected_tokens, expected_cost} <- [
          {[complete, complete], %{"input" => 200, "output" => 60, "total" => 260}, 0.4},
          {[complete, nil], %{"input" => nil, "output" => nil, "total" => nil}, nil},
          {[nil, complete], %{"input" => nil, "output" => nil, "total" => nil}, nil},
          {[complete, partial], %{"input" => 200, "output" => 60, "total" => 260}, nil},
          {[complete, sparse], %{"input" => nil, "output" => 33, "total" => nil}, 0.45},
          {[sparse, nil], %{"input" => nil, "output" => nil, "total" => nil}, nil}
        ] do
      run = "usage-aggregation-#{LemonCore.Id.uuid()}"
      at = System.system_time(:millisecond)

      occurrences =
        Enum.map(usages, fn usage ->
          %{provider: :zai, model: "glm-5.3", at_ms: at, usage: usage, run_id: "not-the-parent"}
        end)

      entries =
        UsageLedger.entries(run, "agent:bot:main", %{
          completed: %{usage: %{occurrences: occurrences}},
          meta: %{agent_id: "bot"}
        })

      for entry <- entries do
        native = UsageLedger.occurrence_record(entry)
        assert :ok = UsageStore.put_occurrence(native)
        on_exit(fn -> LemonCore.Store.delete(:usage_occurrences, native.id) end)
      end

      assert {:ok, [row]} =
               LemonControlPlane.Methods.RunUsage.attach([
                 %{"runId" => run, "startedAtMs" => at, "completedAtMs" => at}
               ])

      assert row["tokens"] == expected_tokens
      assert row["costUsd"] == expected_cost
      assert row["priceKnown"] == not is_nil(expected_cost)
      assert row["provider"] == "zai"
      assert row["model"] == "glm-5.3"

      assert {:ok, result} =
               UsageRecords.handle(%{"fromMs" => at, "toMs" => at + 1, "runId" => run}, %{})

      assert length(result["records"]) == 2
      assert Enum.all?(result["records"], &(&1["runId"] == run))
      refute inspect(result) =~ "not-the-parent"
    end
  end
end
