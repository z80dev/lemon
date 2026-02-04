defmodule LemonAutomation.CronRun do
  @moduledoc """
  Represents a single execution of a cron job.

  Tracks the full lifecycle of a job run from start to completion,
  including success/failure status and any output or errors.

  ## Fields

  - `:id` - Unique run identifier
  - `:job_id` - Reference to the parent CronJob
  - `:run_id` - The LemonRouter run ID (if applicable)
  - `:status` - Current status: :pending, :running, :completed, :failed, :timeout
  - `:started_at_ms` - When the run started
  - `:completed_at_ms` - When the run finished
  - `:duration_ms` - Total execution time
  - `:triggered_by` - What triggered the run: :schedule, :manual, :wake
  - `:error` - Error message if failed
  - `:output` - Captured output/response summary
  - `:suppressed` - Whether output was suppressed (heartbeat OK)
  - `:meta` - Additional metadata

  ## Examples

      %CronRun{
        id: "run_abc123",
        job_id: "cron_xyz789",
        status: :completed,
        triggered_by: :schedule,
        duration_ms: 5230
      }
  """

  @enforce_keys [:id, :job_id, :status]
  defstruct [
    :id,
    :job_id,
    :run_id,
    :status,
    :started_at_ms,
    :completed_at_ms,
    :duration_ms,
    :triggered_by,
    :error,
    :output,
    :meta,
    suppressed: false
  ]

  @type status :: :pending | :running | :completed | :failed | :timeout
  @type trigger :: :schedule | :manual | :wake

  @type t :: %__MODULE__{
          id: binary(),
          job_id: binary(),
          run_id: binary() | nil,
          status: status(),
          started_at_ms: non_neg_integer() | nil,
          completed_at_ms: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          triggered_by: trigger() | nil,
          error: binary() | nil,
          output: binary() | nil,
          suppressed: boolean(),
          meta: map() | nil
        }

  @doc """
  Create a new pending CronRun.
  """
  @spec new(job_id :: binary(), trigger :: trigger()) :: t()
  def new(job_id, triggered_by \\ :schedule) do
    %__MODULE__{
      id: LemonCore.Id.run_id(),
      job_id: job_id,
      status: :pending,
      triggered_by: triggered_by,
      started_at_ms: nil,
      completed_at_ms: nil,
      duration_ms: nil,
      suppressed: false
    }
  end

  @doc """
  Mark the run as started.
  """
  @spec start(t(), run_id :: binary() | nil) :: t()
  def start(%__MODULE__{} = run, run_id \\ nil) do
    %{run | status: :running, run_id: run_id, started_at_ms: LemonCore.Clock.now_ms()}
  end

  @doc """
  Mark the run as completed successfully.
  """
  @spec complete(t(), output :: binary() | nil) :: t()
  def complete(%__MODULE__{} = run, output \\ nil) do
    now = LemonCore.Clock.now_ms()
    duration = if run.started_at_ms, do: now - run.started_at_ms, else: nil

    %{run | status: :completed, completed_at_ms: now, duration_ms: duration, output: output}
  end

  @doc """
  Mark the run as failed.
  """
  @spec fail(t(), error :: binary()) :: t()
  def fail(%__MODULE__{} = run, error) do
    now = LemonCore.Clock.now_ms()
    duration = if run.started_at_ms, do: now - run.started_at_ms, else: nil

    %{run | status: :failed, completed_at_ms: now, duration_ms: duration, error: error}
  end

  @doc """
  Mark the run as timed out.
  """
  @spec timeout(t()) :: t()
  def timeout(%__MODULE__{} = run) do
    now = LemonCore.Clock.now_ms()
    duration = if run.started_at_ms, do: now - run.started_at_ms, else: nil

    %{
      run
      | status: :timeout,
        completed_at_ms: now,
        duration_ms: duration,
        error: "Run exceeded timeout"
    }
  end

  @doc """
  Mark the run's output as suppressed (heartbeat OK).
  """
  @spec suppress(t()) :: t()
  def suppress(%__MODULE__{} = run) do
    %{run | suppressed: true}
  end

  @doc """
  Check if the run is still active.
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}) do
    status in [:pending, :running]
  end

  @doc """
  Check if the run has finished (successfully or not).
  """
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: status}) do
    status in [:completed, :failed, :timeout]
  end

  @doc """
  Convert the run to a map for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = run) do
    %{
      id: run.id,
      job_id: run.job_id,
      run_id: run.run_id,
      status: run.status,
      started_at_ms: run.started_at_ms,
      completed_at_ms: run.completed_at_ms,
      duration_ms: run.duration_ms,
      triggered_by: run.triggered_by,
      error: run.error,
      output: run.output,
      suppressed: run.suppressed,
      meta: run.meta
    }
  end

  @doc """
  Restore a CronRun from a persisted map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map[:id] || map["id"],
      job_id: map[:job_id] || map["job_id"],
      run_id: map[:run_id] || map["run_id"],
      status: parse_status(map[:status] || map["status"]),
      started_at_ms: map[:started_at_ms] || map["started_at_ms"],
      completed_at_ms: map[:completed_at_ms] || map["completed_at_ms"],
      duration_ms: map[:duration_ms] || map["duration_ms"],
      triggered_by: parse_trigger(map[:triggered_by] || map["triggered_by"]),
      error: map[:error] || map["error"],
      output: map[:output] || map["output"],
      suppressed: Map.get(map, :suppressed, Map.get(map, "suppressed", false)),
      meta: map[:meta] || map["meta"]
    }
  end

  defp parse_status(status) when is_atom(status), do: status
  defp parse_status("pending"), do: :pending
  defp parse_status("running"), do: :running
  defp parse_status("completed"), do: :completed
  defp parse_status("failed"), do: :failed
  defp parse_status("timeout"), do: :timeout
  defp parse_status(_), do: :pending

  defp parse_trigger(trigger) when is_atom(trigger), do: trigger
  defp parse_trigger("schedule"), do: :schedule
  defp parse_trigger("manual"), do: :manual
  defp parse_trigger("wake"), do: :wake
  defp parse_trigger(_), do: :schedule
end
