defmodule AgentCore.ContextPropertyTest do
  @moduledoc """
  Property-based tests for AgentCore.Context module.

  Tests invariants that should hold for any input:
  - Size estimation is always non-negative
  - Truncation never increases message count
  - Truncation preserves message order
  - Stats are consistent with estimate_size
  - Token estimation is proportional to char count
  - Unicode handling works correctly
  - Large messages are handled properly
  - System prompt edge cases are covered
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  import StreamData

  alias AgentCore.Context
  alias AgentCore.Test.Mocks

  # ============================================================================
  # Generators
  # ============================================================================

  # Basic printable string content
  defp message_content do
    one_of([
      # Simple text content
      string(:printable, max_length: 500),
      # Empty content
      constant(""),
      # Content with newlines
      map(list_of(string(:printable, max_length: 50), max_length: 10), fn lines ->
        Enum.join(lines, "\n")
      end)
    ])
  end

  # Unicode string content with various character sets
  defp unicode_content do
    one_of([
      # ASCII only
      string(:ascii, max_length: 200),
      # Printable characters
      string(:printable, max_length: 200),
      # UTF-8 with specific ranges
      map(list_of(utf8_char(), min_length: 1, max_length: 100), &Enum.join/1),
      # Mixed ASCII and unicode
      map({string(:ascii, max_length: 50), unicode_word(), string(:ascii, max_length: 50)}, fn {a, u, b} ->
        a <> u <> b
      end)
    ])
  end

  # Generate a single UTF-8 character
  defp utf8_char do
    one_of([
      # Basic Latin
      integer(?a..?z),
      # CJK characters (common Chinese/Japanese/Korean)
      integer(0x4E00..0x4FFF),
      # Cyrillic
      integer(0x0400..0x04FF),
      # Greek
      integer(0x0370..0x03FF),
      # Emoji (common ones)
      member_of([0x1F600, 0x1F601, 0x1F602, 0x1F603, 0x1F604, 0x1F605,
                 0x1F389, 0x1F38A, 0x1F38B, 0x2764, 0x2665, 0x2666])
    ])
    |> map(fn codepoint -> <<codepoint::utf8>> end)
  end

  # Generate a unicode word
  defp unicode_word do
    one_of([
      constant(""),
      constant("hello"),
      constant("world"),
      # Japanese
      constant("\u3053\u3093\u306B\u3061\u306F"),
      # Chinese
      constant("\u4E16\u754C"),
      # Korean
      constant("\uC548\uB155"),
      # Russian
      constant("\u041F\u0440\u0438\u0432\u0435\u0442"),
      # Arabic
      constant("\u0645\u0631\u062D\u0628\u0627"),
      # Emoji sequences
      constant("\u{1F600}\u{1F601}\u{1F602}"),
      constant("\u{1F389}\u{1F38A}")
    ])
  end

  defp role do
    member_of([:user, :assistant, :system, :tool_result])
  end

  defp message do
    fixed_map(%{
      role: role(),
      content: message_content()
    })
  end

  defp unicode_message do
    fixed_map(%{
      role: role(),
      content: unicode_content()
    })
  end

  defp message_list do
    list_of(message(), max_length: 50)
  end

  defp unicode_message_list do
    list_of(unicode_message(), max_length: 30)
  end

  defp system_prompt do
    one_of([
      constant(nil),
      string(:printable, max_length: 200)
    ])
  end

  defp unicode_system_prompt do
    one_of([
      constant(nil),
      unicode_content()
    ])
  end

  # Large content generator for stress testing
  defp large_content do
    one_of([
      # Long single line
      map(integer(1000..5000), fn len -> String.duplicate("x", len) end),
      # Many short lines
      map(list_of(string(:printable, max_length: 80), min_length: 50, max_length: 100), fn lines ->
        Enum.join(lines, "\n")
      end),
      # Mixed large content
      map({integer(500..1000), integer(500..1000)}, fn {a, b} ->
        String.duplicate("a", a) <> "\n" <> String.duplicate("b", b)
      end)
    ])
  end

  defp large_message do
    fixed_map(%{
      role: role(),
      content: large_content()
    })
  end

  # Content block generators for more complex message structures
  defp text_content_block do
    map(string(:printable, max_length: 100), fn text ->
      %{type: :text, text: text}
    end)
  end

  defp thinking_content_block do
    map(string(:printable, max_length: 100), fn text ->
      %{type: :thinking, thinking: text}
    end)
  end

  defp tool_call_content_block do
    map({string(:alphanumeric, min_length: 1, max_length: 20), string(:printable, max_length: 50)}, fn {key, value} ->
      %{type: :tool_call, arguments: %{key => value}}
    end)
  end

  defp image_content_block do
    constant(%{type: :image})
  end

  defp content_block do
    one_of([
      text_content_block(),
      thinking_content_block(),
      tool_call_content_block(),
      image_content_block()
    ])
  end

  defp content_block_list do
    list_of(content_block(), min_length: 1, max_length: 5)
  end

  defp message_with_blocks do
    map({role(), content_block_list()}, fn {r, blocks} ->
      %{role: r, content: blocks}
    end)
  end

  defp truncation_strategy do
    member_of([:sliding_window, :keep_bookends])
  end

  # ============================================================================
  # Size Estimation Properties
  # ============================================================================

  describe "estimate_size properties" do
    property "estimate_size is always non-negative" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        size = Context.estimate_size(messages, prompt)
        assert size >= 0
      end
    end

    property "estimate_size with empty messages and nil prompt is zero" do
      assert Context.estimate_size([], nil) == 0
    end

    property "estimate_size is additive - system prompt adds to message size" do
      check all messages <- message_list(),
                prompt_text <- string(:printable, min_length: 1, max_length: 100) do
        size_without_prompt = Context.estimate_size(messages, nil)
        size_with_prompt = Context.estimate_size(messages, prompt_text)

        # Size with prompt should be exactly prompt length more
        expected_size = size_without_prompt + String.length(prompt_text)
        assert size_with_prompt == expected_size
      end
    end

    property "estimate_size increases monotonically with messages" do
      check all messages <- list_of(message(), min_length: 2, max_length: 20) do
        sizes =
          messages
          |> Enum.scan([], fn msg, acc -> acc ++ [msg] end)
          |> Enum.map(&Context.estimate_size(&1, nil))

        # Each size should be >= previous size
        sizes
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [prev, curr] ->
          assert curr >= prev
        end)
      end
    end

    property "estimate_size equals sum of individual message sizes" do
      check all messages <- list_of(message(), min_length: 1, max_length: 20) do
        total_size = Context.estimate_size(messages, nil)

        # Sum of individual message sizes
        individual_sum =
          messages
          |> Enum.map(fn msg -> Context.estimate_size([msg], nil) end)
          |> Enum.sum()

        assert total_size == individual_sum
      end
    end

    property "estimate_size handles messages with content blocks" do
      check all msg <- message_with_blocks() do
        size = Context.estimate_size([msg], nil)
        assert size >= 0
      end
    end

    property "estimate_size is consistent across multiple calls" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        size1 = Context.estimate_size(messages, prompt)
        size2 = Context.estimate_size(messages, prompt)
        size3 = Context.estimate_size(messages, prompt)

        assert size1 == size2
        assert size2 == size3
      end
    end
  end

  # ============================================================================
  # Token Estimation Properties
  # ============================================================================

  describe "estimate_tokens properties" do
    property "estimate_tokens is always non-negative" do
      check all char_count <- integer(0..1_000_000) do
        tokens = Context.estimate_tokens(char_count)
        assert tokens >= 0
      end
    end

    property "estimate_tokens is proportional to char count (divide by 4)" do
      check all char_count <- integer(0..1_000_000) do
        tokens = Context.estimate_tokens(char_count)
        # Should be char_count / 4 (integer division)
        assert tokens == div(char_count, 4)
      end
    end

    property "estimate_tokens is monotonically increasing" do
      check all counts <- list_of(integer(0..100_000), min_length: 2, max_length: 10) do
        sorted = Enum.sort(counts)
        tokens = Enum.map(sorted, &Context.estimate_tokens/1)

        tokens
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [prev, curr] ->
          assert curr >= prev
        end)
      end
    end

    property "estimate_tokens handles edge cases" do
      # Zero chars
      assert Context.estimate_tokens(0) == 0

      # Small values
      assert Context.estimate_tokens(1) == 0
      assert Context.estimate_tokens(2) == 0
      assert Context.estimate_tokens(3) == 0
      assert Context.estimate_tokens(4) == 1

      # Boundary values
      check all n <- integer(0..100) do
        tokens = Context.estimate_tokens(n)
        assert tokens == div(n, 4)
        assert tokens * 4 <= n
        assert (tokens + 1) * 4 > n
      end
    end
  end

  # ============================================================================
  # Truncation Properties
  # ============================================================================

  describe "truncate properties" do
    property "truncate never increases message count" do
      check all messages <- message_list(),
                max_messages <- integer(1..200),
                max_chars <- integer(100..100_000) do
        {truncated, _dropped} = Context.truncate(messages, max_messages: max_messages, max_chars: max_chars)

        assert length(truncated) <= length(messages)
      end
    end

    property "truncate dropped count equals original minus truncated" do
      check all messages <- message_list(),
                max_messages <- integer(1..100) do
        {truncated, dropped} = Context.truncate(messages, max_messages: max_messages)

        assert dropped == length(messages) - length(truncated)
      end
    end

    property "truncate respects max_messages limit" do
      check all messages <- list_of(message(), min_length: 1, max_length: 100),
                max_messages <- integer(1..50) do
        {truncated, _dropped} = Context.truncate(messages, max_messages: max_messages)

        # Truncated should not exceed max_messages (may be less if original was smaller)
        # Note: keep_first_user may add one extra message
        assert length(truncated) <= max_messages + 1
      end
    end

    property "truncate with large limits returns original messages" do
      check all messages <- list_of(message(), max_length: 20) do
        # Set limits much larger than messages
        {truncated, dropped} = Context.truncate(messages, max_messages: 1000, max_chars: 10_000_000)

        assert truncated == messages
        assert dropped == 0
      end
    end

    property "truncate returns subset of original messages (sliding_window)" do
      check all messages <- list_of(message(), min_length: 3, max_length: 30),
                max_messages <- integer(2..10) do
        {truncated, _dropped} = Context.truncate(messages,
          max_messages: max_messages,
          strategy: :sliding_window,
          keep_first_user: false
        )

        # All truncated messages should be present in original (subset property)
        Enum.each(truncated, fn msg ->
          assert Enum.member?(messages, msg),
            "Truncated message not found in original"
        end)

        # Truncated count should be <= original
        assert length(truncated) <= length(messages)
      end
    end

    property "truncate with keep_first_user preserves first user message" do
      check all messages <- list_of(message(), min_length: 5, max_length: 30),
                max_messages <- integer(3..10) do
        # Ensure there's at least one user message
        messages_with_user = [%{role: :user, content: "first user message"} | messages]

        {truncated, _dropped} = Context.truncate(messages_with_user,
          max_messages: max_messages,
          keep_first_user: true
        )

        if length(truncated) > 0 do
          # First user message should be preserved if truncation happened
          first_user_in_original = Enum.find(messages_with_user, &(&1.role == :user))
          first_user_in_truncated = Enum.find(truncated, &(&1.role == :user))

          if first_user_in_original do
            assert first_user_in_truncated == first_user_in_original
          end
        end
      end
    end

    property "truncate bookends strategy keeps first and last messages" do
      check all messages <- list_of(message(), min_length: 10, max_length: 30),
                max_messages <- integer(4..8) do
        {truncated, _dropped} = Context.truncate(messages,
          max_messages: max_messages,
          strategy: :keep_bookends
        )

        if length(truncated) >= 2 and length(messages) >= 2 do
          # First message should match
          assert List.first(truncated) == List.first(messages)
          # Last message should match
          assert List.last(truncated) == List.last(messages)
        end
      end
    end

    property "truncate preserves relative message order within result" do
      check all messages <- list_of(message(), min_length: 5, max_length: 30),
                max_messages <- integer(2..10),
                strategy <- truncation_strategy() do
        # Add unique identifiers to track order
        indexed_messages =
          messages
          |> Enum.with_index()
          |> Enum.map(fn {msg, idx} -> Map.put(msg, :_test_index, idx) end)

        {truncated, _dropped} = Context.truncate(indexed_messages,
          max_messages: max_messages,
          strategy: strategy,
          keep_first_user: false
        )

        # Extract indices from truncated messages
        indices = Enum.map(truncated, & &1._test_index)

        # Indices should be sorted (truncated messages maintain original relative order)
        assert indices == Enum.sort(indices),
          "Expected indices #{inspect(Enum.sort(indices))}, got #{inspect(indices)}"
      end
    end

    property "truncate always produces valid (non-nil) messages" do
      check all messages <- message_list(),
                max_messages <- integer(0..50),
                max_chars <- integer(0..10_000) do
        {truncated, _dropped} = Context.truncate(messages,
          max_messages: max_messages,
          max_chars: max_chars
        )

        # All messages should be valid maps with role
        Enum.each(truncated, fn msg ->
          assert is_map(msg)
          assert Map.has_key?(msg, :role)
        end)
      end
    end

    property "idempotent truncation - truncating already-truncated messages is stable" do
      check all messages <- list_of(message(), min_length: 5, max_length: 30),
                max_messages <- integer(2..10) do
        opts = [max_messages: max_messages, keep_first_user: false]

        {truncated1, _} = Context.truncate(messages, opts)
        {truncated2, dropped2} = Context.truncate(truncated1, opts)

        # Second truncation should not change anything
        assert truncated1 == truncated2
        assert dropped2 == 0
      end
    end

    property "truncate with both limits applies stricter one" do
      check all messages <- list_of(message(), min_length: 10, max_length: 30),
                max_messages <- integer(5..15),
                max_chars <- integer(10..1000) do
        {truncated, _dropped} = Context.truncate(messages,
          max_messages: max_messages,
          max_chars: max_chars,
          keep_first_user: false
        )

        # Result should satisfy both constraints (or be minimal)
        assert length(truncated) <= max_messages
        # Note: max_chars is soft limit with keep_first_user, but should be respected otherwise
      end
    end
  end

  # ============================================================================
  # Large Context Detection Properties
  # ============================================================================

  describe "large_context? properties" do
    property "large_context? returns boolean" do
      check all messages <- message_list(),
                prompt <- system_prompt(),
                threshold <- integer(1..1_000_000) do
        result = Context.large_context?(messages, prompt, threshold: threshold)
        assert is_boolean(result)
      end
    end

    property "large_context? is consistent with estimate_size" do
      check all messages <- message_list(),
                prompt <- system_prompt(),
                threshold <- integer(100..100_000) do
        size = Context.estimate_size(messages, prompt)
        is_large = Context.large_context?(messages, prompt, threshold: threshold)

        assert is_large == (size > threshold)
      end
    end

    property "empty context is never large (with any reasonable threshold)" do
      check all threshold <- integer(1..1_000_000) do
        refute Context.large_context?([], nil, threshold: threshold)
      end
    end

    property "context becomes large when threshold decreases below size" do
      check all messages <- list_of(message(), min_length: 1, max_length: 10) do
        size = Context.estimate_size(messages, nil)

        if size > 0 do
          # Should be large when threshold is less than size
          assert Context.large_context?(messages, nil, threshold: size - 1)
          # Should not be large when threshold equals size
          refute Context.large_context?(messages, nil, threshold: size)
          # Should not be large when threshold is greater than size
          refute Context.large_context?(messages, nil, threshold: size + 1)
        end
      end
    end
  end

  # ============================================================================
  # Check Size Properties
  # ============================================================================

  describe "check_size properties" do
    property "check_size returns :ok, :warning, or :critical" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        result = Context.check_size(messages, prompt, log: false)
        assert result in [:ok, :warning, :critical]
      end
    end

    property "check_size is consistent with thresholds" do
      check all messages <- message_list(),
                prompt <- system_prompt(),
                warning <- integer(100..10_000),
                critical <- integer(10_001..100_000) do
        size = Context.estimate_size(messages, prompt)
        result = Context.check_size(messages, prompt,
          warning_threshold: warning,
          critical_threshold: critical,
          log: false
        )

        cond do
          size > critical -> assert result == :critical
          size > warning -> assert result == :warning
          true -> assert result == :ok
        end
      end
    end

    property "check_size critical takes precedence over warning" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        size = Context.estimate_size(messages, prompt)

        # Set thresholds so size exceeds both
        if size > 2 do
          result = Context.check_size(messages, prompt,
            warning_threshold: 1,
            critical_threshold: 2,
            log: false
          )

          assert result == :critical
        end
      end
    end

    property "check_size is idempotent" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        result1 = Context.check_size(messages, prompt, log: false)
        result2 = Context.check_size(messages, prompt, log: false)
        result3 = Context.check_size(messages, prompt, log: false)

        assert result1 == result2
        assert result2 == result3
      end
    end
  end

  # ============================================================================
  # Stats Properties
  # ============================================================================

  describe "stats properties" do
    property "stats returns consistent values" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        stats = Context.stats(messages, prompt)

        # Message count should match
        assert stats.message_count == length(messages)

        # Char count should match estimate_size
        assert stats.char_count == Context.estimate_size(messages, prompt)

        # Tokens should match estimate
        assert stats.estimated_tokens == Context.estimate_tokens(stats.char_count)

        # By_role counts should sum to message count
        role_sum = stats.by_role |> Map.values() |> Enum.sum()
        assert role_sum == length(messages)

        # System prompt chars should be correct
        expected_prompt_chars = if prompt, do: String.length(prompt), else: 0
        assert stats.system_prompt_chars == expected_prompt_chars
      end
    end

    property "stats by_role contains all roles present in messages" do
      check all messages <- list_of(message(), min_length: 1, max_length: 20) do
        stats = Context.stats(messages, nil)

        messages_roles = messages |> Enum.map(& &1.role) |> Enum.uniq() |> MapSet.new()
        stats_roles = stats.by_role |> Map.keys() |> MapSet.new()

        assert MapSet.equal?(messages_roles, stats_roles)
      end
    end

    property "stats by_role counts are accurate" do
      check all messages <- list_of(message(), min_length: 1, max_length: 30) do
        stats = Context.stats(messages, nil)

        # Manually count roles
        expected_by_role =
          messages
          |> Enum.group_by(& &1.role)
          |> Enum.map(fn {role, msgs} -> {role, length(msgs)} end)
          |> Map.new()

        assert stats.by_role == expected_by_role
      end
    end

    property "stats is consistent across multiple calls" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        stats1 = Context.stats(messages, prompt)
        stats2 = Context.stats(messages, prompt)

        assert stats1 == stats2
      end
    end

    property "stats estimated_tokens is always less than or equal to char_count" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        stats = Context.stats(messages, prompt)

        # Tokens * 4 should be <= char_count (since we divide by 4)
        assert stats.estimated_tokens * 4 <= stats.char_count + 3
      end
    end
  end

  # ============================================================================
  # Make Transform Properties
  # ============================================================================

  describe "make_transform properties" do
    property "make_transform returns a function that truncates" do
      check all messages <- list_of(message(), min_length: 5, max_length: 30),
                max_messages <- integer(2..10) do
        transform = Context.make_transform(max_messages: max_messages, warn_on_truncation: false)

        {:ok, truncated} = transform.(messages, nil)

        # Should respect the limit
        assert length(truncated) <= max_messages + 1  # +1 for possible first user preservation
        assert length(truncated) <= length(messages)
      end
    end

    property "make_transform returns {:ok, messages} tuple" do
      check all messages <- message_list(),
                max_messages <- integer(1..100) do
        transform = Context.make_transform(max_messages: max_messages, warn_on_truncation: false)

        result = transform.(messages, nil)

        assert {:ok, _truncated} = result
      end
    end

    property "make_transform with signal parameter works" do
      check all messages <- message_list() do
        transform = Context.make_transform(warn_on_truncation: false)
        signal = make_ref()

        {:ok, truncated} = transform.(messages, signal)

        assert is_list(truncated)
      end
    end

    property "make_transform preserves subset relationship" do
      check all messages <- list_of(message(), min_length: 5, max_length: 20),
                max_messages <- integer(2..10) do
        transform = Context.make_transform(
          max_messages: max_messages,
          keep_first_user: false,
          warn_on_truncation: false
        )

        {:ok, truncated} = transform.(messages, nil)

        # All truncated messages should be in original
        Enum.each(truncated, fn msg ->
          assert Enum.member?(messages, msg)
        end)
      end
    end
  end

  # ============================================================================
  # Unicode and Special Character Properties
  # ============================================================================

  describe "unicode handling properties" do
    property "estimate_size handles unicode strings correctly" do
      check all messages <- unicode_message_list(),
                prompt <- unicode_system_prompt() do
        size = Context.estimate_size(messages, prompt)
        assert size >= 0

        # Size should equal sum of grapheme counts
        expected_message_size =
          messages
          |> Enum.map(fn msg ->
            case msg.content do
              content when is_binary(content) -> String.length(content)
              _ -> 0
            end
          end)
          |> Enum.sum()

        expected_prompt_size = if prompt, do: String.length(prompt), else: 0
        assert size == expected_message_size + expected_prompt_size
      end
    end

    property "truncate handles unicode messages" do
      check all messages <- unicode_message_list(),
                max_messages <- integer(1..20) do
        {truncated, dropped} = Context.truncate(messages, max_messages: max_messages)

        assert is_list(truncated)
        assert dropped >= 0
        assert length(truncated) + dropped == length(messages)
      end
    end

    property "stats handles unicode content" do
      check all messages <- unicode_message_list(),
                prompt <- unicode_system_prompt() do
        stats = Context.stats(messages, prompt)

        assert stats.message_count == length(messages)
        assert stats.char_count >= 0
        assert stats.estimated_tokens >= 0
      end
    end

    property "unicode string length uses grapheme count" do
      # Test specific unicode strings
      # Note: String.length/1 counts graphemes, not codepoints
      # "a\u0301" (a + combining accent) is 1 grapheme in modern Elixir
      test_strings = [
        {"hello", 5},
        {"\u3053\u3093\u306B\u3061\u306F", 5},  # Japanese hiragana
        {"\u{1F600}", 1},  # Single emoji
        {"\u{1F600}\u{1F601}\u{1F602}", 3},  # Multiple emoji
        {"a\u0301", 1},  # 'a' with combining accent = 1 grapheme
        {"\u4E16\u754C", 2},  # Chinese "world"
        {"\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", 1},  # Family emoji (single grapheme)
      ]

      for {str, expected_len} <- test_strings do
        messages = [%{role: :user, content: str}]
        size = Context.estimate_size(messages, nil)
        assert size == expected_len, "Expected #{expected_len} for #{inspect(str)}, got #{size}"
      end
    end

    property "empty and whitespace unicode strings handled" do
      check all whitespace <- member_of(["", " ", "\t", "\n", "  ", "\n\n", "\t\t"]) do
        messages = [%{role: :user, content: whitespace}]
        size = Context.estimate_size(messages, nil)

        assert size == String.length(whitespace)
      end
    end
  end

  # ============================================================================
  # Large Message Handling Properties
  # ============================================================================

  describe "large message handling properties" do
    property "estimate_size handles large messages" do
      check all msg <- large_message() do
        size = Context.estimate_size([msg], nil)
        assert size >= 0

        # Size should equal content length
        expected_size = String.length(msg.content)
        assert size == expected_size
      end
    end

    property "truncate handles large messages gracefully" do
      check all messages <- list_of(large_message(), min_length: 3, max_length: 10),
                max_chars <- integer(100..10_000) do
        {truncated, dropped} = Context.truncate(messages, max_chars: max_chars)

        assert is_list(truncated)
        assert dropped >= 0
        assert length(truncated) <= length(messages)
      end
    end

    property "stats handles large messages" do
      check all msg <- large_message() do
        stats = Context.stats([msg], nil)

        assert stats.message_count == 1
        assert stats.char_count == String.length(msg.content)
        assert stats.estimated_tokens == div(stats.char_count, 4)
      end
    end

    property "large_context? detects large messages" do
      check all msg <- large_message() do
        size = Context.estimate_size([msg], nil)

        # Should be large when threshold is less than size
        if size > 100 do
          assert Context.large_context?([msg], nil, threshold: 100)
        end

        # Should not be large when threshold exceeds size
        refute Context.large_context?([msg], nil, threshold: size + 1)
      end
    end
  end

  # ============================================================================
  # System Prompt Edge Cases Properties
  # ============================================================================

  describe "system prompt edge cases" do
    property "nil system prompt contributes zero to size" do
      check all messages <- message_list() do
        size_nil = Context.estimate_size(messages, nil)
        size_empty = Context.estimate_size(messages, "")

        assert size_nil == size_empty
      end
    end

    property "system prompt size is exact string length" do
      check all prompt <- string(:printable, min_length: 1, max_length: 500) do
        size_with = Context.estimate_size([], prompt)
        size_without = Context.estimate_size([], nil)

        assert size_with == size_without + String.length(prompt)
        assert size_with == String.length(prompt)
      end
    end

    property "system prompt with special characters" do
      check all prompt <- unicode_content() do
        size = Context.estimate_size([], prompt)
        assert size == String.length(prompt)
      end
    end

    property "very long system prompts handled correctly" do
      check all base <- string(:printable, max_length: 100),
                multiplier <- integer(10..100) do
        long_prompt = String.duplicate(base, multiplier)
        size = Context.estimate_size([], long_prompt)

        assert size == String.length(long_prompt)
      end
    end

    property "system prompt stats accuracy" do
      check all prompt <- string(:printable, max_length: 200) do
        stats = Context.stats([], prompt)

        assert stats.system_prompt_chars == String.length(prompt)
        assert stats.char_count == String.length(prompt)
        assert stats.message_count == 0
      end
    end

    property "check_size considers system prompt in threshold" do
      check all prompt <- string(:printable, min_length: 100, max_length: 500) do
        prompt_len = String.length(prompt)

        # With threshold below prompt length, should trigger warning
        result = Context.check_size([], prompt,
          warning_threshold: prompt_len - 1,
          critical_threshold: prompt_len * 2,
          log: false
        )

        assert result == :warning
      end
    end
  end

  # ============================================================================
  # Content Block Properties
  # ============================================================================

  describe "content block properties" do
    property "text content blocks contribute text length" do
      check all text <- string(:printable, max_length: 100) do
        msg = %{role: :assistant, content: [%{type: :text, text: text}]}
        size = Context.estimate_size([msg], nil)

        assert size == String.length(text)
      end
    end

    property "thinking content blocks contribute thinking length" do
      check all thinking <- string(:printable, max_length: 100) do
        msg = %{role: :assistant, content: [%{type: :thinking, thinking: thinking}]}
        size = Context.estimate_size([msg], nil)

        assert size == String.length(thinking)
      end
    end

    property "image content blocks contribute fixed size" do
      msg = %{role: :assistant, content: [%{type: :image}]}
      size = Context.estimate_size([msg], nil)

      assert size == 100  # Fixed size for images
    end

    property "multiple content blocks are summed" do
      check all blocks <- content_block_list() do
        msg = %{role: :assistant, content: blocks}
        size = Context.estimate_size([msg], nil)

        assert size >= 0
      end
    end

    property "tool_call arguments contribute to size" do
      check all key <- string(:alphanumeric, min_length: 1, max_length: 20),
                value <- string(:printable, max_length: 50) do
        args = %{key => value}
        msg = %{role: :assistant, content: [%{type: :tool_call, arguments: args}]}
        size = Context.estimate_size([msg], nil)

        # Size should be positive (JSON encoded length)
        assert size > 0
      end
    end

    property "empty tool_call arguments contribute minimal size" do
      msg = %{role: :assistant, content: [%{type: :tool_call, arguments: %{}}]}
      size = Context.estimate_size([msg], nil)

      assert size == 2  # "{}"
    end

    property "nil content in blocks handled gracefully" do
      # Text block with nil
      msg1 = %{role: :assistant, content: [%{type: :text, text: nil}]}
      assert Context.estimate_size([msg1], nil) == 0

      # Thinking block with nil
      msg2 = %{role: :assistant, content: [%{type: :thinking, thinking: nil}]}
      assert Context.estimate_size([msg2], nil) == 0
    end

    property "unknown content block types contribute zero" do
      msg = %{role: :assistant, content: [%{type: :unknown_type, data: "whatever"}]}
      size = Context.estimate_size([msg], nil)

      assert size == 0
    end
  end

  # ============================================================================
  # Message Order Preservation Properties
  # ============================================================================

  describe "message order preservation" do
    property "messages maintain relative order after truncation" do
      check all messages <- list_of(message(), min_length: 5, max_length: 30),
                max_messages <- integer(2..10) do
        # Add unique identifiers to track order
        indexed_messages =
          messages
          |> Enum.with_index()
          |> Enum.map(fn {msg, idx} -> Map.put(msg, :_test_index, idx) end)

        {truncated, _dropped} = Context.truncate(indexed_messages,
          max_messages: max_messages,
          keep_first_user: false
        )

        # Extract indices and verify they're in ascending order
        # This verifies the truncated messages maintain their relative order
        indices = Enum.map(truncated, & &1._test_index)
        assert indices == Enum.sort(indices),
          "Expected indices to be sorted but got #{inspect(indices)}"
      end
    end

    property "sliding window includes recent messages" do
      check all messages <- list_of(message(), min_length: 10, max_length: 30),
                max_messages <- integer(3..8) do
        # Add unique identifiers
        indexed_messages =
          messages
          |> Enum.with_index()
          |> Enum.map(fn {msg, idx} -> Map.put(msg, :_test_index, idx) end)

        {truncated, _dropped} = Context.truncate(indexed_messages,
          max_messages: max_messages,
          strategy: :sliding_window,
          keep_first_user: false
        )

        if length(truncated) > 0 do
          # Truncated messages should include some of the most recent messages
          # (may not be the absolute last due to char limits)
          max_index = Enum.map(truncated, & &1._test_index) |> Enum.max()
          original_max = length(indexed_messages) - 1

          # The max index in truncated should be close to the end of original
          # Allow some flexibility due to char limits
          assert max_index >= original_max - max_messages,
            "Expected recent messages but max index was #{max_index} out of #{original_max}"
        end
      end
    end

    property "bookends keeps first and last messages" do
      check all messages <- list_of(message(), min_length: 10, max_length: 30),
                max_messages <- integer(4..8) do
        {truncated, _dropped} = Context.truncate(messages,
          max_messages: max_messages,
          strategy: :keep_bookends
        )

        if length(truncated) >= 2 do
          assert List.first(truncated) == List.first(messages)
          assert List.last(truncated) == List.last(messages)
        end
      end
    end
  end

  # ============================================================================
  # Invariant Properties (Combined)
  # ============================================================================

  describe "combined invariants" do
    property "truncate then stats gives consistent results" do
      check all messages <- list_of(message(), min_length: 5, max_length: 30),
                max_messages <- integer(2..10) do
        {truncated, dropped} = Context.truncate(messages, max_messages: max_messages)
        stats = Context.stats(truncated, nil)

        # Stats should reflect truncated list
        assert stats.message_count == length(truncated)
        assert stats.message_count == length(messages) - dropped
      end
    end

    property "estimate_size equals stats.char_count" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        size = Context.estimate_size(messages, prompt)
        stats = Context.stats(messages, prompt)

        assert size == stats.char_count
      end
    end

    property "check_size uses estimate_size internally" do
      check all messages <- message_list(),
                prompt <- system_prompt() do
        size = Context.estimate_size(messages, prompt)

        # check_size should use the same size calculation
        result = Context.check_size(messages, prompt,
          warning_threshold: size,
          critical_threshold: size + 1,
          log: false
        )

        # At exactly warning_threshold, should be :ok (uses >)
        assert result == :ok
      end
    end

    property "make_transform produces same result as truncate" do
      check all messages <- list_of(message(), min_length: 5, max_length: 20),
                max_messages <- integer(2..10) do
        opts = [max_messages: max_messages, keep_first_user: false, warn_on_truncation: false]

        {truncated1, _dropped} = Context.truncate(messages, opts)
        transform = Context.make_transform(opts)
        {:ok, truncated2} = transform.(messages, nil)

        assert truncated1 == truncated2
      end
    end

    property "empty list handling is consistent across all functions" do
      # All functions should handle empty lists consistently
      assert Context.estimate_size([], nil) == 0
      assert Context.estimate_size([], "prompt") == 6

      assert Context.estimate_tokens(0) == 0

      refute Context.large_context?([], nil)
      refute Context.large_context?([], nil, threshold: 0)

      assert Context.check_size([], nil, log: false) == :ok

      {truncated, dropped} = Context.truncate([])
      assert truncated == []
      assert dropped == 0

      stats = Context.stats([], nil)
      assert stats.message_count == 0
      assert stats.char_count == 0
      assert stats.estimated_tokens == 0
      assert stats.by_role == %{}

      transform = Context.make_transform(warn_on_truncation: false)
      {:ok, result} = transform.([], nil)
      assert result == []
    end
  end

  # ============================================================================
  # Using Mocks Helper Properties
  # ============================================================================

  describe "mock message compatibility" do
    property "Mocks.user_message creates valid messages" do
      check all content <- string(:printable, max_length: 100) do
        msg = Mocks.user_message(content)
        size = Context.estimate_size([msg], nil)

        assert size == String.length(content)
      end
    end

    property "Mocks.assistant_message creates valid messages" do
      check all content <- string(:printable, max_length: 100) do
        msg = Mocks.assistant_message(content)
        size = Context.estimate_size([msg], nil)

        # Assistant messages have content in list format
        assert size == String.length(content)
      end
    end

    property "Mocks.tool_result_message creates valid messages" do
      check all content <- string(:printable, max_length: 100) do
        msg = Mocks.tool_result_message("call_id", "tool_name", content)
        size = Context.estimate_size([msg], nil)

        assert size == String.length(content)
      end
    end

    property "mixed mock messages work with truncation" do
      check all user_content <- string(:printable, max_length: 50),
                assistant_content <- string(:printable, max_length: 50),
                tool_content <- string(:printable, max_length: 50) do
        messages = [
          Mocks.user_message(user_content),
          Mocks.assistant_message(assistant_content),
          Mocks.tool_result_message("id", "tool", tool_content)
        ]

        {truncated, dropped} = Context.truncate(messages, max_messages: 10)

        assert truncated == messages
        assert dropped == 0
      end
    end
  end

  # ============================================================================
  # Edge Cases Properties
  # ============================================================================

  describe "edge case properties" do
    property "messages with list content blocks are handled" do
      check all text1 <- string(:printable, max_length: 50),
                text2 <- string(:printable, max_length: 50) do
        # Create messages with list content (content blocks)
        messages = [
          %{
            role: :assistant,
            content: [
              %{type: :text, text: text1},
              %{type: :thinking, thinking: text2}
            ]
          }
        ]

        size = Context.estimate_size(messages, nil)

        # Size should include both content blocks
        assert size >= String.length(text1) + String.length(text2)
      end
    end

    property "messages with tool_call content include arguments size" do
      check all arg_key <- string(:alphanumeric, min_length: 1, max_length: 10),
                arg_value <- string(:printable, max_length: 50) do
        args = %{arg_key => arg_value}

        messages = [
          %{
            role: :assistant,
            content: [%{type: :tool_call, arguments: args}]
          }
        ]

        size = Context.estimate_size(messages, nil)

        # Size should be positive (arguments contribute to size)
        assert size > 0
      end
    end

    property "message with nil content handled" do
      msg = %{role: :user, content: nil}
      size = Context.estimate_size([msg], nil)
      assert size == 0
    end

    property "message with missing content key handled" do
      msg = %{role: :user}
      size = Context.estimate_size([msg], nil)
      assert size == 0
    end

    property "message with non-string/list content handled" do
      # Integer content (unexpected)
      msg1 = %{role: :user, content: 12345}
      assert Context.estimate_size([msg1], nil) == 0

      # Atom content (unexpected)
      msg2 = %{role: :user, content: :some_atom}
      assert Context.estimate_size([msg2], nil) == 0

      # Map content (unexpected)
      msg3 = %{role: :user, content: %{nested: "map"}}
      assert Context.estimate_size([msg3], nil) == 0
    end

    property "single message truncation edge cases" do
      check all content <- string(:printable, max_length: 100) do
        messages = [%{role: :user, content: content}]

        # Truncate with max_messages: 1
        {truncated, dropped} = Context.truncate(messages, max_messages: 1)
        assert truncated == messages
        assert dropped == 0

        # Truncate with max_messages: 0 and keep_first_user: true
        {truncated2, dropped2} = Context.truncate(messages, max_messages: 0, keep_first_user: true)
        # First user message preserved
        assert length(truncated2) == 1
        assert dropped2 == 0

        # Truncate with max_messages: 0 and keep_first_user: false
        {truncated3, dropped3} = Context.truncate(messages, max_messages: 0, keep_first_user: false)
        assert truncated3 == []
        assert dropped3 == 1
      end
    end
  end
end
