defmodule LemonSkills.CuratorTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Config, Curator, Usage}

  @moduletag :tmp_dir
  defmodule References do
    def referenced_skills(_names), do: {:ok, Process.get(:cron_skills, [])}
  end

  setup %{tmp_dir: tmp_dir} do
    key = {LemonSkills.CuratorReferences, :provider}
    previous_provider = :persistent_term.get(key, nil)
    LemonSkills.CuratorReferences.register(References, self())

    on_exit(fn ->
      if previous_provider,
        do: :persistent_term.put(key, previous_provider),
        else: LemonSkills.CuratorReferences.unregister()
    end)

    previous_home = System.get_env("HOME")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")

    home = Path.join(tmp_dir, "home")
    agent_dir = Path.join(tmp_dir, "agent")
    File.mkdir_p!(home)
    File.mkdir_p!(agent_dir)

    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("LEMON_AGENT_DIR", previous_agent_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "cron exemptions prevent stale and archive transitions", %{tmp_dir: cwd} do
    write_usage!(
      cwd,
      Map.new(["old", "stale"], fn name ->
        {name, %{"created_by" => "agent", "created_at" => "2026-01-01T00:00:00Z"}}
      end)
    )

    counts =
      Curator.apply_automatic_transitions(
        scope: :project,
        cwd: cwd,
        now: ~U[2026-05-06 00:00:00Z],
        exempt_skills: ["old", "stale"]
      )

    assert counts.checked == 0
    assert counts.archived == 0
    assert counts.marked_stale == 0
    refute Config.skill_disabled?("old", cwd)
    assert Usage.get("stale", scope: :project, cwd: cwd)["lifecycle_state"] == "active"
  end

  test "API curator unions provider references with explicit exemptions", %{tmp_dir: cwd} do
    write_usage!(
      cwd,
      Map.new(["cron", "explicit", "unused"], fn name ->
        {name, %{"created_by" => "agent", "created_at" => "2026-01-01T00:00:00Z"}}
      end)
    )

    Process.put(:cron_skills, ["cron"])

    assert {:ok, result} =
             LemonSkills.curate_skills(
               scope: :project,
               cwd: cwd,
               now: ~U[2026-05-06 00:00:00Z],
               exempt_skills: ["explicit"]
             )

    assert result.auto_transitions.archived == 1
    refute Config.skill_disabled?("cron", cwd)
    refute Config.skill_disabled?("explicit", cwd)
    assert Config.skill_disabled?("unused", cwd)
  end

  test "missing and stopped providers fail closed and report why", %{tmp_dir: cwd} do
    write_usage!(cwd, %{
      "old" => %{"created_by" => "agent", "created_at" => "2026-01-01T00:00:00Z"}
    })

    LemonSkills.CuratorReferences.unregister()
    opts = [scope: :project, cwd: cwd, now: ~U[2026-05-06 00:00:00Z]]
    assert {:ok, result} = Curator.run(opts)
    assert result.auto_transitions.archived == 0
    assert result.summary =~ "archive_skipped=cron_references_unavailable"
    refute Config.skill_disabled?("old", cwd)
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    LemonSkills.CuratorReferences.register(References, pid)
    assert Curator.apply_automatic_transitions(opts).archived == 0
  end

  test "never loaded skills receive the stale age floor before archive", %{tmp_dir: cwd} do
    write_usage!(cwd, %{
      "new" => %{"created_by" => "agent", "created_at" => "2026-05-01T00:00:00Z"}
    })

    opts = [scope: :project, cwd: cwd, stale_after_days: 30, archive_after_days: 1]
    counts = Curator.apply_automatic_transitions(opts ++ [now: ~U[2026-05-06 00:00:00Z]])
    assert counts.archived == 0
    counts = Curator.apply_automatic_transitions(opts ++ [now: ~U[2026-05-31 00:00:00Z]])
    assert counts.archived == 1
  end

  test "automatic transitions archive stale agent-authored skills and disable them", %{
    tmp_dir: tmp_dir
  } do
    write_usage!(tmp_dir, %{
      "archive-me" => %{
        "created_by" => "agent",
        "lifecycle_state" => "active",
        "last_loaded_at" => "2026-01-01T00:00:00Z"
      },
      "mark-stale" => %{
        "created_by" => "agent",
        "lifecycle_state" => "active",
        "last_loaded_at" => "2026-04-01T00:00:00Z"
      },
      "pinned" => %{
        "created_by" => "agent",
        "lifecycle_state" => "pinned",
        "last_loaded_at" => "2026-01-01T00:00:00Z"
      },
      "upstream" => %{
        "lifecycle_state" => "active",
        "last_loaded_at" => "2026-01-01T00:00:00Z"
      }
    })

    counts =
      Curator.apply_automatic_transitions(
        scope: :project,
        cwd: tmp_dir,
        now: ~U[2026-05-06 00:00:00Z],
        stale_after_days: 30,
        archive_after_days: 90
      )

    assert counts == %{checked: 3, marked_stale: 1, archived: 1, reactivated: 0}

    assert Usage.archived?("archive-me", scope: :project, cwd: tmp_dir)
    assert Usage.get("mark-stale", scope: :project, cwd: tmp_dir)["lifecycle_state"] == "stale"
    assert Usage.pinned?("pinned", scope: :project, cwd: tmp_dir)
    assert Config.skill_disabled?("archive-me", tmp_dir)
    refute Config.skill_disabled?("mark-stale", tmp_dir)
  end

  test "automatic transitions reactivate stale skills after recent use", %{tmp_dir: tmp_dir} do
    write_usage!(tmp_dir, %{
      "recent-again" => %{
        "created_by" => "agent",
        "lifecycle_state" => "stale",
        "last_loaded_at" => "2026-05-05T00:00:00Z"
      }
    })

    counts =
      Curator.apply_automatic_transitions(
        scope: :project,
        cwd: tmp_dir,
        now: ~U[2026-05-06 00:00:00Z],
        stale_after_days: 30,
        archive_after_days: 90
      )

    assert counts == %{checked: 1, marked_stale: 0, archived: 0, reactivated: 1}
    assert Usage.get("recent-again", scope: :project, cwd: tmp_dir)["lifecycle_state"] == "active"
  end

  test "run persists state and returns a review prompt for agent-authored candidates", %{
    tmp_dir: tmp_dir
  } do
    write_usage!(tmp_dir, %{
      "deploy-helper" => %{
        "created_by" => "agent",
        "lifecycle_state" => "active",
        "write_count" => 1,
        "last_write_at" => "2026-04-01T00:00:00Z"
      }
    })

    assert {:ok, result} =
             Curator.run(scope: :project, cwd: tmp_dir, now: ~U[2026-05-06 00:00:00Z])

    assert result.review_required
    assert result.review_prompt =~ "Lemon's background skill curator"
    assert result.review_prompt =~ "deploy-helper"
    assert result.auto_transitions.checked == 1
    assert result.auto_transitions.marked_stale == 1

    assert result.report_path ==
             Path.join([tmp_dir, ".lemon", "logs", "curator", "20260506T000000", "run.json"])

    assert {:ok, report} = result.report_path |> File.read!() |> Jason.decode()
    assert report["started_at"] == "2026-05-06T00:00:00Z"
    assert report["scope"] == "project"
    assert report["counts"]["checked"] == 1
    assert report["counts"]["marked_stale"] == 1
    assert report["candidate_count"] == 1
    assert [%{"name" => "deploy-helper"}] = report["candidates"]

    assert [%{"name" => "deploy-helper", "from" => "active", "to" => "stale"}] =
             report["state_transitions"]

    human_report = result.report_path |> Path.dirname() |> Path.join("REPORT.md") |> File.read!()
    assert human_report =~ "# Curator run"
    assert human_report =~ "deploy-helper"
    assert human_report =~ "deploy-helper: active -> stale"

    state = Curator.load_state(scope: :project, cwd: tmp_dir)
    assert state["last_run_at"] == "2026-05-06T00:00:00Z"
    assert state["last_report_path"] == result.report_path
    assert state["last_candidate_count"] == 1
    assert state["run_count"] == 1
  end

  test "record_review_submission links report artifacts to submitted review run", %{
    tmp_dir: tmp_dir
  } do
    write_usage!(tmp_dir, %{
      "deploy-helper" => %{
        "created_by" => "agent",
        "lifecycle_state" => "active",
        "last_write_at" => "2026-05-05T00:00:00Z"
      }
    })

    assert {:ok, result} =
             Curator.run(scope: :project, cwd: tmp_dir, now: ~U[2026-05-06 00:00:00Z])

    assert :ok =
             Curator.record_review_submission(result.report_path, %{
               run_id: "run_review_123",
               submitted_at: "2026-05-06T00:00:05Z",
               status: :submitted
             })

    assert {:ok, report} = result.report_path |> File.read!() |> Jason.decode()

    assert report["review_submission"] == %{
             "run_id" => "run_review_123",
             "submitted_at" => "2026-05-06T00:00:05Z",
             "status" => "submitted"
           }

    human_report = result.report_path |> Path.dirname() |> Path.join("REPORT.md") |> File.read!()
    assert human_report =~ "## Review submission"
    assert human_report =~ "Run id: run_review_123"
  end

  test "record_review_submission reports invalid paths" do
    assert {:error, :enoent} =
             Curator.record_review_submission("/tmp/missing-curator-report.json", %{
               run_id: "run_missing"
             })
  end

  test "should_run_now honors pause and interval state", %{tmp_dir: tmp_dir} do
    opts = [scope: :project, cwd: tmp_dir, now: ~U[2026-05-06 00:00:00Z], interval_hours: 24]

    assert Curator.should_run_now?(opts)

    assert :ok =
             Curator.save_state(
               %{"last_run_at" => "2026-05-05T12:00:00Z", "paused" => false},
               scope: :project,
               cwd: tmp_dir
             )

    refute Curator.should_run_now?(opts)

    assert :ok = Curator.set_paused(true, scope: :project, cwd: tmp_dir)
    refute Curator.should_run_now?(Keyword.put(opts, :now, ~U[2026-05-08 00:00:00Z]))
  end

  test "review prompt prefers active updates before new narrow skills" do
    prompt = Curator.review_prompt([])

    assert prompt =~ "Treat user corrections"
    assert prompt =~ "Patch an existing class-level skill"
    assert prompt =~ "references/, templates/, or scripts/"
    assert prompt =~ "Avoid creating a new narrow skill"
  end

  defp write_usage!(tmp_dir, skills) do
    usage_path = Path.join([tmp_dir, ".lemon", "skills.usage.json"])
    File.mkdir_p!(Path.dirname(usage_path))
    File.write!(usage_path, Jason.encode!(%{"version" => 1, "skills" => skills}, pretty: true))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
