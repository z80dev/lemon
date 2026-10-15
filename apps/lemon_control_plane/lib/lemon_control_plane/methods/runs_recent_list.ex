defmodule LemonControlPlane.Methods.RunsRecentList do
  @moduledoc """
  Handler for the `runs.recent.list` method.

  Lists recent completed/error/aborted/crashed runs using `LemonCore.Introspection.list/1`.
  Filters precede the response limit within the newest 1,000 events of each terminal
  kind. Completed events win over crash events for the same run. Usage is joined
  from at most 500 occurrences in the returned runs' time window; if that window
  exceeds the usage page, usage fields are null rather than misleading partial sums.
  `errorCount` counts errors only; crashes and aborts have separate status counts.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.RunOutcome

  @default_limit 50
  @max_limit 200

  @impl true
  def name, do: "runs.recent.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    agent_id = get_param(params, "agentId")
    session_key = get_param(params, "sessionKey")
    limit = normalize_limit(get_param(params, "limit"), @default_limit, @max_limit)
    status_filter = get_param(params, "status")

    with {:ok, runs} <- fetch_recent_runs(agent_id, session_key, limit, status_filter),
         {:ok, runs} <- attach_usage(runs) do
      filters = %{
        "agentId" => agent_id,
        "sessionKey" => session_key,
        "limit" => limit,
        "status" => status_filter
      }

      {:ok, response(runs, filters)}
    else
      _ -> unavailable()
    end
  rescue
    _ -> unavailable()
  catch
    :exit, _ -> unavailable()
  end

  defp unavailable, do: {:error, {:internal_error, "Run history is unavailable", nil}}

  defp response(runs, filters) do
    %{
      "runs" => runs,
      "total" => length(runs),
      "filters" => filters,
      "summary" => summary(runs, filters)
    }
  end

  defp summary(runs, filters) do
    durations =
      runs
      |> Enum.map(& &1["durationMs"])
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))

    %{
      "count" => length(runs),
      "statusCounts" => count_by(runs, "status"),
      "engineCounts" => count_by(runs, "engine"),
      "agentCount" => unique_count(runs, "agentId"),
      "sessionCount" => unique_count(runs, "sessionKey"),
      "okCount" => Enum.count(runs, &(&1["ok"] == true)),
      "errorCount" => Enum.count(runs, &(&1["status"] == "error")),
      "abortedCount" => Enum.count(runs, &(&1["status"] == "aborted")),
      "averageDurationMs" => average_or_nil(durations),
      "filtersApplied" => filters_applied(filters),
      "cleanup" => %{
        "includesRunEvents" => false,
        "includesRunRecords" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp fetch_recent_runs(agent_id, session_key, limit, status_filter) do
    opts =
      [limit: 1_000]
      |> maybe_add_opt(:agent_id, agent_id)
      |> maybe_add_opt(:session_key, session_key)

    with completed when is_list(completed) <-
           LemonCore.Introspection.list(Keyword.put(opts, :event_type, :run_completed)),
         failed when is_list(failed) <-
           LemonCore.Introspection.list(Keyword.put(opts, :event_type, :run_failed)) do
      runs =
        (completed ++ failed)
        |> Enum.uniq_by(&(&1[:run_id] || &1["run_id"]))
        |> Enum.map(&format_run_event/1)
        |> Enum.filter(&filter_by_status(&1, status_filter))
        |> Enum.sort_by(& &1["completedAtMs"], :desc)
        |> Enum.take(limit)

      attach_start_times(runs, opts)
    end
  end

  defp attach_start_times(runs, opts) do
    with true <- Enum.any?(runs, &is_nil(&1["startedAtMs"])),
         started when is_list(started) <-
           LemonCore.Introspection.list(Keyword.put(opts, :event_type, :run_started)) do
      starts = Enum.reduce(started, %{}, &Map.put_new(&2, &1[:run_id], &1[:ts_ms]))

      {:ok,
       Enum.map(runs, fn run ->
         Map.update!(run, "startedAtMs", &(&1 || starts[run["runId"]]))
       end)}
    else
      false -> {:ok, runs}
      {:error, _} = error -> error
    end
  end

  defp format_run_event(event) when is_map(event) do
    payload = event[:payload] || event["payload"] || %{}
    ok = Map.get(payload, :ok, Map.get(payload, "ok"))
    error = payload[:error] || payload["error"] || payload[:reason] || payload["reason"]
    duration_ms = payload[:duration_ms] || payload["duration_ms"]

    status =
      cond do
        (event[:event_type] || event["event_type"]) in [:run_failed, "run_failed"] -> "crashed"
        ok == true -> "completed"
        RunOutcome.aborted?(error) -> "aborted"
        true -> "error"
      end

    %{
      "runId" => event[:run_id] || event["run_id"],
      "sessionKey" => event[:session_key] || event["session_key"],
      "agentId" => event[:agent_id] || event["agent_id"],
      "engine" => event[:engine] || event["engine"],
      "startedAtMs" => started_at_ms(event, duration_ms),
      "completedAtMs" => event[:ts_ms] || event["ts_ms"],
      "status" => status,
      "error" => error_label(error),
      "durationMs" => duration_ms,
      "ok" => ok == true
    }
  end

  defp error_label(nil), do: nil
  defp error_label(error) when is_atom(error), do: error |> Atom.to_string() |> error_label()

  defp error_label(error) when is_binary(error) do
    error
    |> LemonCore.Redact.text()
    |> truncate_label()
  end

  defp error_label(_), do: "unknown_error"

  defp truncate_label(label) when byte_size(label) <= 256, do: label
  defp truncate_label(label), do: label |> binary_part(0, 256) |> valid_label_prefix()

  defp valid_label_prefix(label) do
    if String.valid?(label),
      do: label,
      else: label |> binary_part(0, byte_size(label) - 1) |> valid_label_prefix()
  end

  defp attach_usage(runs) do
    known = Enum.filter(runs, &is_integer(&1["startedAtMs"]))

    with {:ok, grouped} <- fetch_usage(known) do
      {:ok,
       Enum.map(runs, fn run ->
         records =
           if is_integer(run["startedAtMs"]),
             do: Map.get(grouped, run["runId"], []),
             else: []

         Map.merge(run, usage_fields(records))
       end)}
    end
  end

  defp fetch_usage([]), do: {:ok, %{}}

  defp fetch_usage(runs) do
    timestamps =
      Enum.flat_map(runs, &[&1["startedAtMs"], &1["completedAtMs"]])
      |> Enum.filter(&is_integer/1)

    from_ms = Enum.min(timestamps)
    to_ms = Enum.max(timestamps) + 1

    with {:ok, page} <-
           LemonCore.UsageRecords.query(%{
             "fromMs" => max(from_ms, 0),
             "toMs" => to_ms,
             "limit" => 500
           }) do
      {:ok,
       if(is_nil(page.next_cursor),
         do: Enum.group_by(page.records, & &1.run_id),
         else: %{}
       )}
    end
  end

  defp usage_fields([]) do
    Map.new(["tokens", "costUsd", "priceKnown", "model", "provider"], &{&1, nil})
  end

  defp usage_fields(records) do
    priced? = Enum.all?(records, &(&1.price_known and is_number(&1.cost_usd)))

    %{
      "tokens" => %{
        "input" => Enum.sum(Enum.map(records, & &1.input_tokens)),
        "output" => Enum.sum(Enum.map(records, & &1.output_tokens)),
        "total" => Enum.sum(Enum.map(records, & &1.total_tokens))
      },
      "costUsd" => if(priced?, do: Enum.sum(Enum.map(records, & &1.cost_usd)), else: nil),
      "priceKnown" => priced?,
      "model" => single_value(records, :model),
      "provider" => single_value(records, :provider)
    }
  end

  defp single_value(records, key) do
    case records |> Enum.map(&Map.get(&1, key)) |> Enum.uniq() do
      [value] -> value
      _ -> nil
    end
  end

  defp started_at_ms(event, duration_ms) do
    ts_ms = event[:ts_ms] || event["ts_ms"]

    if is_integer(ts_ms) and is_integer(duration_ms) and duration_ms >= 0 do
      ts_ms - duration_ms
    else
      nil
    end
  end

  defp filter_by_status(_run, nil), do: true
  defp filter_by_status(nil, _filter), do: false
  defp filter_by_status(%{"status" => status}, filter), do: status == filter
  defp filter_by_status(_, _), do: false

  defp count_by(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&blank?/1)
    |> Enum.frequencies()
  end

  defp unique_count(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp filters_applied(filters) do
    filters
    |> Enum.reject(fn {key, value} -> key == "limit" or blank?(value) end)
    |> Enum.map(fn {key, _value} -> key end)
    |> Enum.sort()
  end

  defp average_or_nil([]), do: nil
  defp average_or_nil(values), do: div(Enum.sum(values), length(values))

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

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
