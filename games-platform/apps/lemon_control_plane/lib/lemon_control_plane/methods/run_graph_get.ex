defmodule LemonControlPlane.Methods.RunGraphGet do
  @moduledoc """
  Handler for the `run.graph.get` method.

  Returns the parent/child run structure for a given run_id.

  Supports optional deep internals for each node:

  - run-store record (`includeRunRecord`)
  - run-store raw events (`includeRunEvents`, `runEventLimit`)
  - introspection timeline (`includeIntrospection`, `introspectionLimit`)
  """

  @behaviour LemonControlPlane.Method

  @default_max_depth 10
  @max_max_depth 20
  @default_child_lookup_limit 200
  @max_child_lookup_limit 1_000
  @default_introspection_limit 200
  @max_introspection_limit 2_000
  @default_run_event_limit 300
  @max_run_event_limit 5_000

  @impl true
  def name, do: "run.graph.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    run_id = get_param(params, "runId")

    if is_nil(run_id) or run_id == "" do
      {:error, {:invalid_request, "runId is required", nil}}
    else
      opts = parse_opts(params)
      graph = build_run_graph(run_id, opts)
      node_count = count_nodes(graph)

      {:ok,
       %{
         "runId" => run_id,
         "graph" => graph,
         "nodeCount" => node_count,
         "options" => %{
           "maxDepth" => opts.max_depth,
           "childLimit" => opts.child_limit,
           "includeRunRecord" => opts.include_run_record,
           "includeRunEvents" => opts.include_run_events,
           "runEventLimit" => opts.run_event_limit,
           "includeIntrospection" => opts.include_introspection,
           "introspectionLimit" => opts.introspection_limit
         }
       }}
    end
  rescue
    _ ->
      run_id = get_param(params || %{}, "runId")

      {:ok,
       %{
         "runId" => run_id,
         "graph" => %{
           "runId" => run_id,
           "status" => "unknown",
           "children" => []
         },
         "nodeCount" => 1
       }}
  end

  defp build_run_graph(run_id, opts) do
    build_node(run_id, opts, 0, MapSet.new())
  end

  defp build_node(run_id, opts, depth, visited) do
    if MapSet.member?(visited, run_id) do
      %{
        "runId" => run_id,
        "status" => "cycle",
        "children" => []
      }
    else
      visited = MapSet.put(visited, run_id)
      graph_record = fetch_graph_record(run_id)
      store_record = fetch_store_record(run_id)

      base =
        %{
          "runId" => run_id,
          "status" => fetch_run_status(run_id, graph_record, store_record),
          "parentRunId" => get_graph_field(graph_record, :parent),
          "sessionKey" => resolve_session_key(graph_record, store_record),
          "agentId" => resolve_agent_id(store_record),
          "engine" => resolve_engine(store_record),
          "startedAtMs" => resolve_started_at_ms(graph_record, store_record),
          "completedAtMs" => resolve_completed_at_ms(graph_record, store_record),
          "durationMs" => resolve_duration_ms(graph_record, store_record),
          "ok" => resolve_ok(store_record),
          "error" => resolve_error(store_record),
          "children" => []
        }
        |> maybe_put(
          "runRecord",
          serialize_run_record(store_record, opts.include_run_events, opts.run_event_limit),
          opts.include_run_record
        )
        |> maybe_put(
          "introspection",
          fetch_introspection(run_id, opts.introspection_limit),
          opts.include_introspection
        )

      children =
        if depth < opts.max_depth do
          collect_child_run_ids(
            run_id,
            graph_record,
            opts.child_limit,
            has_graph_record?(graph_record) or has_store_record?(store_record)
          )
          |> Enum.reject(&MapSet.member?(visited, &1))
          |> Enum.map(&build_node(&1, opts, depth + 1, visited))
        else
          []
        end

      Map.put(base, "children", children)
    end
  end

  defp parse_opts(params) do
    %{
      max_depth:
        normalize_limit(get_param(params, "maxDepth"), @default_max_depth, @max_max_depth),
      child_limit:
        normalize_limit(
          get_param(params, "childLimit"),
          @default_child_lookup_limit,
          @max_child_lookup_limit
        ),
      include_run_record: truthy?(get_param(params, "includeRunRecord"), false),
      include_run_events: truthy?(get_param(params, "includeRunEvents"), false),
      run_event_limit:
        normalize_limit(
          get_param(params, "runEventLimit"),
          @default_run_event_limit,
          @max_run_event_limit
        ),
      include_introspection: truthy?(get_param(params, "includeIntrospection"), false),
      introspection_limit:
        normalize_limit(
          get_param(params, "introspectionLimit"),
          @default_introspection_limit,
          @max_introspection_limit
        )
    }
  end

  defp fetch_run_status(run_id, graph_record, store_record) when is_binary(run_id) do
    graph_status = normalize_graph_status(get_graph_field(graph_record, :status))

    cond do
      graph_status in ["queued", "running", "completed", "error", "killed", "cancelled", "lost"] ->
        graph_status

      run_active?(run_id) ->
        "active"

      true ->
        fetch_completed_status(run_id, store_record)
    end
  rescue
    _ -> "unknown"
  catch
    :exit, _ -> "unknown"
  end

  defp fetch_run_status(_run_id, _graph_record, _store_record), do: "unknown"

  defp run_active?(run_id) when is_binary(run_id) do
    case Process.whereis(LemonRouter.RunRegistry) do
      pid when is_pid(pid) ->
        match?([{_pid, _} | _], Registry.lookup(LemonRouter.RunRegistry, run_id))

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp run_active?(_), do: false

  defp fetch_completed_status(run_id, store_record) do
    with status when is_binary(status) <- derive_status_from_store_record(store_record) do
      status
    else
      _ ->
        if has_store_record?(store_record) do
          fetch_completed_status_from_introspection(run_id)
        else
          "unknown"
        end
    end
  end

  defp fetch_completed_status_from_introspection(run_id) do
    events = LemonCore.Introspection.list(run_id: run_id, event_type: :run_completed, limit: 1)

    case events do
      [event | _] ->
        payload = event[:payload] || event["payload"] || %{}
        ok = payload[:ok] || payload["ok"]
        error = payload[:error] || payload["error"]

        cond do
          error in [:user_requested, :interrupted, :aborted] -> "aborted"
          ok == true -> "completed"
          true -> "error"
        end

      [] ->
        "unknown"
      end
  rescue
    _ -> "unknown"
  catch
    :exit, _ -> "unknown"
  end

  defp derive_status_from_store_record(nil), do: nil

  defp derive_status_from_store_record(store_record) when is_map(store_record) do
    summary = get_map(store_record, :summary, %{})
    completed = get_map(summary, :completed, %{})
    ok = get_map(completed, :ok)
    error = get_map(completed, :error)

    cond do
      error in [
        :user_requested,
        :interrupted,
        :aborted,
        "user_requested",
        "interrupted",
        "aborted"
      ] ->
        "aborted"

      ok == true ->
        "completed"

      not is_nil(error) ->
        "error"

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp derive_status_from_store_record(_), do: nil

  defp collect_child_run_ids(run_id, graph_record, child_limit, include_introspection_children?) do
    graph_children =
      graph_record
      |> get_graph_field(:children)
      |> normalize_run_id_list()

    introspection_children =
      if include_introspection_children? and store_available?() do
        LemonCore.Introspection.list(
          parent_run_id: run_id,
          event_type: :run_started,
          limit: child_limit
        )
        |> Enum.map(&(get_map(&1, :run_id) || get_map(&1, "run_id")))
        |> normalize_run_id_list()
      else
        []
      end

    (graph_children ++ introspection_children)
    |> Enum.uniq()
    |> Enum.take(child_limit)
  rescue
    _ -> graph_record |> get_graph_field(:children) |> normalize_run_id_list()
  catch
    :exit, _ -> graph_record |> get_graph_field(:children) |> normalize_run_id_list()
  end

  defp normalize_run_id_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp normalize_run_id_list(_), do: []

  defp has_graph_record?(record) when is_map(record), do: map_size(record) > 0
  defp has_graph_record?(_), do: false

  defp has_store_record?(record) when is_map(record), do: map_size(record) > 0
  defp has_store_record?(_), do: false

  defp store_available?, do: is_pid(Process.whereis(LemonCore.Store))

  defp fetch_graph_record(run_id) do
    case CodingAgent.RunGraph.get(run_id) do
      {:ok, record} when is_map(record) -> record
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp fetch_store_record(run_id) do
    case LemonCore.Store.get_run(run_id) do
      record when is_map(record) -> record
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp fetch_introspection(run_id, limit) do
    LemonCore.Introspection.list(run_id: run_id, limit: limit)
    |> Enum.map(fn event ->
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
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp serialize_run_record(store_record, include_run_events, run_event_limit)
       when is_map(store_record) do
    events = get_map(store_record, :events, []) |> normalize_list()
    serialized = serialize_term(store_record)

    serialized =
      if include_run_events do
        Map.put(
          serialized,
          "events",
          events |> Enum.take(run_event_limit) |> Enum.map(&serialize_term/1)
        )
      else
        Map.put(serialized, "events", [])
      end

    Map.put(serialized, "eventCount", length(events))
  rescue
    _ -> nil
  end

  defp serialize_run_record(_store_record, _include_run_events, _run_event_limit), do: nil

  defp resolve_session_key(graph_record, store_record) do
    get_graph_field(graph_record, :session_key) ||
      get_map(get_map(store_record, :summary, %{}), :session_key)
  end

  defp resolve_agent_id(store_record) do
    summary = get_map(store_record, :summary, %{})
    get_map(summary, :agent_id)
  end

  defp resolve_engine(store_record) do
    summary = get_map(store_record, :summary, %{})
    get_map(summary, :engine)
  end

  defp resolve_started_at_ms(graph_record, store_record) do
    summary = get_map(store_record, :summary, %{})
    store_started = get_map(store_record, :started_at) || get_map(summary, :started_at)
    graph_started = get_graph_field(graph_record, :started_at)
    to_ms(store_started || graph_started)
  end

  defp resolve_completed_at_ms(graph_record, _store_record) do
    graph_completed = get_graph_field(graph_record, :completed_at)
    to_ms(graph_completed)
  end

  defp resolve_duration_ms(graph_record, store_record) do
    summary = get_map(store_record, :summary, %{})
    summary_duration = get_map(summary, :duration_ms)

    cond do
      is_integer(summary_duration) ->
        summary_duration

      true ->
        started_at = to_ms(get_graph_field(graph_record, :started_at))
        completed_at = to_ms(get_graph_field(graph_record, :completed_at))

        if is_integer(started_at) and is_integer(completed_at),
          do: max(completed_at - started_at, 0),
          else: nil
    end
  end

  defp resolve_ok(store_record) do
    summary = get_map(store_record, :summary, %{})
    completed = get_map(summary, :completed, %{})
    get_map(completed, :ok)
  end

  defp resolve_error(store_record) do
    summary = get_map(store_record, :summary, %{})
    completed = get_map(summary, :completed, %{})
    serialize_term(get_map(completed, :error))
  end

  defp normalize_graph_status(nil), do: nil
  defp normalize_graph_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_graph_status(status) when is_binary(status), do: status
  defp normalize_graph_status(_), do: nil

  defp get_graph_field(nil, _key), do: nil

  defp get_graph_field(record, key) when is_map(record) do
    cond do
      Map.has_key?(record, key) ->
        Map.get(record, key)

      is_atom(key) and Map.has_key?(record, Atom.to_string(key)) ->
        Map.get(record, Atom.to_string(key))

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp get_graph_field(_record, _key), do: nil

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
      Map.put(acc, key_to_string(k), serialize_term(v, depth + 1))
    end)
  end

  defp serialize_term(value, depth) when is_list(value),
    do: Enum.map(value, &serialize_term(&1, depth + 1))

  defp serialize_term(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&serialize_term(&1, depth + 1))

  defp serialize_term(value, _depth) when is_boolean(value) or is_nil(value), do: value
  defp serialize_term(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp serialize_term(value, _depth), do: inspect(value, limit: 200)

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

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

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value)

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

  defp to_ms(nil), do: nil
  defp to_ms(ms) when is_integer(ms) and ms > 9_999_999_999, do: ms
  defp to_ms(sec) when is_integer(sec), do: sec * 1000
  defp to_ms(_), do: nil

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil

  defp count_nodes(%{"children" => children}) when is_list(children) do
    1 + Enum.reduce(children, 0, fn child, acc -> acc + count_nodes(child) end)
  end

  defp count_nodes(_), do: 1
end
