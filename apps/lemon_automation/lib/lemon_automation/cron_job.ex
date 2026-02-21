defmodule LemonAutomation.CronJob do
  @moduledoc """
  Represents a scheduled cron job for agent automation.

  ## Fields

  - `:id` - Unique job identifier (e.g., "cron_abc123")
  - `:name` - Human-readable job name
  - `:schedule` - Cron expression (e.g., "0 9 * * *" for 9 AM daily)
  - `:enabled` - Whether the job is active
  - `:agent_id` - Target agent for the job
  - `:session_key` - Session key for routing
  - `:prompt` - The prompt to send to the agent
  - `:timezone` - Timezone for schedule interpretation (default: "UTC")
  - `:jitter_sec` - Random delay in seconds to spread load (default: 0)
  - `:timeout_ms` - Maximum execution time in milliseconds
  - `:created_at_ms` - Creation timestamp
  - `:updated_at_ms` - Last update timestamp
  - `:last_run_at_ms` - Last execution timestamp
  - `:next_run_at_ms` - Next scheduled execution timestamp
  - `:meta` - Additional metadata map

  ## Schedule Format

  Standard cron format with 5 fields:
  ```
  * * * * *
  | | | | |
  | | | | +-- Day of week (0-7, Sunday = 0 or 7)
  | | | +---- Month (1-12)
  | | +------ Day of month (1-31)
  | +-------- Hour (0-23)
  +---------- Minute (0-59)
  ```

  ## Examples

      # Every hour at minute 0
      %CronJob{schedule: "0 * * * *", ...}

      # Daily at 9 AM
      %CronJob{schedule: "0 9 * * *", ...}

      # Every Monday at 8:30 AM
      %CronJob{schedule: "30 8 * * 1", ...}

      # Every 15 minutes
      %CronJob{schedule: "*/15 * * * *", ...}
  """

  @enforce_keys [:id, :name, :schedule, :agent_id, :session_key, :prompt]
  defstruct [
    :id,
    :name,
    :schedule,
    :agent_id,
    :session_key,
    :prompt,
    :created_at_ms,
    :updated_at_ms,
    :last_run_at_ms,
    :next_run_at_ms,
    :meta,
    enabled: true,
    timezone: "UTC",
    jitter_sec: 0,
    timeout_ms: 300_000
  ]

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          schedule: binary(),
          enabled: boolean(),
          agent_id: binary(),
          session_key: binary(),
          prompt: binary(),
          timezone: binary(),
          jitter_sec: non_neg_integer(),
          timeout_ms: non_neg_integer(),
          created_at_ms: non_neg_integer() | nil,
          updated_at_ms: non_neg_integer() | nil,
          last_run_at_ms: non_neg_integer() | nil,
          next_run_at_ms: non_neg_integer() | nil,
          meta: map() | nil
        }

  @doc """
  Create a new CronJob with auto-generated ID and timestamps.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = LemonCore.Clock.now_ms()

    %__MODULE__{
      id: attrs[:id] || LemonCore.Id.cron_id(),
      name: get_attr(attrs, :name),
      schedule: get_attr(attrs, :schedule),
      enabled: get_attr(attrs, :enabled, true),
      agent_id: get_attr(attrs, :agent_id),
      session_key: get_attr(attrs, :session_key),
      prompt: get_attr(attrs, :prompt),
      timezone: get_attr(attrs, :timezone, "UTC"),
      jitter_sec: get_attr(attrs, :jitter_sec, 0),
      timeout_ms: get_attr(attrs, :timeout_ms, 300_000),
      created_at_ms: now,
      updated_at_ms: now,
      last_run_at_ms: nil,
      next_run_at_ms: nil,
      meta: get_attr(attrs, :meta)
    }
  end

  @doc """
  Update a CronJob with new attributes, preserving immutable fields.
  """
  @spec update(t(), map()) :: t()
  def update(%__MODULE__{} = job, attrs) when is_map(attrs) do
    now = LemonCore.Clock.now_ms()

    %{
      job
      | name: get_attr(attrs, :name, job.name),
        schedule: get_attr(attrs, :schedule, job.schedule),
        enabled: get_attr(attrs, :enabled, job.enabled),
        prompt: get_attr(attrs, :prompt, job.prompt),
        timezone: get_attr(attrs, :timezone, job.timezone),
        jitter_sec: get_attr(attrs, :jitter_sec, job.jitter_sec),
        timeout_ms: get_attr(attrs, :timeout_ms, job.timeout_ms),
        meta: get_attr(attrs, :meta, job.meta),
        updated_at_ms: now
    }
  end

  @doc """
  Mark a job as having run at the given timestamp.
  """
  @spec mark_run(t(), non_neg_integer()) :: t()
  def mark_run(%__MODULE__{} = job, run_at_ms) do
    %{job | last_run_at_ms: run_at_ms, updated_at_ms: LemonCore.Clock.now_ms()}
  end

  @doc """
  Set the next scheduled run time.
  """
  @spec set_next_run(t(), non_neg_integer() | nil) :: t()
  def set_next_run(%__MODULE__{} = job, next_run_at_ms) do
    %{job | next_run_at_ms: next_run_at_ms, updated_at_ms: LemonCore.Clock.now_ms()}
  end

  @doc """
  Check if the job is due to run based on the current time.
  """
  @spec due?(t()) :: boolean()
  def due?(%__MODULE__{enabled: false}), do: false

  def due?(%__MODULE__{next_run_at_ms: nil}), do: false

  def due?(%__MODULE__{next_run_at_ms: next_run_at_ms}) do
    LemonCore.Clock.now_ms() >= next_run_at_ms
  end

  @doc """
  Convert the job to a map for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = job) do
    %{
      id: job.id,
      name: job.name,
      schedule: job.schedule,
      enabled: job.enabled,
      agent_id: job.agent_id,
      session_key: job.session_key,
      prompt: job.prompt,
      timezone: job.timezone,
      jitter_sec: job.jitter_sec,
      timeout_ms: job.timeout_ms,
      created_at_ms: job.created_at_ms,
      updated_at_ms: job.updated_at_ms,
      last_run_at_ms: job.last_run_at_ms,
      next_run_at_ms: job.next_run_at_ms,
      meta: job.meta
    }
  end

  @doc """
  Restore a CronJob from a persisted map.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: get_attr(map, :id),
      name: get_attr(map, :name),
      schedule: get_attr(map, :schedule),
      enabled: get_attr(map, :enabled, true),
      agent_id: get_attr(map, :agent_id),
      session_key: get_attr(map, :session_key),
      prompt: get_attr(map, :prompt),
      timezone: get_attr(map, :timezone, "UTC"),
      jitter_sec: get_attr(map, :jitter_sec, 0),
      timeout_ms: get_attr(map, :timeout_ms, 300_000),
      created_at_ms: get_attr(map, :created_at_ms),
      updated_at_ms: get_attr(map, :updated_at_ms),
      last_run_at_ms: get_attr(map, :last_run_at_ms),
      next_run_at_ms: get_attr(map, :next_run_at_ms),
      meta: get_attr(map, :meta)
    }
  end

  # Looks up an attribute by atom key first, then string key, with optional default.
  defp get_attr(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
