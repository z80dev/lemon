defmodule CodingAgent.RateLimitPause do
  @moduledoc """
  Tracks rate limit pause state for auto-resume functionality.

  When a coding session hits a provider rate limit, this module captures
  the pause metadata (retry-after, provider, reset window) and manages
  the resume scheduling.

  ## Usage

      # When rate limit is detected
      {:ok, pause} = RateLimitPause.create(session_id, provider, retry_after_ms)

      # Check if ready to resume
      if RateLimitPause.ready_to_resume?(pause.id) do
        {:ok, state} = RateLimitPause.resume(pause.id)
        # Continue execution...
      end

      # List pending pauses for a session
      pauses = RateLimitPause.list_pending(session_id)
  """

  require Logger

  @type pause_id :: String.t()
  @type session_id :: String.t()
  @type provider :: atom()

  @type t :: %{
    id: pause_id(),
    session_id: session_id(),
    provider: provider(),
    status: :paused | :resumed | :expired,
    paused_at: DateTime.t(),
    retry_after_ms: non_neg_integer(),
    resume_at: DateTime.t() | nil,
    resumed_at: DateTime.t() | nil,
    metadata: map()
  }

  # ETS table for in-memory pause tracking
  @table :coding_agent_rate_limit_pauses

  @doc """
  Creates a new rate limit pause record.

  ## Options
    * `:metadata` - Additional context (error message, headers, etc.)
  """
  @spec create(session_id(), provider(), non_neg_integer(), keyword()) ::
    {:ok, t()} | {:error, term()}
  def create(session_id, provider, retry_after_ms, opts \\ []) when is_binary(session_id) do
    ensure_table()

    now = DateTime.utc_now()
    resume_at = DateTime.add(now, trunc(retry_after_ms / 1000), :second)

    pause = %{
      id: generate_id(),
      session_id: session_id,
      provider: provider,
      status: :paused,
      paused_at: now,
      retry_after_ms: retry_after_ms,
      resume_at: resume_at,
      resumed_at: nil,
      metadata: opts[:metadata] || %{}
    }

    :ets.insert(@table, {pause.id, pause})
    :ets.insert(@table, {{:session, session_id, pause.id}, pause.id})

    Logger.info(
      "Rate limit pause created for session #{session_id} on #{provider}. " <>
      "Will resume at #{DateTime.to_iso8601(resume_at)}"
    )

    emit_telemetry(:paused, pause)
    {:ok, pause}
  end

  @doc """
  Checks if a pause is ready to be resumed.
  """
  @spec ready_to_resume?(pause_id()) :: boolean()
  def ready_to_resume?(pause_id) do
    case get(pause_id) do
      {:ok, %{status: :paused, resume_at: resume_at}} ->
        DateTime.compare(DateTime.utc_now(), resume_at) != :lt

      _ ->
        false
    end
  end

  @doc """
  Marks a pause as resumed and returns the pause state.
  """
  @spec resume(pause_id()) :: {:ok, t()} | {:error, :not_found | :not_ready}
  def resume(pause_id) do
    case get(pause_id) do
      {:ok, %{status: :paused} = pause} ->
        if ready_to_resume?(pause_id) do
          now = DateTime.utc_now()
          updated = %{pause | status: :resumed, resumed_at: now}

          :ets.insert(@table, {pause_id, updated})

          Logger.info("Rate limit pause #{pause_id} resumed for session #{pause.session_id}")
          emit_telemetry(:resumed, updated)

          {:ok, updated}
        else
          {:error, :not_ready}
        end

      {:ok, %{status: other}} ->
        {:error, {:invalid_status, other}}

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Gets a pause by ID.
  """
  @spec get(pause_id()) :: {:ok, t()} | {:error, :not_found}
  def get(pause_id) do
    ensure_table()

    case :ets.lookup(@table, pause_id) do
      [{^pause_id, pause}] -> {:ok, pause}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all pending (paused) rate limit records for a session.
  """
  @spec list_pending(session_id()) :: [t()]
  def list_pending(session_id) do
    ensure_table()

    match_spec = {{:session, session_id, :"$1"}, :_}

    @table
    |> :ets.match_object(match_spec)
    |> Enum.map(fn {{:session, ^session_id, pause_id}, _} ->
      case get(pause_id) do
        {:ok, %{status: :paused} = pause} -> pause
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.paused_at, DateTime)
  end

  @doc """
  Lists all pauses (any status) for a session.
  """
  @spec list_all(session_id()) :: [t()]
  def list_all(session_id) do
    ensure_table()

    match_spec = {{:session, session_id, :"$1"}, :_}

    @table
    |> :ets.match_object(match_spec)
    |> Enum.map(fn {{:session, ^session_id, pause_id}, _} ->
      case get(pause_id) do
        {:ok, pause} -> pause
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.paused_at, DateTime)
  end

  @doc """
  Returns statistics for rate limit pauses.
  """
  @spec stats() :: %{
    total_pauses: non_neg_integer(),
    pending_pauses: non_neg_integer(),
    resumed_pauses: non_neg_integer(),
    by_provider: %{atom() => non_neg_integer()}
  }
  def stats do
    ensure_table()

    all = :ets.tab2list(@table)
    pauses = for {id, pause} when is_binary(id) <- all, do: pause

    total = length(pauses)
    pending = Enum.count(pauses, & &1.status == :paused)
    resumed = Enum.count(pauses, & &1.status == :resumed)

    by_provider =
      pauses
      |> Enum.group_by(& &1.provider)
      |> Enum.map(fn {provider, list} -> {provider, length(list)} end)
      |> Enum.into(%{})

    %{
      total_pauses: total,
      pending_pauses: pending,
      resumed_pauses: resumed,
      by_provider: by_provider
    }
  end

  @doc """
  Cleans up expired pause records older than the given age.
  """
  @spec cleanup_expired(non_neg_integer()) :: non_neg_integer()
  def cleanup_expired(max_age_ms \\ 24 * 60 * 60 * 1000) do
    ensure_table()

    cutoff = DateTime.add(DateTime.utc_now(), -trunc(max_age_ms / 1000), :second)

    expired =
      @table
      |> :ets.tab2list()
      |> Enum.filter(fn
        {id, pause} when is_binary(id) ->
          DateTime.compare(pause.paused_at, cutoff) == :lt

        _ ->
          false
      end)

    count = length(expired)

    for {id, _} <- expired do
      :ets.delete(@table, id)
    end

    Logger.debug("Cleaned up #{count} expired rate limit pause records")
    count
  end

  # Private functions

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  defp generate_id do
    "rlp_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_telemetry(event, pause) do
    :telemetry.execute(
      [:coding_agent, :rate_limit_pause, event],
      %{
        retry_after_ms: pause.retry_after_ms,
        time_to_resume: time_until_resume(pause)
      },
      %{
        session_id: pause.session_id,
        provider: pause.provider,
        pause_id: pause.id
      }
    )
  end

  defp time_until_resume(%{resume_at: nil}), do: nil
  defp time_until_resume(%{resume_at: resume_at}) do
    DateTime.diff(resume_at, DateTime.utc_now(), :millisecond)
  end
end
