defmodule LemonAutomation.Tools.KanbanTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAutomation.Tools.Kanban
  alias LemonAutomation.KanbanStore

  @session [agent_id: "agent_1", session_key: "agent:agent_1:main"]

  setup do
    cwd = Path.join(System.tmp_dir!(), "lemon-kanban-tool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    {real, 0} = System.cmd("pwd", ["-P"], cd: cwd)

    on_exit(fn ->
      KanbanStore.list_boards(limit: 1_000)
      |> Enum.each(fn board -> KanbanStore.clear_board(board.id) end)

      File.rm_rf!(cwd)
    end)

    %{cwd: cwd, real_cwd: String.trim(real)}
  end

  defp kanban(params, cwd, opts \\ @session),
    do: Kanban.execute("call", params, nil, nil, cwd, opts)

  test "returns the kanban tool definition", %{cwd: cwd} do
    tool = Kanban.tool(cwd)

    assert tool.name == "kanban"
    assert "board_create" in tool.parameters["properties"]["action"]["enum"]
    assert "task_comment" in tool.parameters["properties"]["action"]["enum"]
    refute Map.has_key?(tool.parameters["properties"], "meta")

    for key <- ~w(session_key run_id owner worker_profile),
        do: refute(Map.has_key?(tool.parameters["properties"], key))

    workflow = tool.parameters["properties"]["coding_workflow"]
    assert [disabled, settings] = workflow["anyOf"]
    assert disabled == %{"type" => "boolean", "enum" => [false]}
    assert settings["type"] == "object"
    assert settings["additionalProperties"] == false
    assert settings["properties"]["reviewModel"]["type"] == "string"

    assert [_, publish] = settings["properties"]["publish"]["anyOf"]
    assert publish["type"] == "object"
    assert publish["additionalProperties"] == false
    assert publish["properties"]["mode"]["enum"] == ["branch", "pull_request"]
    assert publish["properties"]["draft"]["default"] == true
  end

  test "creates and lists boards with the canonical session cwd as workspace", %{
    cwd: cwd,
    real_cwd: real_cwd
  } do
    assert %AgentToolResult{details: %{board: board}} =
             kanban(%{"action" => "board_create", "name" => "Launch board"}, cwd)

    assert board.name == "Launch board"
    assert board.workspace == real_cwd
    assert board.owner == "agent_1"
    refute Map.has_key?(board.meta, "codingWorkflow")
    authority = board.meta["kanbanAuthority"]

    assert authority["principal"] == %{
             "agentId" => "agent_1",
             "sessionKey" => "agent:agent_1:main"
           }

    assert authority["root"] == real_cwd
    assert authority["unrestricted"] == true

    assert %AgentToolResult{details: %{boards: boards}} =
             kanban(%{"action" => "board_list"}, "/tmp")

    assert Enum.any?(boards, &(&1.id == board.id))
  end

  test "every action needs a trusted session identity", %{cwd: cwd} do
    for params <- [
          %{"action" => "board_list"},
          %{"action" => "board_create", "name" => "Anonymous"}
        ] do
      assert {:error, message} = kanban(params, cwd, agent_id: "agent_1")
      assert message =~ "session identity"
    end
  end

  test "board supervision preserves origin and validates explicit destination before mutation",
       %{cwd: cwd} do
    tool = Kanban.tool(cwd, session_key: "agent:operator:telegram:work:group:-100:thread:77")

    assert %AgentToolResult{details: %{board: board}} =
             tool.execute.(
               "call",
               %{"action" => "board_create", "name" => "Remote", "deliver_to" => " NONE "},
               nil,
               nil
             )

    assert board.meta["deliverTo"] == "none"

    assert board.meta["notificationSessionKey"] ==
             "agent:operator:telegram:work:group:-100:thread:77"

    assert {:error, _} =
             tool.execute.(
               "call",
               %{"action" => "board_create", "name" => "Rejected", "deliver_to" => "wrong"},
               nil,
               nil
             )

    refute Enum.any?(KanbanStore.list_boards(), &(&1.name == "Rejected"))
  end

  test "creates reviewed local boards without inventing publishing settings", %{cwd: cwd} do
    for settings <- [%{}, %{"reviewModel" => "test:reviewer", "publish" => false}] do
      assert %AgentToolResult{details: %{board: board}} =
               kanban(
                 %{
                   "action" => "board_create",
                   "name" => "Reviewed local board",
                   "coding_workflow" => settings
                 },
                 cwd
               )

      assert board.meta["codingWorkflow"] == settings
      assert board.meta["kanbanAuthority"]["publish"] == nil
      assert KanbanStore.get_board(board.id).meta == board.meta
      assert Jason.decode!(Jason.encode!(board.meta)) == board.meta
    end
  end

  test "preserves explicit coding-only workflow opt-out", %{cwd: cwd} do
    assert %AgentToolResult{details: %{board: board}} =
             kanban(
               %{
                 "action" => "board_create",
                 "name" => "Coding-only board",
                 "coding_workflow" => false
               },
               cwd
             )

    assert board.meta["codingWorkflow"] == false
  end

  test "accepts explicit branch and pull request publishing settings unchanged", %{cwd: cwd} do
    for publish <- [
          %{"mode" => "branch", "remote" => "origin"},
          %{
            "mode" => "pull_request",
            "remote" => "origin",
            "repository" => "owner/repo",
            "base" => "main"
          },
          %{
            "mode" => "pull_request",
            "remote" => "origin",
            "repository" => "owner/repo",
            "base" => "main",
            "draft" => false
          }
        ] do
      settings = %{"reviewModel" => "test:reviewer", "publish" => publish}

      assert %AgentToolResult{details: %{board: board}} =
               kanban(
                 %{
                   "action" => "board_create",
                   "name" => "Explicit publish board",
                   "coding_workflow" => settings
                 },
                 cwd
               )

      assert board.meta["codingWorkflow"] == settings
      # Recorded as requested only: publishing needs a separate operator grant.
      assert board.meta["kanbanAuthority"]["publish"] == nil
      assert KanbanStore.get_board(board.id).meta == board.meta
      assert Jason.decode!(Jason.encode!(board.meta)) == board.meta
    end
  end

  test "rejects malformed workflow settings before creating a board", %{
    cwd: cwd,
    real_cwd: real_cwd
  } do
    invalid_settings = [
      nil,
      true,
      [],
      "enabled",
      %{"unknown" => true},
      %{reviewModel: "test:reviewer"},
      %{"reviewModel" => ""},
      %{"reviewModel" => "   "},
      %{"reviewModel" => 1},
      %{"publish" => true},
      %{"publish" => %{}},
      %{"publish" => %{"mode" => "unknown", "remote" => "origin"}},
      %{"publish" => %{"mode" => "branch", "remote" => "origin", "force" => true}},
      %{"publish" => %{"mode" => "branch", "remote" => "origin", "command" => "git push"}},
      %{"publish" => %{mode: "branch", remote: "origin"}},
      %{"publish" => %{"mode" => "pull_request", "remote" => "origin"}},
      %{
        "publish" => %{
          "mode" => "pull_request",
          "remote" => "origin",
          "repository" => "owner/repo"
        }
      },
      %{
        "publish" => %{
          "mode" => "pull_request",
          "remote" => "origin",
          "base" => "main"
        }
      },
      %{
        "publish" => %{
          "mode" => "pull_request",
          "remote" => "origin",
          "repository" => "owner/repo",
          "base" => "main",
          "draft" => "true"
        }
      }
    ]

    for settings <- invalid_settings do
      assert {:error, reason} =
               kanban(
                 %{
                   "action" => "board_create",
                   "name" => "Invalid workflow board",
                   "coding_workflow" => settings
                 },
                 cwd
               )

      assert is_binary(reason)
      refute reason =~ "session identity"
      assert KanbanStore.list_boards(workspace: real_cwd) == []
    end
  end

  test "creates, updates, gets, and comments on tasks", %{cwd: cwd} do
    assert %AgentToolResult{details: %{board: board}} =
             kanban(
               %{
                 "action" => "board_create",
                 "name" => "Task board",
                 "columns" => ["todo", "done"]
               },
               cwd
             )

    assert %AgentToolResult{details: %{task: task}} =
             kanban(
               %{
                 "action" => "task_create",
                 "board_id" => board.id,
                 "title" => "Implement tool",
                 "description" => "Expose kanban to agents",
                 "assignee" => "agent_1"
               },
               cwd
             )

    assert task.status == "todo"
    assert task.assignee == "agent_1"
    assert is_map(task.meta["dispatchPolicy"]) == false

    assert %AgentToolResult{details: %{task: updated}} =
             kanban(%{"action" => "task_update", "task_id" => task.id, "status" => "done"}, cwd)

    assert updated.status == "done"

    assert %AgentToolResult{details: %{task: commented}} =
             kanban(
               %{
                 "action" => "task_comment",
                 "task_id" => task.id,
                 "body" => "Ready",
                 "author" => "me"
               },
               cwd
             )

    assert [%{"body" => "Ready", "author" => "me"}] = commented.comments

    assert %AgentToolResult{details: %{task: fetched}} =
             kanban(%{"action" => "task_get", "task_id" => task.id}, cwd)

    assert fetched.id == task.id
  end

  test "returns clear errors for missing identifiers", %{cwd: cwd} do
    assert {:error, "board_id is required"} = kanban(%{"action" => "task_list"}, cwd)

    assert {:error, "unsupported kanban action: \"wat\""} = kanban(%{"action" => "wat"}, cwd)
  end
end
