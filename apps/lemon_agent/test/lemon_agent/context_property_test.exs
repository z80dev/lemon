defmodule LemonAgent.ContextPropertyTest do
  @moduledoc """
  Property-based invariants for `LemonAgent.Context`. Example-based cases
  (content block sizes, malformed content, empty and single-message inputs)
  live in `context_test.exs`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  import StreamData

  alias LemonAgent.Context
  alias LemonAgent.Test.Mocks

  # ============================================================================
  # Generators
  # ============================================================================

  defp utf8_text do
    one_of([
      integer(?a..?z),
      integer(0x4E00..0x4FFF),
      integer(0x0400..0x04FF),
      member_of([0x1F600, 0x2764])
    ])
    |> map(&<<&1::utf8>>)
    |> list_of(max_length: 50)
    |> map(&Enum.join/1)
  end

  defp message_content do
    one_of([
      string(:printable, max_length: 500),
      utf8_text(),
      map(list_of(string(:printable, max_length: 50), max_length: 10), &Enum.join(&1, "\n"))
    ])
  end

  defp message do
    fixed_map(%{
      role: member_of([:user, :assistant, :system, :tool_result]),
      content: message_content()
    })
  end

  defp message_list(opts \\ []), do: list_of(message(), Keyword.put_new(opts, :max_length, 50))

  defp system_prompt,
    do: one_of([constant(nil), string(:printable, max_length: 200), utf8_text()])

  defp truncation_strategy, do: member_of([:sliding_window, :keep_bookends])

  defp indexed(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} -> Map.put(message, :_test_index, index) end)
  end

  # ============================================================================
  # Size Estimation
  # ============================================================================

  describe "size estimation" do
    property "estimate_size sums grapheme lengths of message content and the system prompt" do
      check all(messages <- message_list(), prompt <- system_prompt()) do
        size = Context.estimate_size(messages, prompt)

        message_sizes = Enum.map(messages, &Context.estimate_size([&1], nil))
        assert message_sizes == Enum.map(messages, &String.length(&1.content))
        assert size == Enum.sum(message_sizes) + String.length(prompt || "")
        assert Context.estimate_size(messages, nil) == Context.estimate_size(messages, "")
      end
    end

    property "estimate_tokens is char count divided by four" do
      check all(char_count <- integer(0..1_000_000)) do
        assert Context.estimate_tokens(char_count) == div(char_count, 4)
      end
    end

    property "stats agree with estimate_size, estimate_tokens and per-role counts" do
      check all(messages <- message_list(), prompt <- system_prompt()) do
        stats = Context.stats(messages, prompt)

        assert stats.message_count == length(messages)
        assert stats.char_count == Context.estimate_size(messages, prompt)
        assert stats.estimated_tokens == Context.estimate_tokens(stats.char_count)
        assert stats.system_prompt_chars == String.length(prompt || "")
        assert stats.by_role == Enum.frequencies_by(messages, & &1.role)
      end
    end

    property "large_context? and check_size classify the estimated size against thresholds" do
      check all(
              messages <- message_list(),
              prompt <- system_prompt(),
              warning <- integer(0..10_000),
              critical_gap <- integer(0..10_000)
            ) do
        size = Context.estimate_size(messages, prompt)
        critical = warning + critical_gap

        assert Context.large_context?(messages, prompt, threshold: warning) == size > warning

        expected =
          cond do
            size > critical -> :critical
            size > warning -> :warning
            true -> :ok
          end

        assert Context.check_size(messages, prompt,
                 warning_threshold: warning,
                 critical_threshold: critical,
                 log: false
               ) == expected
      end
    end
  end

  # ============================================================================
  # Truncation
  # ============================================================================

  describe "truncation" do
    property "truncate returns an ordered, duplicate-free subsequence and counts every drop" do
      check all(
              messages <- message_list(),
              max_messages <- integer(0..60),
              max_chars <- integer(0..20_000),
              strategy <- truncation_strategy(),
              keep_first_user <- boolean()
            ) do
        messages = indexed(messages)

        {truncated, dropped} =
          Context.truncate(messages,
            max_messages: max_messages,
            max_chars: max_chars,
            strategy: strategy,
            keep_first_user: keep_first_user
          )

        indices = Enum.map(truncated, & &1._test_index)
        assert indices == Enum.uniq(Enum.sort(indices))
        assert Enum.all?(truncated, &(&1 in messages))
        assert dropped == length(messages) - length(truncated)
      end
    end

    property "truncation within both limits keeps everything and is idempotent" do
      check all(
              messages <- message_list(min_length: 5, max_length: 30),
              max_messages <- integer(2..10),
              strategy <- truncation_strategy()
            ) do
        assert {^messages, 0} =
                 Context.truncate(messages, max_messages: 1000, max_chars: 10_000_000)

        opts = [max_messages: max_messages, keep_first_user: false, strategy: strategy]
        {truncated, _} = Context.truncate(messages, opts)
        assert {^truncated, 0} = Context.truncate(truncated, opts)
      end
    end

    property "sliding window keeps the newest messages within max_messages" do
      check all(
              messages <- message_list(min_length: 10, max_length: 30),
              max_messages <- integer(3..8)
            ) do
        messages = indexed(messages)

        {truncated, _} =
          Context.truncate(messages,
            max_messages: max_messages,
            strategy: :sliding_window,
            keep_first_user: false
          )

        assert length(truncated) <= max_messages

        assert Enum.max(Enum.map(truncated, & &1._test_index)) >=
                 length(messages) - 1 - max_messages
      end
    end

    property "sliding window with keep_first_user preserves the first user message" do
      check all(
              messages <- message_list(min_length: 5, max_length: 30),
              max_messages <- integer(0..10)
            ) do
        first_user = %{role: :user, content: "first user message"}

        {truncated, _} =
          Context.truncate([first_user | messages],
            max_messages: max_messages,
            strategy: :sliding_window,
            keep_first_user: true
          )

        assert first_user in truncated
      end
    end

    property "bookends satisfies both hard limits and keeps the first and last messages" do
      check all(
              messages <- message_list(min_length: 1, max_length: 30),
              max_messages <- integer(0..12),
              max_chars <- integer(0..2_000)
            ) do
        {truncated, _} =
          Context.truncate(messages,
            max_messages: max_messages,
            max_chars: max_chars,
            strategy: :keep_bookends
          )

        assert length(truncated) <= max_messages
        assert Context.estimate_size(truncated, nil) <= max_chars

        {roomy, _} =
          Context.truncate(messages, max_messages: max(max_messages, 2), strategy: :keep_bookends)

        assert List.first(roomy) == List.first(messages)
        assert List.last(roomy) == List.last(messages)
      end
    end

    property "tool call/result groups are retained atomically" do
      check all(
              prefix_count <- integer(0..8),
              suffix_count <- integer(0..8),
              max_messages <- integer(0..12),
              strategy <- truncation_strategy()
            ) do
        call = Mocks.tool_call("lookup", %{}, id: "atomic-call")
        assistant = Mocks.assistant_message_with_tool_calls([call])
        result = Mocks.tool_result_message("atomic-call", "lookup", "ok")

        prefix = for i <- 1..prefix_count//1, do: Mocks.user_message("before #{i}")
        suffix = for i <- 1..suffix_count//1, do: Mocks.user_message("after #{i}")
        messages = prefix ++ [assistant, result] ++ suffix

        {truncated, _} =
          Context.truncate(messages,
            max_messages: max_messages,
            keep_first_user: false,
            strategy: strategy
          )

        assert assistant in truncated == result in truncated
      end
    end

    property "make_transform applies truncate and ignores the abort signal" do
      check all(
              messages <- message_list(min_length: 5, max_length: 20),
              max_messages <- integer(1..10),
              keep_first_user <- boolean()
            ) do
        opts = [max_messages: max_messages, keep_first_user: keep_first_user]
        {truncated, _} = Context.truncate(messages, opts)
        transform = Context.make_transform([warn_on_truncation: false] ++ opts)

        assert transform.(messages, nil) == {:ok, truncated}
        assert transform.(messages, make_ref()) == {:ok, truncated}
      end
    end
  end
end
