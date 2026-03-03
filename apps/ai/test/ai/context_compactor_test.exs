defmodule Ai.ContextCompactorTest do
  @moduledoc """
  Tests for the Ai.ContextCompactor module.
  """

  use ExUnit.Case, async: true

  alias Ai.ContextCompactor
  alias Ai.Types.{Context, AssistantMessage, TextContent}

  describe "context_length_error?/1" do
    test "detects OpenAI context_length_exceeded error code" do
      error = {:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}}
      assert ContextCompactor.context_length_error?(error)
    end

    test "detects error by message content" do
      error = {:http_error, 400, %{"error" => %{"message" => "This model's maximum context length is 8192 tokens"}}}
      assert ContextCompactor.context_length_error?(error)
    end

    test "detects context length error in string body" do
      error = {:http_error, 400, "context_length_exceeded: too many tokens"}
      assert ContextCompactor.context_length_error?(error)
    end

    test "detects :context_length_exceeded atom" do
      assert ContextCompactor.context_length_error?(:context_length_exceeded)
    end

    test "returns false for rate limit errors" do
      error = {:http_error, 429, %{"error" => %{"message" => "Rate limit exceeded"}}}
      refute ContextCompactor.context_length_error?(error)
    end

    test "returns false for server errors" do
      error = {:http_error, 500, %{"error" => %{"message" => "Internal server error"}}}
      refute ContextCompactor.context_length_error?(error)
    end

    test "returns false for unknown errors" do
      refute ContextCompactor.context_length_error?(:unknown_error)
      refute ContextCompactor.context_length_error?(nil)
      refute ContextCompactor.context_length_error?("some error")
    end
  end

  describe "compact/2 with truncation strategy" do
    test "returns error when context has too few messages" do
      context = Context.new()
      |> Context.add_user_message("Hello")

      assert {:error, :insufficient_messages} = ContextCompactor.compact(context, strategy: :truncation)
    end

    test "truncates oldest messages while preserving recent ones" do
      context = build_test_context(10)

      {:ok, compacted, metadata} = ContextCompactor.compact(context, strategy: :truncation, preserve_recent: 4)

      assert metadata.strategy == :truncation
      assert metadata.original_count == 10
      assert metadata.new_count < 10
      assert metadata.removed_count > 0
      assert metadata.tokens_saved > 0
      assert is_boolean(metadata.has_summary)

      # Verify we still have messages
      assert length(compacted.messages) > 0
    end

    test "preserves system prompt when truncating" do
      context = Context.new(system_prompt: "You are a helpful assistant")
      |> Context.add_user_message("Message 1")
      |> Context.add_user_message("Message 2")
      |> Context.add_user_message("Message 3")
      |> Context.add_user_message("Message 4")
      |> Context.add_user_message("Message 5")

      {:ok, compacted, _metadata} = ContextCompactor.compact(context, strategy: :truncation, preserve_recent: 2)

      assert compacted.system_prompt == "You are a helpful assistant"
    end
  end

  describe "compact/2 with hybrid strategy" do
    test "falls back to truncation for now" do
      context = build_test_context(10)

      {:ok, compacted, metadata} = ContextCompactor.compact(context, strategy: :hybrid)

      assert metadata.strategy == :hybrid
      assert length(compacted.messages) < 10
    end
  end

  describe "compact/2 with unknown strategy" do
    test "returns error for unknown strategy" do
      context = build_test_context(5)

      assert {:error, {:unknown_strategy, :unknown}} = ContextCompactor.compact(context, strategy: :unknown)
    end
  end

  describe "configuration" do
    test "default_strategy/0 returns configured value" do
      strategy = ContextCompactor.default_strategy()
      assert strategy in [:truncation, :summarization, :hybrid]
    end

    test "max_attempts/0 returns positive integer" do
      attempts = ContextCompactor.max_attempts()
      assert is_integer(attempts)
      assert attempts > 0
    end

    test "enabled?/0 returns boolean" do
      assert is_boolean(ContextCompactor.enabled?())
    end
  end

  describe "telemetry" do
    test "emits compaction_started event" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ai, :context_compactor, :compaction_started]])

      context = build_test_context(5)
      ContextCompactor.compact(context, strategy: :truncation)

      assert_received {[:ai, :context_compactor, :compaction_started], ^ref, _measurements, metadata}
      assert metadata.strategy == :truncation
      assert metadata.original_message_count == 5
    end

    test "emits compaction_succeeded event on success" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ai, :context_compactor, :compaction_succeeded]])

      context = build_test_context(5)
      ContextCompactor.compact(context, strategy: :truncation)

      assert_received {[:ai, :context_compactor, :compaction_succeeded], ^ref, _measurements, metadata}
      assert metadata.strategy == :truncation
      assert metadata.original_count == 5
      assert is_integer(metadata.tokens_saved)
    end

    test "emits compaction_failed event on failure" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:ai, :context_compactor, :compaction_failed]])

      context = Context.new() |> Context.add_user_message("Hello")
      ContextCompactor.compact(context, strategy: :truncation)

      assert_received {[:ai, :context_compactor, :compaction_failed], ^ref, _measurements, metadata}
      assert metadata.reason == :insufficient_messages
    end
  end

  # Helper functions

  defp build_test_context(message_count) do
    Enum.reduce(1..message_count, Context.new(), fn i, ctx ->
      if rem(i, 2) == 1 do
        Context.add_user_message(ctx, "User message #{i}")
      else
        assistant_msg = %AssistantMessage{
          role: :assistant,
          content: [%TextContent{type: :text, text: "Assistant response #{i}"}],
          timestamp: System.system_time(:millisecond)
        }
        Context.add_assistant_message(ctx, assistant_msg)
      end
    end)
  end
end
