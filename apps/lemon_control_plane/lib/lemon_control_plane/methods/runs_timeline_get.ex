defmodule LemonControlPlane.Methods.RunsTimelineGet do
  @moduledoc "Read-only, content-free run timeline from bounded introspection and task history."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.{RunOutcome, RunUsage}
  alias LemonCore.{AgentRuntime, Introspection}

  @event_limit 1_000
  @entry_limit 500
  @lifecycle ~w(run_started agent_loop_started agent_turn_observed agent_loop_ended answer_finalize_started answer_finalize_completed run_completed run_failed)

  @impl true
  def name, do: "runs.timeline.get"
  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    run_id = if is_map(params), do: field(params, :runId)

    if is_binary(run_id) and byte_size(run_id) in 1..256 and String.trim(run_id) != "" do
      timeline(run_id)
    else
      {:error, {:invalid_request, "runId is required (1..256 bytes)", nil}}
    end
  rescue
    _ -> unavailable()
  catch
    :exit, _ -> unavailable()
  end

  defp timeline(run_id) do
    case Introspection.list(run_id: run_id, limit: @event_limit) do
      [] ->
        {:error, {:not_found, "Run not found", nil}}

      events when is_list(events) ->
        with {:ok, children} <- children(run_id),
             starts when is_list(starts) <-
               Introspection.list(run_id: run_id, event_type: :run_started, limit: 1),
             {:ok, [usage]} <- RunUsage.attach([usage_window(run_id, events, starts)]) do
          entries = (event_entries(events) ++ children) |> Enum.sort_by(& &1["atMs"])

          {:ok,
           %{
             "runId" => run_id,
             "entries" => Enum.take(entries, -@entry_limit),
             "truncated" => length(entries) > @entry_limit or length(events) == @event_limit,
             "usage" => Map.take(usage, ~w(tokens costUsd priceKnown model provider))
           }}
        else
          _ -> unavailable()
        end

      _ ->
        unavailable()
    end
  end

  defp event_entries(events) do
    ordered = Enum.sort_by(events, &{field(&1, :ts_ms), field(&1, :event_id)})

    completions =
      ordered
      |> Enum.filter(&(kind(&1) == "tool_call_completed"))
      |> Map.new(&{field(payload(&1), :tool_call_id), &1})

    dispatched =
      ordered
      |> Enum.filter(&(kind(&1) == "tool_call_dispatched"))
      |> MapSet.new(&field(payload(&1), :tool_call_id))

    Enum.flat_map(ordered, fn event ->
      case kind(event) do
        "tool_call_dispatched" ->
          completion = Map.get(completions, field(payload(event), :tool_call_id))
          [tool_entry(event, completion)]

        "tool_call_completed" ->
          if MapSet.member?(dispatched, field(payload(event), :tool_call_id)),
            do: [],
            else: [tool_entry(event, event)]

        type when type in @lifecycle ->
          [lifecycle_entry(event, type)]

        _ ->
          []
      end
    end)
  end

  defp tool_entry(dispatch, completion) do
    result = payload(completion)
    ok = field(result, :ok)

    status =
      if is_nil(completion), do: "pending", else: if(ok == true, do: "completed", else: "error")

    entry(
      field(dispatch, :ts_ms),
      "tool_call",
      label(field(payload(dispatch), :tool_name), "tool"),
      nonnegative(field(result, :duration_ms)),
      ok,
      status
    )
  end

  defp lifecycle_entry(event, type) do
    data = payload(event)
    ok = field(data, :ok)

    status =
      cond do
        type == "run_failed" -> "crashed"
        type == "run_completed" and ok == true -> "completed"
        type == "run_completed" and RunOutcome.aborted?(field(data, :error)) -> "aborted"
        type == "run_completed" -> "error"
        String.ends_with?(type, "started") -> "active"
        String.ends_with?(type, "ended") or String.ends_with?(type, "completed") -> "completed"
        true -> "observed"
      end

    entry(
      field(event, :ts_ms),
      type,
      String.replace(type, "_", " "),
      nonnegative(field(data, :duration_ms)),
      if(type == "run_failed", do: false, else: ok),
      status
    )
  end

  defp children(run_id) do
    case AgentRuntime.call(:list_tasks, [], {:error, :unavailable}) do
      tasks when is_list(tasks) ->
        {:ok,
         for {id, record} <- tasks,
             field(record, :parent_run_id) == run_id do
           started = to_ms(field(record, :started_at)) || to_ms(field(record, :inserted_at))
           completed = to_ms(field(record, :completed_at))
           status = task_status(record)
           duration = if started && completed, do: nonnegative(completed - started)
           ok = if status in ["active", "queued"], do: nil, else: status == "completed"

           entry(
             started || 0,
             "subagent",
             "subagent " <> label(id, "unknown"),
             duration,
             ok,
             status
           )
         end}

      _ ->
        {:error, :unavailable}
    end
  end

  defp task_status(record) do
    case field(record, :status) do
      value when value in [:queued, "queued"] -> "queued"
      value when value in [:running, "running"] -> "active"
      value when value in [:completed, "completed"] -> "completed"
      _ -> if RunOutcome.aborted?(field(record, :error)), do: "aborted", else: "error"
    end
  end

  defp usage_window(run_id, events, starts) do
    started_at =
      starts |> List.first() |> field(:ts_ms) ||
        Enum.find_value(events, fn event ->
          duration = nonnegative(field(payload(event), :duration_ms))
          if kind(event) == "run_completed" and duration, do: field(event, :ts_ms) - duration
        end)

    %{
      "runId" => run_id,
      "startedAtMs" => started_at,
      "completedAtMs" => events |> Enum.map(&field(&1, :ts_ms)) |> Enum.max()
    }
  end

  defp entry(at, kind, label, duration, ok, status) do
    %{
      "atMs" => at,
      "kind" => kind,
      "label" => label,
      "durationMs" => duration,
      "ok" => ok,
      "status" => status
    }
  end

  defp kind(event), do: event |> field(:event_type) |> to_string()
  defp payload(event), do: field(event, :payload) || %{}
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
  defp nonnegative(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative(_), do: nil
  defp to_ms(%DateTime{} = time), do: DateTime.to_unix(time, :millisecond)
  defp to_ms(time) when is_integer(time), do: time
  defp to_ms(_), do: nil

  defp label(value, _default) when is_binary(value) do
    value
    |> LemonCore.Redact.text()
    |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/u, " ")
    |> String.slice(0, 128)
  end

  defp label(_, default), do: default
  defp unavailable, do: {:error, {:internal_error, "Run timeline is unavailable", nil}}
end
