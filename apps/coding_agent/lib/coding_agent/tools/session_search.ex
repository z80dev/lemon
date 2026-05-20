defmodule CodingAgent.Tools.SessionSearch do
  @moduledoc """
  Hermes-compatible session search over Lemon's durable memory and run history.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonCore.{SessionSearch, Store}

  @default_discover_limit 3
  @max_discover_limit 10
  @default_window 5
  @max_window 20

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    context = %{
      current_session_id: Keyword.get(opts, :session_key),
      search_fn: Keyword.get(opts, :session_search_fn, &SessionSearch.search/2),
      history_fn: Keyword.get(opts, :session_history_fn, &Store.get_run_history/2)
    }

    %AgentTool{
      name: "session_search",
      description: """
      Search past Lemon sessions and scroll inside known sessions. This is a no-LLM \
      compatibility surface for Hermes-style session_search.

      Three calling shapes:
      1. DISCOVERY: pass query to search stored run summaries and return matching sessions.
      2. SCROLL: pass session_id and around_message_id to read a bounded window in that session.
      3. BROWSE: pass no args to list recent runs in the current session.

      Scroll wins when both query and scroll args are present.
      """,
      label: "Session Search",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Discovery query. Omit to browse recent current-session runs."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_discover_limit,
            "description" => "Discovery or browse result limit. Default 3, max 10."
          },
          "sort" => %{
            "type" => "string",
            "enum" => ["newest", "oldest"],
            "description" => "Discovery result ordering. Omit for store relevance order."
          },
          "session_id" => %{
            "type" => "string",
            "description" => "Scroll target session id returned from discovery or browse."
          },
          "around_message_id" => %{
            "type" => "integer",
            "description" => "Scroll anchor id returned in a prior session_search result."
          },
          "window" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_window,
            "description" => "Messages to return on each side of the anchor. Default 5."
          },
          "role_filter" => %{
            "type" => "string",
            "description" =>
              "Optional comma-separated roles for discovery result messages: user, assistant."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, context)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, map()) ::
          AgentToolResult.t()
  def execute(_tool_call_id, params, _signal, _on_update, context) do
    payload =
      cond do
        scroll_shape?(params) ->
          scroll(params, context)

        discovery_query(params) ->
          discover(params, context)

        true ->
          browse(params, context)
      end

    result(payload)
  rescue
    e ->
      result(%{
        success: false,
        mode: "error",
        error: Exception.message(e)
      })
  end

  defp scroll_shape?(params) do
    is_binary(Map.get(params, "session_id")) and String.trim(Map.get(params, "session_id")) != "" and
      not is_nil(Map.get(params, "around_message_id"))
  end

  defp discovery_query(params) do
    case Map.get(params, "query") do
      query when is_binary(query) -> String.trim(query) != ""
      _ -> false
    end
  end

  defp discover(params, context) do
    query = Map.get(params, "query") |> String.trim()
    limit = clamp_int(Map.get(params, "limit"), @default_discover_limit, 1, @max_discover_limit)
    role_filter = parse_roles(Map.get(params, "role_filter"))

    docs =
      context.search_fn.(query, scope: :all, scope_key: nil, limit: limit)
      |> reject_current_session(context.current_session_id)
      |> sort_docs(Map.get(params, "sort"))
      |> Enum.take(limit)

    %{
      success: true,
      mode: "discover",
      query: query,
      results: Enum.map(docs, &doc_result(&1, role_filter)),
      count: length(docs),
      sessionsSearched: docs |> Enum.map(&doc_session_id/1) |> Enum.uniq() |> length()
    }
  end

  defp browse(params, context) do
    limit = clamp_int(Map.get(params, "limit"), @default_discover_limit, 1, @max_discover_limit)

    case normalize_string(context.current_session_id) do
      nil ->
        %{
          success: false,
          mode: "browse",
          error: "session_search browse requires a current session"
        }

      session_id ->
        runs =
          context.history_fn.(session_id, limit: limit)
          |> Enum.take(limit)

        %{
          success: true,
          mode: "browse",
          results: Enum.map(runs, fn {run_id, data} -> run_result(session_id, run_id, data) end),
          count: length(runs)
        }
    end
  end

  defp scroll(params, context) do
    session_id = Map.get(params, "session_id") |> String.trim()
    anchor = parse_int(Map.get(params, "around_message_id"))
    window = clamp_int(Map.get(params, "window"), @default_window, 1, @max_window)

    cond do
      is_nil(anchor) ->
        %{success: false, mode: "scroll", error: "around_message_id must be an integer"}

      session_id == normalize_string(context.current_session_id) ->
        %{success: false, mode: "scroll", error: "Refusing to scroll the current session"}

      true ->
        messages =
          context.history_fn.(session_id, limit: max(window * 4, 50))
          |> Enum.reverse()
          |> Enum.flat_map(fn {run_id, data} -> run_messages(run_id, data) end)

        anchor_index = Enum.find_index(messages, &(Map.get(&1, "id") == anchor))

        if is_nil(anchor_index) do
          %{success: false, mode: "scroll", error: "around_message_id is not in session"}
        else
          first = max(anchor_index - window, 0)
          last = min(anchor_index + window, length(messages) - 1)
          selected = messages |> Enum.slice(first..last) |> mark_anchor(anchor)

          %{
            success: true,
            mode: "scroll",
            session_id: session_id,
            around_message_id: anchor,
            window: window,
            messages: selected,
            count: length(selected),
            messagesBefore: first,
            messagesAfter: max(length(messages) - last - 1, 0)
          }
        end
    end
  end

  defp doc_result(doc, role_filter) do
    prompt = doc_text(doc, :prompt_summary)
    answer = doc_text(doc, :answer_summary)
    messages = doc_messages(doc, prompt, answer, role_filter)
    anchor = doc_anchor_id(doc)

    %{
      session_id: doc_session_id(doc),
      title: title(prompt, answer),
      when: format_timestamp(doc_time(doc)),
      source: "lemon_memory",
      snippet: snippet(prompt, answer),
      messages: mark_anchor(messages, anchor),
      bookendStart: Enum.take(messages, 2),
      bookendEnd: Enum.take(messages, -2),
      matchMessageId: anchor,
      messagesBefore: 0,
      messagesAfter: 0
    }
  end

  defp run_result(session_id, run_id, data) do
    messages = run_messages(run_id, data)
    anchor = messages |> List.first(%{}) |> Map.get("id")

    %{
      session_id: session_id,
      run_id: to_string(run_id),
      title: data |> run_prompt() |> title(run_answer(data)),
      when: format_timestamp(Map.get(data, :started_at) || Map.get(data, "started_at")),
      messages: mark_anchor(messages, anchor),
      matchMessageId: anchor,
      messageCount: length(messages)
    }
  end

  defp doc_messages(doc, prompt, answer, role_filter) do
    anchor = doc_anchor_id(doc)

    [
      %{"id" => anchor, "role" => "user", "content" => prompt},
      %{"id" => anchor + 1, "role" => "assistant", "content" => answer}
    ]
    |> Enum.reject(&(String.trim(Map.get(&1, "content", "")) == ""))
    |> Enum.filter(fn msg -> role_allowed?(Map.get(msg, "role"), role_filter) end)
  end

  defp run_messages(run_id, data) do
    base = run_anchor_base(data, run_id)
    prompt = run_prompt(data)
    answer = run_answer(data)

    [
      %{"id" => base, "role" => "user", "content" => prompt, "run_id" => to_string(run_id)},
      %{
        "id" => base + 1,
        "role" => "assistant",
        "content" => answer,
        "run_id" => to_string(run_id)
      }
    ]
    |> Enum.reject(&(String.trim(Map.get(&1, "content", "")) == ""))
  end

  defp run_prompt(data), do: summary_text(data, [:prompt])

  defp run_answer(data) do
    completed =
      get_in(data, [:summary, :completed]) || get_in(data, ["summary", "completed"]) || %{}

    value = map_get(completed, :answer) || summary_text(data, [:answer])
    normalize_string(value) || ""
  end

  defp summary_text(data, path) do
    value =
      Enum.reduce_while([:summary | path], data, fn key, acc ->
        case map_get(acc, key) do
          nil -> {:halt, nil}
          next -> {:cont, next}
        end
      end)

    normalize_string(value) || ""
  end

  defp run_anchor_base(data, run_id) do
    value = Map.get(data, :started_at) || Map.get(data, "started_at") || :erlang.phash2(run_id)
    (parse_int(value) || :erlang.phash2(run_id)) * 10 + 1
  end

  defp reject_current_session(docs, nil), do: docs

  defp reject_current_session(docs, current_session_id) do
    Enum.reject(docs, &(doc_session_id(&1) == current_session_id))
  end

  defp sort_docs(docs, "newest"), do: Enum.sort_by(docs, &doc_time/1, :desc)
  defp sort_docs(docs, "oldest"), do: Enum.sort_by(docs, &doc_time/1, :asc)
  defp sort_docs(docs, _), do: docs

  defp parse_roles(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      roles -> MapSet.new(roles)
    end
  end

  defp parse_roles(_), do: nil

  defp role_allowed?(_role, nil), do: true
  defp role_allowed?(role, roles), do: MapSet.member?(roles, role)

  defp doc_session_id(doc), do: doc_text(doc, :session_key)
  defp doc_time(doc), do: doc_value(doc, :started_at_ms) || doc_value(doc, :ingested_at_ms) || 0
  defp doc_anchor_id(doc), do: doc_time(doc) * 10 + 1

  defp doc_text(doc, key), do: doc |> doc_value(key) |> normalize_string() || ""

  defp doc_value(doc, key) when is_map(doc) do
    Map.get(doc, key) || Map.get(doc, Atom.to_string(key))
  end

  defp map_get(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(_, _), do: nil

  defp title(prompt, answer) do
    [prompt, answer]
    |> Enum.find(&(normalize_string(&1) not in [nil, ""]))
    |> case do
      nil -> "Untitled session"
      text -> truncate(text, 80)
    end
  end

  defp snippet(prompt, answer) do
    [prompt, answer]
    |> Enum.reject(&(normalize_string(&1) in [nil, ""]))
    |> Enum.join("\n")
    |> truncate(240)
  end

  defp truncate(text, max) when is_binary(text) and byte_size(text) > max do
    binary_part(text, 0, utf8_safe_boundary(text, max)) <> "..."
  end

  defp truncate(text, _max) when is_binary(text), do: text
  defp truncate(_, _max), do: ""

  defp utf8_safe_boundary(binary, pos) when pos > 0 do
    if String.valid?(binary_part(binary, 0, pos)),
      do: pos,
      else: utf8_safe_boundary(binary, pos - 1)
  end

  defp utf8_safe_boundary(_binary, _pos), do: 0

  defp mark_anchor(messages, nil), do: messages

  defp mark_anchor(messages, anchor) do
    Enum.map(messages, fn message ->
      if Map.get(message, "id") == anchor, do: Map.put(message, "anchor", true), else: message
    end)
  end

  defp clamp_int(value, default, min, max) do
    value = parse_int(value) || default
    value |> max(min) |> min(max)
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_string()

  defp normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_string(_), do: nil

  defp format_timestamp(value) do
    case parse_int(value) do
      nil ->
        "unknown"

      int when int > 10_000_000_000 ->
        int
        |> DateTime.from_unix!(:millisecond)
        |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

      int ->
        int
        |> DateTime.from_unix!(:second)
        |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    end
  rescue
    _ -> "unknown"
  end

  defp result(payload) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: Jason.encode!(payload, pretty: true)}],
      details: payload
    }
  end
end
