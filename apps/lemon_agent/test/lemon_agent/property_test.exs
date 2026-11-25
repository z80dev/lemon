defmodule LemonAgent.TypesPropertyTest do
  @moduledoc """
  Property-based tests for the message types the agent loop builds on.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  import StreamData

  alias LemonAgent.Types.AgentLoopConfig
  alias LemonAi.Types.{Context, StreamOptions, UserMessage}

  test "loop and stream defaults are bounded" do
    assert %AgentLoopConfig{max_tool_turns: 25} = %AgentLoopConfig{}

    assert %StreamOptions{stream_timeout: 1_800_000, stream_idle_timeout: 300_000} =
             %StreamOptions{}
  end

  property "Context.add_user_message appends without reordering history" do
    check all(
            prompt <- one_of([constant(nil), string(:printable, max_length: 100)]),
            initial_count <- integer(0..5),
            content <- string(:printable, min_length: 1, max_length: 100)
          ) do
      initial_messages =
        Enum.map(1..initial_count//1, fn i ->
          %UserMessage{role: :user, content: "msg#{i}", timestamp: i}
        end)

      ctx = %{Context.new(system_prompt: prompt) | messages: initial_messages}
      updated = Context.add_user_message(ctx, content)

      assert updated.system_prompt == prompt
      assert updated.tools == []
      assert [%UserMessage{content: ^content}] = updated.messages -- initial_messages
      assert Enum.take(updated.messages, initial_count) == initial_messages
    end
  end
end
