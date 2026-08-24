defmodule LemonAutomation.Doctor.Checks.Synthesis do
  @moduledoc """
  Reports the state of the scheduled skill-synthesis runner.

  The runner (`LemonAutomation.SynthesisRunner`) records one metrics row per
  pass; this check surfaces those counts so the learning loop is observable.
  It only warns when the runner looks stalled — enabled, with recorded passes,
  but nothing observed for three intervals — since that means the loop
  silently stopped.

  Registered via `config :lemon_core, :doctor_checks, [__MODULE__]`.
  """

  alias LemonAutomation.SynthesisMetrics
  alias LemonAutomation.SynthesisRunner
  alias LemonCore.Config.Features
  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Check

  @name "automation.skill_synthesis"

  @stall_intervals 3

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    features = Keyword.get_lazy(opts, :features, fn -> load_features(opts) end)
    state = Map.get(features, :skill_synthesis_drafts, :off)
    cfg = Keyword.get_lazy(opts, :runner_config, fn -> SynthesisRunner.config([]) end)

    [check(state, cfg, opts)]
  rescue
    e ->
      [Check.warn(@name, "synthesis diagnostics unavailable.", Exception.message(e))]
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp check(:off, _cfg, _opts) do
    Check.pass(@name, "skill_synthesis_drafts is off — synthesis runner inactive.")
  end

  defp check(state, cfg, opts) do
    if Keyword.get(cfg, :enabled, true) == true do
      enabled_check(state, cfg, opts)
    else
      Check.pass(@name, "synthesis runner disabled by config.")
    end
  end

  defp enabled_check(state, cfg, opts) do
    summary = summary(state)

    case {recorded_passes(), stalled(cfg, opts)} do
      {0, _} ->
        Check.pass(
          @name,
          "skill_synthesis_drafts is #{state}; runner enabled; no synthesis passes recorded yet."
        )

      {_, {:stalled, age_hours, interval_hours}} ->
        Check.warn(
          @name,
          summary <>
            " — last pass #{age_hours}h ago, more than #{@stall_intervals}× the #{interval_hours}h interval.",
          "Check SynthesisRunnerManager logs; verify lemon_skills/lemon_memory are running."
        )

      {_, :ok} ->
        Check.pass(@name, summary)
    end
  end

  defp summary(state) do
    counts = SynthesisMetrics.aggregate()

    "skill_synthesis_drafts is #{state}; candidates=#{counts.total_candidates} " <>
      "generated=#{counts.generated} blocked=#{counts.blocked_by_audit}"
  end

  defp recorded_passes do
    length(SynthesisMetrics.list(limit: 1))
  end

  defp stalled(cfg, opts) do
    interval_hours = interval_hours(cfg)
    now_ms = Keyword.get(opts, :now_ms) || LemonCore.Clock.now_ms()
    agent_id = to_string(Keyword.get(cfg, :agent_id, "default"))

    case SynthesisRunner.get_state(agent_id) do
      %{last_run_at_ms: last} when is_integer(last) ->
        age_ms = max(now_ms - last, 0)

        if age_ms > @stall_intervals * interval_hours * 3_600_000 do
          {:stalled, div(age_ms, 3_600_000), interval_hours}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp interval_hours(cfg) do
    case Keyword.get(cfg, :interval_hours, 6) do
      value when is_integer(value) and value > 0 -> value
      _ -> 6
    end
  end

  defp load_features(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    Modular.load(project_dir: project_dir).features
  rescue
    _ -> %Features{}
  end
end
