defmodule LemonAutomation.CronJob do
  @moduledoc """
  Represents a scheduled cron job for agent automation.

  ## Fields

  - `:id` - Unique job identifier (e.g., "cron_abc123")
  - `:name` - Human-readable job name
  - `:schedule` - Cron expression (e.g., "0 9 * * *" for 9 AM daily)
  - `:enabled` - Whether the job is active
  - `:agent_id` - Target agent for prompt jobs
  - `:session_key` - Session key for prompt-job routing
  - `:prompt` - The prompt to send to the agent
  - `:command` - Optional operator-owned shell command for no-agent jobs
  - `:cwd` - Optional command working directory
  - `:env` - Optional command environment overrides
  - `:memory_file` - Optional markdown file used as persistent cross-run memory
  - `:timezone` - Timezone for schedule interpretation (default: "UTC")
  - `:jitter_sec` - Random delay in seconds to spread load (default: 0)
  - `:timeout_ms` - Maximum execution time in milliseconds
  - `:max_retries` - Number of retry runs after failure/timeout (default: 0)
  - `:retry_backoff_ms` - Delay before retry runs in milliseconds (default: 30000)
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

  @enforce_keys [:id, :name, :schedule]
  defstruct [
    :id,
    :name,
    :schedule,
    :agent_id,
    :session_key,
    :prompt,
    :command,
    :cwd,
    :env,
    :memory_file,
    :created_at_ms,
    :updated_at_ms,
    :last_run_at_ms,
    :next_run_at_ms,
    :meta,
    enabled: true,
    timezone: "UTC",
    jitter_sec: 0,
    timeout_ms: 300_000,
    max_retries: 0,
    retry_backoff_ms: 30_000
  ]

  @type t :: %__MODULE__{
          id: binary(),
          name: binary(),
          schedule: binary(),
          enabled: boolean(),
          agent_id: binary() | nil,
          session_key: binary() | nil,
          prompt: binary() | nil,
          command: binary() | nil,
          cwd: binary() | nil,
          env: map() | nil,
          memory_file: binary() | nil,
          timezone: binary(),
          jitter_sec: non_neg_integer(),
          timeout_ms: non_neg_integer(),
          max_retries: non_neg_integer(),
          retry_backoff_ms: non_neg_integer(),
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
      command: get_attr(attrs, :command),
      cwd: get_attr(attrs, :cwd),
      env: get_attr(attrs, :env),
      memory_file: get_attr(attrs, :memory_file),
      timezone: get_attr(attrs, :timezone, "UTC"),
      jitter_sec: get_attr(attrs, :jitter_sec, 0),
      timeout_ms: get_attr(attrs, :timeout_ms, 300_000),
      max_retries: get_attr(attrs, :max_retries, 0),
      retry_backoff_ms: get_attr(attrs, :retry_backoff_ms, 30_000),
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
        command: get_attr(attrs, :command, job.command),
        cwd: get_attr(attrs, :cwd, job.cwd),
        env: get_attr(attrs, :env, job.env),
        memory_file: get_attr(attrs, :memory_file, job.memory_file),
        timezone: get_attr(attrs, :timezone, job.timezone),
        jitter_sec: get_attr(attrs, :jitter_sec, job.jitter_sec),
        timeout_ms: get_attr(attrs, :timeout_ms, job.timeout_ms),
        max_retries: get_attr(attrs, :max_retries, job.max_retries),
        retry_backoff_ms: get_attr(attrs, :retry_backoff_ms, job.retry_backoff_ms),
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
      command: job.command,
      cwd: job.cwd,
      env: job.env,
      memory_file: job.memory_file,
      timezone: job.timezone,
      jitter_sec: job.jitter_sec,
      timeout_ms: job.timeout_ms,
      max_retries: job.max_retries,
      retry_backoff_ms: job.retry_backoff_ms,
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
      command: get_attr(map, :command),
      cwd: get_attr(map, :cwd),
      env: get_attr(map, :env),
      memory_file: get_attr(map, :memory_file),
      timezone: get_attr(map, :timezone, "UTC"),
      jitter_sec: get_attr(map, :jitter_sec, 0),
      timeout_ms: get_attr(map, :timeout_ms, 300_000),
      max_retries: get_attr(map, :max_retries, 0),
      retry_backoff_ms: get_attr(map, :retry_backoff_ms, 30_000),
      created_at_ms: get_attr(map, :created_at_ms),
      updated_at_ms: get_attr(map, :updated_at_ms),
      last_run_at_ms: get_attr(map, :last_run_at_ms),
      next_run_at_ms: get_attr(map, :next_run_at_ms),
      meta: get_attr(map, :meta)
    }
  end

  @doc """
  Return how this cron job executes.
  """
  @spec execution_mode(t()) :: :agent | :command
  def execution_mode(%__MODULE__{command: command}) when is_binary(command) do
    if String.trim(command) == "", do: :agent, else: :command
  end

  def execution_mode(%__MODULE__{}), do: :agent

  # Looks up an attribute by atom key first, then string key, with optional default.
  defp get_attr(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
