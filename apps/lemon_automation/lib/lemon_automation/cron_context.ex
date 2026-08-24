defmodule LemonAutomation.CronContext do
  @moduledoc """
  Job chaining: prepend another job's latest completed output to this job's prompt.

  A job with `context_from: "cron_abc"` gets a `## Chained Context` block ahead
  of its own task text, carrying the most recent completed output of the source
  job. That turns "collect, then summarize" workflows into two ordinary cron
  jobs instead of one long prompt.

  ## One hop only

  Chaining reads *stored run output*, never another job's prompt, so it cannot
  recurse: an `A -> B -> A` reference graph resolves to a single stored block on
  each side and terminates by construction.

  ## Never blocks dispatch

  Every failure mode — missing source job, no completed run, store outage —
  degrades to an explicit note inside the prompt (or, for unexpected raises, to
  the original prompt unchanged). A broken chain must not stop the target job
  from running.

  The block is part of the user prompt (the `## Task` body of the cron memory
  template), never the system prompt, so per-run varying content stays out of
  the cached prefix.
  """

  alias LemonAutomation.{CronJob, CronStore}

  require Logger

  @max_context_bytes 8_000
  @source_run_scan_limit 20

  @doc """
  Prepend the chained-context block to `prompt` when the job declares
  `context_from`. Returns `prompt` unchanged otherwise, or on any failure.
  """
  @spec augment_prompt(CronJob.t(), binary() | nil) :: binary() | nil
  def augment_prompt(%CronJob{context_from: nil}, prompt), do: prompt

  def augment_prompt(%CronJob{context_from: context_from} = job, prompt)
      when is_binary(context_from) and is_binary(prompt) do
    context_block(job) <> "\n\n" <> prompt
  rescue
    error ->
      Logger.warning("[CronContext] Failed to build chained context: #{Exception.message(error)}")
      prompt
  catch
    :exit, reason ->
      Logger.warning("[CronContext] Failed to build chained context: #{inspect(reason)}")
      prompt
  end

  def augment_prompt(_job, prompt), do: prompt

  @doc """
  Render the chained-context block for a job with `context_from` set.
  """
  @spec context_block(CronJob.t()) :: binary()
  def context_block(%CronJob{context_from: context_from} = job) when is_binary(context_from) do
    case CronStore.get_job(context_from) do
      nil ->
        record_missing(job, "source job #{context_from} not found")

        "## Chained Context\n\n[context_from: source job #{context_from} no longer exists; " <>
          "continuing without chained context.]"

      %CronJob{} = source ->
        runs = CronStore.list_runs(source.id, limit: @source_run_scan_limit)

        completed =
          Enum.find(runs, fn run ->
            run.status == :completed and is_binary(run.output) and String.trim(run.output) != ""
          end)

        latest = List.first(runs)

        case completed do
          nil ->
            record_missing(job, "no completed run output")

            "## Chained Context (from job \"#{source.name}\" / #{source.id})\n\n" <>
              "[context_from: source job has no completed run output yet; " <>
              "continuing without chained context.]"

          run ->
            render_block(source, run, latest)
        end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp render_block(source, run, latest) do
    header = [
      "## Chained Context (from job \"#{source.name}\" / #{source.id})",
      "- source_run: #{run.id}",
      "- completed_at: #{format_ts(run.completed_at_ms)}",
      latest_note(run, latest)
    ]

    (header
     |> Enum.reject(&is_nil/1)
     |> Enum.join("\n")) <>
      "\n\n" <> truncate_to_bytes(run.output, @max_context_bytes)
  end

  defp latest_note(%{id: id}, %{id: id}), do: nil

  defp latest_note(_completed, %{status: status} = latest)
       when status in [:failed, :timeout, :aborted] do
    "- note: most recent run #{latest.id} ended with status #{status}: #{latest.error || "(no error recorded)"}"
  end

  defp latest_note(_completed, _latest), do: nil

  defp record_missing(%CronJob{} = job, reason) do
    CronStore.record_audit(:context_source_missing, %{
      job_id: job.id,
      source: :cron_context,
      reason: reason
    })

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp format_ts(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> "unknown"
    end
  end

  defp format_ts(_ms), do: "unknown"

  defp truncate_to_bytes(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes,
    do: text

  defp truncate_to_bytes(text, max_bytes) when is_binary(text) do
    text
    |> binary_part(0, max_bytes)
    |> trim_to_valid_utf8()
  end

  defp truncate_to_bytes(_text, _max_bytes), do: ""

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end
end
