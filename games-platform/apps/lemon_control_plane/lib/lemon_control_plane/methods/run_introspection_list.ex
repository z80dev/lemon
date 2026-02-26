defmodule LemonControlPlane.Methods.RunIntrospectionList do
  @moduledoc """
  Handler for `run.introspection.list`.

  Returns introspection events for a run plus optional run-store internals.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 500
  @max_limit 5_000
  @default_run_event_limit 300
  @max_run_event_limit 5_000

  @impl true
  def name, do: "run.introspection.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    run_id = get_param(params, "runId")

    if is_binary(run_id) and run_id != "" do
      limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)
      run_event_limit = normalize_limit(get_param(params, "runEventLimit"), @default_run_event_limit, @max_run_event_limit)

      event_types =
        get_param(params, "eventTypes")
        |> normalize_event_types()

      since_ms = normalize_optional_integer(get_param(params, "sinceMs"))
      until_ms = normalize_optional_integer(get_param(params, "untilMs"))
      include_run_record = truthy?(get_param(params, "includeRunRecord"), true)
      include_run_events = truthy?(get_param(params, "includeRunEvents"), false)

      events = fetch_events(run_id, limit, event_types, since_ms, until_ms)
      run_record = if include_run_record, do: fetch_run_record(run_id, include_run_events, run_event_limit), else: nil

      {:ok,
       %{
         "runId" => run_id,
         "events" => events,
         "total" => length(events),
         "eventTypes" => summarize_event_types(events),
         "runRecord" => run_record,
         "options" => %{
           "limit" => limit,
           "runEventLimit" => run_event_limit,
           "eventTypes" => event_types,
           "sinceMs" => since_ms,
           "untilMs" => until_ms,
           "includeRunRecord" => include_run_record,
           "includeRunEvents" => include_run_events
         }
       }}
    else
      {:error, {:bad_request, "runId is required", nil}}
    end
  rescue
    _ ->
      run_id = (params || %{})["runId"]

      {:ok,
       %{
         "runId" => run_id,
         "events" => [],
         "total" => 0,
         "eventTypes" => %{},
         "runRecord" => nil
       }}
  end

  defp fetch_events(run_id, limit, event_types, since_ms, until_ms) do
    if Code.ensure_loaded?(LemonCore.Introspection) do
      query_opts =
        [run_id: run_id, limit: limit]
        |> maybe_put_opt(:event_type, event_types != [] && event_types)
        |> maybe_put_opt(:since_ms, since_ms)
        |> maybe_put_opt(:until_ms, until_ms)

      LemonCore.Introspection.list(query_opts)
      |> Enum.filter(&filter_by_event_types(&1, event_types))
      |> Enum.map(&format_event/1)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp fetch_run_record(run_id, include_run_events, run_event_limit) do
    case LemonCore.Store.get_run(run_id) do
      nil ->
        nil

      record when is_map(record) ->
        events = normalize_list(get_map(record, :events, []))
        serialized = serialize_term(record)

        serialized =
          if include_run_events do
            Map.put(serialized, "events", events |> Enum.take(run_event_limit) |> Enum.map(&serialize_term/1))
          else
            Map.put(serialized, "events", [])
          end

        Map.put(serialized, "eventCount", length(events))

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_event(event) when is_map(event) do
    %{
      "eventId" => get_map(event, :event_id),
      "eventType" => normalize_string(get_map(event, :event_type)),
      "tsMs" => get_map(event, :ts_ms),
      "payload" => serialize_term(get_map(event, :payload, %{})),
      "runId" => get_map(event, :run_id),
      "sessionKey" => get_map(event, :session_key),
      "agentId" => get_map(event, :agent_id),
      "parentRunId" => get_map(event, :parent_run_id),
      "engine" => get_map(event, :engine),
      "provenance" => normalize_string(get_map(event, :provenance))
    }
  end

  defp format_event(_), do: %{}

  defp summarize_event_types(events) do
    Enum.reduce(events, %{}, fn event, acc ->
      event_type = event["eventType"] || "unknown"
      Map.update(acc, event_type, 1, &(&1 + 1))
    end)
  end

  defp filter_by_event_types(_event, []), do: true

  defp filter_by_event_types(event, event_types) do
    event_type = normalize_string(get_map(event, :event_type))
    event_type in event_types
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, false), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_event_types(nil), do: []

  defp normalize_event_types(value) when is_binary(value) do
    [value]
  end

  defp normalize_event_types(value) when is_list(value) do
    value
    |> Enum.map(&normalize_string/1)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp normalize_event_types(_), do: []

  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_integer(_), do: nil

  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(value, _default) when value in ["true", "TRUE", "1", 1, "yes", "on"], do: true
  defp truthy?(value, _default) when value in ["false", "FALSE", "0", 0, "no", "off"], do: false
  defp truthy?(_value, default), do: default

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
      Map.put(acc, key_to_string(k), serialize_term(v, depth + 1))
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

  defp serialize_term(value, _depth) when is_boolean(value) or is_nil(value), do: value
  defp serialize_term(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp serialize_term(value, _depth) when is_binary(value), do: value
  defp serialize_term(value, _depth) when is_integer(value) or is_float(value), do: value
  defp serialize_term(value, _depth), do: inspect(value, limit: 200)

  defp get_map(nil, _key, default), do: default

  defp get_map(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        default
    end
  rescue
    _ -> default
  end

  defp get_map(_map, _key, default), do: default
  defp get_map(map, key), do: get_map(map, key, nil)

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value)

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

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
