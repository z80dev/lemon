defmodule LemonControlPlane.Methods.SessionDetail do
  @moduledoc """
  Handler for `session.detail`.

  Returns session/run internals: run summaries, tool calls and, on request, full
  text, raw run events and run records. Prompts, answers, errors, tool titles and
  arguments, event previews and raw payloads are content and need
  `operator.content`; read-only callers get ids, status, counts, token usage and
  timings, and the include flags are ignored.
  """

  import LemonControlPlane.Methods.Params, only: [get_param: 2, truthy?: 2, normalize_limit: 3]

  alias LemonControlPlane.Auth.Authorize

  @behaviour LemonControlPlane.Method

  @default_limit 20
  @max_limit 200
  @default_history_limit 500
  @max_history_limit 5_000
  @default_event_limit 250
  @max_event_limit 2_000
  @default_tool_call_limit 50
  @max_tool_call_limit 500
  @max_preview_bytes 800

  @impl true
  def name, do: "session.detail"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    params = params || %{}
    content? = Authorize.content?(ctx)

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
        content?: content?,
        include_full_text: content? and truthy?(get_param(params, "includeFullText"), false),
        include_raw_events: content? and truthy?(get_param(params, "includeRawEvents"), false),
        include_run_record: content? and truthy?(get_param(params, "includeRunRecord"), false)
      }

      do_handle(session_key, opts)
    end
  end

  defp do_handle(session_key, opts) do
    all_runs =
      fetch_run_history(session_key, opts.history_limit)
      |> Enum.sort_by(&run_started_at/1, :desc)

    case fetch_session_meta(session_key) do
      {:ok, session_meta} ->
        total_run_count = session_meta["runCount"] || length(all_runs)

        runs =
          all_runs
          |> Enum.take(opts.limit)
          |> Enum.map(&format_run(&1, opts))

        {:ok, response(session_key, session_meta, runs, total_run_count, opts)}

      {:error, _reason} ->
        {:error, {:unavailable, "Session directory is unavailable", nil}}
    end
  rescue
    _ -> {:error, {:unavailable, "Session directory is unavailable", nil}}
  catch
    :exit, _ -> {:error, {:unavailable, "Session directory is unavailable", nil}}
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
      "contentWithheld" => not opts.content?,
      "summary" => summary(runs, total_run_count, options, opts.content?)
    }
  end

  defp summary(runs, total_run_count, options, content?) do
    durations =
      runs
      |> Enum.map(& &1["durationMs"])
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    token_totals =
      Map.new(["input", "output", "total"], fn key ->
        values = Enum.map(runs, &get_in(&1, ["tokens", key]))
        {key, if(Enum.all?(values, &is_integer/1), do: Enum.sum(values), else: nil)}
      end)

    %{
      "count" => length(runs),
      "totalAvailable" => total_run_count,
      "okCount" => Enum.count(runs, &(&1["ok"] == true)),
      "errorCount" => Enum.count(runs, &(&1["hasError"] == true)),
      "engineCounts" => count_by(runs, "engine"),
      "toolCallCount" => sum_integer(runs, "toolCallCount"),
      "eventCount" => sum_integer(runs, "eventCount"),
      "tokenTotals" => token_totals,
      "averageDurationMs" => average_or_nil(durations),
      "cleanup" => %{
        "includesFullText" => options["includeFullText"] == true,
        "includesRawEvents" => options["includeRawEvents"] == true,
        "includesRunRecords" => options["includeRunRecord"] == true,
        "includesMessageBodies" => content?,
        "redactsSensitivePreviews" => true,
        "redactsSensitiveRunInternals" => true,
        "includesCredentials" => false,
        "includesSecretValues" => false
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
    case LemonRouter.list_agent_sessions([]) do
      sessions when is_list(sessions) ->
        sess = Enum.find(sessions, &(&1[:session_key] == session_key))

        meta =
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
            |> Map.merge(routing_meta(session_key, sess[:agent_id]))
          else
            %{"sessionKey" => session_key}
            |> Map.merge(routing_meta(session_key, nil))
          end

        lifecycle_meta =
          case LemonCore.SessionLifecycle.get(session_key) do
            nil ->
              %{}

            session ->
              %{
                "title" => session.title,
                "pinned" => session.pinned,
                "archived" => session.archived,
                "metadataUpdatedAtMs" => session.metadata_updated_at_ms
              }
          end

        {:ok, Map.merge(meta, lifecycle_meta)}

      {:error, _reason} ->
        {:error, :unavailable}

      _unexpected ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # `model`/`provider`/`contextWindow`/`thinkingLevel` — what this session's next run resolves
  # to, not what the last one used. `modelSource` says which layer supplied it, so a client can
  # tell a pinned model from an inherited default; `modelOverride` is the session's own pin, or
  # nil.
  defp routing_meta(session_key, agent_id) do
    resolved = LemonControlPlane.SessionModel.resolve(session_key, agent_id)

    resolved
    |> Map.drop(["defaultEngine", "preferredEngine"])
    |> Map.put("modelOverride", LemonControlPlane.SessionModel.override(session_key))
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
    error = get_error(completed)

    run = %{
      "runId" => run_id,
      "startedAtMs" => get_map(run_map, :started_at) || get_map(summary, :started_at),
      "engine" => get_map(summary, :engine),
      "ok" => get_ok(completed),
      "hasError" => present?(error),
      "durationMs" => get_map(summary, :duration_ms),
      "toolCallCount" => count_tool_calls(events),
      "toolCalls" => extract_tool_calls(events, opts.tool_call_limit, opts.content?),
      "tokens" => format_usage(completed),
      "eventCount" => length(events),
      "eventDigest" => build_event_digest(events, opts.event_limit, opts.content?)
    }

    if opts.content?,
      do: put_run_content(run, run_id, summary, completed, error, events, opts),
      else: run
  end

  defp format_run(_other, opts) do
    run = %{
      "runId" => nil,
      "startedAtMs" => nil,
      "engine" => nil,
      "ok" => nil,
      "hasError" => false,
      "durationMs" => nil,
      "toolCallCount" => 0,
      "toolCalls" => [],
      "tokens" => format_usage(nil),
      "eventCount" => 0,
      "eventDigest" => []
    }

    if opts.content?,
      do:
        Map.merge(run, %{
          "prompt" => nil,
          "answer" => nil,
          "error" => nil,
          "summaryRaw" => %{},
          "completedRaw" => %{}
        }),
      else: run
  end

  defp put_run_content(run, run_id, summary, completed, error, events, opts) do
    prompt_raw = safe_binary(get_map(summary, :prompt, ""))
    answer_raw = safe_binary(get_answer(completed))

    run
    |> Map.merge(%{
      "prompt" => maybe_truncate(prompt_raw, opts.include_full_text, 2_000),
      "answer" => maybe_truncate(answer_raw, opts.include_full_text, 4_000),
      "error" => LemonCore.Redact.project(error),
      "summaryRaw" => raw_projection(summary, opts),
      "completedRaw" => raw_projection(completed, opts)
    })
    |> maybe_put(
      "promptFull",
      LemonCore.Redact.text(prompt_raw),
      opts.include_full_text and prompt_raw != ""
    )
    |> maybe_put(
      "answerFull",
      LemonCore.Redact.text(answer_raw),
      opts.include_full_text and answer_raw != ""
    )
    |> maybe_put("events", build_raw_events(events, opts), opts.include_raw_events)
    |> maybe_put("runRecord", fetch_run_record(run_id, opts), opts.include_run_record)
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

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp fetch_run_record(run_id, opts) when is_binary(run_id) do
    case LemonCore.RunStore.get_with_events(run_id) do
      nil ->
        nil

      record when is_map(record) ->
        events = normalize_list(get_map(record, :events, []))
        base = project(record, opts)

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

  defp format_usage(nil), do: %{"input" => nil, "output" => nil, "total" => nil, "costUsd" => nil}

  defp format_usage(completed) when is_map(completed) do
    usage = get_map(completed, :usage)

    if is_map(usage) do
      %{
        "input" => get_map(usage, :input),
        "output" => get_map(usage, :output),
        "total" => get_map(usage, :total_tokens),
        "costUsd" => get_cost_total(usage)
      }
    else
      format_usage(nil)
    end
  end

  defp format_usage(_), do: format_usage(nil)

  defp get_cost_total(usage) do
    normalized = LemonControlPlane.UsageTokens.normalize(usage) || %{}
    normalized["costUsd"]
  end

  defp count_tool_calls(events) when is_list(events) do
    Enum.count(events, &action_event?/1)
  rescue
    _ -> 0
  end

  defp extract_tool_calls(events, max, content?) when is_list(events) do
    events
    |> Enum.filter(&action_event?/1)
    |> Enum.take(max)
    |> Enum.map(&format_tool_call(&1, content?))
  rescue
    _ -> []
  end

  defp action_event?(ev) when is_map(ev) do
    Map.get(ev, :__event__) == :action_event or is_map(get_map(ev, :action))
  rescue
    _ -> false
  end

  defp action_event?(_), do: false

  # Tool titles, details and raw actions carry commands, paths and arguments.
  defp format_tool_call(ev, content?) do
    action = get_map(ev, :action)

    call = %{
      "kind" => normalize_string(get_map(action, :kind)),
      "ok" => get_map(ev, :ok),
      "phase" => normalize_string(get_map(ev, :phase))
    }

    if content?,
      do:
        Map.merge(call, %{
          "name" => get_map(action, :title),
          "detail" => format_tool_detail(get_map(action, :detail)),
          "raw" => LemonCore.Redact.project(action)
        }),
      else: call
  rescue
    _ -> %{"kind" => nil, "ok" => nil, "phase" => nil}
  end

  defp format_tool_detail(nil), do: nil

  defp format_tool_detail(detail) when is_binary(detail),
    do: detail |> LemonCore.Redact.text() |> truncate(@max_preview_bytes)

  defp format_tool_detail(detail) do
    truncate(inspect(LemonCore.Redact.project(detail), limit: 120), @max_preview_bytes)
  end

  defp build_event_digest(events, event_limit, content?) when is_list(events) do
    events
    |> Enum.take(event_limit)
    |> Enum.with_index()
    |> Enum.map(fn {event, idx} ->
      digest = %{
        "index" => idx,
        "type" => event_type_name(event),
        "phase" => normalize_string(get_map(event, :phase)),
        "ok" => get_map(event, :ok),
        "timestampMs" => event_timestamp(event)
      }

      if content?,
        do:
          Map.put(
            digest,
            "preview",
            truncate(inspect(LemonCore.Redact.project(event), limit: 120), @max_preview_bytes)
          ),
        else: digest
    end)
  end

  defp build_raw_events(events, opts) do
    events
    |> Enum.take(opts.event_limit)
    |> Enum.map(&project(&1, opts))
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

  # Explicit full-text requests get larger caps; credentials are scrubbed either way.
  defp project(value, %{include_full_text: true}), do: LemonCore.Redact.operator(value)
  defp project(value, _opts), do: LemonCore.Redact.project(value)

  # Without includeFullText, raw run maps keep only preview-sized strings.
  defp raw_projection(value, %{include_full_text: true}), do: LemonCore.Redact.operator(value)

  defp raw_projection(value, _opts),
    do: LemonCore.Redact.project(value, max_string_bytes: @max_preview_bytes)

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

  defp maybe_truncate(value, true, _max), do: LemonCore.Redact.text(value)
  defp maybe_truncate(value, false, max), do: value |> LemonCore.Redact.text() |> truncate(max)

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
end
