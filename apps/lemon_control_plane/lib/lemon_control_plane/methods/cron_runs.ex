defmodule LemonControlPlane.Methods.CronRuns do
  @moduledoc """
  Handler for `cron.runs`.

  Returns run history for a cron job with optional full output, run-store
  internals, and introspection timeline.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 100
  @max_limit 1_000
  @default_introspection_limit 200
  @max_introspection_limit 2_000

  @impl true
  def name, do: "cron.runs"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      params = params || %{}

      limit = normalize_limit(params["limit"], @default_limit, @max_limit)
      status = normalize_status(params["status"])
      since_ms = normalize_optional_integer(params["sinceMs"] || params["since_ms"])
      include_output = truthy?(params["includeOutput"], false)
      include_meta = truthy?(params["includeMeta"], true)
      include_run_record = truthy?(params["includeRunRecord"], false)
      include_introspection = truthy?(params["includeIntrospection"], false)

      introspection_limit =
        normalize_limit(
          params["introspectionLimit"],
          @default_introspection_limit,
          @max_introspection_limit
        )

      runs =
        LemonAutomation.CronManager.runs(
          job_id,
          limit: limit,
          status: status,
          since_ms: since_ms
        )

      formatted_runs =
        Enum.map(runs, fn run ->
          format_run(
            run,
            include_output,
            include_meta,
            include_run_record,
            include_introspection,
            introspection_limit
          )
        end)

      {:ok,
       %{
         "jobId" => job_id,
         "runs" => formatted_runs,
         "total" => length(formatted_runs),
         "filters" => %{
           "limit" => limit,
           "status" => if(status, do: Atom.to_string(status), else: nil),
           "sinceMs" => since_ms,
           "includeOutput" => include_output,
           "includeMeta" => include_meta,
           "includeRunRecord" => include_run_record,
           "includeIntrospection" => include_introspection,
           "introspectionLimit" => introspection_limit
         }
       }}
    end
  end

  defp format_run(
         run,
         include_output,
         include_meta,
         include_run_record,
         include_introspection,
         introspection_limit
       ) do
    router_run_id = run.run_id
    output = run.output

    base =
      %{
        "id" => run.id,
        "jobId" => run.job_id,
        "routerRunId" => router_run_id,
        "status" => to_string(run.status),
        "triggeredBy" => to_string(run.triggered_by),
        "startedAtMs" => run.started_at_ms,
        "completedAtMs" => run.completed_at_ms,
        "durationMs" => run.duration_ms,
        "output" => if(include_output, do: output, else: truncate(output, 800)),
        "outputPreview" => truncate(output, 300),
        "error" => run.error,
        "suppressed" => run.suppressed || false,
        "sessionKey" => get_meta_value(run.meta, "session_key"),
        "agentId" => get_meta_value(run.meta, "agent_id")
      }
      |> maybe_put("meta", serialize_term(run.meta), include_meta)
      |> maybe_put(
        "runRecord",
        fetch_run_record(router_run_id),
        include_run_record and is_binary(router_run_id)
      )
      |> maybe_put(
        "introspection",
        fetch_introspection(router_run_id, introspection_limit),
        include_introspection and is_binary(router_run_id)
      )

    base
  end

  defp fetch_run_record(run_id) do
    case LemonCore.Store.get_run(run_id) do
      nil -> nil
      record when is_map(record) -> serialize_term(record)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp fetch_introspection(run_id, limit) do
    if Code.ensure_loaded?(LemonCore.Introspection) do
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
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp get_meta_value(meta, key) when is_map(meta) and is_atom(key) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
  rescue
    _ -> nil
  end

  defp get_meta_value(meta, key) when is_map(meta) and is_binary(key) do
    Map.get(meta, key) ||
      case safe_to_existing_atom(key) do
        nil -> nil
        atom_key -> Map.get(meta, atom_key)
      end
  rescue
    _ -> nil
  end

  defp get_meta_value(_meta, _key), do: nil

  defp safe_to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> nil
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp normalize_status(nil), do: nil

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      "pending" -> :pending
      "running" -> :running
      "completed" -> :completed
      "failed" -> :failed
      "timeout" -> :timeout
      _ -> nil
    end
  end

  defp normalize_status(_), do: nil

  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_integer(_), do: nil

  defp normalize_limit(limit, _default, max) when is_integer(limit) and limit > 0,
    do: min(limit, max)

  defp normalize_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, max)
      _ -> default
    end
  end

  defp normalize_limit(_, default, _), do: default

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

  defp serialize_term(value, depth) when is_list(value),
    do: Enum.map(value, &serialize_term(&1, depth + 1))

  defp serialize_term(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&serialize_term(&1, depth + 1))

  defp serialize_term(value, _depth) when is_boolean(value) or is_nil(value), do: value
  defp serialize_term(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp serialize_term(value, _depth), do: value

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

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

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value)

  defp truncate(nil, _), do: nil
  defp truncate(value, max) when is_binary(value) and byte_size(value) <= max, do: value

  defp truncate(value, max) when is_binary(value),
    do: String.slice(value, 0, max) <> "...[truncated]"

  defp truncate(value, _), do: inspect(value, limit: 200)
end
