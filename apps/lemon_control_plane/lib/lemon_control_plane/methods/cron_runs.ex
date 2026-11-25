defmodule LemonControlPlane.Methods.CronRuns do
  @moduledoc """
  Handler for `cron.runs`.

  Returns run history for a cron job with optional full output, run-store
  internals, and introspection timeline. Output and error text, run meta, run
  records and introspection payloads are content and need `operator.content`;
  read-only callers get ids, status, sizes and timings, and the include flags
  are ignored.
  """

  import LemonControlPlane.Methods.Params,
    only: [truthy?: 2, normalize_limit: 3, get_map: 2, get_map: 3]

  alias LemonControlPlane.Auth.Authorize

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
  def handle(params, ctx) do
    with {:ok, job_id} <- LemonControlPlane.Method.require_param(params, "id") do
      params = params || %{}
      content? = Authorize.content?(ctx)

      limit = normalize_limit(params["limit"], @default_limit, @max_limit)
      status = normalize_status(params["status"])
      since_ms = normalize_optional_integer(params["sinceMs"] || params["since_ms"])
      include_output = content? and truthy?(params["includeOutput"], false)
      include_meta = content? and truthy?(params["includeMeta"], true)
      include_run_record = content? and truthy?(params["includeRunRecord"], false)
      include_introspection = content? and truthy?(params["includeIntrospection"], false)

      introspection_limit =
        normalize_limit(
          params["introspectionLimit"],
          @default_introspection_limit,
          @max_introspection_limit
        )

      format = fn run ->
        format_run(
          run,
          content?,
          include_output,
          include_meta,
          include_run_record,
          include_introspection,
          introspection_limit
        )
      end

      with {:ok, runs} <- read_runs(job_id, limit, status, since_ms),
           {:ok, formatted_runs} <- format_runs(runs, format) do
        {:ok,
         %{
           "jobId" => job_id,
           "runs" => formatted_runs,
           "total" => length(formatted_runs),
           "contentWithheld" => not content?,
           "filters" => %{
             "limit" => limit,
             "status" => if(status, do: Atom.to_string(status), else: nil),
             "sinceMs" => since_ms,
             "includeOutput" => include_output,
             "includeMeta" => include_meta,
             "includeRunRecord" => include_run_record,
             "includeIntrospection" => include_introspection,
             "introspectionLimit" => introspection_limit
           },
           "summary" =>
             summary(
               runs,
               status,
               since_ms,
               content?,
               include_output,
               include_meta,
               include_run_record,
               include_introspection
             )
         }}
      end
    end
  end

  defp read_runs(job_id, limit, status, since_ms) do
    case LemonAutomation.CronManager.runs(job_id,
           limit: limit,
           status: status,
           since_ms: since_ms,
           strict: true
         ) do
      {:ok, runs} when is_list(runs) -> {:ok, runs}
      _unavailable -> {:error, {:unavailable, "Cron run history is unavailable", nil}}
    end
  end

  defp format_runs(runs, format) do
    runs
    |> Enum.reduce_while({:ok, []}, fn run, {:ok, acc} ->
      case format.(run) do
        {:ok, formatted} -> {:cont, {:ok, [formatted | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, formatted} ->
        {:ok, Enum.reverse(formatted)}

      {:error, :run_record_unavailable} ->
        {:error, {:unavailable, "Run records are unavailable", nil}}

      {:error, _introspection} ->
        {:error, {:unavailable, "Introspection events are unavailable", nil}}
    end
  end

  defp format_run(
         run,
         content?,
         include_output,
         include_meta,
         include_run_record,
         include_introspection,
         introspection_limit
       ) do
    router_run_id = run.run_id

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
        "suppressed" => run.suppressed || false,
        "sessionKey" => get_meta_value(run.meta, :session_key),
        "agentId" => get_meta_value(run.meta, :agent_id),
        "summary" =>
          run_summary(
            run,
            content?,
            include_output,
            include_meta,
            include_run_record,
            include_introspection
          )
      }
      |> maybe_put_text(run, content?, include_output)
      |> maybe_put("meta", LemonCore.Redact.project(run.meta), include_meta)

    with {:ok, base} <- put_run_record(base, router_run_id, include_run_record) do
      if include_introspection and is_binary(router_run_id) do
        case fetch_introspection(router_run_id, introspection_limit) do
          events when is_list(events) -> {:ok, Map.put(base, "introspection", events)}
          {:error, _} = error -> error
        end
      else
        {:ok, base}
      end
    end
  end

  defp put_run_record(base, run_id, true) when is_binary(run_id) do
    case LemonCore.RunStore.fetch(run_id) do
      {:ok, record} when is_map(record) ->
        {:ok, Map.put(base, "runRecord", LemonCore.Redact.project(record))}

      {:ok, _absent} ->
        {:ok, Map.put(base, "runRecord", nil)}

      {:error, _reason} ->
        {:error, :run_record_unavailable}
    end
  end

  defp put_run_record(base, _run_id, _include), do: {:ok, base}

  defp maybe_put_text(map, _run, false, _include_output), do: map

  defp maybe_put_text(map, run, true, include_output) do
    output = LemonCore.Redact.text(run.output)

    Map.merge(map, %{
      "output" => if(include_output, do: output, else: truncate(output, 800)),
      "outputPreview" => truncate(output, 300),
      "error" => LemonCore.Redact.text(run.error)
    })
  end

  defp run_summary(
         run,
         content?,
         include_output,
         include_meta,
         include_run_record,
         include_introspection
       ) do
    output_bytes = byte_size(run.output || "")
    error_bytes = byte_size(run.error || "")

    %{
      "runId" => run.id,
      "jobId" => run.job_id,
      "status" => Atom.to_string(run.status),
      "triggeredBy" => Atom.to_string(run.triggered_by),
      "outputBytes" => output_bytes,
      "errorBytes" => error_bytes,
      "fullOutputReturned" => include_output,
      "outputPreviewReturned" => content? and output_bytes > 0,
      "errorTextReturned" => content? and error_bytes > 0,
      "metaReturned" => include_meta,
      "runRecordReturned" => include_run_record and is_binary(run.run_id),
      "introspectionReturned" => include_introspection and is_binary(run.run_id),
      "rawIdsReturned" => true
    }
  end

  defp summary(
         runs,
         status,
         since_ms,
         content?,
         include_output,
         include_meta,
         include_run_record,
         include_introspection
       ) do
    output_run_count = Enum.count(runs, &present?(&1.output))
    error_run_count = Enum.count(runs, &present?(&1.error))
    returned_output_runs = if content?, do: output_run_count, else: 0
    returned_error_runs = if content?, do: error_run_count, else: 0

    %{
      "runCount" => length(runs),
      "statusCounts" => status_counts(runs),
      "filteredByStatus" => not is_nil(status),
      "filteredBySinceMs" => not is_nil(since_ms),
      "outputRunCount" => output_run_count,
      "errorRunCount" => error_run_count,
      "fullOutputReturned" => include_output,
      "outputPreviewReturned" => returned_output_runs > 0,
      "errorTextReturned" => returned_error_runs > 0,
      "metaReturned" => include_meta,
      "runRecordReturned" => include_run_record,
      "introspectionReturned" => include_introspection,
      "rawIdsReturned" => true,
      "cleanup" =>
        cleanup_summary(
          returned_output_runs,
          returned_error_runs,
          include_output,
          include_run_record,
          include_introspection
        )
    }
  end

  defp status_counts(runs) do
    Enum.reduce(runs, %{}, fn run, acc ->
      Map.update(acc, Atom.to_string(run.status), 1, &(&1 + 1))
    end)
  end

  defp cleanup_summary(
         output_run_count,
         error_run_count,
         include_output,
         include_run_record,
         include_introspection
       ) do
    %{
      "includesPromptText" => false,
      "includesCommandText" => false,
      "includesOutputText" => output_run_count > 0,
      "includesFullOutputText" => include_output and output_run_count > 0,
      "includesErrorText" => error_run_count > 0,
      "redactsSensitiveOutputValues" => true,
      "includesMessageBodies" => include_run_record or include_introspection,
      "includesCredentials" => false,
      "includesSecretValues" => false
    }
  end

  defp fetch_introspection(run_id, limit) do
    case LemonCore.Introspection.list(run_id: run_id, limit: limit) do
      events when is_list(events) ->
        Enum.map(events, fn event ->
          %{
            "eventId" => get_map(event, :event_id),
            "eventType" => normalize_string(get_map(event, :event_type)),
            "tsMs" => get_map(event, :ts_ms),
            "payload" => LemonCore.Redact.project(get_map(event, :payload, %{})),
            "runId" => get_map(event, :run_id),
            "sessionKey" => get_map(event, :session_key),
            "agentId" => get_map(event, :agent_id),
            "parentRunId" => get_map(event, :parent_run_id),
            "engine" => get_map(event, :engine),
            "provenance" => normalize_string(get_map(event, :provenance))
          }
        end)

      {:error, _} ->
        {:error, :introspection_unavailable}
    end
  rescue
    _ -> {:error, :introspection_unavailable}
  catch
    :exit, _ -> {:error, :introspection_unavailable}
  end

  defp get_meta_value(meta, key) when is_map(meta) and is_atom(key),
    do: Map.get(meta, Atom.to_string(key)) || Map.get(meta, key)

  defp get_meta_value(_meta, _key), do: nil

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
      "aborted" -> :aborted
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

  defp normalize_string(nil), do: nil
  defp normalize_string(value) when is_binary(value), do: value
  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: to_string(value)

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_), do: false

  defp truncate(nil, _), do: nil
  defp truncate(value, max) when is_binary(value) and byte_size(value) <= max, do: value

  defp truncate(value, max) when is_binary(value),
    do: String.slice(value, 0, max) <> "...[truncated]"

  # `CronRun.output` is text; any other term is never rendered onto the wire.
  defp truncate(_value, _max), do: nil
end
