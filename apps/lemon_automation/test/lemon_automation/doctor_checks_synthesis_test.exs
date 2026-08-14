defmodule LemonAutomation.DoctorChecksSynthesisTest do
  # async: false — reads the shared :synthesis_metrics / :synthesis_runner_state tables.
  use ExUnit.Case, async: false

  alias LemonAutomation.Doctor.Checks.Synthesis
  alias LemonAutomation.SynthesisMetrics
  alias LemonAutomation.SynthesisRunner
  alias LemonCore.Config.Features
  alias LemonCore.Store

  @table :synthesis_metrics
  @hour_ms 3_600_000

  setup do
    SynthesisMetrics.clear()
    agent_id = "syndoc-agent-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      SynthesisMetrics.clear()
      SynthesisRunner.delete_state(agent_id)
    end)

    {:ok, agent_id: agent_id}
  end

  defp features(state), do: %Features{skill_synthesis_drafts: state}

  defp runner_config(agent_id, extra \\ []) do
    Keyword.merge([enabled: true, agent_id: agent_id, interval_hours: 6], extra)
  end

  defp seed_row(attrs) do
    ts_ms = Keyword.get(attrs, :ts_ms, LemonCore.Clock.now_ms())
    id = "synmet_#{ts_ms}_#{System.unique_integer([:positive])}"

    Store.put(@table, id, %{
      id: id,
      ts_ms: ts_ms,
      agent_id: Keyword.get(attrs, :agent_id, "seed"),
      total_candidates: Keyword.get(attrs, :total_candidates, 0),
      generated: Keyword.get(attrs, :generated, 0),
      blocked_by_audit: Keyword.get(attrs, :blocked_by_audit, 0),
      skipped_other: 0,
      latest_doc_ms: nil
    })
  end

  test "registered under :doctor_checks so the doctor picks it up" do
    assert Synthesis in Application.get_env(:lemon_core, :doctor_checks, [])
    assert Synthesis in LemonCore.Doctor.registered_checks()
  end

  test "an off feature flag reports the runner as inactive", %{agent_id: agent_id} do
    assert [check] =
             Synthesis.run(features: features(:off), runner_config: runner_config(agent_id))

    assert check.name == "automation.skill_synthesis"
    assert check.status == :pass
    assert check.message =~ "off"
  end

  test "a disabled runner config passes", %{agent_id: agent_id} do
    assert [check] =
             Synthesis.run(
               features: features(:"default-on"),
               runner_config: runner_config(agent_id, enabled: false)
             )

    assert check.status == :pass
    assert check.message =~ "disabled by config"
  end

  test "an enabled runner with no recorded passes passes", %{agent_id: agent_id} do
    assert [check] =
             Synthesis.run(
               features: features(:"default-on"),
               runner_config: runner_config(agent_id)
             )

    assert check.status == :pass
    assert check.message =~ "no synthesis passes recorded yet"
  end

  test "recorded passes surface aggregate counts", %{agent_id: agent_id} do
    seed_row(total_candidates: 5, generated: 1, blocked_by_audit: 0)

    assert [check] =
             Synthesis.run(
               features: features(:"default-on"),
               runner_config: runner_config(agent_id)
             )

    assert check.status == :pass
    assert check.message =~ "candidates=5"
    assert check.message =~ "generated=1"
  end

  test "counts include audit-blocked drafts in generated", %{agent_id: agent_id} do
    seed_row(total_candidates: 25, generated: 19, blocked_by_audit: 1)

    assert [check] =
             Synthesis.run(
               features: features(:"default-on"),
               runner_config: runner_config(agent_id)
             )

    assert check.status == :pass
    assert check.message =~ "candidates=25"
    assert check.message =~ "generated=20"
    assert check.message =~ "blocked=1"
  end

  test "a stalled runner warns with remediation", %{agent_id: agent_id} do
    seed_row(total_candidates: 5, generated: 1)

    now = 1_000 * @hour_ms
    SynthesisRunner.put_state(agent_id, %{watermark_ms: nil, last_run_at_ms: now - 40 * @hour_ms})

    assert [check] =
             Synthesis.run(
               features: features(:"default-on"),
               runner_config: runner_config(agent_id, interval_hours: 6),
               now_ms: now
             )

    assert check.status == :warn
    assert check.message =~ "last pass 40h ago"
    assert check.remediation =~ "SynthesisRunnerManager"
  end

  test "a fresh pass inside the stall window stays a pass", %{agent_id: agent_id} do
    seed_row(total_candidates: 5, generated: 1)

    now = 1_000 * @hour_ms
    SynthesisRunner.put_state(agent_id, %{watermark_ms: nil, last_run_at_ms: now - 2 * @hour_ms})

    assert [check] =
             Synthesis.run(
               features: features(:"default-on"),
               runner_config: runner_config(agent_id, interval_hours: 6),
               now_ms: now
             )

    assert check.status == :pass
  end

  test "an internal failure warns instead of raising" do
    assert [check] = Synthesis.run(features: :not_a_features_struct)

    assert check.status == :warn
    assert check.message =~ "diagnostics unavailable"
    assert is_binary(check.remediation)
  end

  test "run/1 with no opts does not raise" do
    assert [check] = Synthesis.run([])
    assert check.name == "automation.skill_synthesis"
    assert check.status in [:pass, :warn]
  end
end
