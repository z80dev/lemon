defmodule LemonControlPlane.EventProjection do
  @moduledoc """
  Bounded, credential-redacted projections of visible tool output for WS and ACP.

  `tool_result/1` returns a string-keyed map containing only `content`, `details`,
  `is_error` and `trust` when present. Content order is retained. Typed text,
  image, usage and cost values have explicit public-field projections; hidden
  thinking, signatures, arbitrary structs, callbacks and state are never exported.
  `trust` is a tool-supplied label, not proof of a security transformation.
  Usage preserves cumulative budget counters (`tokens`, `cost_usd`, turns and
  tool errors) separately from the current-context token and budget snapshot.

  Each projection has a shared 32 KiB JSON budget, 100 entries and six levels of
  nesting. Strings are redacted before clipping to 16 KiB. Diff snapshots
  (`oldText`/`newText` and snake-case equivalents) are omitted rather than clipped,
  as are incomplete image data. Unsupported values and private fields are dropped.
  These bounds apply to the wire copy, not the persisted tool result.
  """

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{Cost, ImageContent, TextContent, Usage}
  alias LemonCore.Redact

  @max_bytes 32 * 1024
  @max_string_bytes 16 * 1024
  @max_items 100
  @max_depth 6
  @result_fields [:is_error, :trust, :content, :details]
  @detail_fields ~w(type status exit_code exitCode truncated timed_out timedOut background
    process_id processId run_id runId session_id sessionId session_key sessionKey
    action_id actionId tool_call_id toolCallId tool_name toolName name text output
    stdout stderr diff oldText newText old_text new_text path media_path uri first_changed_line
    firstChangedLine bytes_written bytesWritten formatted acp_client acpClient
    line_count lineCount count total duration_ms durationMs usage cost diagnostics
    content results locations error_type errorType message reason retryable
    resolvedPath resolved_path perFileResults terminalId todos phases tasks plan
    task_id taskId description cancelled outcome started partial execution_duration_ms
    context_tokens context_budget cache_write_long turns tool_errors)
  @private_fields ~w(__struct__ callback callbacks on_update onUpdate execute function
    pid ref monitor owner state runtime config context private raw raw_response
    rawResponse text_signature textSignature thinking_signature thinkingSignature
    thought_signature thoughtSignature thinking hidden_thinking hiddenThinking)
  @complete_fields ~w(oldText newText old_text new_text data)
  @field_atoms Map.new(
                 @detail_fields ++
                   ~w(is_error isError trust content details type text mime_type mimeType data),
                 &{&1, String.to_atom(&1)}
               )

  @doc "Project an AgentToolResult or its map representation to bounded visible JSON data."
  @spec tool_result(AgentToolResult.t() | map() | term()) :: map()
  def tool_result(result) do
    fields = result_fields(result)
    {projected, _budget} = project_map(fields, 0, budget(), true)
    projected
  end

  @doc false
  @spec action_detail(term()) :: term()
  def action_detail(detail) do
    case project(detail, 0, budget(), false) do
      {:ok, value, _budget} -> value
      :drop -> nil
    end
  end

  defp budget, do: %{bytes: @max_bytes, items: @max_items}

  defp result_fields(%AgentToolResult{} = result), do: visible_result_fields(result)

  defp result_fields(result) when is_map(result) and not is_struct(result),
    do: visible_result_fields(result)

  defp result_fields(_), do: []

  defp visible_result_fields(result) do
    Enum.flat_map(@result_fields, fn key ->
      case fetch_field(result, key) do
        {:ok, value} -> [{Atom.to_string(key), public_result_field(key, value)}]
        :error -> []
      end
    end)
  end

  defp public_result_field(:content, content) when is_list(content) do
    content
    |> take_content(@max_items)
    |> Enum.flat_map(fn
      %TextContent{} = block ->
        [block]

      %ImageContent{} = block ->
        [block]

      block when is_map(block) and not is_struct(block) ->
        case fetch_named_field(block, "type") do
          {:ok, type} when type in [:text, "text"] ->
            [%{"type" => "text", "text" => field_value(block, "text")}]

          {:ok, type} when type in [:image, "image"] ->
            [
              %ImageContent{
                data: field_value(block, "data"),
                mime_type: field_value(block, "mime_type") || field_value(block, "mimeType")
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp public_result_field(:content, _), do: []

  defp public_result_field(:details, details) when is_map(details) and not is_struct(details) do
    Enum.flat_map(@detail_fields, fn key ->
      case fetch_named_field(details, key) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp public_result_field(:details, _), do: nil
  defp public_result_field(_key, value), do: value

  defp take_content(_content, 0), do: []
  defp take_content([block | rest], left), do: [block | take_content(rest, left - 1)]
  defp take_content(_tail, _left), do: []

  defp fetch_field(map, :is_error) do
    case fetch_named_field(map, "is_error") do
      :error -> fetch_named_field(map, "isError")
      found -> found
    end
  end

  defp fetch_field(map, key), do: fetch_named_field(map, Atom.to_string(key))

  defp fetch_named_field(map, key) do
    case Map.fetch(map, key) do
      :error ->
        case Map.fetch(@field_atoms, key) do
          {:ok, atom} -> Map.fetch(map, atom)
          :error -> :error
        end

      found ->
        found
    end
  end

  defp field_value(map, key) do
    case fetch_named_field(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp project(_value, depth, _budget, _string_keys) when depth >= @max_depth, do: :drop
  defp project(_value, _depth, %{bytes: bytes}, _string_keys) when bytes < 2, do: :drop

  defp project(%AgentToolResult{} = result, depth, budget, _string_keys) do
    {value, budget} = project_map(result_fields(result), depth, budget, true)
    {:ok, value, budget}
  end

  defp project(%TextContent{} = value, depth, budget, _string_keys),
    do: project_selected(value, [:type, :text], depth, budget)

  defp project(%ImageContent{data: data} = value, depth, budget, _string_keys)
       when is_binary(data) do
    case project_selected(value, [:type, :mime_type, :data], depth, budget) do
      {:ok, %{"data" => _} = image, remaining} -> {:ok, image, remaining}
      _ -> :drop
    end
  end

  defp project(%ImageContent{}, _depth, _budget, _string_keys), do: :drop

  defp project(%Usage{} = value, depth, budget, _string_keys),
    do:
      project_selected(
        value,
        [
          :input,
          :output,
          :cache_read,
          :cache_write,
          :cache_write_long,
          :total_tokens,
          :cost,
          :context_tokens,
          :context_budget,
          :turns,
          :tool_errors,
          :tokens,
          :cost_usd
        ],
        depth,
        budget
      )

  defp project(%Cost{} = value, depth, budget, _string_keys),
    do:
      project_selected(
        value,
        [:input, :output, :cache_read, :cache_write, :cache_write_long, :total],
        depth,
        budget
      )

  defp project(%{__struct__: _}, _depth, _budget, _string_keys), do: :drop

  defp project(value, depth, budget, string_keys) when is_map(value) do
    {value, budget} = project_map(value, depth, budget, string_keys)
    {:ok, value, budget}
  end

  defp project(value, depth, budget, string_keys) when is_list(value) do
    if budget.bytes >= 2 do
      {values, budget} =
        project_list(value, depth, %{budget | bytes: budget.bytes - 2}, string_keys, [])

      {:ok, Enum.reverse(values), budget}
    else
      :drop
    end
  end

  defp project(value, _depth, budget, _string_keys) when is_binary(value),
    do: project_string(value, budget, false)

  defp project(value, _depth, budget, string_keys)
       when is_number(value) or is_boolean(value) or is_nil(value) or is_atom(value) do
    value =
      if string_keys and is_atom(value) and value not in [true, false, nil],
        do: Atom.to_string(value),
        else: value

    size = byte_size(Jason.encode!(value))
    if size <= budget.bytes, do: {:ok, value, %{budget | bytes: budget.bytes - size}}, else: :drop
  end

  defp project(_value, _depth, _budget, _string_keys), do: :drop

  defp project_selected(value, keys, depth, budget) do
    fields = Enum.map(keys, &{Atom.to_string(&1), Map.get(value, &1)})
    {value, budget} = project_map(fields, depth, budget, true)
    {:ok, value, budget}
  end

  defp project_map(fields, depth, budget, string_keys) do
    if budget.bytes < 2 do
      {%{}, budget}
    else
      {value, remaining} =
        Enum.reduce_while(fields, {%{}, %{budget | bytes: budget.bytes - 2}}, fn {key, value},
                                                                                 {acc, budget} ->
          if budget.items <= 0 or budget.bytes < 4 do
            {:halt, {acc, budget}}
          else
            case project_field(key, value, depth, budget, string_keys) do
              {:ok, key, value, next_budget} -> {:cont, {Map.put(acc, key, value), next_budget}}
              :drop -> {:cont, {acc, %{budget | items: budget.items - 1}}}
            end
          end
        end)

      {drop_incomplete_diff(fields, value), remaining}
    end
  end

  defp drop_incomplete_diff(fields, value) do
    Enum.reduce(
      [
        {"oldText", "newText"},
        {"old_text", "new_text"},
        {:oldText, :newText},
        {:old_text, :new_text}
      ],
      value,
      fn {old, new}, acc ->
        if field_present?(fields, old) and field_present?(fields, new) and
             not (Map.has_key?(acc, old) and Map.has_key?(acc, new)) do
          acc |> Map.delete(old) |> Map.delete(new)
        else
          acc
        end
      end
    )
  end

  defp field_present?(fields, key) when is_map(fields), do: Map.has_key?(fields, key)
  defp field_present?(fields, key), do: List.keymember?(fields, key, 0)

  defp project_field(key, value, depth, budget, string_keys)
       when is_atom(key) or is_binary(key) do
    name = if is_atom(key), do: Atom.to_string(key), else: key

    if byte_size(name) <= 128 and String.valid?(name) and name not in @private_fields do
      cost = byte_size(Jason.encode!(name)) + 2
      next_budget = %{budget | bytes: budget.bytes - cost, items: budget.items - 1}

      if next_budget.bytes >= 2 do
        projected =
          cond do
            name in [
              "total_tokens",
              "totalTokens",
              "context_tokens",
              "contextTokens",
              "tokens",
              "reserve_tokens",
              "threshold_tokens",
              "headroom_tokens"
            ] and
                (is_number(value) or is_nil(value)) ->
              project(value, depth + 1, next_budget, string_keys)

            Redact.sensitive_key?(name) ->
              project("[REDACTED]", depth + 1, next_budget, string_keys)

            name in @complete_fields and is_binary(value) ->
              project_string(value, next_budget, true)

            name in ["partial_result", "partialResult", "result"] and is_map(value) and
                not is_struct(value) ->
              project(Map.new(result_fields(value)), depth + 1, next_budget, true)

            true ->
              project(value, depth + 1, next_budget, string_keys)
          end

        case projected do
          {:ok, value, next_budget} ->
            {:ok, if(string_keys, do: name, else: key), value, next_budget}

          :drop ->
            :drop
        end
      else
        :drop
      end
    else
      :drop
    end
  end

  defp project_field(_key, _value, _depth, _budget, _string_keys), do: :drop

  defp project_list([], _depth, budget, _string_keys, acc), do: {acc, budget}

  defp project_list(_list, _depth, %{items: items} = budget, _string_keys, acc) when items <= 0,
    do: {acc, budget}

  defp project_list(_list, _depth, %{bytes: bytes} = budget, _string_keys, acc) when bytes < 2,
    do: {acc, budget}

  defp project_list([value | rest], depth, budget, string_keys, acc) do
    next_budget = %{budget | bytes: budget.bytes - 1, items: budget.items - 1}

    case project(value, depth + 1, next_budget, string_keys) do
      {:ok, value, remaining} -> project_list(rest, depth, remaining, string_keys, [value | acc])
      :drop -> project_list(rest, depth, %{budget | items: budget.items - 1}, string_keys, acc)
    end
  end

  defp project_list(_improper_tail, _depth, budget, _string_keys, acc), do: {acc, budget}

  defp project_string(value, budget, complete?) do
    if String.valid?(value) do
      redacted = Redact.text(value)
      limit = min(@max_string_bytes, max(div(budget.bytes - 2, 6), 0))

      cond do
        complete? and
            (byte_size(redacted) > @max_string_bytes or
               byte_size(Jason.encode!(redacted)) > budget.bytes) ->
          :drop

        complete? ->
          size = byte_size(Jason.encode!(redacted))
          {:ok, redacted, %{budget | bytes: budget.bytes - size}}

        budget.bytes >= 2 ->
          text =
            if byte_size(redacted) <= @max_string_bytes and
                 byte_size(Jason.encode!(redacted)) <= budget.bytes,
               do: redacted,
               else: utf8_prefix(redacted, limit)

          size = byte_size(Jason.encode!(text))
          {:ok, text, %{budget | bytes: budget.bytes - size}}

        true ->
          :drop
      end
    else
      :drop
    end
  end

  defp utf8_prefix(text, limit) do
    prefix = binary_part(text, 0, min(byte_size(text), limit))
    valid_prefix(prefix)
  end

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end
end
