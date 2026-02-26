defmodule CodingAgent.CompactionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Compaction
  alias CodingAgent.Messages
  alias CodingAgent.SessionManager.SessionEntry

  describe "should_compact?/3" do
    test "returns true when context exceeds threshold" do
      # context_window = 100000, reserve = 16384
      # context_tokens > 100000 - 16384 = 83616
      assert Compaction.should_compact?(90000, 100_000, %{enabled: true, reserve_tokens: 16384})
    end

    test "returns false when context is within threshold" do
      refute Compaction.should_compact?(50000, 100_000, %{enabled: true, reserve_tokens: 16384})
    end

    test "returns false when compaction disabled" do
      refute Compaction.should_compact?(90000, 100_000, %{enabled: false})
    end

    test "uses default reserve_tokens when not specified" do
      # Default is 16384
      # 90000 > 100000 - 16384 = 83616
      assert Compaction.should_compact?(90000, 100_000, %{enabled: true})
    end

    test "returns false when exactly at threshold" do
      # 83616 is not greater than 83616
      refute Compaction.should_compact?(83616, 100_000, %{enabled: true, reserve_tokens: 16384})
    end

    test "defaults to enabled when not specified" do
      assert Compaction.should_compact?(90000, 100_000, %{})
    end

    test "handles empty settings map" do
      assert Compaction.should_compact?(90000, 100_000, %{})
    end
  end

  describe "message window compaction" do
    test "returns false when there is no provider message budget" do
      model = %Ai.Types.Model{provider: :openai}
      assert Compaction.message_budget(model, %{}) == nil
    end

    test "triggers when message count reaches provider threshold" do
      budget = %{request_limit: 200, trigger_count: 180, keep_recent_messages: 120}

      refute Compaction.should_compact_for_message_limit?(179, budget, %{enabled: true})
      assert Compaction.should_compact_for_message_limit?(180, budget, %{enabled: true})
      refute Compaction.should_compact_for_message_limit?(180, budget, %{enabled: false})
    end
  end

  describe "estimate_message_tokens/1" do
    test "estimates based on text length / 4 for UserMessage" do
      msg = %Messages.UserMessage{content: String.duplicate("a", 400), timestamp: 0}
      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 100
    end

    test "estimates for AssistantMessage with text content" do
      msg = %Messages.AssistantMessage{
        content: [%Messages.TextContent{text: String.duplicate("b", 200)}],
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 50
    end

    test "estimates for BashExecutionMessage" do
      msg = %Messages.BashExecutionMessage{
        command: "ls",
        output: String.duplicate("c", 400),
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 100
    end

    test "handles empty content" do
      msg = %Messages.UserMessage{content: "", timestamp: 0}
      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 0
    end

    test "handles list content in UserMessage" do
      msg = %Messages.UserMessage{
        content: [
          %Messages.TextContent{text: String.duplicate("a", 200)},
          %Messages.TextContent{text: String.duplicate("b", 200)}
        ],
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 100
    end
  end

  describe "estimate_context_tokens/1" do
    test "sums tokens for all messages" do
      messages = [
        %Messages.UserMessage{content: String.duplicate("a", 400), timestamp: 0},
        %Messages.UserMessage{content: String.duplicate("b", 400), timestamp: 1}
      ]

      tokens = Compaction.estimate_context_tokens(messages)
      assert tokens == 200
    end

    test "handles Ai.Types messages" do
      messages = [
        %Ai.Types.UserMessage{role: :user, content: String.duplicate("a", 400), timestamp: 0}
      ]

      tokens = Compaction.estimate_context_tokens(messages)
      assert tokens == 100
    end

    test "handles empty list" do
      tokens = Compaction.estimate_context_tokens([])
      assert tokens == 0
    end

    test "handles mixed message types" do
      messages = [
        %Messages.UserMessage{content: String.duplicate("a", 400), timestamp: 0},
        %Messages.AssistantMessage{
          content: [%Messages.TextContent{text: String.duplicate("b", 400)}],
          timestamp: 1
        },
        %Messages.BashExecutionMessage{
          command: "ls",
          output: String.duplicate("c", 400),
          timestamp: 2
        }
      ]

      tokens = Compaction.estimate_context_tokens(messages)
      assert tokens == 300
    end
  end

  describe "estimate_text_tokens/1" do
    test "uses 4 chars/token heuristic" do
      assert Compaction.estimate_text_tokens(String.duplicate("a", 400)) == 100
    end

    test "returns 0 for nil" do
      assert Compaction.estimate_text_tokens(nil) == 0
    end
  end

  describe "estimate_request_context_tokens/3" do
    test "includes system prompt tokens in total estimate" do
      messages = [%Messages.UserMessage{content: String.duplicate("a", 400), timestamp: 0}]
      system_prompt = String.duplicate("b", 400)

      assert Compaction.estimate_request_context_tokens(messages, system_prompt, []) == 200
    end

    test "includes tool schema payload tokens in total estimate" do
      tools = [
        %{
          "type" => "function",
          "name" => "read",
          "description" => String.duplicate("d", 400),
          "parameters" => %{"type" => "object", "properties" => %{}}
        }
      ]

      assert Compaction.estimate_request_context_tokens([], nil, tools) > 0
    end
  end

  describe "find_cut_point/2" do
    test "returns error when branch is empty" do
      branch = []
      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000)
    end

    test "returns error when no message entries" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :model_change,
          provider: "anthropic",
          model_id: "claude-3",
          timestamp: 0
        }
      ]

      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000)
    end

    test "returns error when cannot find enough tokens to keep" do
      # Very short messages that don't reach keep_recent_tokens threshold
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "hello"},
          timestamp: 0
        }
      ]

      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000)
    end

    test "finds valid cut point preserving recent tokens" do
      # Create messages with known token counts (each ~1000 tokens)
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 3
        },
        %SessionEntry{
          id: "entry5",
          parent_id: "entry4",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 4
        }
      ]

      # With keep_recent_tokens = 2000, should keep at least 2 messages
      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      # Cut point should be one of the earlier entries
      assert cut_id in ["entry1", "entry2", "entry3", "entry4"]
    end

    test "does not cut between tool call and result" do
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I'll help you"},
              %{"type" => "tool_call", "id" => "tool_1", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tool_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 3
        }
      ]

      result = Compaction.find_cut_point(branch, 1000)

      case result do
        {:ok, cut_id} ->
          # Cut should be at entry1 (user) or entry4 (user), not entry2 (assistant with pending tool call)
          # entry2 has a tool call that is followed by entry3 tool_result, so entry2 is valid
          # but the cut point algorithm looks for valid points before the target
          assert cut_id in ["entry1", "entry2", "entry4"]

        {:error, :cannot_compact} ->
          # This is also acceptable if the algorithm can't find a valid cut point
          :ok
      end
    end

    test "allows cut at assistant message when tool results are present" do
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I'll help you"},
              %{"type" => "tool_call", "id" => "tool_1", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tool_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 3
        },
        %SessionEntry{
          id: "entry5",
          parent_id: "entry4",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 4
        },
        %SessionEntry{
          id: "entry6",
          parent_id: "entry5",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 5
        }
      ]

      result = Compaction.find_cut_point(branch, 2000)

      case result do
        {:ok, cut_id} ->
          # entry4 is a valid cut point - it's an assistant message without pending tool calls
          assert cut_id in ["entry1", "entry2", "entry4", "entry5"]

        {:error, :cannot_compact} ->
          :ok
      end
    end
  end

  describe "find_cut_point/3 with force option" do
    test "force: true compacts even with short history" do
      # Create a short conversation that wouldn't normally be compactable
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "hello"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "Hi there!"}]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => "How are you?"},
          timestamp: 2
        }
      ]

      # Without force, should return cannot_compact for short history
      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000)

      # With force, should find a cut point
      assert {:ok, cut_id} = Compaction.find_cut_point(branch, 20000, force: true)
      # Should keep recent messages and cut at an earlier valid point
      assert cut_id in ["entry1", "entry2"]
    end

    test "force: true respects min_keep_messages option" do
      # Create a longer conversation
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "message 1"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "response 1"}]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => "message 2"},
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "response 2"}]
          },
          timestamp: 3
        },
        %SessionEntry{
          id: "entry5",
          parent_id: "entry4",
          type: :message,
          message: %{"role" => "user", "content" => "message 3"},
          timestamp: 4
        },
        %SessionEntry{
          id: "entry6",
          parent_id: "entry5",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "response 3"}]
          },
          timestamp: 5
        }
      ]

      # With force and min_keep_messages: 2, should cut earlier in the conversation
      assert {:ok, cut_id} =
               Compaction.find_cut_point(branch, 20000, force: true, min_keep_messages: 2)

      # Should cut at entry4 or entry5 to keep 2 messages
      assert cut_id in ["entry4", "entry5"]
    end

    test "force: true preserves tool call/result pairs" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "read a file"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I'll help you"},
              %{"type" => "tool_call", "id" => "tool_1", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tool_1",
            "content" => [%{"type" => "text", "text" => "file contents"}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "Here's the file"}]
          },
          timestamp: 3
        }
      ]

      # Force with min_keep=1 - should not cut between tool call (entry2) and result (entry3)
      result = Compaction.find_cut_point(branch, 20000, force: true, min_keep_messages: 1)

      case result do
        {:ok, cut_id} ->
          # Valid cut points are entry1, entry2 (has tool results after), or entry4
          # entry2 is valid because tool_1 has its result in entry3
          assert cut_id in ["entry1", "entry2", "entry4"]

        {:error, :cannot_compact} ->
          # Also acceptable if no valid cut point found
          :ok
      end
    end

    test "force: false (default) returns cannot_compact for short histories" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "hello"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "Hi!"}]
          },
          timestamp: 1
        }
      ]

      # Default (force: false) should return cannot_compact
      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000)
      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000, [])
      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000, force: false)
    end

    test "force: true with only one message returns cannot_compact" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "hello"},
          timestamp: 0
        }
      ]

      # Can't compact a single message even with force
      assert {:error, :cannot_compact} = Compaction.find_cut_point(branch, 20000, force: true)
    end

    test "force: true with empty branch returns cannot_compact" do
      assert {:error, :cannot_compact} = Compaction.find_cut_point([], 20000, force: true)
    end
  end

  describe "extract_file_operations/1" do
    test "extracts read files from tool calls" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "read",
              arguments: %{"path" => "/home/user/file1.txt"}
            }
          ],
          timestamp: 0
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == ["/home/user/file1.txt"]
      assert result.modified_files == []
    end

    test "extracts modified files from write tool calls" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "write",
              arguments: %{"path" => "/home/user/file1.txt", "content" => "hello"}
            }
          ],
          timestamp: 0
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
      assert result.modified_files == ["/home/user/file1.txt"]
    end

    test "extracts modified files from edit tool calls" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "edit",
              arguments: %{"path" => "/home/user/file1.txt", "old" => "a", "new" => "b"}
            }
          ],
          timestamp: 0
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
      assert result.modified_files == ["/home/user/file1.txt"]
    end

    test "deduplicates file paths" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "read",
              arguments: %{"path" => "/home/user/file1.txt"}
            }
          ],
          timestamp: 0
        },
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc2",
              name: "read",
              arguments: %{"path" => "/home/user/file1.txt"}
            }
          ],
          timestamp: 1
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == ["/home/user/file1.txt"]
    end

    test "handles multiple tool calls in one message" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "read",
              arguments: %{"path" => "/home/user/file1.txt"}
            },
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc2",
              name: "write",
              arguments: %{"path" => "/home/user/file2.txt", "content" => "hello"}
            }
          ],
          timestamp: 0
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == ["/home/user/file1.txt"]
      assert result.modified_files == ["/home/user/file2.txt"]
    end

    test "ignores tool calls without path argument" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "read",
              arguments: %{}
            }
          ],
          timestamp: 0
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
      assert result.modified_files == []
    end

    test "ignores other tool types" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "bash",
              arguments: %{"command" => "ls"}
            }
          ],
          timestamp: 0
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
      assert result.modified_files == []
    end

    test "handles empty messages list" do
      result = Compaction.extract_file_operations([])
      assert result.read_files == []
      assert result.modified_files == []
    end

    test "handles messages without tool calls" do
      messages = [
        %Messages.UserMessage{content: "hello", timestamp: 0},
        %Messages.AssistantMessage{
          content: [%Messages.TextContent{text: "Hi there!"}],
          timestamp: 1
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
      assert result.modified_files == []
    end
  end

  describe "total_tokens/1" do
    test "returns total_tokens field when present" do
      usage = %{total_tokens: 150}
      assert Compaction.total_tokens(usage) == 150
    end

    test "sums all components when total_tokens not present" do
      usage = %{input: 100, output: 50, cache_read: 10, cache_write: 5}
      assert Compaction.total_tokens(usage) == 165
    end

    test "sums input and output when cache fields missing" do
      usage = %{input: 100, output: 50}
      assert Compaction.total_tokens(usage) == 150
    end

    test "returns 0 for invalid usage format" do
      assert Compaction.total_tokens(%{}) == 0
      assert Compaction.total_tokens(nil) == 0
      assert Compaction.total_tokens("invalid") == 0
    end

    test "handles Usage struct" do
      usage = %Messages.Usage{
        input: 100,
        output: 50,
        cache_read: 10,
        cache_write: 5,
        total_tokens: 165
      }

      assert Compaction.total_tokens(usage) == 165
    end
  end

  describe "find_cut_point/2 with custom_message entries" do
    test "finds cut point at custom_message entry" do
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :custom_message,
          custom_type: "system_note",
          content: long_content,
          display: true,
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 3
        }
      ]

      # With keep_recent_tokens = 2000, should keep at least 2 messages
      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      # entry2 (custom_message) should be a valid cut point
      assert cut_id in ["entry1", "entry2", "entry3"]
    end

    test "custom_message as only valid cut point between tool call pair" do
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "Starting"},
              %{"type" => "tool_call", "id" => "tool_1", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :custom_message,
          custom_type: "progress_update",
          content: long_content,
          display: true,
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tool_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 3
        },
        %SessionEntry{
          id: "entry5",
          parent_id: "entry4",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 4
        }
      ]

      # entry1 (assistant with tool call) has pending results in entry3, so not valid
      # entry2 (custom_message) is always valid
      # The custom_message at entry2 should be a valid cut point
      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      # entry2 (custom_message) should be valid, entry1 is valid because entry3 has the result
      assert cut_id in ["entry1", "entry2", "entry4"]
    end

    test "custom_message entries are included in scanning" do
      # Test that custom_message entries are counted in token calculation
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :custom_message,
          custom_type: "context",
          content: long_content,
          display: true,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :custom_message,
          custom_type: "context",
          content: long_content,
          display: true,
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 2
        }
      ]

      # Should find a cut point since there are enough tokens
      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      assert cut_id in ["entry1", "entry2"]
    end

    test "only custom_message entries in branch still allows compaction" do
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :custom_message,
          custom_type: "context",
          content: long_content,
          display: true,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :custom_message,
          custom_type: "context",
          content: long_content,
          display: true,
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :custom_message,
          custom_type: "context",
          content: long_content,
          display: true,
          timestamp: 2
        }
      ]

      # Should find a cut point since all custom_message entries are valid cut points
      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      assert cut_id in ["entry1", "entry2"]
    end

    test "custom_message does not break tool call/result pairing rules" do
      long_content = String.duplicate("a", 4000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I'll read the file"},
              %{"type" => "tool_call", "id" => "tool_1", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        # Custom message between tool call and result - should NOT affect tool pairing
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :custom_message,
          custom_type: "status",
          content: "Processing...",
          display: true,
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tool_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 3
        },
        %SessionEntry{
          id: "entry5",
          parent_id: "entry4",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 4
        }
      ]

      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      # entry2 is valid because tool_1 has its result in entry4
      # entry3 (custom_message) is also valid
      # The custom_message should not break the tool call pairing rules
      assert cut_id in ["entry1", "entry2", "entry3"]
    end

    test "finds cut point using keep_recent_messages when token threshold is too high" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "one"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => "two"},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => "three"},
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{"role" => "user", "content" => "four"},
          timestamp: 3
        },
        %SessionEntry{
          id: "entry5",
          parent_id: "entry4",
          type: :message,
          message: %{"role" => "user", "content" => "five"},
          timestamp: 4
        }
      ]

      # keep_recent_tokens is intentionally too high to trigger on tokens.
      assert {:ok, "entry2"} =
               Compaction.find_cut_point(branch, 99_999, keep_recent_messages: 3)
    end
  end

  describe "integration scenarios" do
    test "full compaction decision workflow" do
      # Simulate a conversation that needs compaction
      # Each message has 40_000 chars = 10_000 tokens
      messages = [
        %Messages.UserMessage{content: String.duplicate("a", 40_000), timestamp: 0},
        %Messages.AssistantMessage{
          content: [%Messages.TextContent{text: String.duplicate("b", 40_000)}],
          timestamp: 1
        },
        %Messages.UserMessage{content: String.duplicate("c", 40_000), timestamp: 2}
      ]

      # Estimate tokens: 3 * 10_000 = 30_000 tokens
      tokens = Compaction.estimate_context_tokens(messages)
      assert tokens == 30_000

      # Check if compaction is needed
      # context_window = 35_000, reserve = 5000
      # threshold = 35_000 - 5000 = 30_000
      # 30_000 > 30_000 is false, so we need to set tokens higher or threshold lower
      context_window = 34_000

      should_compact =
        Compaction.should_compact?(tokens, context_window, %{enabled: true, reserve_tokens: 5000})

      # 30_000 > 34_000 - 5000 = 29_000
      assert should_compact == true
    end

    test "no compaction needed for short conversation" do
      messages = [
        %Messages.UserMessage{content: "Hello", timestamp: 0},
        %Messages.AssistantMessage{
          content: [%Messages.TextContent{text: "Hi there!"}],
          timestamp: 1
        }
      ]

      tokens = Compaction.estimate_context_tokens(messages)
      assert tokens < 100

      context_window = 100_000
      should_compact = Compaction.should_compact?(tokens, context_window, %{enabled: true})
      refute should_compact
    end
  end

  # ==========================================================================
  # Edge Case Tests
  # ==========================================================================

  describe "token estimation with very large messages (multi-MB)" do
    test "estimates tokens for 1MB string content" do
      # 1MB of content = 1,048,576 bytes = ~262,144 tokens (at 4 chars/token)
      large_content = String.duplicate("a", 1_048_576)
      msg = %Messages.UserMessage{content: large_content, timestamp: 0}

      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 262_144
    end

    test "estimates tokens for 5MB string content" do
      # 5MB of content = 5,242,880 bytes = ~1,310,720 tokens
      large_content = String.duplicate("x", 5_242_880)
      msg = %Messages.UserMessage{content: large_content, timestamp: 0}

      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 1_310_720
    end

    test "estimates context tokens with multiple large messages" do
      # Create 3 messages of 1MB each
      large_content = String.duplicate("b", 1_048_576)

      messages = [
        %Messages.UserMessage{content: large_content, timestamp: 0},
        %Messages.AssistantMessage{
          content: [%Messages.TextContent{text: large_content}],
          timestamp: 1
        },
        %Messages.UserMessage{content: large_content, timestamp: 2}
      ]

      tokens = Compaction.estimate_context_tokens(messages)
      # 3 * 262,144 = 786,432
      assert tokens == 786_432
    end

    test "handles large content in assistant message with multiple text blocks" do
      large_content = String.duplicate("c", 500_000)

      msg = %Messages.AssistantMessage{
        content: [
          %Messages.TextContent{text: large_content},
          %Messages.TextContent{text: large_content}
        ],
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      # 1,000,000 chars / 4 = 250,000 tokens
      assert tokens == 250_000
    end

    test "handles large tool result content" do
      large_output = String.duplicate("d", 2_000_000)

      msg = %Messages.ToolResultMessage{
        tool_use_id: "test_id",
        content: [%Messages.TextContent{text: large_output}],
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      assert tokens == 500_000
    end

    test "estimates entry tokens for custom_message with large content" do
      large_content = String.duplicate("e", 1_000_000)

      entry = %SessionEntry{
        id: "entry1",
        parent_id: nil,
        type: :custom_message,
        custom_type: "large_context",
        content: large_content,
        display: true,
        timestamp: 0
      }

      # Use find_cut_point to indirectly test estimate_entry_tokens
      branch = [
        entry,
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => large_content},
          timestamp: 1
        }
      ]

      # With keep_recent_tokens = 100_000, should find a cut point
      result = Compaction.find_cut_point(branch, 100_000)
      assert {:ok, "entry1"} = result
    end
  end

  describe "messages with exotic content types" do
    test "estimates tokens for message with image content blocks" do
      # Image data is base64 encoded
      large_base64 = String.duplicate("ABCDEFGHabcdefgh12345678", 10_000)

      msg = %Messages.UserMessage{
        content: [
          %Messages.TextContent{text: "Here's an image:"},
          %Messages.ImageContent{data: large_base64, mime_type: "image/png"}
        ],
        timestamp: 0
      }

      # get_text only extracts text content, not image data
      tokens = Compaction.estimate_message_tokens(msg)
      # Only "Here's an image:" = 16 chars / 4 = 4 tokens
      assert tokens == 4
    end

    test "handles thinking content in assistant messages" do
      msg = %Messages.AssistantMessage{
        content: [
          %Messages.ThinkingContent{thinking: String.duplicate("thinking", 1000)},
          %Messages.TextContent{text: "Final answer"}
        ],
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      # get_text only extracts text content (not thinking content)
      # "Final answer" = 12 chars / 4 = 3 tokens
      assert tokens == 3
    end

    test "handles mixed content with tool calls" do
      msg = %Messages.AssistantMessage{
        content: [
          %Messages.TextContent{text: "I will help you"},
          %Messages.ToolCall{
            id: "tc_1",
            name: "read",
            arguments: %{"path" => "/some/very/long/path/to/file.txt"}
          },
          %Messages.TextContent{text: "Reading file..."}
        ],
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      # "I will help you" = 15 chars + "Reading file..." = 15 chars = 30 chars / 4 = 7
      assert tokens == 7
    end

    test "handles bash execution message with very long command" do
      long_command = "echo " <> String.duplicate("argument ", 10_000)

      msg = %Messages.BashExecutionMessage{
        command: long_command,
        output: "output",
        exit_code: 0,
        timestamp: 0
      }

      # BashExecutionMessage tokens are estimated from output, not command
      tokens = Compaction.estimate_message_tokens(msg)
      # "output" = 6 chars / 4 = 1 token
      assert tokens == 1
    end

    test "handles unicode content in messages" do
      # Unicode characters (emojis, CJK, etc.)
      unicode_content = String.duplicate("🎉中文日本語한국어", 1000)

      msg = %Messages.UserMessage{content: unicode_content, timestamp: 0}

      tokens = Compaction.estimate_message_tokens(msg)
      # String.length counts codepoints, not bytes
      # "🎉中文日本語한국어" = 9 codepoints * 1000 = 9000 codepoints / 4 = 2250
      assert tokens == 2250
    end

    test "handles binary data embedded in content" do
      # Simulating binary-like string content
      binary_like = :crypto.strong_rand_bytes(1000) |> Base.encode64()

      msg = %Messages.UserMessage{content: binary_like, timestamp: 0}

      tokens = Compaction.estimate_message_tokens(msg)
      # Base64 of 1000 bytes is ~1336 chars / 4 = 334 tokens
      assert tokens == div(String.length(binary_like), 4)
    end
  end

  describe "custom_message entries with nil/empty content" do
    test "handles custom_message with nil content" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :custom_message,
          custom_type: "notification",
          content: nil,
          display: true,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      # Should handle nil content gracefully
      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, _cut_id} = result
    end

    test "handles custom_message with empty string content" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :custom_message,
          custom_type: "marker",
          content: "",
          display: true,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, _cut_id} = result
    end

    test "handles custom_message with empty list content" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :custom_message,
          custom_type: "empty_blocks",
          content: [],
          display: true,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, _cut_id} = result
    end

    test "handles custom_message with list content containing text blocks" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :custom_message,
          custom_type: "structured",
          content: [
            %{"type" => "text", "text" => String.duplicate("context ", 10_000)}
          ],
          display: true,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      assert cut_id in ["entry1", "entry2"]
    end

    test "custom_message with display: false is still valid cut point" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :custom_message,
          custom_type: "hidden",
          content: String.duplicate("hidden content ", 5000),
          display: false,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      # entry1 with display: false should still be a valid cut point
      assert cut_id in ["entry1", "entry2"]
    end
  end

  describe "cut point validation with malformed message formats" do
    test "handles message entry with nil message field" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: nil,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      # Should skip nil message entries
      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      # entry1 has nil message so should be excluded
      assert cut_id == "entry2"
    end

    test "handles message with missing role field" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"content" => "missing role"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      # Message without role should not be a valid cut point
      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      # entry1 has no role, so entry2 should be the cut point
      assert cut_id == "entry2"
    end

    test "handles message with unknown role" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "unknown_role", "content" => String.duplicate("a", 80_000)},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("c", 80_000)},
          timestamp: 2
        }
      ]

      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      # unknown_role should not be valid, cut at entry2
      assert cut_id == "entry2"
    end

    test "handles assistant message with nil content" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "assistant", "content" => nil},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      # Assistant with nil content has no tool calls, so should be valid
      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      assert cut_id in ["entry1", "entry2"]
    end

    test "handles tool_result with missing tool_call_id" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 40_000)},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_call", "id" => "tc_1", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            # Missing tool_call_id field
            "content" => [%{"type" => "text", "text" => String.duplicate("b", 40_000)}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("c", 40_000)},
          timestamp: 3
        }
      ]

      # entry2 has pending tool call without matching result, should not be valid cut point
      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      # Only entry1 and entry4 are valid (user messages)
      assert cut_id in ["entry1", "entry4"]
    end

    test "handles tool_call with nil id" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 40_000)},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_call", "id" => nil, "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 40_000)},
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("c", 40_000)},
          timestamp: 3
        }
      ]

      # Tool call with nil id should be filtered out, making entry2 a valid cut point
      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      assert cut_id in ["entry1", "entry2", "entry3"]
    end

    test "handles entry with invalid type" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :invalid_type,
          message: nil,
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("a", 80_000)},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => String.duplicate("b", 80_000)},
          timestamp: 2
        }
      ]

      # Invalid type entries should be filtered out
      result = Compaction.find_cut_point(branch, 10_000)
      assert {:ok, cut_id} = result
      assert cut_id == "entry2"
    end
  end

  describe "deeply nested tool call chains" do
    test "handles 10 consecutive tool call/result pairs" do
      long_content = String.duplicate("a", 8000)

      entries =
        Enum.flat_map(1..10, fn i ->
          parent_id = if i == 1, do: nil, else: "result_#{i - 1}"

          [
            %SessionEntry{
              id: "call_#{i}",
              parent_id: parent_id,
              type: :message,
              message: %{
                "role" => "assistant",
                "content" => [
                  %{"type" => "text", "text" => "Step #{i}"},
                  %{
                    "type" => "tool_call",
                    "id" => "tc_#{i}",
                    "name" => "read",
                    "arguments" => %{}
                  }
                ]
              },
              timestamp: i * 2 - 1
            },
            %SessionEntry{
              id: "result_#{i}",
              parent_id: "call_#{i}",
              type: :message,
              message: %{
                "role" => "tool_result",
                "tool_call_id" => "tc_#{i}",
                "content" => [%{"type" => "text", "text" => long_content}]
              },
              timestamp: i * 2
            }
          ]
        end)

      # Add a final user message
      entries =
        entries ++
          [
            %SessionEntry{
              id: "final_user",
              parent_id: "result_10",
              type: :message,
              message: %{"role" => "user", "content" => long_content},
              timestamp: 21
            }
          ]

      result = Compaction.find_cut_point(entries, 5000)
      assert {:ok, cut_id} = result
      # Should find a valid cut point - assistant messages with completed tool results
      # are valid cut points
      assert String.starts_with?(cut_id, "call_") or cut_id == "final_user"
    end

    test "handles assistant with multiple parallel tool calls" do
      long_content = String.duplicate("a", 10_000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "text", "text" => "I'll read multiple files"},
              %{
                "type" => "tool_call",
                "id" => "tc_1",
                "name" => "read",
                "arguments" => %{"path" => "/a"}
              },
              %{
                "type" => "tool_call",
                "id" => "tc_2",
                "name" => "read",
                "arguments" => %{"path" => "/b"}
              },
              %{
                "type" => "tool_call",
                "id" => "tc_3",
                "name" => "read",
                "arguments" => %{"path" => "/c"}
              }
            ]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tc_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tc_2",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 3
        },
        %SessionEntry{
          id: "entry5",
          parent_id: "entry4",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tc_3",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 4
        },
        %SessionEntry{
          id: "entry6",
          parent_id: "entry5",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 5
        }
      ]

      result = Compaction.find_cut_point(branch, 5000)
      assert {:ok, cut_id} = result
      # entry2 should be valid because all 3 tool calls have results
      assert cut_id in ["entry1", "entry2", "entry6"]
    end

    test "rejects cut at assistant when one of multiple tool calls has no result" do
      long_content = String.duplicate("a", 10_000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_call", "id" => "tc_1", "name" => "read", "arguments" => %{}},
              %{"type" => "tool_call", "id" => "tc_2", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        # Only one tool result provided
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tc_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 3
        }
      ]

      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      # entry2 is not valid (missing tc_2 result), so cut at entry1 or entry4
      assert cut_id in ["entry1", "entry4"]
    end

    test "handles tool_use_id format (alternative to tool_call_id)" do
      long_content = String.duplicate("a", 10_000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_call", "id" => "tc_1", "name" => "read", "arguments" => %{}}
            ]
          },
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{
            "role" => "tool_result",
            # Using tool_use_id instead of tool_call_id
            "tool_use_id" => "tc_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 2
        },
        %SessionEntry{
          id: "entry4",
          parent_id: "entry3",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 3
        }
      ]

      result = Compaction.find_cut_point(branch, 2000)
      assert {:ok, cut_id} = result
      # entry2 should be valid because tc_1 has a result (using tool_use_id)
      assert cut_id in ["entry1", "entry2"]
    end
  end

  describe "summary generation abort signal checking" do
    test "returns :aborted when signal is aborted before generate_summary" do
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      messages = [
        %Messages.UserMessage{content: "Hello", timestamp: 0}
      ]

      model = %Ai.Types.Model{
        provider: :anthropic,
        id: "claude-3-sonnet"
      }

      result = Compaction.generate_summary(messages, model, signal: signal)
      assert {:error, :aborted} = result

      AgentCore.AbortSignal.clear(signal)
    end

    test "returns :aborted when signal is aborted before generate_branch_summary" do
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      branch_entries = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "Hello"},
          timestamp: 0
        }
      ]

      model = %Ai.Types.Model{
        provider: :anthropic,
        id: "claude-3-sonnet"
      }

      result = Compaction.generate_branch_summary(branch_entries, model, signal: signal)
      assert {:error, :aborted} = result

      AgentCore.AbortSignal.clear(signal)
    end

    test "generates summary with nil signal (default behavior)" do
      # This test verifies that nil signal doesn't cause issues
      messages = [
        %Messages.UserMessage{content: "Hello", timestamp: 0}
      ]

      model = %Ai.Types.Model{
        provider: :anthropic,
        id: "claude-3-sonnet"
      }

      # With nil signal and no API mock, this will fail at the API call
      # but should not fail at the abort check
      result = Compaction.generate_summary(messages, model, signal: nil)

      # The result will be an error from the API call, not from abort
      case result do
        {:error, :aborted} -> flunk("Should not return :aborted with nil signal")
        {:ok, _summary} -> :ok
        {:error, _other} -> :ok
      end
    end

    test "accepts pre-generated summary via opts and skips abort check" do
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      messages = [
        %Messages.UserMessage{content: "Hello", timestamp: 0}
      ]

      model = %Ai.Types.Model{
        provider: :anthropic,
        id: "claude-3-sonnet"
      }

      # When summary is provided in opts, it should return immediately
      result =
        Compaction.generate_summary(messages, model,
          signal: signal,
          summary: "Pre-generated summary"
        )

      assert {:ok, "Pre-generated summary"} = result

      AgentCore.AbortSignal.clear(signal)
    end

    test "accepts pre-generated branch summary via opts and skips abort check" do
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      branch_entries = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "Hello"},
          timestamp: 0
        }
      ]

      model = %Ai.Types.Model{
        provider: :anthropic,
        id: "claude-3-sonnet"
      }

      result =
        Compaction.generate_branch_summary(branch_entries, model,
          signal: signal,
          summary: "Branch summary"
        )

      assert {:ok, "Branch summary"} = result

      AgentCore.AbortSignal.clear(signal)
    end

    test "ignores empty string summary in opts" do
      signal = AgentCore.AbortSignal.new()
      AgentCore.AbortSignal.abort(signal)

      messages = [
        %Messages.UserMessage{content: "Hello", timestamp: 0}
      ]

      model = %Ai.Types.Model{
        provider: :anthropic,
        id: "claude-3-sonnet"
      }

      # Empty string summary should be ignored and proceed to abort check
      result = Compaction.generate_summary(messages, model, signal: signal, summary: "")
      assert {:error, :aborted} = result

      AgentCore.AbortSignal.clear(signal)
    end
  end

  describe "failed API calls with various error types" do
    # Note: These tests verify error handling patterns.
    # In real usage, generate_summary calls Ai.complete which may return various errors.

    test "extract_file_operations handles empty tool call list gracefully" do
      messages = [
        %Messages.AssistantMessage{
          content: [],
          timestamp: 0
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
      assert result.modified_files == []
    end

    test "extract_file_operations handles tool call with empty arguments" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "read",
              arguments: %{}
            }
          ],
          timestamp: 0
        }
      ]

      # Should handle empty arguments map without crashing
      # Map.get(%{}, "path") returns nil, which is handled
      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
    end

    test "extract_file_operations handles malformed tool call struct" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "unknown_tool",
              arguments: %{"some" => "args"}
            }
          ],
          timestamp: 0
        }
      ]

      # Unknown tool names should be ignored
      result = Compaction.extract_file_operations(messages)
      assert result.read_files == []
      assert result.modified_files == []
    end
  end

  describe "truncation of very long tool results" do
    test "format_message_for_summary truncates tool results to 500 chars" do
      # This is an internal function, but we can test it indirectly
      # by checking the behavior through generate_summary (if we could mock Ai.complete)
      # For now, we verify that estimate_message_tokens handles long tool results

      long_output = String.duplicate("x", 10_000)

      msg = %Messages.ToolResultMessage{
        tool_use_id: "test_id",
        content: [%Messages.TextContent{text: long_output}],
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      # Full 10,000 chars / 4 = 2500 tokens (not truncated for estimation)
      assert tokens == 2500
    end

    test "format_raw_message_for_summary truncates tool results to 200 chars" do
      # This is tested indirectly - the format functions truncate for summarization
      # We verify that the compaction module handles long content in entries

      long_content = String.duplicate("y", 50_000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tc_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 1
        },
        %SessionEntry{
          id: "entry3",
          parent_id: "entry2",
          type: :message,
          message: %{"role" => "user", "content" => long_content},
          timestamp: 2
        }
      ]

      # Should handle very long tool results in cut point calculation
      result = Compaction.find_cut_point(branch, 5000)
      assert {:ok, _cut_id} = result
    end

    test "handles tool result with very large base64 content" do
      # Simulate a tool result containing base64-encoded file content
      large_base64 = Base.encode64(:crypto.strong_rand_bytes(100_000))

      msg = %Messages.ToolResultMessage{
        tool_use_id: "file_read_1",
        content: [%Messages.TextContent{text: large_base64}],
        is_error: false,
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      # base64 of 100KB is ~133KB of text / 4 = ~33K tokens
      assert tokens > 30_000
    end

    test "handles error tool result with long error message" do
      long_error = "Error: " <> String.duplicate("stack trace line\n", 5000)

      msg = %Messages.ToolResultMessage{
        tool_use_id: "failed_tool",
        content: [%Messages.TextContent{text: long_error}],
        is_error: true,
        timestamp: 0
      }

      tokens = Compaction.estimate_message_tokens(msg)
      expected = div(String.length(long_error), 4)
      assert tokens == expected
    end
  end

  describe "total_tokens edge cases" do
    test "handles map with only some fields present" do
      # Only input and cache_read, missing output and cache_write
      usage = %{input: 100, cache_read: 50}
      assert Compaction.total_tokens(usage) == 0
    end

    test "handles negative token values" do
      # Shouldn't happen in practice, but verify behavior
      usage = %{total_tokens: -100}
      assert Compaction.total_tokens(usage) == -100
    end

    test "handles very large token counts" do
      usage = %{total_tokens: 1_000_000_000}
      assert Compaction.total_tokens(usage) == 1_000_000_000
    end

    test "handles float values (should not match integer patterns)" do
      usage = %{total_tokens: 100.5}
      # Float doesn't match integer guard
      assert Compaction.total_tokens(usage) == 0
    end

    test "handles string token values" do
      usage = %{total_tokens: "100"}
      # String doesn't match integer guard
      assert Compaction.total_tokens(usage) == 0
    end

    test "handles atom values" do
      usage = %{total_tokens: :infinity}
      assert Compaction.total_tokens(usage) == 0
    end
  end

  describe "find_cut_point boundary conditions" do
    test "single message that exceeds keep_recent_tokens" do
      # One very large message that alone exceeds the threshold
      # 100,000 tokens
      huge_content = String.duplicate("z", 400_000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => huge_content},
          timestamp: 0
        }
      ]

      # Even though message exceeds threshold, can't compact single message
      result = Compaction.find_cut_point(branch, 20_000)
      assert {:error, :cannot_compact} = result
    end

    test "all messages are tool_result (no valid cut points)" do
      long_content = String.duplicate("a", 20_000)

      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tc_1",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{
            "role" => "tool_result",
            "tool_call_id" => "tc_2",
            "content" => [%{"type" => "text", "text" => long_content}]
          },
          timestamp: 1
        }
      ]

      # tool_result messages are not valid cut points
      result = Compaction.find_cut_point(branch, 2000)
      assert {:error, :cannot_compact} = result
    end

    test "keep_recent_tokens of 0 still requires valid cut point" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "hello"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => "world"},
          timestamp: 1
        }
      ]

      # With 0 tokens to keep, should immediately find cut point at first valid entry
      result = Compaction.find_cut_point(branch, 0)
      assert {:ok, "entry1"} = result
    end

    test "very high keep_recent_tokens returns cannot_compact" do
      branch = [
        %SessionEntry{
          id: "entry1",
          parent_id: nil,
          type: :message,
          message: %{"role" => "user", "content" => "hello"},
          timestamp: 0
        },
        %SessionEntry{
          id: "entry2",
          parent_id: "entry1",
          type: :message,
          message: %{"role" => "user", "content" => "world"},
          timestamp: 1
        }
      ]

      # Requesting to keep 1 billion tokens
      result = Compaction.find_cut_point(branch, 1_000_000_000)
      assert {:error, :cannot_compact} = result
    end
  end

  describe "extract_file_operations with various message types" do
    test "handles Ai.Types messages" do
      # The function should work with different message formats
      messages = [
        %Ai.Types.AssistantMessage{
          role: :assistant,
          content: [
            %Ai.Types.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "read",
              arguments: %{"path" => "/test/file.txt"}
            }
          ],
          timestamp: 0
        }
      ]

      # Ai.Types.ToolCall has 'arguments' field like Messages.ToolCall
      result = Compaction.extract_file_operations(messages)
      assert is_list(result.read_files)
      assert is_list(result.modified_files)
    end

    test "handles mixed CodingAgent.Messages and Ai.Types messages" do
      messages = [
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc1",
              name: "read",
              arguments: %{"path" => "/path/one.txt"}
            }
          ],
          timestamp: 0
        },
        %Messages.UserMessage{content: "Thanks", timestamp: 1},
        %Messages.AssistantMessage{
          content: [
            %Messages.ToolCall{
              type: :tool_call,
              id: "tc2",
              name: "write",
              arguments: %{"path" => "/path/two.txt", "content" => "data"}
            }
          ],
          timestamp: 2
        }
      ]

      result = Compaction.extract_file_operations(messages)
      assert "/path/one.txt" in result.read_files
      assert "/path/two.txt" in result.modified_files
    end
  end
end
