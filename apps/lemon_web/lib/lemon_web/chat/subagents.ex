defmodule LemonWeb.Chat.Subagents do
  @moduledoc """
  Read-only, content-free projection of the session's task/run graph for the
  chat inspector's Subagents tab.

  The current session establishes ownership; only its selected run's children
  and their actual graph/task descendants are followed. No task descriptions,
  prompts, results, working directories or metadata enter the returned view.
  The tree is capped at 50 nodes and eight levels, including cycle protection.
  A delegated child session links to its own chat workspace.
  """

  alias LemonCore.SessionKey
  alias LemonMemory.Safety

  @max_nodes 50
  @max_depth 8
  @statuses ~w(queued running completed error failed killed cancelled canceled timeout aborted lost tracking_lost)

  def snapshot(session_key, run_id) do
    case runtime(:list_tasks, []) do
      tasks when is_list(tasks) -> project(tasks, session_key, run_id)
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  @doc "Renders the shared recovery authority without keeping another task store."
  def from_recovery(%{"status" => "ok", "items" => items} = projection) when is_list(items) do
    truncated? = projection["truncated"] == true or length(items) > @max_nodes
    items = Enum.take(items, @max_nodes)
    parents = Map.new(items, &{&1["runId"], &1["parentRunId"]})

    nodes =
      Enum.flat_map(items, fn row ->
        case identifier(row["runId"]) do
          nil ->
            []

          id ->
            [
              %{
                id: id,
                dom_id:
                  "subagent-" <> Base.url_encode64(:crypto.hash(:sha256, id), padding: false),
                parent_id: identifier(row["parentRunId"]),
                task_id: identifier(row["taskId"]),
                depth: recovery_depth(id, parents, MapSet.new(), 0),
                label: "Child agent",
                status: status(row["status"]),
                event_count: 0,
                tools: [],
                session_path: nil
              }
            ]
        end
      end)

    %{
      status: :available,
      nodes: nodes,
      truncated?: truncated?,
      active_count: Enum.count(nodes, &(&1.status in ["queued", "running", "tracking_lost"]))
    }
  end

  def from_recovery(_), do: unavailable()

  defp recovery_depth(id, parents, seen, depth) do
    parent = parents[id]

    if depth < @max_depth - 1 and is_binary(parent) and Map.has_key?(parents, parent) and
         not MapSet.member?(seen, parent),
       do: recovery_depth(parent, parents, MapSet.put(seen, id), depth + 1),
       else: depth
  end

  defp project(tasks, session_key, run_id) do
    tasks = Enum.filter(tasks, fn {_, record} -> is_map(record) end)
    by_run = Map.new(tasks, fn {id, record} -> {field(record, :run_id) || id, {id, record}} end)
    scoped = Enum.filter(tasks, fn {_, record} -> field(record, :session_key) == session_key end)
    scoped_ids = MapSet.new(scoped, fn {id, record} -> field(record, :run_id) || id end)

    roots =
      scoped
      |> Enum.filter(fn {_, record} ->
        parent = field(record, :parent_run_id)
        if run_id, do: parent == run_id, else: not MapSet.member?(scoped_ids, parent)
      end)
      |> Enum.sort_by(fn {id, record} -> {field(record, :inserted_at) || 0, id} end, :desc)
      |> Enum.map(fn {id, record} -> {field(record, :run_id) || id, nil, 0} end)

    {nodes, truncated?} = walk(roots, by_run, %{}, [], false)

    %{
      status: :available,
      nodes: nodes,
      truncated?: truncated?,
      active_count: Enum.count(nodes, &(&1.status in ["queued", "running", "tracking_lost"]))
    }
  end

  defp walk([], _tasks, _seen, nodes, truncated?), do: {Enum.reverse(nodes), truncated?}

  defp walk(_queue, _tasks, _seen, nodes, _truncated?) when length(nodes) >= @max_nodes,
    do: {Enum.reverse(nodes), true}

  defp walk([{run_id, parent_id, depth} | rest], tasks, seen, nodes, truncated?) do
    if Map.has_key?(seen, run_id) or is_nil(identifier(run_id)) do
      walk(rest, tasks, seen, nodes, truncated?)
    else
      graph = graph_record(run_id)
      {task_id, record} = Map.get(tasks, run_id, {nil, %{}})
      events = task_events(task_id)
      node = node(run_id, parent_id, depth, task_id, record, graph, events)

      children =
        (List.wrap(field(graph, :children)) ++
           Enum.flat_map(tasks, fn {id, {_, child}} ->
             if field(child, :parent_run_id) == run_id, do: [id], else: []
           end))
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.sort()

      child_queue =
        if depth + 1 < @max_depth,
          do: Enum.map(Enum.take(children, @max_nodes + 1), &{&1, run_id, depth + 1}),
          else: []

      walk(
        child_queue ++ rest,
        tasks,
        Map.put(seen, run_id, true),
        [node | nodes],
        truncated? or (children != [] and depth + 1 >= @max_depth)
      )
    end
  end

  defp node(run_id, parent_id, depth, task_id, record, graph, events) do
    session_key = field(record, :delegated_session_key) || field(graph, :delegated_session_key)
    kind = field(record, :kind) || field(graph, :type)

    %{
      id: identifier(run_id),
      dom_id: "subagent-" <> Base.url_encode64(:crypto.hash(:sha256, run_id), padding: false),
      parent_id: identifier(parent_id),
      task_id: identifier(task_id),
      depth: depth,
      label: if(kind in [:agent, "agent"], do: "Delegated agent", else: "Task agent"),
      status: status(field(record, :status) || field(graph, :status)),
      event_count: length(events),
      tools: tool_names(events),
      session_path: session_path(session_key)
    }
  end

  defp graph_record(run_id) do
    case runtime(:run_graph, [run_id]) do
      {:ok, record} when is_map(record) -> record
      {:error, :not_found} -> %{}
      _ -> throw(:unavailable)
    end
  end

  defp task_events(nil), do: []

  defp task_events(task_id) do
    case runtime(:get_task, [task_id]) do
      {:ok, _record, events} when is_list(events) -> Enum.take(events, -100)
      {:error, :not_found} -> []
      _ -> throw(:unavailable)
    end
  end

  defp tool_names(events) do
    events
    |> Enum.flat_map(fn event ->
      details = field(event, :details)
      detail = field(details, :action_detail)
      name = field(detail, :name)
      if identifier(name), do: [identifier(name)], else: []
    end)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  defp session_path(key) when is_binary(key) do
    if byte_size(key) <= 256 and SessionKey.valid?(key) and identifier(key) == key,
      do: "/chat/" <> URI.encode_www_form(key),
      else: nil
  end

  defp session_path(_), do: nil

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..256 do
    {safe, _} = Safety.redact_for_operator(value, max_bytes: 256)
    if safe == value and Regex.match?(~r/\A[A-Za-z0-9_:.@-]+\z/, value), do: value, else: nil
  end

  defp identifier(_), do: nil

  defp status(value) when is_atom(value), do: status(Atom.to_string(value))
  defp status(value) when value in @statuses, do: value
  defp status(_), do: "unknown"

  defp field(value, key), do: LemonWeb.Chat.Tool.f(value, key)

  # Optional runtime seam: the web app does not depend on the coding product.
  defp runtime(function, args) do
    LemonCore.AgentRuntime.call(function, args, :unavailable)
  end

  defp unavailable, do: %{status: :unavailable, nodes: [], truncated?: false, active_count: 0}
end
