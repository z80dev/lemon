defmodule LemonControlPlane.Methods.RunGraphGet do
  @moduledoc """
  Handler for the `run.graph.get` method.

  Returns the parent/child run structure for a given run_id, building
  a tree of related runs from the introspection log.
  """

  @behaviour LemonControlPlane.Method

  @max_depth 10
  @child_lookup_limit 200

  @impl true
  def name, do: "run.graph.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    run_id = params["runId"]

    if is_nil(run_id) or run_id == "" do
      {:error, {:invalid_request, "runId is required", nil}}
    else
      graph = build_run_graph(run_id)
      node_count = count_nodes(graph)

      {:ok,
       %{
         "runId" => run_id,
         "graph" => graph,
         "nodeCount" => node_count
       }}
    end
  rescue
    _ ->
      run_id = (params || %{})["runId"]

      {:ok,
       %{
         "runId" => run_id,
         "graph" => %{"runId" => run_id, "status" => "unknown", "children" => []},
         "nodeCount" => 1
       }}
  end

  defp build_run_graph(run_id) do
    root_status = fetch_run_status(run_id)
    children = fetch_children(run_id, 0)

    %{
      "runId" => run_id,
      "status" => root_status,
      "children" => children
    }
  end

  defp fetch_children(_run_id, depth) when depth >= @max_depth, do: []

  defp fetch_children(run_id, depth) do
    if Code.ensure_loaded?(LemonCore.Introspection) do
      child_events =
        LemonCore.Introspection.list(
          parent_run_id: run_id,
          event_type: :run_started,
          limit: @child_lookup_limit
        )

      child_run_ids =
        child_events
        |> Enum.map(&((&1)[:run_id] || (&1)["run_id"]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      Enum.map(child_run_ids, fn child_run_id ->
        status = fetch_run_status(child_run_id)
        grandchildren = fetch_children(child_run_id, depth + 1)

        %{
          "runId" => child_run_id,
          "status" => status,
          "children" => grandchildren
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp fetch_run_status(run_id) when is_binary(run_id) do
    # Check if run is currently active in RunRegistry
    is_active =
      if Code.ensure_loaded?(Registry) and Code.ensure_loaded?(LemonRouter.RunRegistry) do
        case Registry.lookup(LemonRouter.RunRegistry, run_id) do
          [{_pid, _}] -> true
          _ -> false
        end
      else
        false
      end

    if is_active do
      "active"
    else
      fetch_completed_status(run_id)
    end
  rescue
    _ -> "unknown"
  catch
    :exit, _ -> "unknown"
  end

  defp fetch_run_status(_), do: "unknown"

  defp fetch_completed_status(run_id) do
    if Code.ensure_loaded?(LemonCore.Introspection) do
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
    else
      "unknown"
    end
  rescue
    _ -> "unknown"
  catch
    :exit, _ -> "unknown"
  end

  defp count_nodes(%{"children" => children}) when is_list(children) do
    1 + Enum.reduce(children, 0, fn child, acc -> acc + count_nodes(child) end)
  end

  defp count_nodes(_), do: 1
end
