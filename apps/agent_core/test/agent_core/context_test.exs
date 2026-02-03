defmodule AgentCore.ContextTest do
  use ExUnit.Case, async: true

  alias AgentCore.Context
  alias AgentCore.Test.Mocks

  # ============================================================================
  # Telemetry Setup
  # ============================================================================

  setup do
    # Generate a unique handler ID for this test
    handler_id = :erlang.unique_integer()

    # Start an agent to collect telemetry events
    {:ok, collector} = Agent.start_link(fn -> [] end)

    %{handler_id: handler_id, collector: collector}
  end

  defp attach_telemetry(event_names, handler_id, collector) do
    :telemetry.attach_many(
      "context-test-handler-#{handler_id}",
      event_names,
      fn event_name, measurements, metadata, _config ->
        Agent.update(collector, fn events ->
          [{event_name, measurements, metadata} | events]
        end)
      end,
      nil
    )
  end

  defp detach_telemetry(handler_id) do
    :telemetry.detach("context-test-handler-#{handler_id}")
  end

  defp get_events(collector) do
    Agent.get(collector, & &1) |> Enum.reverse()
  end

  # ============================================================================
  # estimate_size/2 Tests
  # ============================================================================

  describe "estimate_size/2" do
    test "returns 0 for empty messages and no system prompt" do
      assert Context.estimate_size([], nil) == 0
    end

    test "counts system prompt characters" do
      assert Context.estimate_size([], "Hello World") == 11
    end

    test "counts string content in user messages" do
      messages = [Mocks.user_message("Hello")]
      assert Context.estimate_size(messages, nil) == 5
    end

    test "counts text content in assistant messages" do
      messages = [Mocks.assistant_message("Hello World")]
      assert Context.estimate_size(messages, nil) == 11
    end

    test "sums multiple messages" do
      messages = [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("World")
      ]

      assert Context.estimate_size(messages, nil) == 10
    end

    test "includes system prompt in total" do
      messages = [Mocks.user_message("Hi")]
      assert Context.estimate_size(messages, "System") == 8
    end

    test "handles tool result messages" do
      result = Mocks.tool_result_message("call_1", "echo", "Result text")
      assert Context.estimate_size([result], nil) == 11
    end

    test "handles messages with tool calls" do
      tool_call = Mocks.tool_call("echo", %{"text" => "hello"})
      msg = Mocks.assistant_message_with_tool_calls([tool_call])

      # Tool call arguments get JSON encoded
      size = Context.estimate_size([msg], nil)
      assert size > 0
    end

    test "emits telemetry event", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :size]], handler_id, collector)

      messages = [Mocks.user_message("Test")]
      Context.estimate_size(messages, "System")

      events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(events) >= 1

      {event_name, measurements, metadata} = hd(events)
      assert event_name == [:agent_core, :context, :size]
      assert measurements.char_count == 10
      assert measurements.message_count == 1
      assert metadata.has_system_prompt == true
    end
  end

  # ============================================================================
  # estimate_tokens/1 Tests
  # ============================================================================

  describe "estimate_tokens/1" do
    test "divides by 4 (chars per token)" do
      assert Context.estimate_tokens(400) == 100
    end

    test "rounds down" do
      assert Context.estimate_tokens(7) == 1
    end

    test "returns 0 for 0 chars" do
      assert Context.estimate_tokens(0) == 0
    end
  end

  # ============================================================================
  # large_context?/3 Tests
  # ============================================================================

  describe "large_context?/3" do
    test "returns false for small context" do
      messages = [Mocks.user_message("Hi")]
      refute Context.large_context?(messages, nil)
    end

    test "returns true when above default threshold" do
      # Create a large message (> 200k chars)
      large_text = String.duplicate("x", 250_000)
      messages = [Mocks.user_message(large_text)]

      assert Context.large_context?(messages, nil)
    end

    test "respects custom threshold" do
      messages = [Mocks.user_message("Hello")]
      assert Context.large_context?(messages, nil, threshold: 3)
    end

    test "includes system prompt in calculation" do
      messages = [Mocks.user_message("Hi")]
      assert Context.large_context?(messages, "System", threshold: 5)
    end
  end

  # ============================================================================
  # check_size/3 Tests
  # ============================================================================

  describe "check_size/3" do
    test "returns :ok for small context" do
      messages = [Mocks.user_message("Hi")]
      assert Context.check_size(messages, nil, log: false) == :ok
    end

    test "returns :warning when above warning threshold" do
      large_text = String.duplicate("x", 250_000)
      messages = [Mocks.user_message(large_text)]

      assert Context.check_size(messages, nil, log: false) == :warning
    end

    test "returns :critical when above critical threshold" do
      large_text = String.duplicate("x", 450_000)
      messages = [Mocks.user_message(large_text)]

      assert Context.check_size(messages, nil, log: false) == :critical
    end

    test "respects custom thresholds" do
      messages = [Mocks.user_message("Hello")]

      assert Context.check_size(messages, nil,
               warning_threshold: 3,
               critical_threshold: 10,
               log: false
             ) == :warning

      assert Context.check_size(messages, nil,
               warning_threshold: 3,
               critical_threshold: 4,
               log: false
             ) == :critical
    end

    test "emits telemetry for warning", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :warning]], handler_id, collector)

      messages = [Mocks.user_message("Hello World")]

      Context.check_size(messages, nil,
        warning_threshold: 5,
        critical_threshold: 100,
        log: false
      )

      events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(events) >= 1

      {event_name, measurements, metadata} = hd(events)
      assert event_name == [:agent_core, :context, :warning]
      assert measurements.char_count == 11
      assert measurements.threshold == 5
      assert metadata.level == :warning
    end

    test "emits telemetry for critical", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :warning]], handler_id, collector)

      messages = [Mocks.user_message("Hello World")]

      Context.check_size(messages, nil,
        warning_threshold: 3,
        critical_threshold: 5,
        log: false
      )

      events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(events) >= 1

      {_event_name, _measurements, metadata} = hd(events)
      assert metadata.level == :critical
    end
  end

  # ============================================================================
  # truncate/2 Tests
  # ============================================================================

  describe "truncate/2" do
    test "returns all messages when within limits" do
      messages = [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("World")
      ]

      {truncated, dropped} = Context.truncate(messages, max_messages: 10)

      assert truncated == messages
      assert dropped == 0
    end

    test "truncates to max_messages limit" do
      messages =
        for i <- 1..10 do
          Mocks.user_message("Message #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 5)

      assert length(truncated) <= 6
      assert dropped >= 4
    end

    test "truncates to max_chars limit" do
      messages = [
        Mocks.user_message("Short"),
        Mocks.user_message(String.duplicate("x", 1000))
      ]

      {_truncated, dropped} = Context.truncate(messages, max_chars: 100)

      assert dropped >= 1
    end

    test "keeps first user message by default" do
      messages = [
        Mocks.user_message("First user"),
        Mocks.assistant_message("Response 1"),
        Mocks.user_message("Second user"),
        Mocks.assistant_message("Response 2"),
        Mocks.user_message("Third user")
      ]

      {truncated, _dropped} = Context.truncate(messages, max_messages: 3)

      # First message should be preserved
      first = hd(truncated)
      assert Map.get(first, :content) == "First user"
    end

    test "can disable keeping first user message" do
      messages = [
        Mocks.user_message("First user"),
        Mocks.assistant_message("Response 1"),
        Mocks.user_message("Second user"),
        Mocks.assistant_message("Response 2")
      ]

      {truncated, _dropped} = Context.truncate(messages, max_messages: 2, keep_first_user: false)

      # Should only have last 2 messages
      assert length(truncated) == 2
    end

    test "bookends strategy keeps first and last" do
      messages =
        for i <- 1..10 do
          Mocks.user_message("Message #{i}")
        end

      {truncated, _dropped} = Context.truncate(messages, max_messages: 4, strategy: :keep_bookends)

      assert length(truncated) == 4

      # First two and last two
      first_content = Map.get(hd(truncated), :content)
      last_content = Map.get(List.last(truncated), :content)

      assert first_content == "Message 1"
      assert last_content == "Message 10"
    end

    test "emits telemetry when truncating", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :truncated]], handler_id, collector)

      messages =
        for i <- 1..10 do
          Mocks.user_message("Message #{i}")
        end

      {_truncated, dropped} = Context.truncate(messages, max_messages: 5)

      events = get_events(collector)
      detach_telemetry(handler_id)

      if dropped > 0 do
        assert length(events) >= 1

        {event_name, measurements, metadata} = hd(events)
        assert event_name == [:agent_core, :context, :truncated]
        assert measurements.dropped_count > 0
        assert metadata.strategy == :sliding_window
      end
    end
  end

  # ============================================================================
  # make_transform/1 Tests
  # ============================================================================

  describe "make_transform/1" do
    test "returns a function" do
      transform = Context.make_transform(max_messages: 10)
      assert is_function(transform, 2)
    end

    test "transform function returns {:ok, messages}" do
      transform = Context.make_transform(max_messages: 10)
      messages = [Mocks.user_message("Hello")]

      result = transform.(messages, nil)
      assert {:ok, ^messages} = result
    end

    test "transform function truncates when needed" do
      transform = Context.make_transform(max_messages: 2, warn_on_truncation: false)

      messages =
        for i <- 1..5 do
          Mocks.user_message("Message #{i}")
        end

      {:ok, truncated} = transform.(messages, nil)
      assert length(truncated) <= 3
    end
  end

  # ============================================================================
  # stats/2 Tests
  # ============================================================================

  describe "stats/2" do
    test "returns correct message count" do
      messages = [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("World")
      ]

      stats = Context.stats(messages, nil)
      assert stats.message_count == 2
    end

    test "returns correct char count" do
      messages = [Mocks.user_message("Hello")]
      stats = Context.stats(messages, "System")

      assert stats.char_count == 11
    end

    test "estimates tokens" do
      messages = [Mocks.user_message(String.duplicate("x", 400))]
      stats = Context.stats(messages, nil)

      assert stats.estimated_tokens == 100
    end

    test "groups by role" do
      messages = [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("Hi"),
        Mocks.user_message("How are you?"),
        Mocks.tool_result_message("call_1", "echo", "Result")
      ]

      stats = Context.stats(messages, nil)

      assert stats.by_role[:user] == 2
      assert stats.by_role[:assistant] == 1
      assert stats.by_role[:tool_result] == 1
    end

    test "includes system prompt chars" do
      messages = [Mocks.user_message("Hi")]
      stats = Context.stats(messages, "System prompt here")

      assert stats.system_prompt_chars == 18
    end

    test "handles nil system prompt" do
      messages = [Mocks.user_message("Hi")]
      stats = Context.stats(messages, nil)

      assert stats.system_prompt_chars == 0
    end
  end

  # ============================================================================
  # Edge Cases: Content Block Handling
  # ============================================================================

  describe "content block handling" do
    test "handles text content blocks" do
      msg = %{
        role: :assistant,
        content: [%{type: :text, text: "Hello"}]
      }

      assert Context.estimate_size([msg], nil) == 5
    end

    test "handles thinking content blocks" do
      msg = %{
        role: :assistant,
        content: [%{type: :thinking, thinking: "Deep thought"}]
      }

      assert Context.estimate_size([msg], nil) == 12
    end

    test "handles tool_call content blocks with arguments" do
      msg = %{
        role: :assistant,
        content: [%{type: :tool_call, arguments: %{"key" => "value"}}]
      }

      size = Context.estimate_size([msg], nil)
      # Should be the JSON-encoded length of {"key":"value"}
      assert size > 0
    end

    test "handles image content blocks" do
      msg = %{
        role: :assistant,
        content: [%{type: :image}]
      }

      # Image blocks have a fixed size estimate of 100
      assert Context.estimate_size([msg], nil) == 100
    end

    test "handles unknown content block types" do
      msg = %{
        role: :assistant,
        content: [%{type: :unknown_type}]
      }

      # Unknown block types return 0
      assert Context.estimate_size([msg], nil) == 0
    end

    test "handles mixed content blocks" do
      msg = %{
        role: :assistant,
        content: [
          %{type: :text, text: "Hello"},
          %{type: :thinking, thinking: "Hmm"},
          %{type: :image}
        ]
      }

      # "Hello" (5) + "Hmm" (3) + image (100) = 108
      assert Context.estimate_size([msg], nil) == 108
    end

    test "handles nil text in text content block" do
      msg = %{
        role: :assistant,
        content: [%{type: :text, text: nil}]
      }

      assert Context.estimate_size([msg], nil) == 0
    end

    test "handles nil thinking in thinking content block" do
      msg = %{
        role: :assistant,
        content: [%{type: :thinking, thinking: nil}]
      }

      assert Context.estimate_size([msg], nil) == 0
    end
  end

  # ============================================================================
  # Edge Cases: Message Content
  # ============================================================================

  describe "message content edge cases" do
    test "handles message with nil content" do
      msg = %{role: :user, content: nil}
      assert Context.estimate_size([msg], nil) == 0
    end

    test "handles message with missing content key" do
      msg = %{role: :user}
      assert Context.estimate_size([msg], nil) == 0
    end

    test "handles message with integer content (unexpected type)" do
      msg = %{role: :user, content: 12345}
      assert Context.estimate_size([msg], nil) == 0
    end

    test "handles empty string content" do
      msg = %{role: :user, content: ""}
      assert Context.estimate_size([msg], nil) == 0
    end

    test "handles empty list content" do
      msg = %{role: :assistant, content: []}
      assert Context.estimate_size([msg], nil) == 0
    end
  end

  # ============================================================================
  # Edge Cases: Truncation
  # ============================================================================

  describe "truncation edge cases" do
    test "truncate returns empty list for empty messages" do
      {truncated, dropped} = Context.truncate([])
      assert truncated == []
      assert dropped == 0
    end

    test "truncate with max_messages: 0 returns minimal set" do
      messages = [Mocks.user_message("Hello")]
      {truncated, _dropped} = Context.truncate(messages, max_messages: 0)

      # With keep_first_user: true (default), should keep first user message
      assert length(truncated) <= 1
    end

    test "truncate preserves first user message when it's at the very beginning" do
      messages = [
        Mocks.user_message("First"),
        Mocks.assistant_message("Response")
      ]

      {truncated, dropped} = Context.truncate(messages, max_messages: 100)

      assert dropped == 0
      assert length(truncated) == 2
    end

    test "truncate with unknown strategy falls back to sliding_window" do
      messages = [
        Mocks.user_message("First"),
        Mocks.assistant_message("Second")
      ]

      {truncated, _dropped} = Context.truncate(messages, strategy: :unknown_strategy)
      assert length(truncated) == 2
    end

    test "bookends strategy with odd max_messages" do
      messages =
        for i <- 1..10 do
          Mocks.user_message("Message #{i}")
        end

      {truncated, _dropped} = Context.truncate(messages, max_messages: 5, strategy: :keep_bookends)

      # With max_messages: 5, half = 2, so we get first 2 + last 2 = 4
      assert length(truncated) == 4
    end

    test "bookends strategy keeps all when within limits" do
      messages =
        for i <- 1..3 do
          Mocks.user_message("Message #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 10, strategy: :keep_bookends)

      assert truncated == messages
      assert dropped == 0
    end

    test "sliding window respects both max_messages and max_chars" do
      # Create messages where char limit is reached before message limit
      messages = [
        Mocks.user_message("Short"),
        Mocks.user_message(String.duplicate("x", 50)),
        Mocks.user_message("End")
      ]

      {truncated, _dropped} = Context.truncate(messages, max_messages: 100, max_chars: 20)

      # First user message is preserved, so we might exceed a bit
      # but recent messages should be dropped
      assert length(truncated) < 3
    end

    test "sliding window includes first user message even when truncating" do
      messages = [
        Mocks.user_message("First user message"),
        Mocks.assistant_message("Response 1"),
        Mocks.user_message("Second user"),
        Mocks.assistant_message("Response 2"),
        Mocks.user_message("Third user"),
        Mocks.assistant_message("Response 3"),
        Mocks.user_message("Fourth user"),
        Mocks.assistant_message("Response 4")
      ]

      {truncated, dropped} = Context.truncate(messages, max_messages: 3)

      assert dropped > 0

      # First message should always be the first user message
      first = hd(truncated)
      assert Map.get(first, :content) == "First user message"
    end
  end

  # ============================================================================
  # Edge Cases: make_transform
  # ============================================================================

  describe "make_transform edge cases" do
    test "transform handles empty messages" do
      transform = Context.make_transform(max_messages: 10, warn_on_truncation: false)
      {:ok, result} = transform.([], nil)
      assert result == []
    end

    test "transform passes signal parameter through" do
      transform = Context.make_transform()
      signal = make_ref()

      {:ok, _result} = transform.([Mocks.user_message("Test")], signal)
      # Signal is passed but not used by default truncation
    end

    test "transform with all options" do
      transform =
        Context.make_transform(
          max_messages: 5,
          max_chars: 1000,
          strategy: :sliding_window,
          keep_first_user: true,
          warn_on_truncation: false
        )

      messages =
        for i <- 1..10 do
          Mocks.user_message("Message #{i}")
        end

      {:ok, truncated} = transform.(messages, nil)
      assert length(truncated) <= 6
    end
  end

  # ============================================================================
  # Edge Cases: stats function
  # ============================================================================

  describe "stats edge cases" do
    test "stats with empty messages" do
      stats = Context.stats([], nil)

      assert stats.message_count == 0
      assert stats.char_count == 0
      assert stats.estimated_tokens == 0
      assert stats.by_role == %{}
      assert stats.system_prompt_chars == 0
    end

    test "stats handles messages with missing role" do
      messages = [%{content: "No role"}]
      stats = Context.stats(messages, nil)

      assert stats.by_role[:unknown] == 1
    end

    test "stats counts all role types" do
      messages = [
        Mocks.user_message("User 1"),
        Mocks.user_message("User 2"),
        Mocks.assistant_message("Assistant 1"),
        Mocks.assistant_message("Assistant 2"),
        Mocks.assistant_message("Assistant 3"),
        Mocks.tool_result_message("id1", "tool1", "Result 1"),
        Mocks.tool_result_message("id2", "tool2", "Result 2")
      ]

      stats = Context.stats(messages, nil)

      assert stats.by_role[:user] == 2
      assert stats.by_role[:assistant] == 3
      assert stats.by_role[:tool_result] == 2
      assert stats.message_count == 7
    end
  end

  # ============================================================================
  # Edge Cases: check_size thresholds
  # ============================================================================

  describe "check_size edge cases" do
    test "returns :ok when exactly at warning threshold" do
      # Create message with exact size
      text = String.duplicate("x", 100)
      messages = [Mocks.user_message(text)]

      # Threshold at 100 means 100 chars triggers warning (> 100)
      result = Context.check_size(messages, nil, warning_threshold: 100, log: false)
      assert result == :ok
    end

    test "returns :warning when one char over warning threshold" do
      text = String.duplicate("x", 101)
      messages = [Mocks.user_message(text)]

      result = Context.check_size(messages, nil, warning_threshold: 100, critical_threshold: 200, log: false)
      assert result == :warning
    end

    test "returns :critical when one char over critical threshold" do
      text = String.duplicate("x", 201)
      messages = [Mocks.user_message(text)]

      result = Context.check_size(messages, nil, warning_threshold: 100, critical_threshold: 200, log: false)
      assert result == :critical
    end

    test "critical takes precedence over warning" do
      text = String.duplicate("x", 500)
      messages = [Mocks.user_message(text)]

      result = Context.check_size(messages, nil, warning_threshold: 100, critical_threshold: 200, log: false)
      assert result == :critical
    end
  end

  # ============================================================================
  # Edge Cases: large_context? with system prompt
  # ============================================================================

  describe "large_context? edge cases" do
    test "considers system prompt size in threshold check" do
      messages = [Mocks.user_message("Hi")]
      # 2 chars from "Hi" + 100 from system prompt = 102
      assert Context.large_context?(messages, String.duplicate("x", 100), threshold: 101)
    end

    test "returns false for empty context with no system prompt" do
      refute Context.large_context?([], nil, threshold: 1)
    end
  end

  # ============================================================================
  # Integration: Full workflow
  # ============================================================================

  describe "integration: full workflow" do
    test "can check size, get stats, and truncate in sequence" do
      messages =
        for i <- 1..20 do
          if rem(i, 2) == 0 do
            Mocks.assistant_message("Response #{i}")
          else
            Mocks.user_message("Query #{i}")
          end
        end

      system_prompt = "You are a helpful assistant."

      # Check initial size
      _initial_status = Context.check_size(messages, system_prompt, log: false)
      initial_stats = Context.stats(messages, system_prompt)

      assert initial_stats.message_count == 20
      assert initial_stats.by_role[:user] == 10
      assert initial_stats.by_role[:assistant] == 10

      # Truncate if needed
      {truncated, dropped} = Context.truncate(messages, max_messages: 10)

      assert dropped > 0
      assert length(truncated) <= 11  # max + possibly first user

      # Verify truncated stats
      truncated_stats = Context.stats(truncated, system_prompt)
      assert truncated_stats.message_count < initial_stats.message_count
      assert truncated_stats.char_count < initial_stats.char_count
    end
  end

  # ============================================================================
  # Edge Cases: Very Small max_chars in truncate_sliding_window
  # ============================================================================

  describe "truncate_sliding_window with very small max_chars" do
    test "max_chars: 1 keeps only first user message when keep_first_user is true" do
      messages = [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("World"),
        Mocks.user_message("Again")
      ]

      {truncated, dropped} = Context.truncate(messages, max_chars: 1, max_messages: 100)

      # First user message is preserved regardless of max_chars
      assert length(truncated) >= 1
      assert dropped >= 1
      first = hd(truncated)
      assert Map.get(first, :content) == "Hello"
    end

    test "max_chars: 0 with keep_first_user: false returns empty or minimal" do
      messages = [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("World")
      ]

      {truncated, dropped} = Context.truncate(messages, max_chars: 0, max_messages: 100, keep_first_user: false)

      # With 0 max_chars and no first user preservation, should drop everything
      assert length(truncated) == 0
      assert dropped == 2
    end

    test "max_chars smaller than single message truncates all but first user" do
      messages = [
        Mocks.user_message("A"),
        Mocks.assistant_message("BCDEFGHIJ"),
        Mocks.user_message("K")
      ]

      # max_chars: 5 means only first user (1 char) can fit, plus reserved chars
      {truncated, dropped} = Context.truncate(messages, max_chars: 5, max_messages: 100)

      # First user message preserved, others dropped due to char limit
      assert length(truncated) >= 1
      assert dropped >= 1
    end

    test "max_chars exactly fits one message after first user" do
      messages = [
        Mocks.user_message("AB"),
        Mocks.assistant_message("CD"),
        Mocks.user_message("EF")
      ]

      # Reserved: 2 (first user), max_chars: 4 allows one more 2-char message
      {truncated, dropped} = Context.truncate(messages, max_chars: 4, max_messages: 100)

      assert length(truncated) == 2
      assert dropped == 1
    end

    test "max_chars: 1 with large messages drops all but first user" do
      messages = [
        Mocks.user_message("X"),
        Mocks.assistant_message(String.duplicate("Y", 1000)),
        Mocks.assistant_message(String.duplicate("Z", 1000))
      ]

      {truncated, dropped} = Context.truncate(messages, max_chars: 1, max_messages: 100)

      # Only first user message preserved
      assert length(truncated) == 1
      assert dropped == 2
      assert Map.get(hd(truncated), :content) == "X"
    end
  end

  # ============================================================================
  # Edge Cases: truncate_bookends with odd/even message counts
  # ============================================================================

  describe "truncate_bookends with odd/even message counts" do
    test "even message count with even max_messages" do
      messages =
        for i <- 1..8 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 4, strategy: :keep_bookends)

      # half = 2, so first 2 + last 2 = 4
      assert length(truncated) == 4
      assert dropped == 4
      assert Map.get(hd(truncated), :content) == "Msg 1"
      assert Map.get(Enum.at(truncated, 1), :content) == "Msg 2"
      assert Map.get(Enum.at(truncated, 2), :content) == "Msg 7"
      assert Map.get(List.last(truncated), :content) == "Msg 8"
    end

    test "odd message count with even max_messages" do
      messages =
        for i <- 1..9 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 4, strategy: :keep_bookends)

      # half = 2, so first 2 + last 2 = 4
      assert length(truncated) == 4
      assert dropped == 5
      assert Map.get(hd(truncated), :content) == "Msg 1"
      assert Map.get(List.last(truncated), :content) == "Msg 9"
    end

    test "even message count with odd max_messages" do
      messages =
        for i <- 1..10 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 5, strategy: :keep_bookends)

      # half = 2 (div 5, 2), so first 2 + last 2 = 4
      assert length(truncated) == 4
      assert dropped == 6
    end

    test "odd message count with odd max_messages" do
      messages =
        for i <- 1..11 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 5, strategy: :keep_bookends)

      # half = 2, so first 2 + last 2 = 4
      assert length(truncated) == 4
      assert dropped == 7
    end

    test "max_messages: 1 with bookends strategy" do
      messages =
        for i <- 1..5 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, _dropped} = Context.truncate(messages, max_messages: 1, strategy: :keep_bookends)

      # half = 0, so empty result from take operations
      assert length(truncated) == 0
    end

    test "max_messages: 2 with bookends strategy" do
      messages =
        for i <- 1..10 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 2, strategy: :keep_bookends)

      # half = 1, so first 1 + last 1 = 2
      assert length(truncated) == 2
      assert dropped == 8
      assert Map.get(hd(truncated), :content) == "Msg 1"
      assert Map.get(List.last(truncated), :content) == "Msg 10"
    end

    test "max_messages: 3 with bookends strategy (odd)" do
      messages =
        for i <- 1..10 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 3, strategy: :keep_bookends)

      # half = 1, so first 1 + last 1 = 2
      assert length(truncated) == 2
      assert dropped == 8
    end

    test "bookends with exactly max_messages count" do
      messages =
        for i <- 1..4 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 4, strategy: :keep_bookends)

      # No truncation needed
      assert truncated == messages
      assert dropped == 0
    end

    test "bookends with fewer messages than max_messages" do
      messages =
        for i <- 1..3 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 10, strategy: :keep_bookends)

      assert truncated == messages
      assert dropped == 0
    end
  end

  # ============================================================================
  # Edge Cases: keep_first_user: true but no user messages
  # ============================================================================

  describe "truncation with keep_first_user: true but no user messages" do
    test "all assistant messages with keep_first_user: true" do
      messages = [
        Mocks.assistant_message("Response 1"),
        Mocks.assistant_message("Response 2"),
        Mocks.assistant_message("Response 3")
      ]

      {truncated, dropped} = Context.truncate(messages, max_messages: 2, keep_first_user: true)

      # No user message to preserve, so just sliding window behavior
      assert length(truncated) == 2
      assert dropped == 1
    end

    test "all tool_result messages with keep_first_user: true" do
      messages = [
        Mocks.tool_result_message("id1", "tool1", "Result 1"),
        Mocks.tool_result_message("id2", "tool2", "Result 2"),
        Mocks.tool_result_message("id3", "tool3", "Result 3")
      ]

      {truncated, dropped} = Context.truncate(messages, max_messages: 2, keep_first_user: true)

      # No user message to preserve
      assert length(truncated) == 2
      assert dropped == 1
    end

    test "mixed assistant and tool_result with no user messages" do
      messages = [
        Mocks.assistant_message("Response 1"),
        Mocks.tool_result_message("id1", "tool1", "Result 1"),
        Mocks.assistant_message("Response 2"),
        Mocks.tool_result_message("id2", "tool2", "Result 2")
      ]

      {truncated, dropped} = Context.truncate(messages, max_messages: 2, keep_first_user: true)

      # No user message found, sliding window keeps last 2
      assert length(truncated) == 2
      assert dropped == 2
    end

    test "user message appears later in list with keep_first_user: true" do
      messages = [
        Mocks.assistant_message("Response 1"),
        Mocks.assistant_message("Response 2"),
        Mocks.user_message("First actual user message"),
        Mocks.assistant_message("Response 3")
      ]

      {truncated, _dropped} = Context.truncate(messages, max_messages: 2, keep_first_user: true)

      # First user message (at index 2) should be preserved
      assert length(truncated) >= 1
      first_user = Enum.find(truncated, fn msg -> Map.get(msg, :role) == :user end)
      assert first_user != nil
      assert Map.get(first_user, :content) == "First actual user message"
    end
  end

  # ============================================================================
  # Edge Cases: Empty message list handling
  # ============================================================================

  describe "empty message list handling" do
    test "estimate_size with empty messages" do
      assert Context.estimate_size([], nil) == 0
      assert Context.estimate_size([], "System") == 6
    end

    test "large_context? with empty messages" do
      refute Context.large_context?([], nil)
      refute Context.large_context?([], "Hi", threshold: 100)
      assert Context.large_context?([], "Hi", threshold: 1)
    end

    test "check_size with empty messages" do
      assert Context.check_size([], nil, log: false) == :ok
      assert Context.check_size([], "System", log: false) == :ok
    end

    test "truncate with empty messages" do
      {truncated, dropped} = Context.truncate([])
      assert truncated == []
      assert dropped == 0
    end

    test "truncate empty with various options" do
      {t1, d1} = Context.truncate([], max_messages: 0)
      assert t1 == []
      assert d1 == 0

      {t2, d2} = Context.truncate([], max_chars: 0)
      assert t2 == []
      assert d2 == 0

      {t3, d3} = Context.truncate([], strategy: :keep_bookends)
      assert t3 == []
      assert d3 == 0

      {t4, d4} = Context.truncate([], keep_first_user: false)
      assert t4 == []
      assert d4 == 0
    end

    test "stats with empty messages" do
      stats = Context.stats([], nil)
      assert stats.message_count == 0
      assert stats.char_count == 0
      assert stats.estimated_tokens == 0
      assert stats.by_role == %{}
      assert stats.system_prompt_chars == 0
    end

    test "make_transform handles empty messages" do
      transform = Context.make_transform(max_messages: 10, warn_on_truncation: false)
      {:ok, result} = transform.([], nil)
      assert result == []
    end
  end

  # ============================================================================
  # Edge Cases: Single message truncation
  # ============================================================================

  describe "single message truncation" do
    test "single user message with sliding window" do
      messages = [Mocks.user_message("Hello")]
      {truncated, dropped} = Context.truncate(messages, max_messages: 10)
      assert truncated == messages
      assert dropped == 0
    end

    test "single user message exceeds max_messages: 0" do
      messages = [Mocks.user_message("Hello")]
      {truncated, dropped} = Context.truncate(messages, max_messages: 0)

      # First user message is preserved with keep_first_user: true
      assert length(truncated) == 1
      assert dropped == 0
    end

    test "single assistant message with max_messages: 0" do
      messages = [Mocks.assistant_message("Hello")]
      {truncated, dropped} = Context.truncate(messages, max_messages: 0, keep_first_user: false)

      # No user message, nothing preserved
      assert length(truncated) == 0
      assert dropped == 1
    end

    test "single message with bookends strategy" do
      messages = [Mocks.user_message("Solo")]
      {truncated, dropped} = Context.truncate(messages, max_messages: 10, strategy: :keep_bookends)
      assert truncated == messages
      assert dropped == 0
    end

    test "single message exceeds max_chars" do
      messages = [Mocks.user_message(String.duplicate("x", 1000))]
      {truncated, dropped} = Context.truncate(messages, max_chars: 10)

      # First user message preserved regardless
      assert length(truncated) == 1
      assert dropped == 0
    end

    test "single message fits exactly in max_chars" do
      messages = [Mocks.user_message("12345")]
      {truncated, dropped} = Context.truncate(messages, max_chars: 5)
      assert truncated == messages
      assert dropped == 0
    end

    test "single tool_result message" do
      messages = [Mocks.tool_result_message("id1", "tool", "Result")]
      {truncated, dropped} = Context.truncate(messages, max_messages: 10)
      assert truncated == messages
      assert dropped == 0
    end
  end

  # ============================================================================
  # Edge Cases: Messages with embedded binary data
  # ============================================================================

  describe "messages with embedded binary data" do
    test "message with binary content containing null bytes" do
      # Binary with null bytes (not valid UTF-8 string in some contexts)
      binary_content = <<72, 101, 108, 108, 111, 0, 87, 111, 114, 108, 100>>
      msg = %{role: :user, content: binary_content}

      # Should handle without crashing
      size = Context.estimate_size([msg], nil)
      assert size == 11  # Length of the binary
    end

    test "message with unicode content" do
      # Unicode characters (multi-byte in UTF-8)
      unicode_content = "Hello 世界 🌍"
      messages = [Mocks.user_message(unicode_content)]

      size = Context.estimate_size(messages, nil)
      # String.length counts graphemes, not bytes
      assert size == String.length(unicode_content)
    end

    test "message with emoji content" do
      emoji_content = "🎉🎊🎈🎁🎀"
      messages = [Mocks.user_message(emoji_content)]

      size = Context.estimate_size(messages, nil)
      assert size == 5  # 5 graphemes
    end

    test "message with mixed ASCII and unicode" do
      mixed_content = "ABC日本語DEF"
      messages = [Mocks.user_message(mixed_content)]

      size = Context.estimate_size(messages, nil)
      assert size == String.length(mixed_content)
    end

    test "truncation with unicode messages" do
      messages = [
        Mocks.user_message("こんにちは"),
        Mocks.assistant_message("世界"),
        Mocks.user_message("🌍🌎🌏")
      ]

      {truncated, _dropped} = Context.truncate(messages, max_messages: 2)
      assert length(truncated) == 2
    end

    test "message with control characters" do
      content_with_controls = "Hello\n\t\rWorld"
      messages = [Mocks.user_message(content_with_controls)]

      size = Context.estimate_size(messages, nil)
      assert size == String.length(content_with_controls)
    end

    test "message with very long unicode string" do
      # Long string with mixed characters
      long_unicode = String.duplicate("日本語テスト ", 1000)
      messages = [Mocks.user_message(long_unicode)]

      size = Context.estimate_size(messages, nil)
      assert size == String.length(long_unicode)
    end

    test "content block with binary-encoded data" do
      msg = %{
        role: :assistant,
        content: [
          %{type: :text, text: "Result: " <> Base.encode64(<<1, 2, 3, 4, 5>>)}
        ]
      }

      size = Context.estimate_size([msg], nil)
      assert size > 0
    end
  end

  # ============================================================================
  # Edge Cases: Token estimation accuracy
  # ============================================================================

  describe "token estimation accuracy" do
    test "estimate_tokens with exact multiple of 4" do
      assert Context.estimate_tokens(400) == 100
      assert Context.estimate_tokens(4000) == 1000
      assert Context.estimate_tokens(0) == 0
    end

    test "estimate_tokens rounds down for non-multiples" do
      assert Context.estimate_tokens(1) == 0
      assert Context.estimate_tokens(3) == 0
      assert Context.estimate_tokens(5) == 1
      assert Context.estimate_tokens(7) == 1
      assert Context.estimate_tokens(9) == 2
    end

    test "estimate_tokens with large values" do
      assert Context.estimate_tokens(1_000_000) == 250_000
      assert Context.estimate_tokens(4_000_000) == 1_000_000
    end

    test "token estimation from stats matches direct call" do
      messages = [Mocks.user_message(String.duplicate("x", 800))]
      stats = Context.stats(messages, nil)

      assert stats.estimated_tokens == Context.estimate_tokens(800)
      assert stats.estimated_tokens == 200
    end

    test "token estimation with system prompt included" do
      messages = [Mocks.user_message("Hi")]  # 2 chars
      system = "Be helpful"  # 10 chars
      # Total: 12 chars -> 3 tokens

      stats = Context.stats(messages, system)
      assert stats.char_count == 12
      assert stats.estimated_tokens == 3
    end

    test "chars_per_token approximation for English text" do
      # English text typically has ~4 chars per token
      english_text = "The quick brown fox jumps over the lazy dog."
      messages = [Mocks.user_message(english_text)]

      stats = Context.stats(messages, nil)
      # 44 characters -> 11 estimated tokens
      assert stats.estimated_tokens == 11
    end

    test "chars_per_token approximation for code" do
      code_text = "def foo(x, y):\n    return x + y"
      messages = [Mocks.user_message(code_text)]

      stats = Context.stats(messages, nil)
      # Code often has shorter tokens, but our estimate is conservative
      assert stats.char_count == String.length(code_text)
      assert stats.estimated_tokens == div(String.length(code_text), 4)
    end
  end

  # ============================================================================
  # Edge Cases: Telemetry emission validation
  # ============================================================================

  describe "telemetry emission validation" do
    test "estimate_size emits telemetry with correct measurements", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :size]], handler_id, collector)

      messages = [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("World")
      ]

      Context.estimate_size(messages, "System")

      events = get_events(collector)
      detach_telemetry(handler_id)

      assert length(events) == 1
      {event_name, measurements, metadata} = hd(events)

      assert event_name == [:agent_core, :context, :size]
      assert measurements.char_count == 16  # 5 + 5 + 6
      assert measurements.message_count == 2
      assert metadata.has_system_prompt == true
    end

    test "estimate_size emits telemetry with has_system_prompt: false", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :size]], handler_id, collector)

      messages = [Mocks.user_message("Test")]
      Context.estimate_size(messages, nil)

      events = get_events(collector)
      detach_telemetry(handler_id)

      {_event_name, _measurements, metadata} = hd(events)
      assert metadata.has_system_prompt == false
    end

    test "check_size emits warning telemetry with correct level", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :warning]], handler_id, collector)

      messages = [Mocks.user_message("Hello")]
      Context.check_size(messages, nil, warning_threshold: 3, critical_threshold: 100, log: false)

      events = get_events(collector)
      detach_telemetry(handler_id)

      # Filter for warning events only
      warning_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :warning] end)
      assert length(warning_events) >= 1

      {_event_name, measurements, metadata} = hd(warning_events)
      assert measurements.char_count == 5
      assert measurements.threshold == 3
      assert metadata.level == :warning
    end

    test "check_size emits critical telemetry with correct level", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :warning]], handler_id, collector)

      messages = [Mocks.user_message("Hello World")]
      Context.check_size(messages, nil, warning_threshold: 3, critical_threshold: 5, log: false)

      events = get_events(collector)
      detach_telemetry(handler_id)

      warning_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :warning] end)
      assert length(warning_events) >= 1

      {_event_name, measurements, metadata} = hd(warning_events)
      assert measurements.char_count == 11
      assert measurements.threshold == 5
      assert metadata.level == :critical
    end

    test "check_size does not emit telemetry when below thresholds", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :warning]], handler_id, collector)

      messages = [Mocks.user_message("Hi")]
      Context.check_size(messages, nil, warning_threshold: 100, critical_threshold: 200, log: false)

      events = get_events(collector)
      detach_telemetry(handler_id)

      warning_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :warning] end)
      assert warning_events == []
    end

    test "truncate emits telemetry when messages are dropped", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :truncated]], handler_id, collector)

      messages =
        for i <- 1..10 do
          Mocks.user_message("Message #{i}")
        end

      {_truncated, dropped} = Context.truncate(messages, max_messages: 3)

      events = get_events(collector)
      detach_telemetry(handler_id)

      if dropped > 0 do
        truncated_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :truncated] end)
        assert length(truncated_events) == 1

        {_event_name, measurements, metadata} = hd(truncated_events)
        assert measurements.dropped_count > 0
        assert measurements.remaining_count > 0
        assert metadata.strategy == :sliding_window
      end
    end

    test "truncate does not emit telemetry when no messages are dropped", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :truncated]], handler_id, collector)

      messages = [Mocks.user_message("Hello")]
      {_truncated, dropped} = Context.truncate(messages, max_messages: 100)

      events = get_events(collector)
      detach_telemetry(handler_id)

      assert dropped == 0
      truncated_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :truncated] end)
      assert truncated_events == []
    end

    test "truncate emits telemetry with bookends strategy", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :truncated]], handler_id, collector)

      messages =
        for i <- 1..10 do
          Mocks.user_message("Message #{i}")
        end

      Context.truncate(messages, max_messages: 4, strategy: :keep_bookends)

      events = get_events(collector)
      detach_telemetry(handler_id)

      truncated_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :truncated] end)
      assert length(truncated_events) == 1

      {_event_name, _measurements, metadata} = hd(truncated_events)
      assert metadata.strategy == :keep_bookends
    end

    test "multiple estimate_size calls emit multiple telemetry events", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :size]], handler_id, collector)

      messages = [Mocks.user_message("Test")]

      Context.estimate_size(messages, nil)
      Context.estimate_size(messages, "System")
      Context.estimate_size(messages, nil)

      events = get_events(collector)
      detach_telemetry(handler_id)

      size_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :size] end)
      assert length(size_events) == 3
    end

    test "stats function also triggers size telemetry", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :size]], handler_id, collector)

      messages = [Mocks.user_message("Hello")]
      Context.stats(messages, "System")

      events = get_events(collector)
      detach_telemetry(handler_id)

      # stats calls estimate_size internally
      size_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :size] end)
      assert length(size_events) >= 1
    end

    test "large_context? also triggers size telemetry", %{handler_id: handler_id, collector: collector} do
      attach_telemetry([[:agent_core, :context, :size]], handler_id, collector)

      messages = [Mocks.user_message("Test")]
      Context.large_context?(messages, nil)

      events = get_events(collector)
      detach_telemetry(handler_id)

      size_events = Enum.filter(events, fn {name, _, _} -> name == [:agent_core, :context, :size] end)
      assert length(size_events) >= 1
    end
  end

  # ============================================================================
  # Edge Cases: Boundary conditions
  # ============================================================================

  describe "boundary conditions" do
    test "max_messages exactly equals message count" do
      messages =
        for i <- 1..5 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, dropped} = Context.truncate(messages, max_messages: 5)
      assert truncated == messages
      assert dropped == 0
    end

    test "max_chars exactly equals total char count" do
      messages = [
        Mocks.user_message("AB"),
        Mocks.assistant_message("CD")
      ]
      # Total: 4 chars

      {truncated, dropped} = Context.truncate(messages, max_chars: 4)
      assert truncated == messages
      assert dropped == 0
    end

    test "max_messages one less than message count" do
      messages =
        for i <- 1..5 do
          Mocks.user_message("Msg #{i}")
        end

      {truncated, _dropped} = Context.truncate(messages, max_messages: 4)

      # With keep_first_user, might keep first + last 4 - 1 = 5 total, so 0 dropped
      # Actually, sliding window with keep_first_user reserves first user
      # So we get first user + as many recent as fit in remaining slots
      assert length(truncated) <= 5
    end

    test "negative-like behavior: max_messages much larger than list" do
      messages = [Mocks.user_message("Solo")]

      {truncated, dropped} = Context.truncate(messages, max_messages: 1_000_000)
      assert truncated == messages
      assert dropped == 0
    end

    test "truncate with both limits being restrictive" do
      messages = [
        Mocks.user_message("A"),
        Mocks.user_message("B"),
        Mocks.user_message("C"),
        Mocks.user_message("D"),
        Mocks.user_message("E")
      ]

      # max_messages: 3, max_chars: 3
      # First user "A" reserved (1 char), leaves 2 chars for 2 messages max
      {truncated, dropped} = Context.truncate(messages, max_messages: 3, max_chars: 3)

      assert dropped >= 2
      assert length(truncated) <= 3
    end

    test "sliding window with first user message already in recent set" do
      messages = [
        Mocks.assistant_message("Pre-response"),
        Mocks.user_message("User query"),
        Mocks.assistant_message("Response")
      ]

      {truncated, dropped} = Context.truncate(messages, max_messages: 3)

      # All messages fit, first user at index 1 is included
      assert truncated == messages
      assert dropped == 0
    end
  end

  # ============================================================================
  # Edge Cases: Content type variations
  # ============================================================================

  describe "content type variations" do
    test "message with multiple content blocks of same type" do
      msg = %{
        role: :assistant,
        content: [
          %{type: :text, text: "Hello"},
          %{type: :text, text: " "},
          %{type: :text, text: "World"}
        ]
      }

      size = Context.estimate_size([msg], nil)
      assert size == 11  # "Hello" + " " + "World"
    end

    test "message with all supported content block types" do
      msg = %{
        role: :assistant,
        content: [
          %{type: :text, text: "Text"},
          %{type: :thinking, thinking: "Think"},
          %{type: :tool_call, arguments: %{"a" => 1}},
          %{type: :image}
        ]
      }

      size = Context.estimate_size([msg], nil)
      # "Text" (4) + "Think" (5) + JSON {"a":1} (7) + image (100) = 116
      assert size > 100  # At least image size
    end

    test "tool_call with complex nested arguments" do
      msg = %{
        role: :assistant,
        content: [
          %{
            type: :tool_call,
            arguments: %{
              "nested" => %{
                "level1" => %{
                  "level2" => [1, 2, 3, %{"deep" => "value"}]
                }
              },
              "array" => ["a", "b", "c"]
            }
          }
        ]
      }

      size = Context.estimate_size([msg], nil)
      assert size > 0
    end

    test "tool_call with empty arguments" do
      msg = %{
        role: :assistant,
        content: [%{type: :tool_call, arguments: %{}}]
      }

      size = Context.estimate_size([msg], nil)
      assert size == 2  # "{}"
    end

    test "tool_call with non-serializable arguments fallback" do
      # This tests the rescue branch in map_size_estimate
      msg = %{
        role: :assistant,
        content: [%{type: :tool_call, arguments: %{pid: self()}}]
      }

      size = Context.estimate_size([msg], nil)
      # Falls back to 50 when JSON encoding fails
      assert size == 50
    end

    test "tool_call with nil arguments" do
      msg = %{
        role: :assistant,
        content: [%{type: :tool_call, arguments: nil}]
      }

      size = Context.estimate_size([msg], nil)
      assert size == 0
    end

    test "multiple images count correctly" do
      msg = %{
        role: :assistant,
        content: [
          %{type: :image},
          %{type: :image},
          %{type: :image}
        ]
      }

      size = Context.estimate_size([msg], nil)
      assert size == 300  # 3 * 100
    end
  end
end
