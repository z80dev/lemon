defmodule LemonAutomation.SkillCuratorTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.SkillCurator

  defmodule ReviewCurator do
    def should_run_now?(opts) do
      send(Process.get(:test_pid), {:should_run_now, opts})
      true
    end

    def run(opts) do
      send(Process.get(:test_pid), {:curator_run, opts})

      {:ok,
       %{
         started_at: "2026-05-06T00:00:00Z",
         summary: "checked=1 stale=0 archived=0 reactivated=0",
         candidates: [%{name: "demo"}],
         report_path: Process.get(:curator_report_path),
         review_required: true,
         review_prompt: "review demo"
       }}
    end
  end

  defmodule NoReviewCurator do
    def should_run_now?(_opts), do: true

    def run(_opts) do
      {:ok,
       %{
         started_at: "2026-05-06T00:00:00Z",
         summary: "checked=0 stale=0 archived=0 reactivated=0",
         candidates: [],
         review_required: false,
         review_prompt: "nothing"
       }}
    end
  end

  defmodule NotDueCurator do
    def should_run_now?(_opts), do: false
  end

  defmodule RouterStub do
    def submit(params) do
      send(Process.get(:test_pid), {:router_submit, params})
      {:ok, params.run_id}
    end
  end

  setup do
    Process.put(:test_pid, self())
    :ok
  end

  test "skips when disabled" do
    assert {:skip, :disabled} =
             SkillCurator.run_once(enabled: false, curator_mod: ReviewCurator)
  end

  test "skips when the idle gate has not elapsed" do
    assert {:skip, :not_idle} =
             SkillCurator.run_once(
               enabled: true,
               curator_mod: ReviewCurator,
               idle_for_seconds: 60,
               min_idle_hours: 2
             )
  end

  test "skips when curator interval gate says not due" do
    assert {:skip, :not_due} =
             SkillCurator.run_once(enabled: true, curator_mod: NotDueCurator)
  end

  test "submits the rendered curator prompt when review is required" do
    assert {:ok, result} =
             SkillCurator.run_once(
               enabled: true,
               curator_mod: ReviewCurator,
               router_mod: RouterStub,
               run_id: "run_curator_test",
               agent_id: "curator-agent",
               session_key: "agent:curator-agent:main",
               interval_hours: 24,
               stale_after_days: 10,
               archive_after_days: 20,
               now: ~U[2026-05-06 00:00:00Z]
             )

    assert result.submitted == true
    assert result.run_id == "run_curator_test"

    assert_receive {:should_run_now, opts}
    assert opts[:interval_hours] == 24
    assert opts[:stale_after_days] == 10
    assert opts[:archive_after_days] == 20

    assert_receive {:curator_run, opts}
    assert opts[:now] == ~U[2026-05-06 00:00:00Z]

    assert_receive {:router_submit, params}
    assert params.origin == :skill_curator
    assert params.agent_id == "curator-agent"
    assert params.session_key == "agent:curator-agent:main"
    assert params.prompt == "review demo"
    assert params.tool_policy == %{allow: ["read_skill", "skill_manage", "search_memory", "memory_topic"]}
    assert params.meta.skill_curator == true
    assert params.meta.skill_curator_candidate_count == 1
  end

  test "records submitted review run in curator report" do
    report_path = Path.join(System.tmp_dir!(), "lemon_curator_report_#{System.unique_integer([:positive])}.json")
    File.mkdir_p!(Path.dirname(report_path))
    File.write!(report_path, Jason.encode!(%{"started_at" => "2026-05-06T00:00:00Z"}))
    Process.put(:curator_report_path, report_path)

    on_exit(fn ->
      File.rm(report_path)
      File.rm(Path.join(Path.dirname(report_path), "REPORT.md"))
    end)

    assert {:ok, result} =
             SkillCurator.run_once(
               enabled: true,
               curator_mod: ReviewCurator,
               router_mod: RouterStub,
               run_id: "run_curator_report_link"
             )

    assert result.review_report_updated == true

    assert_receive {:should_run_now, _opts}
    assert_receive {:curator_run, _opts}
    assert_receive {:router_submit, params}
    assert params.meta.skill_curator_report_path == report_path

    assert {:ok, report} = report_path |> File.read!() |> Jason.decode()
    assert report["review_submission"]["run_id"] == "run_curator_report_link"
    assert report["review_submission"]["status"] == "submitted"
  end

  test "allows explicit curator tool policy override" do
    assert {:ok, result} =
             SkillCurator.run_once(
               enabled: true,
               curator_mod: ReviewCurator,
               router_mod: RouterStub,
               tool_policy: %{allow: ["read_skill"], blocked_tools: ["bash"]}
             )

    assert result.submitted == true

    assert_receive {:should_run_now, _opts}
    assert_receive {:curator_run, _opts}
    assert_receive {:router_submit, params}
    assert params.tool_policy == %{allow: ["read_skill"], blocked_tools: ["bash"]}
  end

  test "does not submit when only automatic transitions ran" do
    assert {:ok, result} =
             SkillCurator.run_once(
               enabled: true,
               curator_mod: NoReviewCurator,
               router_mod: RouterStub
             )

    assert result.submitted == false
    assert result.skip_reason == :no_review_required
    refute_receive {:router_submit, _}
  end

  test "reports active sessions through the configured checker" do
    assert SkillCurator.active_sessions?(active_sessions_fun: fn -> [%{session_key: "a"}] end)
    refute SkillCurator.active_sessions?(active_sessions_fun: fn -> [] end)
  end
end
