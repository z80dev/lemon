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
end
