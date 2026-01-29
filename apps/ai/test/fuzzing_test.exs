defmodule Ai.FuzzingTest do
  use ExUnit.Case

  alias Ai.Providers.OpenAIResponsesShared
  alias Ai.Providers.TextSanitizer
  alias Ai.Types.{AssistantMessage, Cost, Model, ModelCost, ToolCall, Usage}

  defp random_bytes(size) do
    for _ <- 1..size, into: <<>>, do: <<:rand.uniform(256) - 1>>
  end

  defp random_string(size) do
    alphabet = Enum.concat([?a..?z, ?A..?Z, ?0..?9, ' !@#$%^&*()-=+[]{}|;:",.<>?/\\'])
    for _ <- 1..size, into: "", do: <<Enum.random(alphabet)>>
  end

  test "parse_streaming_json fuzz does not crash" do
    :rand.seed(:exsplus, {1, 2, 3})

    for _ <- 1..50 do
      bytes = random_bytes(:rand.uniform(200))
      assert is_map(OpenAIResponsesShared.parse_streaming_json(bytes))
    end
  end

  test "text sanitizer fuzz always yields valid utf-8" do
    :rand.seed(:exsplus, {4, 5, 6})

    for _ <- 1..50 do
      bytes = random_bytes(:rand.uniform(200))
      sanitized = TextSanitizer.sanitize(bytes)
      assert is_binary(sanitized)
      assert String.valid?(sanitized)
    end
  end

  test "tool call normalization fuzz produces safe ids" do
    :rand.seed(:exsplus, {7, 8, 9})

    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      cost: %ModelCost{}
    }

    for _ <- 1..50 do
      tool_id = random_string(:rand.uniform(40)) <> "|" <> random_string(:rand.uniform(40))
      tool_call = %ToolCall{id: tool_id, name: "tool_a", arguments: %{}}

      assistant = %AssistantMessage{
        role: :assistant,
        content: [tool_call],
        api: :openai_responses,
        provider: :openai,
        model: "different-model",
        usage: %Usage{cost: %Cost{}},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [updated | _] =
        OpenAIResponsesShared.transform_messages(
          [assistant],
          model,
          MapSet.new([:openai])
        )

      [%ToolCall{id: normalized}] = updated.content

      assert Regex.match?(~r/^[a-zA-Z0-9_-]+\|[a-zA-Z0-9_-]+$/, normalized)

      [call_id, item_id] = String.split(normalized, "|")
      assert byte_size(call_id) <= 64
      assert byte_size(item_id) <= 64
    end
  end
end
