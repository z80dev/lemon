defmodule LemonAutomation.SkillCurator do
  @moduledoc """
  Background submission path for Lemon's learned-skill curator.

  `LemonSkills.Curator` owns lifecycle state and prompt rendering. This module
  applies automation gates and submits the generated review prompt to an agent
  when review work is due.
  """

  @default_interval_hours 24 * 7
  @default_min_idle_hours 2
  @default_stale_after_days 30
  @default_archive_after_days 90
  @default_agent_id "default"

  @doc """
  Run one curator pass and submit the review prompt when needed.
  """
  @spec run_once(keyword()) :: {:ok, map()} | {:skip, atom()} | {:error, term()}
  def run_once(opts \\ []) do
    cfg = config(opts)
    curator_mod = Keyword.get(opts, :curator_mod, LemonSkills.Curator)

    cond do
      not enabled?(cfg) ->
        {:skip, :disabled}

      not idle_enough?(cfg, opts) ->
        {:skip, :not_idle}

      not curator_mod.should_run_now?(curator_opts(cfg, opts)) ->
        {:skip, :not_due}

      true ->
        case curator_mod.run(curator_opts(cfg, opts)) do
          {:ok, %{review_required: true, review_prompt: prompt} = result} ->
            submit_review(prompt, result, cfg, opts)

          {:ok, result} ->
            {:ok, Map.merge(result, %{submitted: false, skip_reason: :no_review_required})}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Return true when a curator pass should be attempted.
  """
  @spec should_run_now?(keyword()) :: boolean()
  def should_run_now?(opts \\ []) do
    cfg = config(opts)
    curator_mod = Keyword.get(opts, :curator_mod, LemonSkills.Curator)

    enabled?(cfg) and idle_enough?(cfg, opts) and
      curator_mod.should_run_now?(curator_opts(cfg, opts))
  rescue
    _ -> false
  end

  @doc false
  @spec config(keyword()) :: keyword()
  def config(opts \\ []) do
    app_cfg =
      :lemon_automation
      |> Application.get_env(:skill_curator, [])
      |> normalize_config()

    Keyword.merge(default_config(), Keyword.merge(app_cfg, opts))
  end

  @doc false
  @spec idle_for_seconds(keyword()) :: non_neg_integer()
  def idle_for_seconds(opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, LemonCore.Clock.now_ms())
    last_busy_at_ms = Keyword.get(opts, :last_busy_at_ms, now_ms)
    max(0, div(now_ms - last_busy_at_ms, 1000))
  end

  @doc false
  @spec active_sessions?(keyword()) :: boolean()
  def active_sessions?(opts \\ []) do
    sessions_fun = Keyword.get(opts, :active_sessions_fun)

    sessions =
      cond do
        is_function(sessions_fun, 0) ->
          sessions_fun.()

        router_mod = Keyword.get(opts, :active_sessions_mod, LemonRouter.Router) ->
          router_mod.list_active_sessions()
      end

    match?([_ | _], sessions)
  rescue
    _ -> false
  end

  defp submit_review(prompt, result, cfg, opts) do
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    agent_id = to_string(Keyword.get(cfg, :agent_id, @default_agent_id))
    session_key = Keyword.get(cfg, :session_key) || "agent:#{agent_id}:main"
    run_id = Keyword.get(opts, :run_id, LemonCore.Id.run_id())

    params = %{
      origin: :skill_curator,
      run_id: run_id,
      session_key: session_key,
      agent_id: agent_id,
      prompt: prompt,
      meta: %{
        skill_curator: true,
        skill_curator_started_at: result.started_at,
        skill_curator_summary: result.summary,
        skill_curator_candidate_count: length(Map.get(result, :candidates, []))
      }
    }

    case router_mod.submit(params) do
      {:ok, router_run_id} ->
        {:ok, Map.merge(result, %{submitted: true, run_id: router_run_id})}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_submit_result, other}}
    end
  end

  defp enabled?(cfg), do: Keyword.get(cfg, :enabled, true) == true

  defp idle_enough?(cfg, opts) do
    case Keyword.get(opts, :idle_for_seconds) do
      nil ->
        true

      seconds when is_number(seconds) ->
        seconds >= positive_number(cfg, :min_idle_hours, @default_min_idle_hours) * 3600

      _ ->
        true
    end
  end

  defp curator_opts(cfg, opts) do
    [
      enabled: enabled?(cfg),
      scope: Keyword.get(cfg, :scope, :global),
      cwd: Keyword.get(cfg, :cwd),
      interval_hours: positive_integer(cfg, :interval_hours, @default_interval_hours),
      stale_after_days: positive_integer(cfg, :stale_after_days, @default_stale_after_days),
      archive_after_days: positive_integer(cfg, :archive_after_days, @default_archive_after_days),
      now: Keyword.get(opts, :now, DateTime.utc_now())
    ]
  end

  defp default_config do
    [
      enabled: true,
      scope: :global,
      cwd: nil,
      interval_hours: @default_interval_hours,
      min_idle_hours: @default_min_idle_hours,
      stale_after_days: @default_stale_after_days,
      archive_after_days: @default_archive_after_days,
      agent_id: @default_agent_id,
      session_key: nil
    ]
  end

  defp normalize_config(config) when is_map(config) do
    Enum.flat_map(config, fn {key, value} ->
      case normalize_key(key) do
        key when is_atom(key) -> [{key, value}]
        _ -> []
      end
    end)
  end

  defp normalize_config(config) when is_list(config), do: config
  defp normalize_config(_), do: []

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "enabled" -> :enabled
      "scope" -> :scope
      "cwd" -> :cwd
      "interval_hours" -> :interval_hours
      "min_idle_hours" -> :min_idle_hours
      "stale_after_days" -> :stale_after_days
      "archive_after_days" -> :archive_after_days
      "agent_id" -> :agent_id
      "session_key" -> :session_key
      _ -> key
    end
  end

  defp positive_integer(cfg, key, default) do
    case Keyword.get(cfg, key, default) do
      value when is_integer(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_integer(value, default)
      _ -> default
    end
  end

  defp positive_number(cfg, key, default) do
    case Keyword.get(cfg, key, default) do
      value when is_number(value) and value > 0 -> value
      value when is_binary(value) -> parse_positive_float(value, default)
      _ -> default
    end
  end

  defp parse_positive_integer(value, default) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_float(value, default) do
    case Float.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end
end
