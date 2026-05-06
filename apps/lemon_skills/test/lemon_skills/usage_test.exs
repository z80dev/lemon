defmodule LemonSkills.UsageTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Usage

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

  test "records project skill loads in the project sidecar", %{tmp_dir: tmp_dir} do
    assert :ok =
             Usage.record_load(%{
               result: "ok",
               key: "project-skill",
               source: "project",
               cwd: tmp_dir,
               view: "summary",
               tool_call_id: "call-load",
               session_key: "session-1",
               run_id: "run-1",
               path: Path.join([tmp_dir, ".lemon", "skill", "project-skill"])
             })

    assert :ok =
             Usage.record_load(%{
               result: "ok",
               key: "project-skill",
               source: "project",
               cwd: tmp_dir,
               view: "full"
             })

    usage = Usage.get("project-skill", scope: :project, cwd: tmp_dir)

    assert usage["lifecycle_state"] == "active"
    assert usage["load_count"] == 2
    assert usage["last_view"] == "full"
    assert usage["last_run_id"] == "run-1"
    assert File.regular?(Path.join([tmp_dir, ".lemon", "skills.usage.json"]))
  end

  test "ignores missing skill loads and project updates without cwd", %{tmp_dir: tmp_dir} do
    assert :ok =
             Usage.record_load(%{
               result: "not_found",
               key: "missing-skill",
               source: "project",
               cwd: tmp_dir
             })

    assert Usage.get("missing-skill", scope: :project, cwd: tmp_dir)["load_count"] == nil

    assert :ok =
             Usage.record_load(%{
               result: "ok",
               key: "missing-cwd",
               source: "project"
             })

    assert Usage.get("missing-cwd", scope: :project)["load_count"] == nil
  end

  test "records agent-authored write provenance", %{tmp_dir: tmp_dir} do
    assert :ok =
             Usage.record_write(%{
               result: "ok",
               action: "create",
               name: "learned-skill",
               scope: "project",
               cwd: tmp_dir,
               agent_id: "agent-1",
               session_key: "session-1",
               tool_call_id: "call-write"
             })

    usage = Usage.get("learned-skill", scope: :project, cwd: tmp_dir)

    assert usage["write_count"] == 1
    assert usage["created_by"] == "agent"
    assert usage["created_by_agent_id"] == "agent-1"
    assert usage["last_writer_agent_id"] == "agent-1"
    assert usage["last_action"] == "create"
  end

  test "does not mark rejected creates as agent-authored skills", %{tmp_dir: tmp_dir} do
    assert :ok =
             Usage.record_write(%{
               result: "error",
               action: "create",
               name: "rejected-skill",
               scope: "project",
               cwd: tmp_dir,
               agent_id: "agent-1"
             })

    usage = Usage.get("rejected-skill", scope: :project, cwd: tmp_dir)

    assert usage["write_error_count"] == 1
    refute Map.has_key?(usage, "created_by")
    refute Map.has_key?(usage, "created_by_agent_id")
  end

  test "serializes concurrent usage updates", %{tmp_dir: tmp_dir} do
    tasks =
      for idx <- 1..20 do
        Task.async(fn ->
          Usage.record_load(%{
            result: "ok",
            key: "concurrent-skill",
            source: "project",
            cwd: tmp_dir,
            tool_call_id: "call-#{idx}"
          })
        end)
      end

    assert Enum.all?(tasks, &(Task.await(&1, 1_000) == :ok))

    usage = Usage.get("concurrent-skill", scope: :project, cwd: tmp_dir)

    assert usage["load_count"] == 20
  end

  test "sets and queries lifecycle states", %{tmp_dir: tmp_dir} do
    assert :ok = Usage.set_state("pin-me", :pinned, scope: :project, cwd: tmp_dir)
    assert Usage.pinned?("pin-me", scope: :project, cwd: tmp_dir)

    assert :ok = Usage.set_state("pin-me", :archived, scope: :project, cwd: tmp_dir)
    assert Usage.archived?("pin-me", scope: :project, cwd: tmp_dir)
    refute Usage.pinned?("pin-me", scope: :project, cwd: tmp_dir)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
