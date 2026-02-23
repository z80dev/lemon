defmodule CodingAgent.Tools.Await do
  @moduledoc """
  Await tool - blocks until one or more background jobs complete, fail, or are cancelled.

  Use this instead of polling `read jobs://` in a loop when you need to wait for
  background task or bash results before continuing.

  Returns the status and results of all watched jobs once at least one finishes.
  """

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.ProcessStore

  @default_timeout_ms 60_000
  @poll_interval_ms 100

  @doc """
  Returns the tool definition for the tool registry.
  """
  @spec tool(String.t()) :: map()
  def tool(cwd) do
    %{
      name: "await",
      description: """
      Block until one or more background jobs complete, fail, or are cancelled.

      Use this instead of polling `read jobs://` in a loop when you need to wait
      for background task or bash results before continuing.

      Returns the status and results of all watched jobs once at least one finishes.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "job_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "List of job IDs to watch. If empty, watches all jobs."
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Maximum time to wait in seconds (default: 60)"
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, [])
    }
  end

  @doc """
  Execute the await tool.

  Blocks until at least one job completes, fails, or is cancelled, then returns
  the status of all watched jobs.
  """
  @spec execute(
          call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t()
  def execute(_call_id, params, signal, _on_update, _cwd, _opts) do
    job_ids = Map.get(params, "job_ids", [])
    timeout_ms = Map.get(params, "timeout", div(@default_timeout_ms, 1000)) * 1_000

    # Normalize job_ids to a list of strings
    job_ids =
      case job_ids do
        ids when is_list(ids) -> ids
        id when is_binary(id) -> [id]
        _ -> []
      end

    # Filter to valid job IDs (or all jobs if empty)
    watched_jobs = get_watched_jobs(job_ids)

    if watched_jobs == [] do
      return_no_jobs_result()
    else
      do_poll(watched_jobs, timeout_ms, signal)
    end
  end

  # Get the list of jobs to watch
  defp get_watched_jobs([]) do
    # Watch all jobs
    ProcessStore.list(:all)
  end

  defp get_watched_jobs(job_ids) when is_list(job_ids) do
    # Watch specific jobs
    Enum.flat_map(job_ids, fn id ->
      case ProcessStore.get(id) do
        {:ok, record, _logs} -> [{id, record}]
        {:error, :not_found} -> []
      end
    end)
  end

  # Poll until at least one job completes or timeout
  defp do_poll(watched_jobs, timeout_ms, signal) do
    start_time = System.monotonic_time(:millisecond)
    initial_count = length(watched_jobs)

    poll_loop(watched_jobs, start_time, timeout_ms, signal, initial_count)
  end

  defp poll_loop(initial_jobs, start_time, timeout_ms, signal, initial_count) do
    # Check for abort signal
    if signal && AgentCore.AbortSignal.aborted?(signal) do
      return_aborted_result(initial_jobs)
    else
      # Check if timeout exceeded
      elapsed = System.monotonic_time(:millisecond) - start_time

      if elapsed >= timeout_ms do
        return_timeout_result(initial_jobs, timeout_ms)
      else
        # Refresh job statuses
        current_jobs = refresh_jobs(initial_jobs)

        # Check if any job has completed
        completed = Enum.filter(current_jobs, fn {_id, record} ->
          record.status in [:completed, :error, :killed]
        end)

        if completed != [] do
          # At least one job finished - return results
          return_results(current_jobs, initial_count, :completed)
        else
          # No jobs finished yet - wait and poll again
          Process.sleep(@poll_interval_ms)
          poll_loop(initial_jobs, start_time, timeout_ms, signal, initial_count)
        end
      end
    end
  end

  # Refresh job statuses from the store
  defp refresh_jobs(jobs) do
    Enum.map(jobs, fn {id, _record} ->
      case ProcessStore.get(id) do
        {:ok, record, _logs} -> {id, record}
        {:error, :not_found} -> {id, %{status: :lost}}
      end
    end)
  end

  # Return result when no jobs are found
  defp return_no_jobs_result do
    content = """
    No jobs to watch.

    Either no job IDs were specified and there are no active jobs,
    or the specified job IDs were not found.
    """

    %AgentToolResult{
      content: [%TextContent{type: :text, text: String.trim(content)}],
      details: %{status: :no_jobs}
    }
  end

  # Return result when polling was aborted
  defp return_aborted_result(jobs) do
    job_summary = format_job_summary(jobs)

    content = """
    Polling aborted.

    #{job_summary}
    """

    %AgentToolResult{
      content: [%TextContent{type: :text, text: String.trim(content)}],
      details: %{status: :aborted, jobs: format_job_details(jobs)}
    }
  end

  # Return result when timeout was reached
  defp return_timeout_result(jobs, timeout_ms) do
    timeout_sec = div(timeout_ms, 1000)
    job_summary = format_job_summary(jobs)

    content = """
    Timeout after #{timeout_sec}s - no jobs completed.

    #{job_summary}
    """

    %AgentToolResult{
      content: [%TextContent{type: :text, text: String.trim(content)}],
      details: %{status: :timeout, timeout_sec: timeout_sec, jobs: format_job_details(jobs)}
    }
  end

  # Return results when at least one job completed
  defp return_results(jobs, initial_count, status) do
    completed_count = Enum.count(jobs, fn {_id, r} -> r.status in [:completed, :error, :killed] end)
    job_summary = format_job_summary(jobs)

    content = """
    #{completed_count} of #{initial_count} job(s) finished.

    #{job_summary}
    """

    %AgentToolResult{
      content: [%TextContent{type: :text, text: String.trim(content)}],
      details: %{status: status, jobs: format_job_details(jobs)}
    }
  end

  # Format a summary of all jobs
  defp format_job_summary(jobs) do
    jobs
    |> Enum.map(fn {id, record} ->
      status = record.status |> to_string() |> String.upcase()
      command = truncate_command(Map.get(record, :command, "N/A"))
      "- #{id}: #{status} - #{command}"
    end)
    |> Enum.join("\n")
  end

  # Format detailed job information
  defp format_job_details(jobs) do
    Enum.map(jobs, fn {id, record} ->
      %{
        id: id,
        status: record.status,
        command: Map.get(record, :command),
        exit_code: Map.get(record, :exit_code),
        error: Map.get(record, :error)
      }
    end)
  end

  # Truncate long commands for display
  defp truncate_command(nil), do: "N/A"
  defp truncate_command(cmd) when byte_size(cmd) > 50, do: String.slice(cmd, 0, 47) <> "..."
  defp truncate_command(cmd), do: cmd
end
