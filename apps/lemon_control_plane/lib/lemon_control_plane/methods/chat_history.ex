defmodule LemonControlPlane.Methods.ChatHistory do
  @moduledoc """
  Handler for the chat.history method.

  Returns the conversation history for a session.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions
  alias LemonControlPlane.EventProjection

  @default_limit 50
  @max_limit 200
  @preview_bytes 500

  @impl true
  def name, do: "chat.history"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_key = get_param(params, "sessionKey")
    limit = normalize_limit(get_param(params, "limit"))
    before_id = get_param(params, "beforeId")
    include_full_text = truthy?(get_param(params, "includeFullText"), true)

    if is_nil(session_key) or session_key == "" do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      with {:ok, history} <- history(params, session_key, limit, before_id, include_full_text) do
        {:ok,
         %{
           "sessionKey" => session_key,
           "messages" => history,
           "summary" => summary(history, limit, before_id, include_full_text)
         }}
      end
    end
  end

  defp history(params, session_key, limit, before_id, full_text) do
    if Map.has_key?(params, "cwd") do
      with {:ok, _key, cwd} <- NativeSessions.target(params) do
        case AgentRuntime.call(:session_history, [session_key, cwd], {:error, :unavailable}) do
          {:ok, entries} when is_list(entries) ->
            entries =
              LemonControlPlane.ACP.History.reconcile_answers(
                entries,
                LemonCore.RunStore.history(session_key, limit: 200)
              )

            messages = native_messages(entries, full_text)

            page =
              if before_id in [nil, ""],
                do: Enum.take(messages, -limit),
                else: messages |> apply_before_id(before_id) |> Enum.take(limit)

            {:ok, page}

          {:error, reason}
          when reason in [:session_not_found, :unsupported_session, :unavailable] ->
            {:ok, get_chat_history(session_key, limit, before_id, full_text)}

          {:error, reason} ->
            NativeSessions.failure(reason)

          _ ->
            NativeSessions.failure(:invalid_response)
        end
      end
    else
      {:ok, get_chat_history(session_key, limit, before_id, full_text)}
    end
  end

  @doc false
  def run_messages(run_id, data), do: extract_messages(run_id, data, true)

  @doc false
  def native_messages(entries, full_text) do
    {rows, _calls} =
      Enum.reduce(entries, {[], %{}}, fn entry, {rows, calls} ->
        {new_rows, calls} =
          Enum.map_reduce(native_message(entry, full_text), calls, fn row, calls ->
            id = row["toolCallId"]

            cond do
              row["role"] == "tool_use" ->
                {row, Map.put(calls, id, row)}

              row["role"] == "tool_result" ->
                call = Map.get(calls, id, %{})

                row =
                  row
                  |> Map.put_new("arguments", call["arguments"])
                  |> Map.put_new("title", call["title"] || row["toolName"])

                {row, Map.delete(calls, id)}

              true ->
                {row, calls}
            end
          end)

        {Enum.reverse(new_rows, rows), calls}
      end)

    Enum.reverse(rows)
  end

  defp native_message(%{type: :message, id: id, message: message} = entry, full_text)
       when is_map(message) do
    role = field(message, :role)
    timestamp = field(message, :timestamp) || Map.get(entry, :timestamp)
    content = field(message, :content)

    case role do
      role when role in ["user", :user] ->
        [text_row(id, "user", native_text(content), timestamp, full_text, true)]

      role when role in ["assistant", :assistant] ->
        text = native_text(content)
        stop = field(message, :stop_reason)

        text_rows =
          if text == "",
            do: [],
            else: [
              text_row(id, "assistant", text, timestamp, full_text, stop not in ["error", :error])
            ]

        calls =
          content
          |> List.wrap()
          |> Enum.with_index()
          |> Enum.flat_map(fn {block, index} ->
            if field(block, :type) in [:tool_call, "tool_call"] and is_binary(field(block, :id)) do
              args = tool_arguments(field(block, :arguments))
              name = field(block, :name)

              [
                %{
                  "id" => "#{id}:tool:#{index}",
                  "role" => "tool_use",
                  "content" => "",
                  "timestampMs" => timestamp,
                  "toolCallId" => field(block, :id),
                  "toolName" => name,
                  "title" => tool_title(name, args),
                  "arguments" => args,
                  "phase" => "started",
                  "ok" => nil,
                  "cancelled" => false,
                  "durationMs" => nil,
                  "details" => %{}
                }
              ]
            else
              []
            end
          end)

        text_rows ++ calls

      role when role in ["tool_result", :tool_result] ->
        projected =
          EventProjection.tool_result(%{
            content: field(message, :content),
            details: field(message, :details),
            is_error: field(message, :is_error),
            trust: field(message, :trust)
          })

        details = projected["details"] || %{}
        text = native_text(projected["content"])

        [
          text_row(
            id,
            "tool_result",
            text,
            timestamp,
            full_text,
            field(message, :is_error) != true
          )
          |> Map.merge(%{
            "toolCallId" => field(message, :tool_call_id),
            "toolName" => field(message, :tool_name),
            "phase" => "completed",
            "details" => details,
            "cancelled" => details["cancelled"] == true,
            "durationMs" => duration(details)
          })
        ]

      _ ->
        []
    end
  end

  defp native_message(_, _), do: []

  defp text_row(id, role, content, timestamp, full_text, ok) do
    %{
      "id" => id,
      "role" => role,
      "content" => maybe_preview(content, full_text),
      "timestampMs" => timestamp,
      "ok" => ok,
      "truncated" => truncated?(content, full_text)
    }
  end

  defp tool_arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, args} when is_map(args) -> tool_arguments(args)
      _ -> %{}
    end
  end

  defp tool_arguments(value) when is_map(value) do
    projected = EventProjection.action_detail(%{args: value})
    if is_map(projected), do: Map.get(projected, :args, %{}), else: %{}
  end

  defp tool_arguments(_value), do: %{}

  defp tool_title(name, args) do
    name = if is_binary(name), do: name, else: "tool"
    subject = field(args, :command) || field(args, :path) || field(args, :query)
    if is_binary(subject), do: "#{name}: #{String.slice(subject, 0, 500)}", else: name
  end

  defp duration(details) do
    value = field(details, :execution_duration_ms) || field(details, :duration_ms)
    if is_number(value) and value >= 0, do: value
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_value, _key), do: nil

  defp native_text(content) when is_binary(content), do: content

  defp native_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: :text, text: text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp native_text(_), do: ""

  defp get_chat_history(session_key, limit, before_id, include_full_text) do
    runs = LemonCore.RunStore.history(session_key, limit: limit * 2)

    runs
    |> Enum.flat_map(fn {run_id, data} ->
      extract_messages(run_id, data, include_full_text)
    end)
    |> apply_before_id(before_id)
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  defp extract_messages(run_id, data, include_full_text) do
    summary = data[:summary] || %{}
    completed = summary[:completed] || %{}
    timestamp = data[:started_at]

    messages = []

    # Add user prompt if available
    prompt = get_in(summary, [:prompt]) || get_prompt_from_events(data[:events])

    messages =
      if prompt do
        [
          %{
            "id" => "#{run_id}_user",
            "role" => "user",
            "content" => maybe_preview(prompt, include_full_text),
            "timestampMs" => timestamp,
            "truncated" => truncated?(prompt, include_full_text)
          }
          | messages
        ]
      else
        messages
      end

    # Add assistant response
    answer = completed[:answer]

    messages =
      if answer && answer != "" do
        [
          %{
            "id" => "#{run_id}_assistant",
            "role" => "assistant",
            "content" => maybe_preview(answer, include_full_text),
            "timestampMs" => timestamp,
            "ok" => completed[:ok],
            "truncated" => truncated?(answer, include_full_text)
          }
          | messages
        ]
      else
        messages
      end

    {prompts, answers} = messages |> Enum.reverse() |> Enum.split_while(&(&1["role"] == "user"))
    prompts ++ stored_tools(run_id, data, completed, timestamp, include_full_text) ++ answers
  end

  defp stored_tools(run_id, data, completed, timestamp, full_text) do
    {order, tools} =
      (field(data, :events) || [])
      |> Enum.reverse()
      |> Enum.reduce({[], %{}}, fn event, {order, tools} ->
        payload = field(event, :payload) || event
        action = field(payload, :action)
        detail = field(action, :detail) || %{}
        id = field(detail, :tool_call_id) || field(action, :id)

        if is_binary(id) and field(action, :kind) not in [:approval, "approval"] do
          previous = Map.get(tools, id, %{detail: %{}})
          detail = Map.merge(previous.detail, detail)

          tool = %{
            action: action,
            detail: detail,
            phase: field(payload, :phase),
            ok: field(payload, :ok),
            message: field(payload, :message)
          }

          order = if Map.has_key?(tools, id), do: order, else: [id | order]
          {order, Map.put(tools, id, tool)}
        else
          {order, tools}
        end
      end)

    Enum.reverse(order)
    |> Enum.map(fn id ->
      tool = Map.fetch!(tools, id)
      terminal? = tool.phase in [:completed, "completed"]
      partial = field(tool.detail, :partial_result)
      result_text = field(tool.detail, :result_full) || field(tool.detail, :result)

      result =
        if is_binary(result_text) and terminal? do
          %{
            content: [%{type: :text, text: result_text}],
            details: field(tool.detail, :details) || %{}
          }
        else
          partial || %{content: [], details: field(tool.detail, :details) || %{}}
        end

      projected = EventProjection.tool_result(result)
      details = projected["details"] || %{}

      cancelled =
        details["cancelled"] == true or
          (not terminal? and
             field(completed, :error) in [
               :acp_cancel,
               :user_requested,
               :assistant_aborted,
               "acp_cancel",
               "user_requested",
               "assistant_aborted"
             ])

      details =
        if not terminal? and cancelled,
          do: Map.merge(details, %{"cancelled" => true, "outcome" => "unknown"}),
          else: details

      content = native_text(projected["content"])
      name = field(tool.detail, :name) || field(tool.action, :kind)
      args = tool_arguments(field(tool.detail, :args))

      text_row(
        "#{run_id}:tool:#{id}",
        if(terminal? or cancelled, do: "tool_result", else: "tool_use"),
        content,
        timestamp,
        full_text,
        if(terminal?, do: tool.ok, else: if(cancelled, do: false))
      )
      |> Map.merge(%{
        "toolCallId" => id,
        "toolName" => name,
        "title" => field(tool.action, :title) || tool_title(name, args),
        "arguments" => args,
        "details" => details,
        "phase" => if(terminal? or cancelled, do: "completed", else: "started"),
        "cancelled" => cancelled,
        "durationMs" => duration(details)
      })
    end)
  end

  defp get_prompt_from_events(nil), do: nil

  defp get_prompt_from_events(events) when is_list(events) do
    events
    |> Enum.find(fn e -> is_map(e) and (e[:type] == :prompt or e["type"] == "prompt") end)
    |> case do
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end
  end

  defp get_prompt_from_events(_), do: nil

  defp apply_before_id(messages, nil), do: messages
  defp apply_before_id(messages, ""), do: messages

  defp apply_before_id(messages, before_id) do
    messages
    |> Enum.drop_while(&(&1["id"] != before_id))
    |> case do
      [] -> []
      [_matched | rest] -> rest
    end
  end

  defp summary(messages, limit, before_id, include_full_text) do
    %{
      "count" => length(messages),
      "limit" => limit,
      "beforeId" => before_id,
      "roleCounts" => count_by(messages, "role"),
      "okCount" => Enum.count(messages, &(&1["ok"] == true)),
      "errorCount" => Enum.count(messages, &(&1["ok"] == false)),
      "truncatedCount" => Enum.count(messages, &(&1["truncated"] == true)),
      "cleanup" => %{
        "includesMessageBodies" => true,
        "includesFullText" => include_full_text == true,
        "includesRawEvents" => false,
        "includesRunRecords" => false,
        "redactsSensitivePreviews" => include_full_text != true,
        "includesCredentials" => false,
        "includesSecretValues" => include_full_text == true
      }
    }
  end

  defp count_by(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.frequencies()
  end

  defp maybe_preview(text, true), do: text

  defp maybe_preview(text, false) when is_binary(text) do
    text = LemonCore.Redact.text(text)

    if byte_size(text) > @preview_bytes do
      String.slice(text, 0, @preview_bytes) <> "..."
    else
      text
    end
  end

  defp maybe_preview(text, false), do: text

  defp truncated?(text, true) when is_binary(text), do: false
  defp truncated?(text, false) when is_binary(text), do: byte_size(text) > @preview_bytes
  defp truncated?(_, _), do: false

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, @max_limit)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(value, _default) when value in [1, "1", "true", "TRUE", "yes", "on"], do: true
  defp truthy?(value, _default) when value in [0, "0", "false", "FALSE", "no", "off"], do: false
  defp truthy?(_value, default), do: default

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
