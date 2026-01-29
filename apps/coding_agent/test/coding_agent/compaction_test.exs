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
          message: %{"role" => "assistant", "content" => [%{"type" => "text", "text" => long_content}]},
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
          message: %{"role" => "assistant", "content" => [%{"type" => "text", "text" => long_content}]},
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
      assert {:ok, cut_id} = Compaction.find_cut_point(branch, 20000, force: true, min_keep_messages: 2)
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
      should_compact = Compaction.should_compact?(tokens, context_window, %{enabled: true, reserve_tokens: 5000})
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
end
