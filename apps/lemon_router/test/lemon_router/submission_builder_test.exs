defmodule LemonRouter.SubmissionBuilderTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ExecutionCommand, ResumeToken}
  alias LemonRouter.{Submission, SubmissionBuilder}

  setup do
    original_profiles_state = :sys.get_state(LemonRouter.AgentProfiles)

    :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
      %{state | profiles: profile_map()}
    end)

    on_exit(fn ->
      :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_profiles_state end)
    end)

    :ok
  end

  test "build/2 creates an execution request while preserving queue and metadata" do
    session_key = unique_session_key("build")

    assert {:ok, %Submission{} = submission} =
             SubmissionBuilder.build(
               request(session_key, %{
                 agent_id: "test",
                 queue_mode: :collect
               }),
               orchestrator_state()
             )

    assert %ExecutionCommand{} = submission.execution_request
    assert submission.run_id == submission.execution_request.run_id
    assert submission.session_key == session_key
    assert submission.queue_mode == :collect
    assert submission.meta[:origin] == :control_plane
    assert submission.execution_request.meta[:origin] == :control_plane
  end

  test "conversation_key is present on submission and execution_request" do
    session_key = unique_session_key("conversation")

    assert {:ok, %Submission{} = submission} =
             SubmissionBuilder.build(
               request(session_key, %{agent_id: "test"}),
               orchestrator_state()
             )

    assert submission.conversation_key == {:session, session_key}
    assert submission.execution_request.conversation_key == {:session, session_key}
  end

  test "meta thinking_level overrides session config thinking_level" do
    session_key = unique_session_key("thinking")
    LemonCore.PolicyStore.put_session(session_key, %{thinking_level: "low"})

    on_exit(fn -> LemonCore.PolicyStore.delete_session(session_key) end)

    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(session_key, %{agent_id: "test", meta: %{thinking_level: "high"}}),
               orchestrator_state()
             )

    assert submission.meta[:thinking_level] == :high
    assert submission.execution_request.meta[:thinking_level] == :high
  end

  test "top-level request model overrides profile model" do
    session_key = unique_session_key("model")

    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(session_key, %{agent_id: "oracle", model: "request-model"}),
               orchestrator_state()
             )

    assert submission.meta[:model] == "request-model"
  end

  test "records explicit native resume provenance in submission metadata" do
    session_key = unique_session_key("explicit-resume")
    resume = %ResumeToken{engine: "lemon", value: "thread_123"}

    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(session_key, %{agent_id: "test", resume: resume}),
               orchestrator_state()
             )

    assert submission.execution_request.resume == resume
    assert submission.meta[:resume_source] == :explicit
    assert submission.execution_request.meta[:resume_source] == :explicit
  end

  test "profile tool_policy is merged before operator override" do
    session_key = unique_session_key("tool-policy")

    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(session_key, %{
                 agent_id: "oracle",
                 tool_policy: %{
                   approvals: %{"bash" => :never},
                   blocked_tools: ["rm"]
                 }
               }),
               orchestrator_state()
             )

    tool_policy = submission.execution_request.tool_policy

    assert get_in(tool_policy, [:approvals, "bash"]) == :never
    assert "bash" in (tool_policy[:blocked_tools] || [])
    assert "rm" in (tool_policy[:blocked_tools] || [])
  end

  test "unknown agent returns {:error, {:unknown_agent_id, ...}}" do
    session_key = unique_session_key("unknown")

    assert {:error, {:unknown_agent_id, "missing-agent"}} =
             SubmissionBuilder.build(
               request(session_key, %{agent_id: "missing-agent"}),
               orchestrator_state()
             )
  end

  test "named profile placement with no explicit cwd never uses controller cwd" do
    meta = %{
      node: "worker-one",
      profile_id: "test",
      remote_cwd_explicit: false,
      cwd: "/controller/workspace",
      mcp_servers: [
        %{"name" => "bot", "url" => "https://example.com/mcp",
          "headers" => %{"Authorization" => "Bearer private-token"}}
      ]
    }

    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(unique_session_key("remote"), %{
                 agent_id: "test",
                 cwd: "/controller/override",
                 meta: meta
               }),
               orchestrator_state()
             )

    assert submission.execution_request.cwd == nil
    assert submission.execution_request.meta.mcp_servers == meta.mcp_servers
    refute Map.has_key?(submission.meta, :mcp_servers)
    refute inspect(submission.meta) =~ "private-token"
  end

  test "explicit destination cwd is retained for named profiles" do
    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(unique_session_key("remote-explicit"), %{
                 agent_id: "test",
                 cwd: "/worker/project",
                 meta: %{node: "worker-one", remote_cwd_explicit: true}
               }),
               orchestrator_state()
             )

    assert submission.execution_request.cwd == "/worker/project"
  end

  test "local placement continues resolving the controller cwd default" do
    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(unique_session_key("local"), %{
                 agent_id: "test",
                 meta: %{node: "local", remote_cwd_explicit: false}
               }),
               orchestrator_state()
             )

    assert submission.execution_request.cwd == LemonCore.Cwd.default_cwd()
  end

  @tag :tmp_dir
  test "new managed profiles are admitted before registry reload", %{tmp_dir: root} do
    config = Path.join(root, "profiles.toml")
    File.write!(config, "")
    previous_paths = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths,
      (previous_paths || [])
      |> Keyword.put(:global_config, config)
      |> Keyword.put(:home_state_dir, root))
    on_exit(fn ->
      if is_nil(previous_paths) do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, previous_paths)
      end
    end)

    assert {:ok, profile} =
             LemonCore.ProfileStore.create(%{
               id: "new-managed-profile", node: "worker-new",
               systemPrompt: "New managed persona", model: "new-profile-model"
             })
    assert {:ok, request} =
             LemonCore.ProfileStore.chat_request(profile, "hello",
               run_id: "run_new_managed_profile",
               session_key: "agent:new-managed-profile:task-example")

    refute LemonRouter.AgentProfiles.exists?("new-managed-profile")
    assert {:ok, submission} = SubmissionBuilder.build(request, orchestrator_state())
    assert submission.execution_request.meta.node == "worker-new"
    assert submission.execution_request.meta.system_prompt == "New managed persona"
    assert submission.execution_request.meta.model == "new-profile-model"
    assert submission.execution_request.cwd == nil
  end

  defp request(session_key, attrs) do
    attrs
    |> Map.merge(%{
      origin: :control_plane,
      session_key: session_key,
      prompt: "Hello",
      run_id: "run_#{System.unique_integer([:positive])}"
    })
    |> LemonCore.RunRequest.new()
  end

  defp orchestrator_state do
    %{
      run_supervisor: LemonRouter.RunSupervisor,
      run_process_module: LemonRouter.RunProcess,
      run_process_opts: %{notify_pid: self()}
    }
  end

  defp unique_session_key(label) do
    "agent:submission-builder:#{label}:#{System.unique_integer([:positive])}"
  end

  defp profile_map do
    %{
      "default" => %{
        id: "default",
        name: "Default Agent",
        tool_policy: nil,
        system_prompt: nil,
        model: nil
      },
      "test" => %{
        id: "test",
        name: "Test Agent",
        tool_policy: nil,
        system_prompt: nil,
        model: nil
      },
      "oracle" => %{
        id: "oracle",
        name: "Oracle",
        tool_policy: %{approvals: %{"bash" => :always}, blocked_tools: ["bash"]},
        system_prompt: "You are the oracle.",
        model: "profile-model"
      }
    }
  end
end
