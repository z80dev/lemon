defmodule LemonSkills.Tools.SkillManageTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Introspection, Store}
  alias LemonSkills.Tools.SkillManage

  @moduletag :tmp_dir

  defp execute(tmp_dir, params) do
    tool = SkillManage.tool(cwd: tmp_dir)
    tool.execute.("call-1", params, nil, nil)
  end

  def handle_telemetry(event_name, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_handler(event_names) do
    handler_id = "skill-manage-telemetry-#{System.unique_integer([:positive, :monotonic])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        event_names,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp valid_skill(name \\ "Learned Workflow") do
    """
    ---
    name: #{name}
    description: Captures a learned workflow
    ---

    ## Usage

    Follow the proven workflow.
    """
  end

  describe "create" do
    test "emits skill write telemetry for successful writes", %{tmp_dir: tmp_dir} do
      enable_introspection()
      attach_handler([[:lemon_skills, :skill, :write]])
      run_id = "run_skill_write_#{System.unique_integer([:positive, :monotonic])}"

      tool =
        SkillManage.tool(
          cwd: tmp_dir,
          run_id: run_id,
          session_key: "session-write",
          session_id: "session-write",
          agent_id: "agent-write"
        )

      result =
        tool.execute.(
          "call-write-telemetry",
          %{
            "action" => "create",
            "name" => "telemetry-write",
            "content" => valid_skill("Telemetry Write")
          },
          nil,
          nil
        )

      assert result.details.action == "create"

      path = result.details.path

      assert_receive {:telemetry_event, [:lemon_skills, :skill, :write],
                      %{count: 1, system_time: system_time},
                      %{
                        result: "ok",
                        action: "create",
                        name: "telemetry-write",
                        scope: "project",
                        path: ^path,
                        audit_status: "pass",
                        tool_call_id: "call-write-telemetry",
                        run_id: ^run_id,
                        session_key: "session-write",
                        session_id: "session-write",
                        agent_id: "agent-write",
                        cwd: ^tmp_dir
                      }}

      assert is_integer(system_time)

      event =
        eventually(fn ->
          Introspection.list(run_id: run_id, event_type: :skill_write_observed, limit: 10)
          |> Enum.find(&(&1.payload[:name] == "telemetry-write"))
        end)

      assert event.session_key == "session-write"
      assert event.agent_id == "agent-write"
      assert event.payload.result == "ok"
      assert event.payload.action == "create"
      refute Map.has_key?(event.payload, :session_key)

      usage = LemonSkills.usage("telemetry-write", scope: :project, cwd: tmp_dir)
      assert usage["write_count"] == 1
      assert usage["created_by_agent_id"] == "agent-write"
    end

    test "emits skill write telemetry for direct tool calls", %{tmp_dir: tmp_dir} do
      attach_handler([[:lemon_skills, :skill, :write]])

      result =
        execute(tmp_dir, %{
          "action" => "create",
          "name" => "direct-telemetry-write",
          "content" => valid_skill("Direct Telemetry Write")
        })

      path = result.details.path

      assert_receive {:telemetry_event, [:lemon_skills, :skill, :write],
                      %{count: 1, system_time: system_time},
                      %{
                        result: "ok",
                        action: "create",
                        name: "direct-telemetry-write",
                        scope: "project",
                        path: ^path,
                        audit_status: "pass",
                        tool_call_id: "call-1",
                        cwd: ^tmp_dir
                      }}

      assert is_integer(system_time)
    end

    test "emits skill write telemetry for rejected writes", %{tmp_dir: tmp_dir} do
      attach_handler([[:lemon_skills, :skill, :write]])

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "create",
                 "name" => "bad-skill",
                 "content" => "# Missing frontmatter"
               })

      assert message =~ "frontmatter"

      assert_receive {:telemetry_event, [:lemon_skills, :skill, :write], %{count: 1},
                      %{
                        result: "error",
                        action: "create",
                        name: "bad-skill",
                        scope: "project",
                        reason: reason,
                        tool_call_id: "call-1",
                        cwd: ^tmp_dir
                      }}

      assert reason =~ "frontmatter"
    end

    test "creates a project skill and refreshes the registry", %{tmp_dir: tmp_dir} do
      result =
        execute(tmp_dir, %{
          "action" => "create",
          "name" => "learned-workflow",
          "content" => valid_skill()
        })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "learned-workflow"])

      assert result.details.action == "create"
      assert result.details.audit.status == "pass"
      assert File.regular?(Path.join(skill_dir, "SKILL.md"))
      assert {:ok, entry} = LemonSkills.Registry.get("learned-workflow", cwd: tmp_dir)
      assert entry.name == "Learned Workflow"
    end

    test "pins, protects, archives, and restores a skill", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "curated-skill",
        "content" => valid_skill("Curated Skill")
      })

      pin_result =
        execute(tmp_dir, %{
          "action" => "pin",
          "name" => "curated-skill"
        })

      assert pin_result.details.lifecycle_state == "pinned"
      assert LemonSkills.Usage.pinned?("curated-skill", scope: :project, cwd: tmp_dir)

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "archive",
                 "name" => "curated-skill"
               })

      assert message =~ "is pinned"

      execute(tmp_dir, %{
        "action" => "unpin",
        "name" => "curated-skill"
      })

      archive_result =
        execute(tmp_dir, %{
          "action" => "archive",
          "name" => "curated-skill"
        })

      assert archive_result.details.lifecycle_state == "archived"
      assert LemonSkills.Usage.archived?("curated-skill", scope: :project, cwd: tmp_dir)
      assert LemonSkills.Config.skill_disabled?("curated-skill", tmp_dir)

      restore_result =
        execute(tmp_dir, %{
          "action" => "restore",
          "name" => "curated-skill"
        })

      assert restore_result.details.lifecycle_state == "active"
      refute LemonSkills.Config.skill_disabled?("curated-skill", tmp_dir)
      assert {:ok, _entry} = LemonSkills.Registry.get("curated-skill", cwd: tmp_dir)
    end

    test "reports curation candidates without requiring a skill name", %{tmp_dir: tmp_dir} do
      attach_handler([[:lemon_skills, :skill, :write]])

      usage_path = Path.join([tmp_dir, ".lemon", "skills.usage.json"])
      File.mkdir_p!(Path.dirname(usage_path))

      File.write!(
        usage_path,
        Jason.encode!(%{
          "version" => 1,
          "skills" => %{
            "old-agent-skill" => %{
              "created_by" => "agent",
              "lifecycle_state" => "active",
              "load_count" => 2,
              "write_count" => 1,
              "last_loaded_at" => "2026-01-01T00:00:00Z"
            }
          }
        })
      )

      result =
        execute(tmp_dir, %{
          "action" => "report",
          "stale_after_days" => 1,
          "archive_after_days" => 1
        })

      assert result.details.action == "report"
      assert result.details.scope == "project"
      assert [row] = result.details.skills
      assert row.name == "old-agent-skill"
      assert row.archive_candidate

      [text] = result.content
      assert text.text =~ "old-agent-skill"
      assert text.text =~ "archive-candidate"
      refute_receive {:telemetry_event, [:lemon_skills, :skill, :write], _, _}, 100
    end

    test "rejects invalid frontmatter before writing", %{tmp_dir: tmp_dir} do
      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "create",
                 "name" => "bad-skill",
                 "content" => "# Missing frontmatter"
               })

      assert message =~ "frontmatter"
      refute File.exists?(Path.join([tmp_dir, ".lemon", "skill", "bad-skill"]))
    end
  end

  describe "patch" do
    test "patches SKILL.md and keeps manifest valid", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "patchable-skill",
        "content" => valid_skill("Patchable Skill")
      })

      result =
        execute(tmp_dir, %{
          "action" => "patch",
          "name" => "patchable-skill",
          "old_string" => "Follow the proven workflow.",
          "new_string" => "Follow the updated proven workflow."
        })

      skill_file = Path.join([tmp_dir, ".lemon", "skill", "patchable-skill", "SKILL.md"])

      assert result.details.action == "patch"
      assert File.read!(skill_file) =~ "updated proven workflow"
    end

    test "requires replace_all for repeated matches", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "repeat-skill",
        "content" => """
        ---
        name: Repeat Skill
        description: Has repeated content
        ---

        foo
        foo
        """
      })

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "patch",
                 "name" => "repeat-skill",
                 "old_string" => "foo",
                 "new_string" => "bar"
               })

      assert message =~ "replace_all=true"
    end

    test "enforces supporting file size limits when patching", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "large-patch-skill",
        "content" => valid_skill("Large Patch Skill")
      })

      execute(tmp_dir, %{
        "action" => "write_file",
        "name" => "large-patch-skill",
        "file_path" => "references/guide.md",
        "file_content" => "small"
      })

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "patch",
                 "name" => "large-patch-skill",
                 "file_path" => "references/guide.md",
                 "old_string" => "small",
                 "new_string" => String.duplicate("x", 100_001)
               })

      assert message =~ "supporting file exceeds"
    end
  end

  describe "supporting files" do
    test "writes and removes a supporting file under an allowed directory", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "support-skill",
        "content" => valid_skill("Support Skill")
      })

      write_result =
        execute(tmp_dir, %{
          "action" => "write_file",
          "name" => "support-skill",
          "file_path" => "references/guide.md",
          "file_content" => "# Guide\n"
        })

      target = Path.join([tmp_dir, ".lemon", "skill", "support-skill", "references", "guide.md"])

      assert write_result.details.action == "write_file"
      assert File.read!(target) == "# Guide\n"

      remove_result =
        execute(tmp_dir, %{
          "action" => "remove_file",
          "name" => "support-skill",
          "file_path" => "references/guide.md"
        })

      assert remove_result.details.action == "remove_file"
      refute File.exists?(target)
    end

    test "rejects path traversal for supporting files", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "traversal-skill",
        "content" => valid_skill("Traversal Skill")
      })

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "write_file",
                 "name" => "traversal-skill",
                 "file_path" => "references/../../escape.md",
                 "file_content" => "bad"
               })

      assert message =~ "may not contain '..'"
    end

    test "rejects writes through symlinked support directories", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "symlink-skill",
        "content" => valid_skill("Symlink Skill")
      })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "symlink-skill"])
      outside_dir = Path.join(tmp_dir, "outside")
      File.mkdir_p!(outside_dir)
      File.rm_rf!(Path.join(skill_dir, "references"))
      :ok = File.ln_s(outside_dir, Path.join(skill_dir, "references"))

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "write_file",
                 "name" => "symlink-skill",
                 "file_path" => "references/guide.md",
                 "file_content" => "bad"
               })

      assert message =~ "refusing to write through symlink"
      refute File.exists?(Path.join(outside_dir, "guide.md"))
    end

    test "rejects patches through symlinked support directories", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "symlink-patch-skill",
        "content" => valid_skill("Symlink Patch Skill")
      })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "symlink-patch-skill"])
      outside_dir = Path.join(tmp_dir, "outside-patch")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "guide.md"), "outside")
      File.rm_rf!(Path.join(skill_dir, "references"))
      :ok = File.ln_s(outside_dir, Path.join(skill_dir, "references"))

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "patch",
                 "name" => "symlink-patch-skill",
                 "file_path" => "references/guide.md",
                 "old_string" => "outside",
                 "new_string" => "changed"
               })

      assert message =~ "refusing to write through symlink"
      assert File.read!(Path.join(outside_dir, "guide.md")) == "outside"
    end

    test "rejects removals through symlinked support directories", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "symlink-remove-skill",
        "content" => valid_skill("Symlink Remove Skill")
      })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "symlink-remove-skill"])
      outside_dir = Path.join(tmp_dir, "outside-remove")
      outside_file = Path.join(outside_dir, "guide.md")
      File.mkdir_p!(outside_dir)
      File.write!(outside_file, "outside")
      File.rm_rf!(Path.join(skill_dir, "references"))
      :ok = File.ln_s(outside_dir, Path.join(skill_dir, "references"))

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "remove_file",
                 "name" => "symlink-remove-skill",
                 "file_path" => "references/guide.md"
               })

      assert message =~ "refusing to write through symlink"
      assert File.exists?(outside_file)
    end
  end

  defp enable_introspection do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    previous = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, previous) end)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually(fun, 0), do: flunk("expected condition to become true, got: #{inspect(fun.())}")
end
