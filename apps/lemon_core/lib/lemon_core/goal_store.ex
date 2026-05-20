defmodule LemonCore.GoalStore do
  @moduledoc """
  Durable user goal state keyed by session.
  """

  require Logger

  alias LemonCore.{Bus, Event, Introspection, Store}

  @table :goals
  @statuses ~w(active paused completed)
  @loop_actions ~w(continue done blocked needs_input)
  @loop_statuses ~w(running stopped finished limit_reached error)
  @loop_auto_policies ~w(pause continue_once needs_input)

  @spec set(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def set(session_key, objective, opts \\ [])
      when is_binary(session_key) and is_binary(objective) do
    objective = String.trim(objective)

    cond do
      session_key == "" ->
        {:error, :invalid_session_key}

      objective == "" ->
        {:error, :empty_objective}

      true ->
        now = now_ms()
        existing = get(session_key)

        goal =
          %{
            id: existing[:id] || existing["id"] || goal_id(),
            session_key: session_key,
            agent_id: string_opt(opts[:agent_id]) || existing[:agent_id] || existing["agent_id"],
            objective: objective,
            status: "active",
            created_at_ms: existing[:created_at_ms] || existing["created_at_ms"] || now,
            updated_at_ms: now,
            paused_at_ms: nil,
            completed_at_ms: nil,
            last_run_id:
              string_opt(opts[:run_id]) || existing[:last_run_id] || existing["last_run_id"],
            continuation_count:
              existing[:continuation_count] || existing["continuation_count"] || 0,
            budget: normalize_budget(opts[:budget] || existing[:budget] || existing["budget"]),
            meta: normalize_meta(opts[:meta] || existing[:meta] || existing["meta"])
          }

        with :ok <- Store.put(@table, session_key, goal) do
          emit(:goal_set, goal, opts)
          {:ok, goal}
        end
    end
  end

  @spec get(binary()) :: map()
  def get(session_key) when is_binary(session_key) do
    case Store.get(@table, session_key) do
      nil -> %{}
      goal when is_map(goal) -> normalize_goal(goal)
      _ -> %{}
    end
  end

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    status = opts[:status] && to_string(opts[:status])
    agent_id = opts[:agent_id] && to_string(opts[:agent_id])
    limit = opts[:limit] || 50

    @table
    |> Store.list()
    |> Enum.map(fn {_key, goal} -> normalize_goal(goal) end)
    |> Enum.reject(&(&1 == %{}))
    |> maybe_filter(:status, status)
    |> maybe_filter(:agent_id, agent_id)
    |> Enum.sort_by(&(&1[:updated_at_ms] || 0), :desc)
    |> Enum.take(limit)
  end

  @spec pause(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def pause(session_key, opts \\ []), do: transition(session_key, "paused", :goal_paused, opts)

  @spec resume(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume(session_key, opts \\ []), do: transition(session_key, "active", :goal_resumed, opts)

  @spec complete(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete(session_key, opts \\ []),
    do: transition(session_key, "completed", :goal_completed, opts)

  @spec record_continuation(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_continuation(session_key, run_id, opts \\ [])
      when is_binary(session_key) and is_binary(run_id) do
    cond do
      String.trim(run_id) == "" ->
        {:error, :invalid_run_id}

      true ->
        case get(session_key) do
          %{} = goal when map_size(goal) == 0 ->
            {:error, :not_found}

          goal ->
            now = now_ms()

            updated =
              goal
              |> Map.put(:status, "active")
              |> Map.put(:updated_at_ms, now)
              |> Map.put(:paused_at_ms, nil)
              |> Map.put(:last_run_id, run_id)
              |> Map.put(:continuation_count, (goal.continuation_count || 0) + 1)

            with :ok <- Store.put(@table, session_key, updated) do
              emit(:goal_continuation_submitted, updated, Keyword.put(opts, :run_id, run_id))
              {:ok, updated}
            end
        end
    end
  end

  @spec record_loop_verdict(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def record_loop_verdict(session_key, verdict, opts \\ [])
      when is_binary(session_key) and is_map(verdict) do
    case normalize_loop_verdict(verdict) do
      {:ok, normalized} ->
        case get(session_key) do
          %{} = goal when map_size(goal) == 0 ->
            {:error, :not_found}

          goal ->
            now = now_ms()
            run_id = string_opt(opts[:run_id]) || goal.last_run_id

            loop =
              goal.meta
              |> current_loop()
              |> Map.put(
                "lastVerdict",
                normalized
                |> Map.put("atMs", now)
                |> maybe_put("runId", run_id)
              )
              |> Map.put("verdictCount", loop_verdict_count(goal.meta) + 1)

            updated =
              goal
              |> Map.put(:updated_at_ms, now)
              |> Map.put(:meta, Map.put(goal.meta || %{}, "goalLoop", loop))

            with :ok <- Store.put(@table, session_key, updated) do
              emit(:goal_loop_verdict, updated, Keyword.put(opts, :run_id, run_id))
              {:ok, updated}
            end
        end

      error ->
        error
    end
  end

  @spec record_loop_status(binary(), binary() | atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def record_loop_status(session_key, status, opts \\ []) when is_binary(session_key) do
    status = to_string(status)

    cond do
      status not in @loop_statuses ->
        {:error, :invalid_loop_status}

      true ->
        case get(session_key) do
          %{} = goal when map_size(goal) == 0 ->
            {:error, :not_found}

          goal ->
            now = now_ms()

            loop =
              goal.meta
              |> current_loop()
              |> Map.put("status", status)
              |> Map.put("updatedAtMs", now)
              |> maybe_put("lastError", string_opt(opts[:error]))
              |> maybe_put("lastRunId", string_opt(opts[:run_id]) || goal.last_run_id)
              |> maybe_started_at(status, now)
              |> maybe_stopped_at(status, now)

            updated =
              goal
              |> Map.put(:updated_at_ms, now)
              |> Map.put(:meta, Map.put(goal.meta || %{}, "goalLoop", loop))

            with :ok <- Store.put(@table, session_key, updated) do
              emit(:goal_loop_status, updated, Keyword.put(opts, :run_id, loop["lastRunId"]))
              {:ok, updated}
            end
        end
    end
  end

  @spec configure_loop_auto(binary(), boolean(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def configure_loop_auto(session_key, enabled, opts \\ [])
      when is_binary(session_key) and is_boolean(enabled) do
    case get(session_key) do
      %{} = goal when map_size(goal) == 0 ->
        {:error, :not_found}

      goal ->
        now = now_ms()
        loop = current_loop(goal.meta)
        existing_auto = current_loop_auto(loop)
        options = normalize_loop_auto_options(opts)

        auto =
          existing_auto
          |> Map.put("enabled", enabled)
          |> Map.put("updatedAtMs", now)
          |> maybe_put_auto_options(options)

        loop =
          loop
          |> Map.put("auto", auto)
          |> Map.put("updatedAtMs", now)

        updated =
          goal
          |> Map.put(:updated_at_ms, now)
          |> Map.put(:meta, Map.put(goal.meta || %{}, "goalLoop", loop))

        with :ok <- Store.put(@table, session_key, updated) do
          emit(:goal_loop_status, updated, opts)
          {:ok, updated}
        end
    end
  end

  @spec clear(binary(), keyword()) :: :ok | {:error, term()}
  def clear(session_key, opts \\ []) when is_binary(session_key) do
    goal = get(session_key)

    with :ok <- Store.delete(@table, session_key) do
      if goal != %{} do
        emit(:goal_cleared, goal, opts)
      end

      :ok
    end
  end

  @spec diagnostics(keyword()) :: map()
  def diagnostics(opts \\ []) do
    goals = list(limit: opts[:limit] || 20)

    %{
      count: length(goals),
      active_count: Enum.count(goals, &(&1.status == "active")),
      paused_count: Enum.count(goals, &(&1.status == "paused")),
      completed_count: Enum.count(goals, &(&1.status == "completed")),
      recent:
        Enum.map(goals, fn goal ->
          %{
            goal_id: goal.id,
            session_hash: hash_value(goal.session_key),
            agent_id: goal.agent_id,
            status: goal.status,
            objective_bytes: byte_size(goal.objective || ""),
            updated_at_ms: goal.updated_at_ms,
            continuation_count: goal.continuation_count || 0,
            max_continuations: max_continuations(goal.budget),
            loop_status: loop_status(goal.meta),
            loop_auto_enabled: loop_auto_enabled(goal.meta),
            loop_verdict_count: loop_verdict_count(goal.meta),
            loop_last_action: loop_last_action(goal.meta)
          }
        end),
      cleanup: %{
        includes_objectives: false,
        includes_raw_session_ids: false
      }
    }
  end

  defp transition(session_key, status, event_type, opts) when status in @statuses do
    case get(session_key) do
      %{} = goal when map_size(goal) == 0 ->
        {:error, :not_found}

      goal ->
        now = now_ms()

        updated =
          goal
          |> Map.put(:status, status)
          |> Map.put(:updated_at_ms, now)
          |> Map.put(:paused_at_ms, paused_at(status, now))
          |> Map.put(:completed_at_ms, completed_at(status, now))

        with :ok <- Store.put(@table, session_key, updated) do
          emit(event_type, updated, opts)
          {:ok, updated}
        end
    end
  end

  defp paused_at("paused", now), do: now
  defp paused_at(_status, _now), do: nil

  defp completed_at("completed", now), do: now
  defp completed_at(_status, _now), do: nil

  defp maybe_filter(goals, _field, nil), do: goals
  defp maybe_filter(goals, _field, ""), do: goals
  defp maybe_filter(goals, field, value), do: Enum.filter(goals, &(Map.get(&1, field) == value))

  defp normalize_goal(goal) when is_map(goal) do
    %{
      id: field(goal, :id),
      session_key: field(goal, :session_key),
      agent_id: field(goal, :agent_id),
      objective: field(goal, :objective),
      status: field(goal, :status) || "active",
      created_at_ms: field(goal, :created_at_ms),
      updated_at_ms: field(goal, :updated_at_ms),
      paused_at_ms: field(goal, :paused_at_ms),
      completed_at_ms: field(goal, :completed_at_ms),
      last_run_id: field(goal, :last_run_id),
      continuation_count: field(goal, :continuation_count) || 0,
      budget: field(goal, :budget) || %{},
      meta: field(goal, :meta) || %{}
    }
  end

  defp normalize_goal(_), do: %{}

  defp normalize_budget(value) when is_map(value), do: value
  defp normalize_budget(_), do: %{}

  defp max_continuations(%{} = budget),
    do: budget["max_continuations"] || budget[:max_continuations]

  defp max_continuations(_), do: nil

  defp normalize_meta(value) when is_map(value), do: value
  defp normalize_meta(_), do: %{}

  defp normalize_loop_verdict(verdict) do
    action =
      verdict
      |> field(:action)
      |> to_string()

    cond do
      action not in @loop_actions ->
        {:error, :invalid_loop_action}

      true ->
        {:ok,
         %{
           "action" => action,
           "reason" => string_opt(field(verdict, :reason)) || "",
           "source" => string_opt(field(verdict, :source)) || "unknown"
         }}
    end
  end

  defp current_loop(meta) when is_map(meta) do
    meta["goalLoop"] || meta[:goalLoop] || meta["goal_loop"] || meta[:goal_loop] || %{}
  end

  defp current_loop(_), do: %{}

  defp loop_verdict_count(meta) when is_map(meta) do
    loop = current_loop(meta)

    loop["verdictCount"] || loop[:verdictCount] || loop["verdict_count"] || loop[:verdict_count] ||
      0
  end

  defp loop_verdict_count(_), do: 0

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp last_loop_verdict(meta) when is_map(meta) do
    loop = current_loop(meta)
    loop["lastVerdict"] || loop[:lastVerdict]
  end

  defp last_loop_verdict(_), do: nil

  defp loop_status(meta) when is_map(meta) do
    current_loop(meta)["status"] || current_loop(meta)[:status]
  end

  defp loop_status(_), do: nil

  defp current_loop_auto(loop) when is_map(loop) do
    case loop["auto"] || loop[:auto] do
      %{} = auto -> auto
      _ -> %{}
    end
  end

  defp current_loop_auto(_), do: %{}

  defp loop_auto_enabled(meta) when is_map(meta) do
    meta
    |> current_loop()
    |> current_loop_auto()
    |> Map.get("enabled", false)
  end

  defp loop_auto_enabled(_), do: false

  defp loop_last_action(meta) when is_map(meta) do
    case last_loop_verdict(meta) do
      %{} = verdict -> verdict["action"] || verdict[:action]
      _ -> nil
    end
  end

  defp loop_last_action(_), do: nil

  defp maybe_started_at(loop, "running", now), do: Map.put_new(loop, "startedAtMs", now)
  defp maybe_started_at(loop, _status, _now), do: loop

  defp maybe_stopped_at(loop, status, now)
       when status in ["stopped", "finished", "limit_reached", "error"] do
    Map.put(loop, "stoppedAtMs", now)
  end

  defp maybe_stopped_at(loop, _status, _now), do: loop

  defp normalize_loop_auto_options(opts) when is_list(opts) do
    opts
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      put_loop_auto_option(acc, key, value)
    end)
  end

  defp normalize_loop_auto_options(opts) when is_map(opts) do
    opts
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      put_loop_auto_option(acc, key, value)
    end)
  end

  defp normalize_loop_auto_options(_), do: %{}

  defp put_loop_auto_option(acc, key, value)
       when key in [:max_ticks, "max_ticks", "maxTicks"] and is_integer(value) and value > 0,
       do: Map.put(acc, "maxTicks", value)

  defp put_loop_auto_option(acc, key, value)
       when key in [:max_continuations, "max_continuations", "maxContinuations"] and
              is_integer(value) and value >= 0,
       do: Map.put(acc, "maxContinuations", value)

  defp put_loop_auto_option(acc, key, value)
       when key in [:interval_ms, "interval_ms", "intervalMs"] and is_integer(value) and
              value >= 0,
       do: Map.put(acc, "intervalMs", value)

  defp put_loop_auto_option(acc, key, value)
       when key in [:wait_timeout_ms, "wait_timeout_ms", "waitTimeoutMs"] and is_integer(value) and
              value > 0,
       do: Map.put(acc, "waitTimeoutMs", value)

  defp put_loop_auto_option(acc, key, value)
       when key in [:judge_model, "judge_model", "judgeModel"] and is_binary(value),
       do: Map.put(acc, "judgeModel", value)

  defp put_loop_auto_option(acc, key, value)
       when key in [:model, "model"] and is_binary(value),
       do: Map.put(acc, "model", value)

  defp put_loop_auto_option(acc, key, value)
       when key in [:judge_failure_policy, "judge_failure_policy", "judgeFailurePolicy"] do
    policy = to_string(value)

    if policy in @loop_auto_policies do
      Map.put(acc, "judgeFailurePolicy", policy)
    else
      acc
    end
  end

  defp put_loop_auto_option(acc, _key, _value), do: acc

  defp maybe_put_auto_options(auto, options) when map_size(options) == 0, do: auto
  defp maybe_put_auto_options(auto, options), do: Map.put(auto, "options", options)

  defp emit(event_type, goal, opts) do
    payload = %{
      goal_id: goal.id,
      session_key: goal.session_key,
      agent_id: goal.agent_id,
      status: goal.status,
      objective_bytes: byte_size(goal.objective || ""),
      continuation_count: goal.continuation_count || 0,
      last_run_id: goal.last_run_id,
      loop_verdict: last_loop_verdict(goal.meta),
      loop_status: loop_status(goal.meta),
      loop_auto_enabled: loop_auto_enabled(goal.meta)
    }

    _ =
      Introspection.record(event_type, payload,
        run_id: string_opt(opts[:run_id]) || goal.last_run_id,
        session_key: goal.session_key,
        agent_id: goal.agent_id,
        engine: "lemon",
        provenance: :direct
      )

    if Process.whereis(LemonCore.PubSub) do
      event = Event.new(event_type, payload, %{session_key: goal.session_key, goal_id: goal.id})
      Bus.broadcast("goals", event)
      Bus.broadcast(Bus.session_topic(goal.session_key), event)
    end

    :ok
  rescue
    error ->
      Logger.debug("Failed to emit goal event #{event_type}: #{Exception.message(error)}")
      :ok
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp string_opt(value) when is_binary(value) and value != "", do: value
  defp string_opt(value) when is_atom(value), do: Atom.to_string(value)
  defp string_opt(value) when is_integer(value), do: Integer.to_string(value)
  defp string_opt(_), do: nil

  defp goal_id, do: "goal_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp now_ms, do: System.system_time(:millisecond)

  defp hash_value(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_value(_), do: nil
end
