defmodule LemonControlPlane.Methods.UsageCostTrackingTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.UsageCost

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  setup do
    on_exit(fn -> LemonCore.Store.delete(:usage_data, :current) end)
    :ok
  end

  defp record_usage(usage) do
    run_id = "usage-test-#{LemonCore.Id.uuid()}"
    provider = usage[:provider] || usage["provider"]
    entry = LemonCore.UsageLedger.entry(run_id, "agent:test:usage", %{
      completed: %{usage: usage},
      completed_at_ms: System.system_time(:millisecond),
      meta: %{provider: provider, model: "test"}
    })
    record = LemonCore.UsageLedger.occurrence_record(entry)
    on_exit(fn -> LemonCore.Store.delete(:usage_occurrences, record.id) end)
    LemonCore.UsageLedger.record(entry)
  end

  describe "UsageCost" do
    test "returns cost breakdown with default date range" do
      {:ok, result} = UsageCost.handle(%{}, @ctx)

      assert is_binary(result["startDate"])
      assert is_binary(result["endDate"])
      assert is_number(result["totalCost"])
      assert is_map(result["breakdown"])
      assert is_integer(result["totalRequests"])
      assert is_map(result["totalTokens"])
      assert result["summary"]["providerCount"] == map_size(result["breakdown"])
      assert result["summary"]["totalRequests"] == result["totalRequests"]
      assert result["summary"]["totalTokenCount"] >= 0
      assert result["summary"]["cleanup"]["includesPrompts"] == false
      assert result["summary"]["cleanup"]["includesResponses"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "accepts date range parameters" do
      {:ok, result} =
        UsageCost.handle(
          %{
            "startDate" => "2024-01-01",
            "endDate" => "2024-01-31"
          },
          @ctx
        )

      assert result["startDate"] == "2024-01-01"
      assert result["endDate"] == "2024-01-31"
    end

    test "accepts snake_case parameters" do
      {:ok, result} =
        UsageCost.handle(
          %{
            "start_date" => "2024-01-01",
            "end_date" => "2024-01-31",
            "group_by" => "day"
          },
          @ctx
        )

      assert result["startDate"] == "2024-01-01"
    end

    test "has correct method name and scopes" do
      assert UsageCost.name() == "usage.cost"
      assert UsageCost.scopes() == [:read]
    end
  end

  describe "canonical UsageLedger recording" do
    test "records usage and updates totals" do
      # Record some usage
      :ok =
        record_usage(%{
          provider: "claude",
          cost: 0.05,
          input_tokens: 500,
          output_tokens: 200
        })

      :ok =
        record_usage(%{
          provider: "openai",
          cost: 0.03,
          input_tokens: 300,
          output_tokens: 100
        })

      # Get the cost report
      {:ok, result} = UsageCost.handle(%{}, @ctx)

      assert result["totalCost"] >= 0.08
      assert result["totalRequests"] >= 2
      assert result["breakdown"]["claude"] >= 0.05
      assert result["breakdown"]["openai"] >= 0.03
    end

    test "records usage with string keys" do
      :ok =
        record_usage(%{
          "provider" => "claude",
          "cost" => 0.10,
          "input_tokens" => 1000,
          "output_tokens" => 500
        })

      # Verify it was recorded
      summary = LemonCore.Store.get(:usage_data, :current)
      assert summary != nil
      assert summary.total_cost >= 0.10
    end

    test "keeps unavailable provider attribution unknown" do
      :ok = record_usage(%{cost: 0.01})

      summary = LemonCore.Store.get(:usage_data, :current)
      assert Map.get(summary.breakdown, "unknown", 0) >= 0.01
    end

    test "accumulates usage across multiple calls" do
      for _ <- 1..5 do
        :ok =
          record_usage(%{
            provider: "claude",
            cost: 0.01,
            input_tokens: 100,
            output_tokens: 50
          })
      end

      summary = LemonCore.Store.get(:usage_data, :current)
      assert summary.total_cost >= 0.05
      assert summary.total_requests >= 5
      assert summary.total_tokens.input >= 500
      assert summary.total_tokens.output >= 250
    end

    test "stores daily records" do
      :ok =
        record_usage(%{
          provider: "claude",
          cost: 0.05,
          input_tokens: 500,
          output_tokens: 200
        })

      # Get today's date key
      date_key = Date.utc_today() |> Date.to_iso8601()

      # Check daily record exists
      record = LemonCore.Store.get(:usage_records, date_key)
      assert record != nil
      assert record.total_cost >= 0.05
      assert record.breakdown["claude"] >= 0.05

      # Clean up
      on_exit(fn ->
        LemonCore.Store.delete(:usage_records, date_key)
      end)
    end
  end

  describe "UsageCost daily grouping" do
    test "returns daily breakdown when grouped by day" do
      # Get today's date
      today = Date.utc_today() |> Date.to_iso8601()

      # Create a usage record for today
      record = %{
        date: today,
        total_cost: 1.50,
        breakdown: %{"claude" => 1.00, "openai" => 0.50},
        requests: %{"claude" => 10, "openai" => 5},
        tokens: %{
          "claude" => %{input: 5000, output: 2000},
          "openai" => %{input: 3000, output: 1000}
        }
      }

      LemonCore.Store.put(:usage_records, today, record)

      on_exit(fn ->
        LemonCore.Store.delete(:usage_records, today)
      end)

      # Query with groupBy=day
      {:ok, result} = UsageCost.handle(%{"groupBy" => "day"}, @ctx)

      assert is_map(result["daily"])
      assert Map.has_key?(result["daily"], today)
      assert result["daily"][today]["cost"] == 1.50
      assert result["summary"]["dailyReturned"] == true
      assert result["summary"]["dailyCount"] >= 1
    end
  end
end
