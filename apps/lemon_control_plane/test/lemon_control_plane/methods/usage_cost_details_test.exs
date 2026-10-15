defmodule LemonControlPlane.Methods.UsageCostDetailsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{UsageCost, UsageStatus}
  alias LemonCore.{UsageLedger, UsageStore}

  setup do
    today = Date.utc_today() |> Date.to_iso8601()
    previous_today = UsageStore.get_record(today)
    previous_summary = UsageStore.get_summary(:current)
    LemonCore.Store.delete(:usage_records, today)
    LemonCore.Store.delete(:usage_data, :current)

    on_exit(fn ->
      if previous_today,
        do: UsageStore.put_record(today, previous_today),
        else: LemonCore.Store.delete(:usage_records, today)

      if previous_summary,
        do: UsageStore.put_summary(:current, previous_summary),
        else: LemonCore.Store.delete(:usage_data, :current)
    end)

    %{today: today}
  end

  defp finalize(run_id, session_key, model, usage) do
    UsageLedger.entry(run_id, session_key, %{
      completed: %{ok: true, usage: usage, answer: "private answer"},
      meta: %{model: model},
      prompt: "private prompt"
    })
  end

  test "finalized runs feed provider, model, session and daily projections", ctx do
    :ok =
      UsageLedger.record(
        finalize("run-a", "agent:web:one", "openai:gpt-5", %{
          input_tokens: 1_000,
          output_tokens: 200,
          cache_read_input_tokens: 500,
          cost: %{total: 0.25}
        })
      )

    :ok =
      UsageLedger.record(
        finalize("run-b", "agent:web:two", "anthropic:claude-x", %{input: 300, output: 50})
      )

    # A retried finalization of the same run is not counted twice.
    :ok =
      UsageLedger.record(
        finalize("run-a", "agent:web:one", "openai:gpt-5", %{
          input_tokens: 1_000,
          output_tokens: 200
        })
      )

    assert {:ok, result} =
             UsageCost.handle(%{"startDate" => ctx.today, "endDate" => ctx.today}, %{})

    assert result["totalRequests"] == 2
    assert_in_delta result["totalCost"], 0.25, 1.0e-9

    assert [openai, anthropic] = result["providers"]
    assert openai["provider"] == "openai"
    assert openai["inputTokens"] == 1_500
    assert openai["outputTokens"] == 200

    assert anthropic == %{
             "provider" => "anthropic",
             "cost" => 0.0,
             "requests" => 1,
             "inputTokens" => 300,
             "outputTokens" => 50
           }

    assert [%{"provider" => "openai", "model" => "gpt-5", "requests" => 1} | _] = result["models"]
    assert Enum.map(result["sessions"], & &1["sessionKey"]) == ["agent:web:one", "agent:web:two"]
    assert Enum.all?(result["sessions"], &is_integer(&1["lastAtMs"]))
    assert result["sessionsOmitted"] == 0

    assert [%{"date" => date, "requests" => 2, "inputTokens" => 1_800, "outputTokens" => 250}] =
             result["dailyUsage"]

    assert date == ctx.today
    refute inspect(result) =~ "private"

    assert {:ok, status} = UsageStatus.handle(%{}, %{})
    assert status["runs"] == 2
    assert status["tokens"] == %{"input" => 1_800, "output" => 250}
  end

  test "a run without usage is ignored and the summary restarts each day" do
    assert UsageLedger.entry("run-x", "s", %{completed: %{ok: true}, meta: %{}}) == nil

    UsageStore.put_summary(:current, %{date: "2000-01-01", total_requests: 9, total_cost: 1.0})
    assert {:ok, status} = UsageStatus.handle(%{}, %{})
    assert status["runs"] == 0

    :ok = UsageLedger.record(finalize("run-c", "s", "zai:glm", %{input: 10, output: 5}))
    assert %{date: date, total_requests: 1} = UsageStore.get_summary(:current)
    assert date == Date.to_iso8601(Date.utc_today())
  end

  test "reads at most a year of daily records" do
    assert {:ok, result} =
             UsageCost.handle(%{"startDate" => "1900-01-01", "endDate" => "2000-12-31"}, %{})

    assert result["totalRequests"] == 0
    assert result["providers"] == []
    assert result["dailyUsage"] == []
  end

  test "usage.cost pins the complete seeded wire shape", ctx do
    usage = %{cost: 0.5, requests: 2, input: 30, output: 4}

    UsageStore.put_record(ctx.today, %{
      date: ctx.today,
      total_cost: 0.5,
      breakdown: %{"test" => 0.5},
      requests: %{"test" => 2},
      tokens: %{"test" => %{input: 30, output: 4}},
      models: %{"test:model" => Map.merge(usage, %{provider: "test", model: "model"})},
      sessions: %{"session" => Map.put(usage, :last_at_ms, 123)},
      sessions_omitted: 3,
      unknown_cost_records: 1
    })

    params = %{"startDate" => ctx.today, "endDate" => ctx.today}
    assert {:ok, result} = UsageCost.handle(params, %{})

    expected = %{
      "startDate" => ctx.today,
      "endDate" => ctx.today,
      "totalCost" => 0.5,
      "knownCostSubtotal" => 0.5,
      "incomplete" => true,
      "breakdown" => %{"test" => 0.5},
      "totalRequests" => 2,
      "totalTokens" => %{"input" => 30, "output" => 4},
      "providers" => [
        %{
          "provider" => "test",
          "cost" => 0.5,
          "requests" => 2,
          "inputTokens" => 30,
          "outputTokens" => 4
        }
      ],
      "models" => [
        %{
          "provider" => "test",
          "model" => "model",
          "cost" => 0.5,
          "requests" => 2,
          "inputTokens" => 30,
          "outputTokens" => 4
        }
      ],
      "sessions" => [
        %{
          "sessionKey" => "session",
          "lastAtMs" => 123,
          "cost" => 0.5,
          "requests" => 2,
          "inputTokens" => 30,
          "outputTokens" => 4
        }
      ],
      "sessionsOmitted" => 3,
      "dailyUsage" => [
        %{
          "date" => ctx.today,
          "cost" => 0.5,
          "requests" => 2,
          "inputTokens" => 30,
          "outputTokens" => 4
        }
      ],
      "daily" => %{
        ctx.today => %{"cost" => 0.5, "requests" => 2, "breakdown" => %{"test" => 0.5}}
      },
      "summary" => %{
        "groupBy" => "day",
        "providerCount" => 1,
        "dailyReturned" => true,
        "dailyCount" => 1,
        "totalRequests" => 2,
        "totalTokenCount" => 34,
        "cleanup" => %{
          "includesPrompts" => false,
          "includesResponses" => false,
          "includesMessageBodies" => false,
          "includesCredentials" => false,
          "includesSecretValues" => false
        }
      }
    }

    # Round-trip pins JSON keys, numeric values, nesting, and absence of extra fields.
    assert Jason.decode!(Jason.encode!(result)) == expected
    assert Jason.encode!(result) == Jason.encode!(expected)

    assert {:ok, provider_result} = UsageCost.handle(Map.put(params, "groupBy", "provider"), %{})
    refute Map.has_key?(provider_result, "daily")

    assert provider_result["summary"] ==
             Map.merge(expected["summary"], %{
               "groupBy" => "provider",
               "dailyReturned" => false,
               "dailyCount" => 0
             })

    assert Map.drop(provider_result, ["daily", "summary"]) ==
             Map.drop(result, ["daily", "summary"])
  end
end
