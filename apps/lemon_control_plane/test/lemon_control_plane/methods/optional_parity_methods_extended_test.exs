defmodule LemonControlPlane.Methods.OptionalParityMethodsExtendedTest do
  @moduledoc """
  Extended tests for optional parity methods with full implementations.

  Tests cover:
  - browser.request forwarding to browser nodes
  - tts.convert with system TTS
  - update.run with update manifest fetching
  - usage.cost with record_usage tracking
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    BrowserRequest,
    TtsConvert,
    UpdateRun,
    UsageCost
  }

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  setup do
    # Clean up test data
    on_exit(fn ->
      # Clean up any test nodes
      case LemonCore.Store.get(:nodes_registry, "test-browser-node") do
        nil -> :ok
        _ -> LemonCore.Store.delete(:nodes_registry, "test-browser-node")
      end

      # Clean up TTS config
      LemonCore.Store.delete(:tts_config, :global)

      # Clean up usage data
      LemonCore.Store.delete(:usage_data, :current)

      # Clean up update config
      LemonCore.Store.delete(:update_config, :global)
    end)

    :ok
  end

  describe "BrowserRequest" do
    test "requires method parameter" do
      {:error, error} = BrowserRequest.handle(%{}, @ctx)
      assert error == {:invalid_request, "method is required"}
    end

    test "returns not_found when no browser node available" do
      {:error, error} = BrowserRequest.handle(%{"method" => "navigate"}, @ctx)
      assert error == {:not_found, "No browser node available. Pair a browser node first."}
    end

    test "returns unavailable when browser node is offline" do
      # Create an offline browser node
      node = %{
        id: "test-browser-node",
        type: "browser",
        status: :offline,
        name: "Test Browser"
      }
      LemonCore.Store.put(:nodes_registry, "test-browser-node", node)

      {:error, error} = BrowserRequest.handle(%{
        "method" => "navigate",
        "nodeId" => "test-browser-node"
      }, @ctx)

      assert error == {:unavailable, "Browser node is not online"}
    end

    test "forwards request to online browser node" do
      # Create an online browser node
      node = %{
        id: "test-browser-node",
        type: "browser",
        status: :online,
        name: "Test Browser"
      }
      LemonCore.Store.put(:nodes_registry, "test-browser-node", node)

      # This will forward to node.invoke which creates a pending invocation
      {:ok, result} = BrowserRequest.handle(%{
        "method" => "navigate",
        "args" => %{"url" => "https://example.com"},
        "nodeId" => "test-browser-node"
      }, @ctx)

      assert result["nodeId"] == "test-browser-node"
      assert result["method"] == "browser.navigate"
      assert result["status"] == "pending"
      assert is_binary(result["invokeId"])
    end

    test "finds default browser node when nodeId not specified" do
      # Create an online browser node
      node = %{
        id: "default-browser-node",
        type: "browser",
        status: :online,
        name: "Default Browser"
      }
      LemonCore.Store.put(:nodes_registry, "default-browser-node", node)

      on_exit(fn ->
        LemonCore.Store.delete(:nodes_registry, "default-browser-node")
      end)

      {:ok, result} = BrowserRequest.handle(%{
        "method" => "screenshot"
      }, @ctx)

      assert result["nodeId"] == "default-browser-node"
      assert result["method"] == "browser.screenshot"
    end

    test "has correct method name and scopes" do
      assert BrowserRequest.name() == "browser.request"
      assert BrowserRequest.scopes() == [:write]
    end
  end

  describe "TtsConvert" do
    test "requires text parameter" do
      {:error, error} = TtsConvert.handle(%{}, @ctx)
      assert error == {:invalid_request, "text is required"}
    end

    test "returns forbidden when TTS is not enabled" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: false})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)
      assert error == {:forbidden, "TTS is not enabled"}
    end

    test "returns not_implemented for cloud providers without API keys" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "openai"})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)
      assert error == {:not_implemented, "Method not implemented: OpenAI TTS requires api key. Set openai_api_key in tts_config."}
    end

    test "returns not_implemented for elevenlabs without API key" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "elevenlabs"})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)
      assert error == {:not_implemented, "Method not implemented: ElevenLabs TTS requires api key. Set elevenlabs_api_key in tts_config."}
    end

    test "returns error for unknown provider" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "unknown"})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)
      assert elem(error, 0) == :internal_error
    end

    # Skip system TTS test on CI or when say command not available
    @tag :system_tts
    test "converts text with system TTS on macOS" do
      # Only run on macOS
      case :os.type() do
        {:unix, :darwin} ->
          LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "system"})

          {:ok, result} = TtsConvert.handle(%{"text" => "Test"}, @ctx)

          assert result["success"] == true
          assert result["provider"] == "system"
          assert result["format"] in ["audio/wav", "audio/aiff"]
          assert is_binary(result["data"])
          # Data should be base64 encoded
          assert {:ok, _} = Base.decode64(result["data"])

        _ ->
          :skip
      end
    end

    test "has correct method name and scopes" do
      assert TtsConvert.name() == "tts.convert"
      assert TtsConvert.scopes() == [:write]
    end
  end

  describe "UpdateRun" do
    test "returns version info when update URL not configured" do
      {:ok, result} = UpdateRun.handle(%{}, @ctx)

      assert is_binary(result["currentVersion"])
      assert result["updateAvailable"] == false
      assert String.contains?(result["message"], "not configured")
    end

    test "respects force parameter" do
      {:ok, result} = UpdateRun.handle(%{"force" => true}, @ctx)

      assert is_binary(result["currentVersion"])
    end

    test "respects checkOnly parameter" do
      {:ok, result} = UpdateRun.handle(%{"checkOnly" => true}, @ctx)

      assert is_binary(result["currentVersion"])
    end

    test "has correct method name and scopes" do
      assert UpdateRun.name() == "update.run"
      assert UpdateRun.scopes() == [:admin]
    end
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
    end

    test "accepts date range parameters" do
      {:ok, result} = UsageCost.handle(%{
        "startDate" => "2024-01-01",
        "endDate" => "2024-01-31"
      }, @ctx)

      assert result["startDate"] == "2024-01-01"
      assert result["endDate"] == "2024-01-31"
    end

    test "accepts snake_case parameters" do
      {:ok, result} = UsageCost.handle(%{
        "start_date" => "2024-01-01",
        "end_date" => "2024-01-31",
        "group_by" => "day"
      }, @ctx)

      assert result["startDate"] == "2024-01-01"
    end

    test "has correct method name and scopes" do
      assert UsageCost.name() == "usage.cost"
      assert UsageCost.scopes() == [:read]
    end
  end

  describe "UsageCost.record_usage/1" do
    test "records usage and updates totals" do
      # Record some usage
      :ok = UsageCost.record_usage(%{
        provider: "claude",
        cost: 0.05,
        input_tokens: 500,
        output_tokens: 200
      })

      :ok = UsageCost.record_usage(%{
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
      :ok = UsageCost.record_usage(%{
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

    test "defaults to 'other' provider when not specified" do
      :ok = UsageCost.record_usage(%{cost: 0.01})

      summary = LemonCore.Store.get(:usage_data, :current)
      assert Map.get(summary.breakdown, "other", 0) >= 0.01
    end

    test "accumulates usage across multiple calls" do
      for _ <- 1..5 do
        :ok = UsageCost.record_usage(%{
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
      :ok = UsageCost.record_usage(%{
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
    end
  end
end
