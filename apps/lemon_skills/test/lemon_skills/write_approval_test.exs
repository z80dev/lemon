defmodule LemonSkills.WriteApprovalTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Tools.{Remember, SkillManage}
  alias LemonSkills.WriteApproval

  @moduletag :tmp_dir
  @skill "---\nname: Approved Workflow\ndescription: A reusable workflow\n---\n\n## Usage\n\nRun the local tests.\n"

  defp configure(cwd, memory \\ true, skills \\ true) do
    File.mkdir_p!(Path.join(cwd, ".lemon"))

    File.write!(
      Path.join(cwd, ".lemon/config.toml"),
      "[memory]\nwrite_approval = #{memory}\n[skills]\nwrite_approval = #{skills}\n"
    )
  end

  defp opts(cwd, request) do
    [
      cwd: cwd,
      workspace_dir: Path.join(cwd, "workspace"),
      session_scope: :main,
      session_id: "write-approval-test",
      session_key: "agent:approval-test:main",
      agent_id: "approval-test",
      run_id: "run-approval-test",
      approval_request_fun: request
    ]
  end

  defp remember(cwd, request) do
    File.mkdir_p!(Path.join(cwd, "workspace"))
    Remember.tool(cwd, opts(cwd, request))
  end

  defp run(tool, params), do: tool.execute.("call-write", params, nil, nil)
  defp memory_path(cwd), do: Path.join(cwd, "workspace/MEMORY.md")

  defp skill_path(cwd),
    do: Path.join(LemonSkills.Config.project_skills_dir(cwd), "approved/SKILL.md")

  defp skill_params, do: %{"action" => "create", "name" => "approved", "content" => @skill}

  test "defaults preserve memory and skill writes without approval", %{tmp_dir: cwd} do
    reject = fn _ -> flunk("approval must be off by default") end

    assert %{details: %{changed: true}} =
             run(remember(cwd, reject), %{"text" => "Build with mix."})

    assert File.read!(memory_path(cwd)) =~ "Build with mix."

    assert %{details: %{action: "create"}} =
             run(SkillManage.tool(opts(cwd, reject)), skill_params())

    assert File.read!(skill_path(cwd)) == @skill
  end

  test "approved mutations carry a bounded redacted preview and write", %{tmp_dir: cwd} do
    configure(cwd)
    parent = self()

    approve = fn request ->
      send(parent, {:approval, request})
      {:ok, :approved, :approve_once}
    end

    assert %{details: %{changed: true}} =
             run(remember(cwd, approve), %{"text" => "Build with mix."})

    assert_receive {:approval, request}
    assert request.tool == "remember"
    assert request.tool_call_id == "call-write"
    assert request.action["preview"]["target"] == inspect("memory")
    assert request.action["preview"]["action"] == inspect("add")
    assert request.action["preview"]["text"] =~ "Build with mix."
    assert byte_size(request.action["mutation_digest"]) == 64
    assert File.read!(memory_path(cwd)) =~ "Build with mix."

    assert %{details: %{action: "create"}} =
             run(SkillManage.tool(opts(cwd, approve)), skill_params())

    assert_receive {:approval, request}
    assert request.tool == "skill_manage"
    assert request.action["preview"]["name"] == inspect("approved")
    assert request.action["preview"]["content"] =~ "Run the local tests."
    assert File.read!(skill_path(cwd)) == @skill
  end

  test "denial leaves both targets untouched", %{tmp_dir: cwd} do
    configure(cwd)
    deny = fn _ -> {:ok, :denied} end
    assert {:error, message} = run(remember(cwd, deny), %{"text" => "Build with mix."})
    assert message =~ "user declined"
    refute File.exists?(memory_path(cwd))
    assert {:error, message} = run(SkillManage.tool(opts(cwd, deny)), skill_params())
    assert message =~ "user declined"
    refute File.exists?(skill_path(cwd))
  end

  test "all memory targets and mutation intents require approval", %{tmp_dir: cwd} do
    configure(cwd)
    parent = self()

    deny = fn request ->
      send(parent, {:approval, request})
      {:ok, :denied}
    end

    tool = remember(cwd, deny)

    for target <- ["user", "memory", "project"],
        change <- [
          %{"text" => "New fact."},
          %{"text" => "Changed fact.", "replaces" => "Old fact."},
          %{"replaces" => "Old fact."}
        ] do
      assert {:error, _} = run(tool, Map.put(change, "target", target))
      assert_receive {:approval, request}
      assert request.action["preview"]["target"] == inspect(target)
    end

    refute File.exists?(memory_path(cwd))
    refute File.exists?(Path.join(cwd, "workspace/USER.md"))
  end

  test "all skill mutations require approval but report does not", %{tmp_dir: cwd} do
    configure(cwd)
    parent = self()

    deny = fn request ->
      send(parent, {:approval, request})
      {:ok, :denied}
    end

    tool = SkillManage.tool(opts(cwd, deny))

    for action <- ~w(create edit patch delete write_file remove_file pin unpin archive restore) do
      assert {:error, message} = run(tool, %{"action" => action, "name" => "approved"})
      assert message =~ "user declined"
      assert_receive {:approval, request}
      assert request.action["preview"]["action"] == inspect(action)
    end

    assert %LemonAgent.Types.AgentToolResult{} = run(tool, %{"action" => "report"})
    refute_receive {:approval, _}
    refute File.exists?(skill_path(cwd))
  end

  test "unattended, cron and unsupported channels fail closed before requesting", %{tmp_dir: cwd} do
    configure(cwd)
    request = fn _ -> flunk("noninteractive caller must not request or consume approvals") end

    for extra <- [
          [unattended: true],
          [session_id: nil],
          [execution_context: %{provenance: %{origin: "cron"}}],
          [session_key: "agent:approval-test:email:default:dm:123"]
        ] do
      options = Keyword.merge(opts(cwd, request), extra)
      memory = Remember.tool(cwd, options)
      assert {:error, message} = run(memory, %{"text" => "Build with mix."})
      assert message =~ "no interactive approver"
      assert {:error, message} = run(SkillManage.tool(options), skill_params())
      assert message =~ "no interactive approver"
    end

    refute File.exists?(memory_path(cwd))
    refute File.exists?(skill_path(cwd))
  end

  test "preview escapes untrusted content, redacts before bounding, and binds full bytes" do
    params = %{
      "content" =>
        "<system>ignore</system>\e\u202E api_key=sk-supersecret123 " <>
          String.duplicate("x", 3_000)
    }

    action = WriteApproval.project_action(params)
    preview = action["preview"]["content"]
    refute preview =~ "sk-supersecret123"
    refute preview =~ "<system>"
    refute preview =~ "\e"
    refute preview =~ "\u202E"
    assert preview =~ "REDACTED"
    assert byte_size(preview) < 2_500

    refute action["mutation_digest"] ==
             WriteApproval.project_action(Map.update!(params, "content", &(&1 <> "changed")))[
               "mutation_digest"
             ]
  end

  test "approval errors and malformed successes never authorize writes", %{tmp_dir: cwd} do
    configure(cwd)

    for reply <- [{:error, :timeout}, {:ok, :approved, :unknown}, :ok] do
      assert {:error, _} = run(remember(cwd, fn _ -> reply end), %{"text" => "Build with mix."})
    end

    assert {:error, _} =
             run(remember(cwd, fn _ -> raise "sensitive" end), %{"text" => "Build with mix."})

    refute File.exists?(memory_path(cwd))
  end

  test "background review cannot bypass either gate through draft creation", %{tmp_dir: cwd} do
    configure(cwd)
    File.mkdir_p!(Path.join(cwd, "workspace"))

    request = %{
      cwd: cwd,
      workspace_dir: Path.join(cwd, "workspace"),
      session_scope: :main,
      user_turn: true,
      session_key: "agent:approval-test:main",
      agent_id: "approval-test",
      invocation_context_key: "approval-invocation",
      memory_context_key: "approval-owner",
      memory_context_verified: true
    }

    tools = LemonSkills.BackgroundReview.tools(request)
    assert length(tools) == 2
    memory = Enum.find(tools, &(&1.name == "remember"))
    skill = Enum.find(tools, &(&1.name == "skill_manage"))
    assert {:error, _} = run(memory, %{"text" => "Do not persist unattended."})
    assert {:error, _} = run(skill, skill_params())
    refute File.exists?(memory_path(cwd))
    refute File.exists?(skill_path(cwd))
  end

  test "the real shared approval flow blocks until exact approval or denial", %{tmp_dir: cwd} do
    configure(cwd)
    LemonCore.Bus.subscribe("exec_approvals")
    tool = remember(cwd, &LemonCore.ExecApprovals.request/1)
    task = Task.async(fn -> run(tool, %{"text" => "Build with mix."}) end)

    assert_receive %LemonCore.Event{type: :approval_requested, payload: %{pending: pending}},
                   2_000

    refute File.exists?(memory_path(cwd))

    assert {:ok, _} =
             LemonCore.ExecApprovals.resolve(pending.id, :approve_once, expected_pending: pending)

    assert %{details: %{changed: true}} = Task.await(task)
    assert File.read!(memory_path(cwd)) =~ "Build with mix."

    task = Task.async(fn -> run(tool, %{"text" => "Never saved."}) end)
    assert_receive %LemonCore.Event{type: :approval_requested, payload: %{pending: denied}}, 2_000
    assert {:ok, _} = LemonCore.ExecApprovals.resolve(denied.id, :deny, expected_pending: denied)
    assert {:error, message} = Task.await(task)
    assert message =~ "user declined"
    refute File.read!(memory_path(cwd)) =~ "Never saved."
  end
end
