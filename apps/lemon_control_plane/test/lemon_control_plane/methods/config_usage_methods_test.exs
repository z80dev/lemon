defmodule LemonControlPlane.Methods.ConfigUsageMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{
    ConfigGet,
    ConfigSet,
    ConnectChallenge,
    UsageStatus,
    UsageCost
  }

  alias LemonControlPlane.ConfigStore
  alias LemonCore.Store

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  describe "ConfigGet" do
    test "returns config for specific key" do
      {:ok, result} = ConfigGet.handle(%{"key" => "logLevel"}, @ctx)

      assert result["key"] == "logLevel"
      assert result["summary"]["requestedKey"] == "logLevel"
      assert result["summary"]["keyCount"] == 1
      assert result["summary"]["sensitive"] == false
      assert result["summary"]["cleanup"]["includesSensitiveValues"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "returns all config when no key specified" do
      {:ok, result} = ConfigGet.handle(%{}, @ctx)

      assert is_map(result)
      assert result["summary"]["keyCount"] == map_size(Map.delete(result, "summary"))
      assert is_integer(result["summary"]["sensitiveKeyCount"])
      assert result["summary"]["cleanup"]["includesSensitiveValues"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "redacts sensitive stored config values" do
      key = "openai_api_key"
      previous = ConfigStore.get(key)

      on_exit(fn ->
        case previous do
          nil -> Store.delete(:system_config, key)
          value -> ConfigStore.put(key, value)
        end
      end)

      :ok = ConfigStore.put(key, "sk-private-test-value")

      {:ok, single} = ConfigGet.handle(%{"key" => key}, @ctx)
      {:ok, all_config} = ConfigGet.handle(%{}, @ctx)

      assert single["value"] == %{"redacted" => true, "kind" => "secret"}
      assert all_config[key] == %{"redacted" => true, "kind" => "secret"}
      assert single["summary"]["sensitive"] == true
      assert single["summary"]["valueReturned"] == false
      assert all_config["summary"]["sensitiveKeyCount"] >= 1
      refute inspect(single["summary"]) =~ "sk-private-test-value"
      refute inspect(all_config["summary"]) =~ "sk-private-test-value"
    end

    test "has correct method name and scopes" do
      assert ConfigGet.name() == "config.get"
      assert ConfigGet.scopes() == [:read]
    end
  end

  describe "ConfigSet" do
    test "requires key and value" do
      {:error, error1} = ConfigSet.handle(%{}, @ctx)
      assert error1 == {:invalid_request, "key is required"}

      {:error, error2} = ConfigSet.handle(%{"key" => "test"}, @ctx)
      assert error2 == {:invalid_request, "value is required"}
    end

    test "sets config value" do
      {:ok, result} = ConfigSet.handle(%{"key" => "testKey", "value" => "testValue"}, @ctx)

      assert result["key"] == "testKey"
      assert result["value"] == "testValue"
      assert result["success"] == true
      assert result["summary"]["key"] == "testKey"
      assert result["summary"]["valueStored"] == true
      assert result["summary"]["sensitive"] == false
      assert result["summary"]["cleanup"]["includesValue"] == true
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "redacts sensitive config value in response" do
      key = "provider_secret_token"
      previous = ConfigStore.get(key)

      on_exit(fn ->
        case previous do
          nil -> Store.delete(:system_config, key)
          value -> ConfigStore.put(key, value)
        end
      end)

      {:ok, result} = ConfigSet.handle(%{"key" => key, "value" => "private-token"}, @ctx)

      assert result["key"] == key
      assert result["value"] == %{"redacted" => true, "kind" => "secret"}
      assert result["summary"]["sensitive"] == true
      assert result["summary"]["cleanup"]["includesValue"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      assert ConfigStore.get(key) == "private-token"
    end

    test "has correct method name and scopes" do
      assert ConfigSet.name() == "config.set"
      assert ConfigSet.scopes() == [:admin]
    end
  end

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
          input_tokens: 12,
          output_tokens: 3
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
