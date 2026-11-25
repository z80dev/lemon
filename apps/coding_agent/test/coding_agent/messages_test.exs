defmodule CodingAgent.MessagesTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Messages
  alias CodingAgent.Messages.{BranchSummaryMessage, CustomMessage}

  describe "to_llm/1" do
    test "passes through LemonAi.Types.UserMessage unchanged" do
      msg = %LemonAi.Types.UserMessage{role: :user, content: "hello", timestamp: 0}
      [result] = Messages.to_llm([msg])
      assert result == msg
    end

    test "passes through LemonAi.Types.AssistantMessage unchanged" do
      msg = %LemonAi.Types.AssistantMessage{
        role: :assistant,
        content: [],
        model: "test",
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result == msg
    end

    test "passes through LemonAi.Types.ToolResultMessage unchanged" do
      msg = %LemonAi.Types.ToolResultMessage{
        role: :tool_result,
        tool_call_id: "123",
        tool_name: "test_tool",
        content: [],
        trust: :untrusted,
        is_error: false,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result == msg
    end

    test "converts CustomMessage to user message with string content" do
      msg = %CustomMessage{
        custom_type: "test",
        content: "custom content",
        display: true,
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.UserMessage{} = result
      assert result.content == "custom content"
      assert result.timestamp == 123
    end

    test "converts CustomMessage to user message with content blocks" do
      msg = %CustomMessage{
        custom_type: "test",
        content: [%LemonAi.Types.TextContent{text: "block content"}],
        display: true,
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.UserMessage{} = result
      assert [%LemonAi.Types.TextContent{text: "block content"}] = result.content
    end

    test "wraps async followup custom messages with provenance header" do
      original_content = "task output\nwith detail"

      msg = %CustomMessage{
        custom_type: "async_followup",
        content: original_content,
        details: %{
          "source" => :task,
          "task_id" => "task-123",
          "run_id" => "run-123",
          "delivery" => :steer,
          "delivery_receipt" => %{
            requested_mode: :followup,
            actual_mode: :steer,
            status: :dispatched_to_active,
            fallback_mode: :followup,
            active_run_id: "active-run"
          }
        },
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.UserMessage{} = result
      assert result.timestamp == 123
      assert result.content =~ "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"
      assert_async_followup_envelope(result.content, original_content)
      assert result.content =~ "task_id: task-123"
      assert result.content =~ "run_id: run-123"
      assert result.content =~ "delivery: steer"
      assert result.content =~ "requested_delivery: followup"
      assert result.content =~ "actual_delivery: steer"
      assert result.content =~ "delivery_status: dispatched_to_active"
      assert result.content =~ "fallback_delivery: followup"
      assert result.content =~ "active_run_id: active-run"
    end

    test "renders every batched completion's identity and delivery receipt" do
      original_content = "first answer\n\nsecond answer"

      msg = %CustomMessage{
        custom_type: "async_followup",
        content: original_content,
        details: %{
          "run_id" => "legacy-latest-run",
          "async_followups" => [
            %{
              source: :task,
              task_id: "task-first",
              run_id: "run-first",
              delivery: :followup,
              delivery_receipt: %{actual_mode: :followup, status: :queued}
            },
            %{
              "source" => "agent",
              "task_id" => "task-second",
              "run_id" => "run-second",
              "agent_id" => "oracle",
              "session_key" => "agent:oracle:child",
              "delivery" => "followup",
              "delivery_receipt" => %{"actual_mode" => "collect", "status" => "collected"}
            }
          ]
        }
      }

      [result] = Messages.to_llm([msg])
      assert_async_followup_envelope(result.content, original_content)
      assert result.content =~ "task_id: task-first\nrun_id: run-first"
      assert result.content =~ "actual_delivery: followup\ndelivery_status: queued"
      assert result.content =~ "task_id: task-second\nrun_id: run-second"
      assert result.content =~ "agent_id: oracle\nsession_key: agent:oracle:child"
      assert result.content =~ "actual_delivery: collect\ndelivery_status: collected"
      refute result.content =~ "legacy-latest-run"
    end

    test "wraps async followup custom messages with fallback values for missing metadata" do
      msg = %CustomMessage{
        custom_type: "async_followup",
        content: "",
        details: %{
          "source" => :agent,
          "task_id" => nil,
          "run_id" => nil,
          "delivery" => nil
        },
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.UserMessage{} = result
      assert_async_followup_envelope(result.content, "")
    end

    test "wraps very long async followup content inside a safe markdown fence" do
      original_content =
        String.duplicate("long async completion\n", 300) <>
          "```\nembedded fence\n```"

      msg = %CustomMessage{
        custom_type: "async_followup",
        content: original_content,
        details: %{
          "source" => :task,
          "task_id" => "task-long",
          "run_id" => "run-long",
          "delivery" => :followup
        },
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.UserMessage{} = result
      assert result.content =~ "\n````\n"
      assert_async_followup_envelope(result.content, original_content)
    end

    test "converts BranchSummaryMessage with tags" do
      msg = %BranchSummaryMessage{summary: "branch info", timestamp: 123}
      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.UserMessage{} = result
      assert result.content =~ "<branch_summary>"
      assert result.content =~ "branch info"
      assert result.content =~ "</branch_summary>"
      assert result.timestamp == 123
    end

    test "converts plain map with role: :user" do
      msg = %{role: :user, content: "plain map content", timestamp: 100}
      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.UserMessage{} = result
      assert result.content == "plain map content"
      assert result.timestamp == 100
    end

    test "converts plain map with role: :assistant" do
      msg = %{role: :assistant, content: [], model: "test-model", timestamp: 100}
      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.AssistantMessage{} = result
      assert result.model == "test-model"
      assert result.timestamp == 100
    end

    test "converts plain map with role: :tool_result" do
      msg = %{
        role: :tool_result,
        tool_call_id: "abc",
        content: [],
        is_error: false,
        timestamp: 100
      }

      [result] = Messages.to_llm([msg])
      assert %LemonAi.Types.ToolResultMessage{} = result
      assert result.tool_call_id == "abc"
      assert result.trust == :untrusted
      assert result.timestamp == 100
    end

    test "returns empty list for empty input" do
      assert Messages.to_llm([]) == []
    end
  end

  describe "to_llm/1 with journal maps" do
    test "reads them through the canonical deserializer" do
      [user, assistant, tool_result] =
        Messages.to_llm([
          %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => "question"}],
            "timestamp" => 1
          },
          %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_call", "id" => "c1", "name" => "read", "arguments" => %{}}
            ],
            "stop_reason" => "tool_use",
            "timestamp" => 2
          },
          %{
            "role" => "tool_result",
            "tool_call_id" => "c1",
            "tool_name" => "read",
            "trust" => "trusted",
            "content" => [%{"type" => "text", "text" => "body"}],
            "timestamp" => 3
          }
        ])

      assert %LemonAi.Types.UserMessage{content: [%LemonAi.Types.TextContent{text: "question"}]} =
               user

      assert %LemonAi.Types.AssistantMessage{
               stop_reason: :tool_use,
               content: [%LemonAi.Types.ToolCall{id: "c1", name: "read"}]
             } = assistant

      # The tool name survives and a journal never restores trust.
      assert %LemonAi.Types.ToolResultMessage{
               tool_call_id: "c1",
               tool_name: "read",
               trust: :untrusted
             } = tool_result
    end

    test "branch summaries are fenced like the struct" do
      [result] =
        Messages.to_llm([
          %{
            "role" => "branch_summary",
            "summary" => "explored x",
            "from_id" => "a",
            "timestamp" => 9
          }
        ])

      assert [expected] =
               Messages.to_llm([%BranchSummaryMessage{summary: "explored x", timestamp: 9}])

      assert result == expected
    end

    test "async followup journal maps keep their provenance wrapper" do
      [result] =
        Messages.to_llm([
          %{
            "role" => "custom",
            "custom_type" => "async_followup",
            "content" => [%{"type" => "text", "text" => "done"}],
            "details" => %{"task_id" => "task-1"}
          }
        ])

      assert result.content =~ "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"
      assert result.content =~ "task_id: task-1"
      assert_async_followup_envelope(result.content, "done")
    end

    test "unknown roles are dropped, as on session restore" do
      assert Messages.to_llm([%{"role" => "retired_kind", "content" => "x"}]) == []
    end
  end

  describe "to_llm/1 edge cases" do
    test "plain map with role: :user and missing timestamp" do
      msg = %{role: :user, content: "hello"}
      [result] = Messages.to_llm([msg])
      assert result.timestamp == 0
    end

    test "plain map with role: :assistant and minimal fields" do
      msg = %{role: :assistant, content: []}
      [result] = Messages.to_llm([msg])
      assert result.model == ""
      assert result.provider == nil
      assert result.api == nil
      assert result.usage == nil
      assert result.stop_reason == nil
      assert result.timestamp == 0
    end

    test "plain map with role: :tool_result using tool_use_id field" do
      msg = %{role: :tool_result, tool_use_id: "legacy_id", content: []}
      [result] = Messages.to_llm([msg])
      assert result.tool_call_id == "legacy_id"
      assert result.trust == :untrusted
    end

    test "plain map with role: :tool_result prefers tool_call_id over tool_use_id" do
      msg = %{role: :tool_result, tool_call_id: "new_id", tool_use_id: "old_id", content: []}
      [result] = Messages.to_llm([msg])
      assert result.tool_call_id == "new_id"
    end

    test "plain map with role: :tool_result accepts string trust values" do
      msg = %{role: :tool_result, tool_call_id: "trusted_id", trust: "untrusted", content: []}
      [result] = Messages.to_llm([msg])
      assert result.trust == :untrusted
    end

    test "CustomMessage with details field is ignored in conversion" do
      msg = %CustomMessage{
        custom_type: "test",
        content: "content",
        display: true,
        details: %{some: "data"},
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      # Details are not preserved in the LemonAi.Types.UserMessage
      assert result.content == "content"
    end
  end

  describe "struct defaults" do
    test "CustomMessage has correct defaults" do
      msg = %CustomMessage{}
      assert msg.role == :custom
      assert msg.custom_type == ""
      assert msg.content == ""
      assert msg.display == true
      assert msg.details == nil
      assert msg.timestamp == 0
    end

    test "BranchSummaryMessage has correct defaults" do
      msg = %BranchSummaryMessage{}
      assert msg.role == :branch_summary
      assert msg.summary == ""
      assert msg.timestamp == 0
    end
  end

  defp assert_async_followup_envelope(content, original_content) do
    assert Regex.match?(
             ~r/\n(`{3,})\n#{Regex.escape(original_content)}\n\1\z/s,
             content
           )
  end
end
