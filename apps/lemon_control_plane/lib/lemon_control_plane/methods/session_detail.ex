defmodule LemonControlPlane.Methods.SessionDetail do
  @moduledoc """
  Handler for `session.detail`.

  Returns rich session/run internals including run summaries, tool calls, and
  optional raw run event payloads.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 20
  @max_limit 200
  @default_history_limit 500
  @max_history_limit 5_000
  @default_event_limit 250
  @max_event_limit 2_000
  @default_tool_call_limit 50
  @max_tool_call_limit 500
  @max_string_bytes 20_000
  @max_preview_bytes 800

  @impl true
  def name, do: "session.detail"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, session_key} <- require_session_key(params) do
      limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)

      history_limit =
        normalize_limit(
          get_param(params, "historyLimit"),
          max(limit * 5, @default_history_limit),
          @max_history_limit
        )

      event_limit =
        normalize_limit(get_param(params, "eventLimit"), @default_event_limit, @max_event_limit)

      tool_call_limit =
        normalize_limit(
          get_param(params, "toolCallLimit"),
          @default_tool_call_limit,
          @max_tool_call_limit
        )

      opts = %{
        limit: limit,
        history_limit: history_limit,
        event_limit: event_limit,
        tool_call_limit: tool_call_limit,
        include_full_text: truthy?(get_param(params, "includeFullText"), false),
        include_raw_events: truthy?(get_param(params, "includeRawEvents"), false),
        include_run_record: truthy?(get_param(params, "includeRunRecord"), false)
      }

      do_handle(session_key, opts)
    end
  end

  defp do_handle(session_key, opts) do
    all_runs =
      fetch_run_history(session_key, opts.history_limit)
      |> Enum.sort_by(&run_started_at/1, :desc)

    session_meta = fetch_session_meta(session_key)
    total_run_count = session_meta["runCount"] || length(all_runs)

    runs =
      all_runs
      |> Enum.take(opts.limit)
      |> Enum.map(&format_run(&1, opts))

    {:ok, response(session_key, session_meta, runs, total_run_count, opts)}
  rescue
    _ -> {:ok, response(session_key, %{}, [], 0, opts)}
  catch
    :exit, _ ->
      {:ok, response(session_key, %{}, [], 0, opts)}
  end

  defp response(session_key, session_meta, runs, total_run_count, opts) do
    options = %{
      "limit" => opts.limit,
      "historyLimit" => opts.history_limit,
      "eventLimit" => opts.event_limit,
      "toolCallLimit" => opts.tool_call_limit,
      "includeFullText" => opts.include_full_text,
      "includeRawEvents" => opts.include_raw_events,
      "includeRunRecord" => opts.include_run_record
    }

    %{
      "sessionKey" => session_key,
      "session" => session_meta,
      "runs" => runs,
      "runCount" => total_run_count,
      "options" => options,
      "summary" => summary(runs, total_run_count, options)
    }
  end

  defp summary(runs, total_run_count, options) do
    durations =
      runs
      |> Enum.map(& &1["durationMs"])
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    token_totals =
      Enum.reduce(runs, %{"input" => 0, "output" => 0, "total" => 0}, fn run, acc ->
        tokens = run["tokens"] || %{}

        %{
          "input" => acc["input"] + integer_or_zero(tokens["input"]),
          "output" => acc["output"] + integer_or_zero(tokens["output"]),
          "total" => acc["total"] + integer_or_zero(tokens["total"])
        }
      end)

    %{
      "count" => length(runs),
      "totalAvailable" => total_run_count,
      "okCount" => Enum.count(runs, &(&1["ok"] == true)),
      "errorCount" => Enum.count(runs, &present?(&1["error"])),
      "engineCounts" => count_by(runs, "engine"),
      "toolCallCount" => sum_integer(runs, "toolCallCount"),
      "eventCount" => sum_integer(runs, "eventCount"),
      "tokenTotals" => token_totals,
      "averageDurationMs" => average_or_nil(durations),
      "cleanup" => %{
        "includesFullText" => options["includeFullText"] == true,
        "includesRawEvents" => options["includeRawEvents"] == true,
        "includesRunRecords" => options["includeRunRecord"] == true,
        "includesMessageBodies" => true,
        "redactsSensitivePreviews" => options["includeFullText"] != true,
        "redactsSensitiveRunInternals" => true,
        "includesCredentials" => false,
        "includesSecretValues" => options["includeFullText"] == true
      }
    }
  end

  defp require_session_key(params) do
    case get_param(params, "sessionKey") do
      session_key when is_binary(session_key) and session_key != "" ->
        {:ok, session_key}

      _ ->
        {:error, {:bad_request, "sessionKey is required", nil}}
    end
  end

  defp fetch_run_history(session_key, limit) do
    LemonCore.RunStore.history(session_key, limit: limit)
    |> Enum.map(fn {run_id, run_map} -> {to_string_safe(run_id), run_map || %{}} end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp fetch_session_meta(session_key) do
    sess =
      LemonRouter.list_agent_sessions([])
      |> Enum.find(&(&1[:session_key] == session_key))

    if sess do
      %{
        "sessionKey" => session_key,
        "agentId" => sess[:agent_id],
        "channelId" => sess[:channel_id],
        "peerId" => sess[:peer_id],
        "peerLabel" => sess[:peer_label],
        "runCount" => sess[:run_count],
        "active" => sess[:active?] == true,
        "createdAtMs" => sess[:created_at_ms],
        "updatedAtMs" => sess[:updated_at_ms],
        "origin" => to_string_safe(sess[:origin] || :unknown)
      }
    else
      %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp run_started_at({_run_id, run_map}) when is_map(run_map) do
    summary = get_map(run_map, :summary, %{})
    get_map(run_map, :started_at) || get_map(summary, :started_at) || 0
  end

  defp run_started_at(_), do: 0

  defp format_run({run_id, run_map}, opts) do
    summary = get_map(run_map, :summary, %{})
    events = normalize_list(get_map(run_map, :events, []))
    completed = get_map(summary, :completed)

    prompt_raw = safe_binary(get_map(summary, :prompt, ""))
    answer_raw = safe_binary(get_answer(completed))

    prompt = maybe_truncate(prompt_raw, opts.include_full_text, 2_000)
    answer = maybe_truncate(answer_raw, opts.include_full_text, 4_000)

    run =
      %{
        "runId" => run_id,
        "startedAtMs" => get_map(run_map, :started_at) || get_map(summary, :started_at),
        "engine" => get_map(summary, :engine),
        "prompt" => prompt,
        "answer" => answer,
        "ok" => get_ok(completed),
        "error" => serialize_term(get_error(completed)),
        "durationMs" => get_map(summary, :duration_ms),
        "toolCallCount" => count_tool_calls(events),
        "toolCalls" => extract_tool_calls(events, opts.tool_call_limit),
        "tokens" => format_usage(completed),
        "eventCount" => length(events),
        "eventDigest" => build_event_digest(events, opts.event_limit),
        "summaryRaw" => serialize_term(sanitize_text_fields(summary, opts.include_full_text)),
        "completedRaw" => serialize_term(sanitize_text_fields(completed, opts.include_full_text))
      }
      |> maybe_put("promptFull", prompt_raw, opts.include_full_text and prompt_raw != "")
      |> maybe_put("answerFull", answer_raw, opts.include_full_text and answer_raw != "")
      |> maybe_put("events", build_raw_events(events, opts), opts.include_raw_events)
      |> maybe_put("runRecord", fetch_run_record(run_id, opts), opts.include_run_record)

    run
  end

  defp format_run(_other, _opts) do
    %{
      "runId" => nil,
      "startedAtMs" => nil,
      "engine" => nil,
      "prompt" => nil,
      "answer" => nil,
      "ok" => nil,
      "error" => nil,
      "durationMs" => nil,
      "toolCallCount" => 0,
      "toolCalls" => [],
      "tokens" => %{"input" => 0, "output" => 0, "total" => 0, "costUsd" => 0.0},
      "eventCount" => 0,
      "eventDigest" => [],
      "summaryRaw" => %{},
      "completedRaw" => %{}
    }
  end

  defp count_by(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.frequencies()
  end

  defp sum_integer(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp average_or_nil([]), do: nil
  defp average_or_nil(values), do: div(Enum.sum(values), length(values))

  defp integer_or_zero(value) when is_integer(value), do: value
  defp integer_or_zero(_), do: 0

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp sanitize_text_fields(value, true), do: value

  defp sanitize_text_fields(%{__struct__: _} = struct, false) do
    struct
    |> Map.from_struct()
    |> sanitize_text_fields(false)
  end

  defp sanitize_text_fields(map, false) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key_name = key |> key_to_string() |> String.downcase()

      safe_value =
        if key_name in ["prompt", "answer", "prompt_full", "answer_full"] do
          value
          |> safe_binary()
          |> truncate(@max_preview_bytes)
        else
          sanitize_text_fields(value, false)
        end

      {key, safe_value}
    end)
  end

  defp sanitize_text_fields(list, false) when is_list(list),
    do: Enum.map(list, &sanitize_text_fields(&1, false))

  defp sanitize_text_fields(value, false), do: value

  defp fetch_run_record(run_id, opts) when is_binary(run_id) do
    case LemonCore.RunStore.get(run_id) do
      nil ->
        nil

      record when is_map(record) ->
        events = normalize_list(get_map(record, :events, []))
        base = serialize_term(record)

        base =
          if opts.include_raw_events do
            Map.put(base, "events", build_raw_events(events, opts))
          else
            Map.put(base, "events", [])
          end

        Map.put(base, "eventCount", length(events))

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp fetch_run_record(_, _), do: nil

  defp get_answer(nil), do: ""
  defp get_answer(completed) when is_map(completed), do: get_map(completed, :answer, "") || ""
  defp get_answer(_), do: ""

  defp get_ok(nil), do: nil
  defp get_ok(completed) when is_map(completed), do: get_map(completed, :ok)
  defp get_ok(_), do: nil

  defp get_error(nil), do: nil
  defp get_error(completed) when is_map(completed), do: get_map(completed, :error)
  defp get_error(_), do: nil

  defp format_usage(nil), do: %{"input" => 0, "output" => 0, "total" => 0, "costUsd" => 0.0}

  defp format_usage(completed) when is_map(completed) do
    usage = get_map(completed, :usage)

    if is_map(usage) do
      %{
        "input" => get_map(usage, :input, 0),
        "output" => get_map(usage, :output, 0),
        "total" => get_map(usage, :total_tokens, 0),
        "costUsd" => get_cost_total(usage)
      }
    else
      %{"input" => 0, "output" => 0, "total" => 0, "costUsd" => 0.0}
    end
  end

  defp format_usage(_), do: %{"input" => 0, "output" => 0, "total" => 0, "costUsd" => 0.0}

  defp get_cost_total(usage) do
    case get_map(usage, :cost) do
      nil ->
        0.0

      cost when is_map(cost) ->
        get_map(cost, :total, 0.0) || 0.0

      _ ->
        0.0
    end
  end

  defp count_tool_calls(events) when is_list(events) do
    Enum.count(events, &action_event?/1)
  rescue
    _ -> 0
  end

  defp count_tool_calls(_), do: 0

  defp extract_tool_calls(events, max) when is_list(events) do
    events
    |> Enum.filter(&action_event?/1)
    |> Enum.take(max)
    |> Enum.map(&format_tool_call/1)
  rescue
    _ -> []
  end

  defp extract_tool_calls(_, _), do: []

  defp action_event?(ev) when is_map(ev) do
    Map.get(ev, :__event__) == :action_event or is_map(get_map(ev, :action))
  rescue
    _ -> false
  end

  defp action_event?(_), do: false

  defp format_tool_call(ev) do
    action = get_map(ev, :action)

    %{
      "name" => get_map(action, :title),
      "kind" => normalize_string(get_map(action, :kind)),
      "ok" => get_map(ev, :ok),
      "phase" => normalize_string(get_map(ev, :phase)),
      "detail" => format_tool_detail(get_map(action, :detail)),
      "raw" => serialize_term(action)
    }
  rescue
    _ ->
      %{
        "name" => nil,
        "kind" => nil,
        "ok" => nil,
        "phase" => nil,
        "detail" => nil,
        "raw" => %{}
      }
  end

  defp format_tool_detail(nil), do: nil

  defp format_tool_detail(detail) when is_binary(detail),
    do: detail |> redact_text() |> truncate(@max_preview_bytes)

  defp format_tool_detail(detail) do
    truncate(inspect(serialize_term(detail), limit: 120), @max_preview_bytes)
  end

  defp build_event_digest(events, event_limit) when is_list(events) do
    events
    |> Enum.take(event_limit)
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} ->
      %{
        "index" => idx,
        "type" => event_type_name(event),
        "phase" => normalize_string(get_map(event, :phase)),
        "ok" => get_map(event, :ok),
        "timestampMs" => event_timestamp(event),
        "preview" => truncate(inspect(serialize_term(event), limit: 120), @max_preview_bytes)
      }
    end)
  end

  defp build_event_digest(_, _), do: []

  defp build_raw_events(events, opts) do
    events
    |> Enum.take(opts.event_limit)
    |> Enum.map(&serialize_term/1)
  end

  defp event_type_name(event) when is_map(event) do
    cond do
      is_atom(Map.get(event, :__event__)) ->
        Atom.to_string(Map.get(event, :__event__))

      is_binary(get_map(event, :type)) ->
        get_map(event, :type)

      is_atom(get_map(event, :type)) ->
        Atom.to_string(get_map(event, :type))

      is_binary(get_map(event, :event_type)) ->
        get_map(event, :event_type)

      is_atom(get_map(event, :event_type)) ->
        Atom.to_string(get_map(event, :event_type))

      is_atom(Map.get(event, :__struct__)) ->
        event.__struct__ |> Module.split() |> List.last()

      true ->
        "event"
    end
  rescue
    _ -> "event"
  end

  defp event_type_name(_), do: "event"

  defp event_timestamp(event) when is_map(event) do
    get_map(event, :timestamp_ms) || get_map(event, :ts_ms) || get_map(event, :timestamp)
  end

  defp event_timestamp(_), do: nil

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp serialize_term(value, depth \\ 0)

  defp serialize_term(_value, depth) when depth >= 7, do: "[max_depth]"

  defp serialize_term(%{__struct__: mod} = struct, depth) do
    struct
    |> Map.from_struct()
    |> Map.put("__struct__", inspect(mod))
    |> serialize_term(depth + 1)
  end

  defp serialize_term(value, depth) when is_map(value) do
    Enum.reduce(value, %{}, fn {k, v}, acc ->
      key = key_to_string(k)
      value = if sensitive_key?(key), do: %{"redacted" => true, "kind" => "secret"}, else: v

      Map.put(acc, key, serialize_term(value, depth + 1))
    end)
  end

  defp serialize_term(value, depth) when is_list(value) do
    Enum.map(value, &serialize_term(&1, depth + 1))
  end

  defp serialize_term(value, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&serialize_term(&1, depth + 1))
  end

  defp serialize_term(value, _depth) when is_binary(value),
    do: value |> redact_text() |> truncate(@max_string_bytes)

  defp serialize_term(value, _depth) when is_integer(value) or is_float(value), do: value
  defp serialize_term(value, _depth) when is_boolean(value) or is_nil(value), do: value
  defp serialize_term(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp serialize_term(value, _depth), do: inspect(value, limit: 200)

  defp redact_text(text) do
    text
    |> then(fn value ->
      Regex.replace(
        ~r/(?i)\b(api[_-]?key|token|secret|password|private[_-]?key|credential)\s*=\s*([^\s,;]+)/,
        value,
        "\\1=[REDACTED]"
      )
    end)
    |> then(fn value ->
      Regex.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/=-]+/, value, "Bearer [REDACTED]")
    end)
  end

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    Enum.any?(
      ["api_key", "apikey", "secret", "token", "password", "private_key", "credential"],
      &String.contains?(normalized, &1)
    )
  end

  defp get_map(nil, _key, default), do: default

  defp get_map(map, key, default) when is_map(map) do
    key_string = key_to_string(key)

    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      Map.has_key?(map, key_string) ->
        Map.get(map, key_string)

      true ->
        default
    end
  rescue
    _ -> default
  end

  defp get_map(_map, _key, default), do: default

  defp get_map(map, key), do: get_map(map, key, nil)

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value)

  defp safe_binary(nil), do: ""
  defp safe_binary(value) when is_binary(value), do: value
  defp safe_binary(value), do: inspect(value)

  defp maybe_truncate(value, true, _max), do: value
  defp maybe_truncate(value, false, max), do: value |> redact_text() |> truncate(max)

  defp truncate(nil, _), do: nil
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text

  defp truncate(text, max) when is_binary(text) do
    String.slice(text, 0, max) <> "...[truncated]"
  end

  defp truncate(value, _max), do: safe_binary(value)

  defp to_string_safe(nil), do: nil
  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v) when is_atom(v), do: Atom.to_string(v)
  defp to_string_safe(v), do: to_string(v)

  defp truthy?(value, _default) when is_boolean(value), do: value

  defp truthy?(value, _default) when value in [1, "1", "true", "TRUE", "yes", "on"], do: true
  defp truthy?(value, _default) when value in [0, "0", "false", "FALSE", "no", "off"], do: false
  defp truthy?(_value, default), do: default

  defp normalize_limit(limit, _default, max) when is_integer(limit) and limit > 0,
    do: min(limit, max)

  defp normalize_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, max)
      _ -> default
    end
  end

  defp normalize_limit(_, default, _), do: default

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
