defmodule CodingAgent.Session.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.Diagnostics

  describe "count_tool_results/1" do
    test "returns {0, 0} for empty messages" do
      assert Diagnostics.count_tool_results([]) == {0, 0}
    end

    test "counts tool result messages" do
      messages = [
        %Ai.Types.ToolResultMessage{
          tool_call_id: "tc_1",
          content: [%Ai.Types.TextContent{type: :text, text: "ok"}],
          is_error: false
        },
        %Ai.Types.ToolResultMessage{
          tool_call_id: "tc_2",
          content: [%Ai.Types.TextContent{type: :text, text: "fail"}],
          is_error: true
        },
        %Ai.Types.UserMessage{role: :user, content: "hello"}
      ]

      assert Diagnostics.count_tool_results(messages) == {2, 1}
    end

    test "counts all results as non-error when is_error is false" do
      messages = [
        %Ai.Types.ToolResultMessage{
          tool_call_id: "tc_1",
          content: [%Ai.Types.TextContent{type: :text, text: "ok"}],
          is_error: false
        },
        %Ai.Types.ToolResultMessage{
          tool_call_id: "tc_2",
          content: [%Ai.Types.TextContent{type: :text, text: "ok2"}],
          is_error: false
        }
      ]

      assert Diagnostics.count_tool_results(messages) == {2, 0}
    end
  end

  describe "latest_activity_timestamp/2" do
    test "returns fallback when messages are empty" do
      assert Diagnostics.latest_activity_timestamp([], 1000) == 1000
    end

    test "returns the latest timestamp from messages" do
      messages = [
        %{timestamp: 100},
        %{timestamp: 300},
        %{timestamp: 200}
      ]

      assert Diagnostics.latest_activity_timestamp(messages, 0) == 300
    end

    test "returns fallback when no timestamps are larger" do
      messages = [
        %{timestamp: 50},
        %{timestamp: 75}
      ]

      assert Diagnostics.latest_activity_timestamp(messages, 100) == 100
    end

    test "ignores non-integer timestamps" do
      messages = [
        %{timestamp: nil},
        %{timestamp: "invalid"},
        %{timestamp: 200}
      ]

      assert Diagnostics.latest_activity_timestamp(messages, 100) == 200
    end

    test "handles messages without timestamp key" do
      messages = [
        %{content: "hello"},
        %{timestamp: 150}
      ]

      assert Diagnostics.latest_activity_timestamp(messages, 100) == 150
    end
  end

  describe "determine_health_status/3" do
    test "returns :unhealthy when agent is not alive (false)" do
      assert Diagnostics.determine_health_status(false, 0.0, %{}) == :unhealthy
    end

    test "returns :unhealthy when agent is nil" do
      assert Diagnostics.determine_health_status(nil, 0.0, %{}) == :unhealthy
    end

    test "returns :degraded when error rate exceeds 0.2" do
      assert Diagnostics.determine_health_status(true, 0.3, %{}) == :degraded
    end

    test "returns :degraded at boundary (just above 0.2)" do
      assert Diagnostics.determine_health_status(true, 0.21, %{}) == :degraded
    end

    test "returns :healthy when agent is alive and error rate is low" do
      assert Diagnostics.determine_health_status(true, 0.0, %{}) == :healthy
    end

    test "returns :healthy at boundary (exactly 0.2)" do
      assert Diagnostics.determine_health_status(true, 0.2, %{}) == :healthy
    end

    test "returns :healthy when error rate is between 0 and 0.2" do
      assert Diagnostics.determine_health_status(true, 0.1, %{}) == :healthy
    end
  end
end
