defmodule LemonControlPlane.Methods.ConnectUsageMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{
    ConnectChallenge,
    UsageStatus,
    UsageCost
  }

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  describe "ConnectChallenge" do
    test "requires challenge" do
      {:error, error} = ConnectChallenge.handle(%{}, @ctx)
      assert error == {:invalid_request, "challenge is required"}
    end

    test "has correct method name and scopes" do
      assert ConnectChallenge.name() == "connect.challenge"
      assert ConnectChallenge.scopes() == []
    end
  end

  describe "UsageStatus" do
    test "returns usage status" do
      {:ok, result} = UsageStatus.handle(%{}, @ctx)

      assert is_binary(result["period"])
      assert is_integer(result["periodStart"])
      assert is_map(result["quotas"])
      assert is_map(result["summary"])
      assert is_list(result["providers"])
      assert result["includesPrompts"] == false
      assert result["includesResponses"] == false
      assert result["includesMessageBodies"] == false
      assert result["includesCredentials"] == false
      assert result["includesSecretValues"] == false
    end

    test "reports usage recorded through usage.cost" do
      :ok =
        record_usage(%{
          provider: "usage_status_test",
          cost: 0.02,
          input: 12,
          output: 3,
          cache_read: 0,
          cache_write: 0
        })

      {:ok, result} = UsageStatus.handle(%{}, @ctx)

      assert result["runs"] >= 1
      assert result["cost"] >= 0.02
      assert result["tokens"]["input"] >= 12
      assert result["tokens"]["output"] >= 3
      assert result["summary"]["totalTokens"] >= 15

      provider = Enum.find(result["providers"], &(&1["provider"] == "usage_status_test"))
      assert provider["cost"] >= 0.02
      assert provider["requests"] >= 1
      assert provider["inputTokens"] >= 12
      assert provider["outputTokens"] >= 3
    end

    test "uses shared usage diagnostics without leaking stored sensitive fields" do
      previous_summary = LemonCore.UsageStore.get_summary(:current)
      today_key = Date.to_iso8601(Date.utc_today())
      previous_today = LemonCore.UsageStore.get_record(today_key)

      on_exit(fn ->
        if previous_summary do
          LemonCore.UsageStore.put_summary(:current, previous_summary)
        else
          LemonCore.Store.delete(:usage_data, :current)
        end

        if previous_today do
          LemonCore.UsageStore.put_record(today_key, previous_today)
        else
          LemonCore.Store.delete(:usage_records, today_key)
        end
      end)

      LemonCore.UsageStore.put_summary(:current, %{
        total_cost: 0.42,
        total_requests: 3,
        total_tokens: %{input: 1_000, output: 500},
        breakdown: %{"openai" => 0.42},
        requests: %{"openai" => 3},
        tokens: %{"openai" => %{input: 1_000, output: 500}},
        prompt: "private usage status prompt",
        response: "private usage status response",
        api_key: "usage-status-secret-key"
      })

      LemonCore.UsageStore.put_record(today_key, %{
        date: today_key,
        total_cost: 0.42,
        requests: %{"openai" => 3},
        message_body: "private usage status message"
      })

      {:ok, result} = UsageStatus.handle(%{}, @ctx)

      assert result["runs"] == 3
      assert result["cost"] == 0.42
      assert result["tokens"] == %{"input" => 1_000, "output" => 500}
      assert result["summary"]["status"] in ["within_limits", "unlimited"]
      assert result["summary"]["totalTokens"] == 1_500
      assert result["includesPrompts"] == false
      assert result["includesResponses"] == false
      assert result["includesMessageBodies"] == false
      assert result["includesCredentials"] == false
      assert result["includesSecretValues"] == false

      assert [provider] = result["providers"]
      assert provider["provider"] == "openai"
      assert provider["cost"] == 0.42
      assert provider["requests"] == 3
      assert provider["inputTokens"] == 1_000
      assert provider["outputTokens"] == 500

      result_text = inspect(result)
      refute result_text =~ "private usage status prompt"
      refute result_text =~ "private usage status response"
      refute result_text =~ "private usage status message"
      refute result_text =~ "usage-status-secret-key"
    end

    test "has correct method name and scopes" do
      assert UsageStatus.name() == "usage.status"
      assert UsageStatus.scopes() == [:read]
    end
  end

  defp record_usage(usage) do
    run_id = "usage-test-#{LemonCore.Id.uuid()}"
    provider = usage[:provider] || usage["provider"]

    entry =
      LemonCore.UsageLedger.entry(run_id, "agent:test:usage", %{
        completed: %{usage: usage},
        completed_at_ms: System.system_time(:millisecond),
        meta: %{provider: provider, model: "test"}
      })

    record = LemonCore.UsageLedger.occurrence_record(entry)
    on_exit(fn -> LemonCore.Store.delete(:usage_occurrences, record.id) end)
    LemonCore.UsageLedger.record(entry)
  end

  describe "UsageCost" do
    test "returns cost breakdown" do
      {:ok, result} = UsageCost.handle(%{}, @ctx)

      assert is_binary(result["startDate"])
      assert is_binary(result["endDate"])
      assert is_number(result["totalCost"])
      assert is_map(result["breakdown"])
      assert result["summary"]["providerCount"] == map_size(result["breakdown"])
      assert result["summary"]["dailyReturned"] == Map.has_key?(result, "daily")
      assert result["summary"]["cleanup"]["includesPrompts"] == false
      assert result["summary"]["cleanup"]["includesResponses"] == false
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

    test "has correct method name and scopes" do
      assert UsageCost.name() == "usage.cost"
      assert UsageCost.scopes() == [:read]
    end
  end
end
