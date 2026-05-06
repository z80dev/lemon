defmodule LemonSkills.CuratorTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Config, Curator, Usage}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
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
    assert result.report_path == Path.join([tmp_dir, ".lemon", "logs", "curator", "20260506T000000", "run.json"])

    assert {:ok, report} = result.report_path |> File.read!() |> Jason.decode()
    assert report["started_at"] == "2026-05-06T00:00:00Z"
    assert report["scope"] == "project"
    assert report["counts"]["checked"] == 1
    assert report["counts"]["marked_stale"] == 1
    assert report["candidate_count"] == 1
    assert [%{"name" => "deploy-helper"}] = report["candidates"]
    assert [%{"name" => "deploy-helper", "from" => "active", "to" => "stale"}] = report["state_transitions"]

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
