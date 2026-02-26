defmodule CodingAgent.MessagesTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Messages

  alias CodingAgent.Messages.{
    UserMessage,
    AssistantMessage,
    ToolResultMessage,
    BashExecutionMessage,
    CustomMessage,
    BranchSummaryMessage,
    CompactionSummaryMessage,
    TextContent,
    ImageContent,
    ThinkingContent,
    ToolCall,
    Usage
  }

  describe "to_llm/1" do
    test "passes through Ai.Types.UserMessage unchanged" do
      msg = %Ai.Types.UserMessage{role: :user, content: "hello", timestamp: 0}
      [result] = Messages.to_llm([msg])
      assert result == msg
    end

    test "passes through Ai.Types.AssistantMessage unchanged" do
      msg = %Ai.Types.AssistantMessage{role: :assistant, content: [], model: "test", timestamp: 0}
      [result] = Messages.to_llm([msg])
      assert result == msg
    end

    test "passes through Ai.Types.ToolResultMessage unchanged" do
      msg = %Ai.Types.ToolResultMessage{
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

    test "converts UserMessage to Ai.Types.UserMessage" do
      msg = %UserMessage{content: "hello world", timestamp: 123}
      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert result.role == :user
      assert result.content == "hello world"
      assert result.timestamp == 123
    end

    test "converts UserMessage with content blocks" do
      msg = %UserMessage{
        content: [
          %TextContent{text: "hello"},
          %ImageContent{data: "abc123", mime_type: "image/png"}
        ],
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert is_list(result.content)
      assert length(result.content) == 2

      [text_block, image_block] = result.content
      assert %Ai.Types.TextContent{text: "hello"} = text_block
      assert %Ai.Types.ImageContent{data: "abc123", mime_type: "image/png"} = image_block
    end

    test "converts AssistantMessage to Ai.Types.AssistantMessage" do
      msg = %AssistantMessage{
        content: [%TextContent{text: "response"}],
        provider: "anthropic",
        model: "claude-3",
        api: "messages",
        usage: %Usage{input: 10, output: 20, cache_read: 5, cache_write: 2, total_tokens: 37},
        stop_reason: :stop,
        timestamp: 456
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.AssistantMessage{} = result
      assert result.role == :assistant
      assert length(result.content) == 1
      assert hd(result.content).text == "response"
      assert result.provider == "anthropic"
      assert result.model == "claude-3"
      assert result.api == "messages"
      assert result.stop_reason == :stop
      assert result.timestamp == 456
      assert result.usage.input == 10
      assert result.usage.output == 20
    end

    test "converts AssistantMessage with tool calls" do
      msg = %AssistantMessage{
        content: [
          %TextContent{text: "I'll read that file"},
          %ToolCall{id: "tool_1", name: "read", arguments: %{"path" => "/test.txt"}}
        ],
        model: "claude-3",
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.AssistantMessage{} = result
      assert length(result.content) == 2

      [text_block, tool_block] = result.content
      assert %Ai.Types.TextContent{text: "I'll read that file"} = text_block
      assert %Ai.Types.ToolCall{id: "tool_1", name: "read"} = tool_block
      assert tool_block.arguments == %{"path" => "/test.txt"}
    end

    test "converts AssistantMessage with thinking content" do
      msg = %AssistantMessage{
        content: [
          %ThinkingContent{thinking: "Let me think about this..."},
          %TextContent{text: "Here's my answer"}
        ],
        model: "claude-3",
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.AssistantMessage{} = result
      assert length(result.content) == 2

      [thinking_block, text_block] = result.content
      assert %Ai.Types.ThinkingContent{thinking: "Let me think about this..."} = thinking_block
      assert %Ai.Types.TextContent{text: "Here's my answer"} = text_block
    end

    test "converts AssistantMessage with nil usage" do
      msg = %AssistantMessage{content: [], model: "test", usage: nil, timestamp: 0}
      [result] = Messages.to_llm([msg])
      assert result.usage == nil
    end

    test "converts ToolResultMessage to Ai.Types.ToolResultMessage" do
      msg = %ToolResultMessage{
        tool_use_id: "tool_123",
        content: [%TextContent{text: "file contents here"}],
        is_error: false,
        timestamp: 789
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.ToolResultMessage{} = result
      assert result.role == :tool_result
      assert result.tool_call_id == "tool_123"
      assert result.trust == :trusted
      assert result.is_error == false
      assert result.timestamp == 789
      assert length(result.content) == 1
    end

    test "converts ToolResultMessage with is_error true" do
      msg = %ToolResultMessage{
        tool_use_id: "tool_123",
        content: [%TextContent{text: "Error: file not found"}],
        is_error: true,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.is_error == true
    end

    test "converts ToolResultMessage trust to Ai.Types.ToolResultMessage" do
      msg = %ToolResultMessage{
        tool_use_id: "tool_123",
        content: [%TextContent{text: "untrusted output"}],
        trust: :untrusted,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.trust == :untrusted
    end

    test "converts BashExecutionMessage to user message" do
      msg = %BashExecutionMessage{
        command: "ls",
        output: "file.txt",
        exit_code: 0,
        cancelled: false,
        truncated: false,
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert result.content =~ "ls"
      assert result.content =~ "file.txt"
      assert result.timestamp == 123
    end

    test "BashExecutionMessage includes command prefix" do
      msg = %BashExecutionMessage{
        command: "echo hello",
        output: "hello",
        exit_code: 0,
        cancelled: false,
        truncated: false,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.content =~ "$ echo hello"
    end

    test "BashExecutionMessage with non-zero exit code includes exit code" do
      msg = %BashExecutionMessage{
        command: "false",
        output: "",
        exit_code: 1,
        cancelled: false,
        truncated: false,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.content =~ "[exit code: 1]"
    end

    test "BashExecutionMessage with cancelled flag" do
      msg = %BashExecutionMessage{
        command: "sleep 100",
        output: "",
        exit_code: nil,
        cancelled: true,
        truncated: false,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.content =~ "[cancelled]"
    end

    test "BashExecutionMessage with truncated flag" do
      msg = %BashExecutionMessage{
        command: "cat bigfile",
        output: "partial output...",
        exit_code: 0,
        cancelled: false,
        truncated: true,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.content =~ "[truncated]"
    end

    test "excludes BashExecutionMessage with exclude_from_context: true" do
      msg = %BashExecutionMessage{
        command: "ls",
        output: "file.txt",
        exit_code: 0,
        cancelled: false,
        truncated: false,
        exclude_from_context: true,
        timestamp: 123
      }

      result = Messages.to_llm([msg])
      assert result == []
    end

    test "converts CustomMessage to user message with string content" do
      msg = %CustomMessage{
        custom_type: "test",
        content: "custom content",
        display: true,
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert result.content == "custom content"
      assert result.timestamp == 123
    end

    test "converts CustomMessage to user message with content blocks" do
      msg = %CustomMessage{
        custom_type: "test",
        content: [%TextContent{text: "block content"}],
        display: true,
        timestamp: 123
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert is_list(result.content)
    end

    test "converts BranchSummaryMessage with tags" do
      msg = %BranchSummaryMessage{summary: "branch info", timestamp: 123}
      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert result.content =~ "<branch_summary>"
      assert result.content =~ "branch info"
      assert result.content =~ "</branch_summary>"
      assert result.timestamp == 123
    end

    test "converts CompactionSummaryMessage with tags" do
      msg = %CompactionSummaryMessage{summary: "compaction info", timestamp: 123}
      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert result.content =~ "<compaction_summary>"
      assert result.content =~ "compaction info"
      assert result.content =~ "</compaction_summary>"
      assert result.timestamp == 123
    end

    test "converts plain map with role: :user" do
      msg = %{role: :user, content: "plain map content", timestamp: 100}
      [result] = Messages.to_llm([msg])
      assert %Ai.Types.UserMessage{} = result
      assert result.content == "plain map content"
      assert result.timestamp == 100
    end

    test "converts plain map with role: :assistant" do
      msg = %{role: :assistant, content: [], model: "test-model", timestamp: 100}
      [result] = Messages.to_llm([msg])
      assert %Ai.Types.AssistantMessage{} = result
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
      assert %Ai.Types.ToolResultMessage{} = result
      assert result.tool_call_id == "abc"
      assert result.trust == :trusted
      assert result.timestamp == 100
    end

    test "handles list of mixed message types" do
      messages = [
        %Ai.Types.UserMessage{content: "hi", timestamp: 1},
        %AssistantMessage{content: [%TextContent{text: "hello"}], model: "test", timestamp: 2},
        %BashExecutionMessage{
          command: "ls",
          output: "files",
          exit_code: 0,
          cancelled: false,
          truncated: false,
          timestamp: 3
        },
        %BranchSummaryMessage{summary: "branch", timestamp: 4}
      ]

      result = Messages.to_llm(messages)
      assert length(result) == 4
      assert %Ai.Types.UserMessage{content: "hi"} = Enum.at(result, 0)
      assert %Ai.Types.AssistantMessage{} = Enum.at(result, 1)
      assert %Ai.Types.UserMessage{} = Enum.at(result, 2)
      assert %Ai.Types.UserMessage{} = Enum.at(result, 3)
    end

    test "filters out excluded messages from list" do
      messages = [
        %BashExecutionMessage{
          command: "included",
          output: "yes",
          exit_code: 0,
          cancelled: false,
          truncated: false,
          exclude_from_context: false,
          timestamp: 1
        },
        %BashExecutionMessage{
          command: "excluded",
          output: "no",
          exit_code: 0,
          cancelled: false,
          truncated: false,
          exclude_from_context: true,
          timestamp: 2
        },
        %BashExecutionMessage{
          command: "also_included",
          output: "yes",
          exit_code: 0,
          cancelled: false,
          truncated: false,
          exclude_from_context: false,
          timestamp: 3
        }
      ]

      result = Messages.to_llm(messages)
      assert length(result) == 2
      assert hd(result).content =~ "included"
      refute hd(result).content =~ "excluded"
    end

    test "returns empty list for empty input" do
      assert Messages.to_llm([]) == []
    end
  end

  describe "get_text/1" do
    test "extracts text from UserMessage with string content" do
      msg = %UserMessage{content: "hello world", timestamp: 0}
      assert Messages.get_text(msg) == "hello world"
    end

    test "extracts text from UserMessage with content blocks" do
      msg = %UserMessage{
        content: [
          %TextContent{text: "hello "},
          %TextContent{text: "world"},
          %ImageContent{data: "abc", mime_type: "image/png"}
        ],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "hello world"
    end

    test "extracts text from Ai.Types.UserMessage with string content" do
      msg = %Ai.Types.UserMessage{role: :user, content: "hello", timestamp: 0}
      assert Messages.get_text(msg) == "hello"
    end

    test "extracts text from Ai.Types.UserMessage with content blocks" do
      msg = %Ai.Types.UserMessage{
        role: :user,
        content: [
          %Ai.Types.TextContent{text: "first"},
          %Ai.Types.TextContent{text: "second"}
        ],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "first\nsecond"
    end

    test "extracts text from AssistantMessage with content blocks" do
      msg = %AssistantMessage{
        content: [
          %TextContent{text: "part1"},
          %ToolCall{id: "1", name: "test", arguments: %{}},
          %TextContent{text: "part2"}
        ],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "part1part2"
    end

    test "extracts text from Ai.Types.AssistantMessage with content blocks" do
      msg = %Ai.Types.AssistantMessage{
        role: :assistant,
        content: [%Ai.Types.TextContent{text: "hello"}],
        model: "test",
        timestamp: 0
      }

      assert Messages.get_text(msg) == "hello"
    end

    test "extracts text from Ai.Types.AssistantMessage with thinking content" do
      msg = %Ai.Types.AssistantMessage{
        role: :assistant,
        content: [
          %Ai.Types.ThinkingContent{thinking: "thinking..."},
          %Ai.Types.TextContent{text: "response"}
        ],
        model: "test",
        timestamp: 0
      }

      assert Messages.get_text(msg) == "thinking...\nresponse"
    end

    test "extracts text from Ai.Types.AssistantMessage with image content" do
      msg = %Ai.Types.AssistantMessage{
        role: :assistant,
        content: [
          %Ai.Types.TextContent{text: "here's an image:"},
          %Ai.Types.ImageContent{data: "abc", mime_type: "image/png"}
        ],
        model: "test",
        timestamp: 0
      }

      assert Messages.get_text(msg) == "here's an image:\n[image]"
    end

    test "extracts text from Ai.Types.AssistantMessage with tool call" do
      msg = %Ai.Types.AssistantMessage{
        role: :assistant,
        content: [
          %Ai.Types.TextContent{text: "calling tool:"},
          %Ai.Types.ToolCall{id: "1", name: "read", arguments: %{}}
        ],
        model: "test",
        timestamp: 0
      }

      assert Messages.get_text(msg) == "calling tool:\n[tool_call: read]"
    end

    test "extracts text from ToolResultMessage" do
      msg = %ToolResultMessage{
        tool_use_id: "123",
        content: [%TextContent{text: "result text"}],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "result text"
    end

    test "extracts text from Ai.Types.ToolResultMessage" do
      msg = %Ai.Types.ToolResultMessage{
        role: :tool_result,
        tool_call_id: "123",
        tool_name: "test",
        content: [%Ai.Types.TextContent{text: "tool result"}],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "tool result"
    end

    test "extracts output from BashExecutionMessage" do
      msg = %BashExecutionMessage{
        command: "echo hello",
        output: "hello",
        exit_code: 0,
        cancelled: false,
        truncated: false,
        timestamp: 0
      }

      assert Messages.get_text(msg) == "hello"
    end

    test "extracts text from CustomMessage with string content" do
      msg = %CustomMessage{
        custom_type: "test",
        content: "custom text",
        display: true,
        timestamp: 0
      }

      assert Messages.get_text(msg) == "custom text"
    end

    test "extracts text from CustomMessage with content blocks" do
      msg = %CustomMessage{
        custom_type: "test",
        content: [%TextContent{text: "block1"}, %TextContent{text: "block2"}],
        display: true,
        timestamp: 0
      }

      assert Messages.get_text(msg) == "block1block2"
    end

    test "extracts summary from BranchSummaryMessage" do
      msg = %BranchSummaryMessage{summary: "branch summary text", timestamp: 0}
      assert Messages.get_text(msg) == "branch summary text"
    end

    test "extracts summary from CompactionSummaryMessage" do
      msg = %CompactionSummaryMessage{summary: "compaction summary text", timestamp: 0}
      assert Messages.get_text(msg) == "compaction summary text"
    end
  end

  describe "get_tool_calls/1" do
    test "extracts tool calls from AssistantMessage" do
      tool1 = %ToolCall{id: "tool_1", name: "read", arguments: %{"path" => "/test.txt"}}
      tool2 = %ToolCall{id: "tool_2", name: "write", arguments: %{"path" => "/out.txt"}}

      msg = %AssistantMessage{
        content: [
          %TextContent{text: "doing work"},
          tool1,
          %TextContent{text: "more text"},
          tool2
        ],
        timestamp: 0
      }

      result = Messages.get_tool_calls(msg)
      assert length(result) == 2
      assert tool1 in result
      assert tool2 in result
    end

    test "returns empty list for message without tool calls" do
      msg = %AssistantMessage{content: [%TextContent{text: "no tools"}], timestamp: 0}
      assert Messages.get_tool_calls(msg) == []
    end

    test "returns empty list for non-assistant message types" do
      assert Messages.get_tool_calls(%UserMessage{content: "test", timestamp: 0}) == []

      assert Messages.get_tool_calls(%BashExecutionMessage{
               command: "ls",
               output: "",
               exit_code: 0,
               cancelled: false,
               truncated: false,
               timestamp: 0
             }) == []

      assert Messages.get_tool_calls(%ToolResultMessage{
               tool_use_id: "123",
               content: [],
               timestamp: 0
             }) == []

      assert Messages.get_tool_calls(%CustomMessage{
               custom_type: "test",
               content: "",
               timestamp: 0
             }) == []

      assert Messages.get_tool_calls(%BranchSummaryMessage{summary: "", timestamp: 0}) == []
      assert Messages.get_tool_calls(%CompactionSummaryMessage{summary: "", timestamp: 0}) == []
    end

    test "returns empty list for Ai.Types messages" do
      assert Messages.get_tool_calls(%Ai.Types.UserMessage{content: "test", timestamp: 0}) == []

      assert Messages.get_tool_calls(%Ai.Types.AssistantMessage{
               content: [],
               model: "test",
               timestamp: 0
             }) == []
    end
  end

  describe "total_tokens/1" do
    test "calculates from usage struct using total_tokens field" do
      usage = %Usage{
        input: 100,
        output: 50,
        cache_read: 10,
        cache_write: 5,
        total_tokens: 165
      }

      # The function calculates: input + output + cache_read + cache_write
      assert Messages.total_tokens(usage) == 100 + 50 + 10 + 5
    end

    test "returns sum of all token fields" do
      usage = %Usage{
        input: 200,
        output: 100,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 300
      }

      assert Messages.total_tokens(usage) == 300
    end

    test "handles zero values" do
      usage = %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0
      }

      assert Messages.total_tokens(usage) == 0
    end

    test "ignores cost field in calculation" do
      usage = %Usage{
        input: 50,
        output: 50,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 100,
        cost: 0.05
      }

      assert Messages.total_tokens(usage) == 100
    end
  end

  describe "Usage.total_tokens/1" do
    test "calculates total from all token fields" do
      usage = %Usage{input: 100, output: 50, cache_read: 25, cache_write: 10}
      assert Usage.total_tokens(usage) == 185
    end
  end

  describe "get_text/1 edge cases" do
    test "returns nil for UserMessage with nil content" do
      msg = %UserMessage{content: nil, timestamp: 0}
      assert Messages.get_text(msg) == nil
    end

    test "returns empty string for UserMessage with empty string content" do
      msg = %UserMessage{content: "", timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "returns empty string for UserMessage with empty list content" do
      msg = %UserMessage{content: [], timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "returns empty string for AssistantMessage with empty content list" do
      msg = %AssistantMessage{content: [], model: "test", timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "returns empty string for ToolResultMessage with empty content list" do
      msg = %ToolResultMessage{tool_use_id: "123", content: [], timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "returns empty string for BashExecutionMessage with empty output" do
      msg = %BashExecutionMessage{
        command: "true",
        output: "",
        exit_code: 0,
        cancelled: false,
        truncated: false,
        timestamp: 0
      }

      assert Messages.get_text(msg) == ""
    end

    test "returns empty string for CustomMessage with empty string content" do
      msg = %CustomMessage{custom_type: "test", content: "", timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "returns empty string for CustomMessage with empty list content" do
      msg = %CustomMessage{custom_type: "test", content: [], timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "filters out ImageContent from CustomMessage list" do
      msg = %CustomMessage{
        custom_type: "test",
        content: [
          %ImageContent{data: "abc", mime_type: "image/png"},
          %TextContent{text: "visible text"}
        ],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "visible text"
    end

    test "returns empty string for BranchSummaryMessage with empty summary" do
      msg = %BranchSummaryMessage{summary: "", timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "returns empty string for CompactionSummaryMessage with empty summary" do
      msg = %CompactionSummaryMessage{summary: "", timestamp: 0}
      assert Messages.get_text(msg) == ""
    end

    test "extracts text from Ai.Types.UserMessage with mixed content types" do
      msg = %Ai.Types.UserMessage{
        role: :user,
        content: [
          %Ai.Types.TextContent{text: "text1"},
          %Ai.Types.ImageContent{data: "img", mime_type: "image/png"},
          %Ai.Types.TextContent{text: "text2"}
        ],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "text1\n[image]\ntext2"
    end

    test "handles unknown content block types in Ai.Types" do
      # The extract_text_from_ai_content/1 returns "" for unknown types
      msg = %Ai.Types.UserMessage{
        role: :user,
        content: [%Ai.Types.TextContent{text: "known"}],
        timestamp: 0
      }

      assert Messages.get_text(msg) == "known"
    end

    test "extracts text from AssistantMessage with only thinking content" do
      msg = %AssistantMessage{
        content: [%ThinkingContent{thinking: "deep thoughts"}],
        model: "test",
        timestamp: 0
      }

      # ThinkingContent is not a TextContent, so get_text should return ""
      assert Messages.get_text(msg) == ""
    end

    test "extracts text from AssistantMessage with only tool calls" do
      msg = %AssistantMessage{
        content: [%ToolCall{id: "1", name: "read", arguments: %{}}],
        model: "test",
        timestamp: 0
      }

      # ToolCall is not a TextContent, so get_text should return ""
      assert Messages.get_text(msg) == ""
    end
  end

  describe "to_llm/1 edge cases" do
    test "BashExecutionMessage with empty output includes command" do
      msg = %BashExecutionMessage{
        command: "true",
        output: "",
        exit_code: 0,
        cancelled: false,
        truncated: false,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.content == "$ true"
    end

    test "BashExecutionMessage with all flags set" do
      msg = %BashExecutionMessage{
        command: "cat bigfile",
        output: "partial",
        exit_code: 1,
        cancelled: true,
        truncated: true,
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      # cancelled takes precedence over truncated
      assert result.content =~ "$ cat bigfile"
      assert result.content =~ "partial"
      assert result.content =~ "[cancelled]"
      assert result.content =~ "[exit code: 1]"
    end

    test "AssistantMessage with usage containing float cost" do
      msg = %AssistantMessage{
        content: [%TextContent{text: "test"}],
        model: "claude-3",
        usage: %Usage{
          input: 100,
          output: 50,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 150,
          cost: 0.00123
        },
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert result.usage.cost.total == 0.00123
    end

    test "AssistantMessage with usage containing nil cost" do
      msg = %AssistantMessage{
        content: [],
        model: "test",
        usage: %Usage{
          input: 10,
          output: 5,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 15,
          cost: nil
        },
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert %Ai.Types.Cost{} = result.usage.cost
    end

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
      assert result.trust == :trusted
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

    test "UserMessage with only image content blocks" do
      msg = %UserMessage{
        content: [
          %ImageContent{data: "img1", mime_type: "image/png"},
          %ImageContent{data: "img2", mime_type: "image/jpeg"}
        ],
        timestamp: 0
      }

      [result] = Messages.to_llm([msg])
      assert is_list(result.content)
      assert length(result.content) == 2
      assert %Ai.Types.ImageContent{data: "img1", mime_type: "image/png"} = hd(result.content)
    end

    test "preserves all stop_reason values" do
      for stop_reason <- [:stop, :length, :tool_use, :error, :aborted] do
        msg = %AssistantMessage{
          content: [],
          model: "test",
          stop_reason: stop_reason,
          timestamp: 0
        }

        [result] = Messages.to_llm([msg])
        assert result.stop_reason == stop_reason
      end
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
      # Details are not preserved in the Ai.Types.UserMessage
      assert result.content == "content"
    end

    test "multiple excluded messages are all filtered" do
      messages = [
        %BashExecutionMessage{
          command: "ls",
          output: "",
          exit_code: 0,
          cancelled: false,
          truncated: false,
          exclude_from_context: true,
          timestamp: 1
        },
        %BashExecutionMessage{
          command: "pwd",
          output: "",
          exit_code: 0,
          cancelled: false,
          truncated: false,
          exclude_from_context: true,
          timestamp: 2
        }
      ]

      assert Messages.to_llm(messages) == []
    end

    test "non-BashExecution messages are never excluded" do
      # Only BashExecutionMessage checks exclude_from_context
      messages = [
        %UserMessage{content: "test", timestamp: 0},
        %AssistantMessage{content: [], model: "test", timestamp: 0}
      ]

      result = Messages.to_llm(messages)
      assert length(result) == 2
    end
  end

  describe "get_tool_calls/1 edge cases" do
    test "returns empty list for AssistantMessage with only text" do
      msg = %AssistantMessage{
        content: [%TextContent{text: "just text"}, %TextContent{text: "more text"}],
        timestamp: 0
      }

      assert Messages.get_tool_calls(msg) == []
    end

    test "returns empty list for AssistantMessage with thinking content" do
      msg = %AssistantMessage{
        content: [
          %ThinkingContent{thinking: "thinking..."},
          %TextContent{text: "response"}
        ],
        timestamp: 0
      }

      assert Messages.get_tool_calls(msg) == []
    end

    test "extracts single tool call" do
      tool = %ToolCall{id: "1", name: "read", arguments: %{"path" => "/test"}}
      msg = %AssistantMessage{content: [tool], timestamp: 0}

      result = Messages.get_tool_calls(msg)
      assert length(result) == 1
      assert hd(result) == tool
    end

    test "preserves tool call order" do
      tool1 = %ToolCall{id: "1", name: "first", arguments: %{}}
      tool2 = %ToolCall{id: "2", name: "second", arguments: %{}}
      tool3 = %ToolCall{id: "3", name: "third", arguments: %{}}

      msg = %AssistantMessage{content: [tool1, tool2, tool3], timestamp: 0}

      result = Messages.get_tool_calls(msg)
      assert Enum.map(result, & &1.name) == ["first", "second", "third"]
    end
  end

  describe "Usage module" do
    test "total_tokens adds all token fields" do
      usage = %Usage{input: 1, output: 2, cache_read: 3, cache_write: 4}
      assert Usage.total_tokens(usage) == 10
    end

    test "total_tokens with large values" do
      usage = %Usage{
        input: 100_000,
        output: 50_000,
        cache_read: 200_000,
        cache_write: 10_000
      }

      assert Usage.total_tokens(usage) == 360_000
    end
  end

  describe "content block creation" do
    test "TextContent can be created with custom text" do
      tc = %TextContent{text: "custom text"}
      assert tc.type == :text
      assert tc.text == "custom text"
    end

    test "ImageContent can be created with custom values" do
      ic = %ImageContent{data: "base64data", mime_type: "image/jpeg"}
      assert ic.type == :image
      assert ic.data == "base64data"
      assert ic.mime_type == "image/jpeg"
    end

    test "ThinkingContent can be created with custom thinking" do
      tc = %ThinkingContent{thinking: "deep thoughts"}
      assert tc.type == :thinking
      assert tc.thinking == "deep thoughts"
    end

    test "ToolCall can be created with all fields" do
      tc = %ToolCall{id: "tool_123", name: "read", arguments: %{"path" => "/file.txt"}}
      assert tc.type == :tool_call
      assert tc.id == "tool_123"
      assert tc.name == "read"
      assert tc.arguments == %{"path" => "/file.txt"}
    end

    test "ToolCall arguments can be complex nested maps" do
      args = %{
        "files" => ["/a.txt", "/b.txt"],
        "options" => %{"recursive" => true, "depth" => 3}
      }

      tc = %ToolCall{id: "1", name: "batch_read", arguments: args}
      assert tc.arguments == args
    end
  end

  describe "message creation with all fields" do
    test "UserMessage with list content" do
      content = [
        %TextContent{text: "hello"},
        %ImageContent{data: "img", mime_type: "image/png"}
      ]

      msg = %UserMessage{content: content, timestamp: 12345}
      assert msg.role == :user
      assert msg.content == content
      assert msg.timestamp == 12345
    end

    test "AssistantMessage with all fields populated" do
      usage = %Usage{
        input: 10,
        output: 20,
        cache_read: 5,
        cache_write: 2,
        total_tokens: 37,
        cost: 0.001
      }

      msg = %AssistantMessage{
        content: [%TextContent{text: "response"}],
        provider: "anthropic",
        model: "claude-3-sonnet",
        api: "messages",
        usage: usage,
        stop_reason: :stop,
        timestamp: 99999
      }

      assert msg.role == :assistant
      assert msg.provider == "anthropic"
      assert msg.model == "claude-3-sonnet"
      assert msg.api == "messages"
      assert msg.usage == usage
      assert msg.stop_reason == :stop
      assert msg.timestamp == 99999
    end

    test "ToolResultMessage with error" do
      msg = %ToolResultMessage{
        tool_use_id: "tool_abc",
        content: [%TextContent{text: "Error: file not found"}],
        is_error: true,
        timestamp: 54321
      }

      assert msg.role == :tool_result
      assert msg.tool_use_id == "tool_abc"
      assert msg.is_error == true
      assert msg.timestamp == 54321
    end

    test "BashExecutionMessage with full_output_path" do
      msg = %BashExecutionMessage{
        command: "cat huge_file",
        output: "truncated...",
        exit_code: 0,
        cancelled: false,
        truncated: true,
        full_output_path: "/tmp/output_12345.txt",
        timestamp: 1000
      }

      assert msg.full_output_path == "/tmp/output_12345.txt"
    end

    test "CustomMessage with details" do
      msg = %CustomMessage{
        custom_type: "mcp_result",
        content: "result content",
        display: false,
        details: %{tool: "some_mcp_tool", duration_ms: 150},
        timestamp: 2000
      }

      assert msg.custom_type == "mcp_result"
      assert msg.display == false
      assert msg.details == %{tool: "some_mcp_tool", duration_ms: 150}
    end
  end

  describe "struct defaults" do
    test "TextContent has correct defaults" do
      tc = %TextContent{}
      assert tc.type == :text
      assert tc.text == ""
    end

    test "ImageContent has correct defaults" do
      ic = %ImageContent{}
      assert ic.type == :image
      assert ic.data == ""
      assert ic.mime_type == "image/png"
    end

    test "ThinkingContent has correct defaults" do
      tc = %ThinkingContent{}
      assert tc.type == :thinking
      assert tc.thinking == ""
    end

    test "ToolCall has correct defaults" do
      tc = %ToolCall{}
      assert tc.type == :tool_call
      assert tc.id == ""
      assert tc.name == ""
      assert tc.arguments == %{}
    end

    test "Usage has correct defaults" do
      usage = %Usage{}
      assert usage.input == 0
      assert usage.output == 0
      assert usage.cache_read == 0
      assert usage.cache_write == 0
      assert usage.total_tokens == 0
      assert usage.cost == nil
    end

    test "UserMessage has correct defaults" do
      msg = %UserMessage{}
      assert msg.role == :user
      assert msg.content == ""
      assert msg.timestamp == 0
    end

    test "AssistantMessage has correct defaults" do
      msg = %AssistantMessage{}
      assert msg.role == :assistant
      assert msg.content == []
      assert msg.provider == ""
      assert msg.model == ""
      assert msg.api == ""
      assert msg.usage == nil
      assert msg.stop_reason == nil
      assert msg.timestamp == 0
    end

    test "ToolResultMessage has correct defaults" do
      msg = %ToolResultMessage{}
      assert msg.role == :tool_result
      assert msg.tool_use_id == ""
      assert msg.content == []
      assert msg.trust == :trusted
      assert msg.is_error == false
      assert msg.timestamp == 0
    end

    test "BashExecutionMessage has correct defaults" do
      msg = %BashExecutionMessage{}
      assert msg.role == :bash_execution
      assert msg.command == ""
      assert msg.output == ""
      assert msg.exit_code == nil
      assert msg.cancelled == false
      assert msg.truncated == false
      assert msg.full_output_path == nil
      assert msg.timestamp == 0
      assert msg.exclude_from_context == false
    end

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

    test "CompactionSummaryMessage has correct defaults" do
      msg = %CompactionSummaryMessage{}
      assert msg.role == :compaction_summary
      assert msg.summary == ""
      assert msg.timestamp == 0
    end
  end
end
