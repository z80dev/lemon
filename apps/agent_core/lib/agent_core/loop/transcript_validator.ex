defmodule AgentCore.Loop.TranscriptValidator do
  @moduledoc """
  Validates tool-call transcript invariants before provider calls.
  """

  alias Ai.Types.{AssistantMessage, ToolCall, ToolResultMessage}

  @type violation :: %{
          required(:type) => atom(),
          required(:index) => non_neg_integer() | nil,
          optional(:tool_call_id) => String.t() | nil,
          optional(:tool_call_ids) => [String.t() | nil],
          optional(:result_ids) => [String.t() | nil]
        }

  @spec validate([Ai.Types.message()]) ::
          :ok | {:error, {:invalid_tool_transcript, [violation()]}}
  def validate(messages) when is_list(messages) do
    case do_validate(messages, 0, []) do
      [] -> :ok
      violations -> {:error, {:invalid_tool_transcript, Enum.reverse(violations)}}
    end
  end

  def validate(_messages) do
    {:error, {:invalid_tool_transcript, [%{type: :invalid_messages, index: nil}]}}
  end

  defp do_validate([], _index, violations), do: violations

  defp do_validate([message | rest], index, violations) do
    case tool_calls(message) do
      [] ->
        violations =
          if tool_result_message?(message) do
            [
              %{type: :orphan_tool_result, index: index, tool_call_id: tool_result_id(message)}
              | violations
            ]
          else
            violations
          end

        do_validate(rest, index + 1, violations)

      calls ->
        {results, remaining} = Enum.split_while(rest, &tool_result_message?/1)

        expected_ids = Enum.map(calls, &tool_call_id/1)
        result_ids = Enum.map(results, &tool_result_id/1)

        violations =
          violations
          |> add_invalid_call_ids(index, expected_ids)
          |> add_duplicate_call_ids(index, expected_ids)
          |> add_missing_result_ids(index, expected_ids, result_ids)
          |> add_unexpected_result_ids(index, expected_ids, result_ids)
          |> add_duplicate_result_ids(index, result_ids)

        do_validate(remaining, index + 1 + length(results), violations)
    end
  end

  defp tool_calls(%AssistantMessage{content: content}) when is_list(content) do
    Enum.filter(content, &tool_call?/1)
  end

  defp tool_calls(%{role: role, content: content})
       when role in [:assistant, "assistant"] and is_list(content) do
    Enum.filter(content, &tool_call?/1)
  end

  defp tool_calls(%{"role" => role, "content" => content})
       when role in [:assistant, "assistant"] and is_list(content) do
    Enum.filter(content, &tool_call?/1)
  end

  defp tool_calls(_message), do: []

  defp tool_call?(%ToolCall{}), do: true
  defp tool_call?(%{type: type}) when type in [:tool_call, "tool_call"], do: true
  defp tool_call?(_), do: false

  defp tool_call_id(%ToolCall{id: id}), do: id
  defp tool_call_id(%{id: id}), do: id
  defp tool_call_id(%{"id" => id}), do: id
  defp tool_call_id(_), do: nil

  defp tool_result_message?(%ToolResultMessage{}), do: true
  defp tool_result_message?(%{role: role}) when role in [:tool_result, "tool_result"], do: true

  defp tool_result_message?(%{"role" => role}) when role in [:tool_result, "tool_result"],
    do: true

  defp tool_result_message?(_), do: false

  defp tool_result_id(%ToolResultMessage{tool_call_id: id}), do: id
  defp tool_result_id(%{tool_call_id: id}), do: id
  defp tool_result_id(%{"tool_call_id" => id}), do: id
  defp tool_result_id(%{tool_use_id: id}), do: id
  defp tool_result_id(%{"tool_use_id" => id}), do: id
  defp tool_result_id(_), do: nil

  defp add_invalid_call_ids(violations, index, expected_ids) do
    invalid_ids =
      Enum.filter(expected_ids, fn
        id when is_binary(id) -> String.trim(id) == ""
        _ -> true
      end)

    if invalid_ids == [] do
      violations
    else
      [%{type: :invalid_tool_call_id, index: index, tool_call_ids: invalid_ids} | violations]
    end
  end

  defp add_duplicate_call_ids(violations, index, expected_ids) do
    case duplicates(expected_ids) do
      [] ->
        violations

      duplicate_ids ->
        [
          %{type: :duplicate_tool_call_id, index: index, tool_call_ids: duplicate_ids}
          | violations
        ]
    end
  end

  defp add_missing_result_ids(violations, index, expected_ids, result_ids) do
    result_counts = frequencies(result_ids)

    missing =
      expected_ids
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(result_counts, &1, 0) == 0))

    if missing == [] do
      violations
    else
      [
        %{
          type: :missing_tool_result,
          index: index,
          tool_call_ids: missing,
          result_ids: result_ids
        }
        | violations
      ]
    end
  end

  defp add_unexpected_result_ids(violations, index, expected_ids, result_ids) do
    expected = MapSet.new(expected_ids)
    unexpected = result_ids |> Enum.reject(&MapSet.member?(expected, &1)) |> Enum.uniq()

    if unexpected == [] do
      violations
    else
      [
        %{
          type: :unexpected_tool_result,
          index: index,
          tool_call_ids: expected_ids,
          result_ids: unexpected
        }
        | violations
      ]
    end
  end

  defp add_duplicate_result_ids(violations, index, result_ids) do
    case duplicates(result_ids) do
      [] ->
        violations

      duplicate_ids ->
        [%{type: :duplicate_tool_result, index: index, result_ids: duplicate_ids} | violations]
    end
  end

  defp duplicates(values) do
    values
    |> frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end

  defp frequencies(values) do
    Enum.reduce(values, %{}, fn value, acc -> Map.update(acc, value, 1, &(&1 + 1)) end)
  end
end
