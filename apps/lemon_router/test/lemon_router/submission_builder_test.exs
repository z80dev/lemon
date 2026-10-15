defmodule LemonRouter.SubmissionBuilderTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ExecutionCommand, ExecutionContext, ResumeToken}
  alias LemonRouter.{PendingCompactionStore, ResumeResolver, Submission, SubmissionBuilder}

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

  test "delegated context remains an additional monotonic authority" do
    cwd = LemonCore.Cwd.default_cwd()

    assert {:ok, parent} =
             ExecutionContext.new(
               run_id: "parent_#{System.unique_integer([:positive])}",
               agent_id: "source",
               origin: :control_plane,
               cwd: cwd,
               tool_policy: %{allow: ["read", "write"], require_approval: ["read"]},
               capabilities: ["read"],
               limits: %{max_steps: 4}
             )

    incoming =
      request(unique_session_key("delegated"), %{
        agent_id: "test",
        cwd: cwd,
        tool_policy: %{allow: :all, require_approval: []},
        execution_context: parent
      })

    assert {:ok, submission} = SubmissionBuilder.build(incoming, orchestrator_state())
    command = submission.execution_request
    child = command.execution_context

    assert child.run_id == incoming.run_id
    assert child.parent_run_id == parent.run_id
    assert child.principal == %{type: "agent", id: "test"}
    assert child.provenance.delegated_by == ExecutionContext.identity(parent)
    assert ExecutionContext.subset?(child, parent)
    assert child.capabilities == ["read"]
    assert child.limits.max_steps == 4
    assert command.tool_policy == child.tool_policy
    assert command.tool_policy.allow == ["read"]
    assert "read" in command.tool_policy.require_approval
  end

  @tag :tmp_dir
  test "delegated workspace escapes and malformed contexts reject admission", %{tmp_dir: root} do
    assert {:ok, parent} =
             ExecutionContext.new(run_id: "parent", cwd: Path.join(root, "workspace"))

    incoming =
      request(unique_session_key("context-refusal"), %{
        agent_id: "test",
        cwd: Path.join(root, "outside"),
        execution_context: parent
      })

    assert {:error, _reason} = SubmissionBuilder.build(incoming, orchestrator_state())

    assert {:error, :invalid_execution_context} =
             SubmissionBuilder.build(
               %{incoming | execution_context: %{"runId" => "untrusted"}},
               orchestrator_state()
             )
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

  test "profile approval and denial floors cannot be weakened by caller overrides" do
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

    assert tool_policy.approvals["bash"] == :always
    assert "bash" in tool_policy.blocked_tools
    assert "rm" in tool_policy.blocked_tools
    assert %LemonCore.ExecutionContext{} = submission.execution_request.execution_context
  end

  test "unknown agent returns {:error, {:unknown_agent_id, ...}}" do
    session_key = unique_session_key("unknown")

    assert {:error, {:unknown_agent_id, "missing-agent"}} =
             SubmissionBuilder.build(
               request(session_key, %{agent_id: "missing-agent"}),
               orchestrator_state()
             )
  end

  @tag :tmp_dir
  test "named profile placement with no explicit cwd never uses controller cwd", %{tmp_dir: root} do
    profile = managed_profile(root, "worker-one")

    meta = %{
      node: profile["node"],
      profile_id: profile["id"],
      remote_cwd_explicit: false,
      cwd: "/controller/workspace",
      mcp_servers: [
        %{
          "name" => "bot",
          "url" => "https://example.com/mcp",
          "headers" => %{"Authorization" => "Bearer private-token"}
        }
      ]
    }

    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(profile["canonicalSessionKey"], %{
                 agent_id: profile["id"],
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

  test "named delegation relocates only workspace binding, not parent authority" do
    assert {:ok, parent} =
             ExecutionContext.new(
               run_id: "remote-parent",
               cwd: "/controller/workspace",
               tool_policy: %{allow: ["read"], deny: ["bash"]},
               limits: %{max_steps: 3}
             )

    assert {:ok, submission} =
             SubmissionBuilder.build(
               request(unique_session_key("remote-context"), %{
                 agent_id: "test",
                 cwd: "/worker/project",
                 execution_context: parent,
                 meta: %{node: "worker-one", remote_cwd_explicit: true}
               }),
               orchestrator_state()
             )

    command = submission.execution_request
    assert command.cwd == "/worker/project"
    assert command.execution_context.workspace_scope.root == nil
    assert command.execution_context.parent_run_id == parent.run_id
    assert command.execution_context.limits.max_steps == 3
    assert command.tool_policy.allow == ["read"]
    assert "bash" in command.tool_policy.deny
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

    Application.put_env(
      :lemon_core,
      :paths,
      (previous_paths || [])
      |> Keyword.put(:global_config, config)
      |> Keyword.put(:home_state_dir, root)
    )

    on_exit(fn ->
      if is_nil(previous_paths) do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, previous_paths)
      end
    end)

    assert {:ok, profile} =
             LemonCore.ProfileStore.create(%{
               id: "new-managed-profile",
               node: "worker-new",
               systemPrompt: "New managed persona",
               model: "new-profile-model",
               toolPolicy: %{"deny" => ["bash"], "approvals" => %{"write" => "always"}}
             })

    assert {:ok, request} =
             LemonCore.ProfileStore.chat_request(profile, "hello",
               run_id: "run_new_managed_profile",
               session_key: "agent:new-managed-profile:task-example"
             )

    refute LemonRouter.AgentProfiles.exists?("new-managed-profile")
    assert {:ok, submission} = SubmissionBuilder.build(request, orchestrator_state())
    assert submission.execution_request.meta.node == "worker-new"
    assert submission.execution_request.meta.system_prompt == "New managed persona"
    assert submission.execution_request.meta.model == "new-profile-model"
    assert submission.execution_request.cwd == nil
    assert submission.execution_request.tool_policy.deny == ["bash"]

    assert {:ok, _} =
             LemonCore.ProfileStore.update(
               "new-managed-profile",
               %{toolPolicy: %{"allow" => ["read"], "deny" => ["write"]}}
             )

    :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
      %{
        state
        | profiles: Map.put(state.profiles, "new-managed-profile", %{tool_policy: %{allow: :all}})
      }
    end)

    LemonCore.PolicyStore.put_session(request.session_key, %{
      tool_policy: %{"allow" => "all", "deny" => []}
    })

    on_exit(fn -> LemonCore.PolicyStore.delete_session(request.session_key) end)

    request = %{
      request
      | tool_policy: %{allow: :all},
        meta: Map.put(request.meta, :tool_policy, %{allow: :all})
    }

    assert {:ok, narrowed} = SubmissionBuilder.build(request, orchestrator_state())
    assert narrowed.execution_request.tool_policy.allow == ["read"]
    assert narrowed.execution_request.tool_policy.deny == ["write"]
  end

  test "resolved capabilities and memory audience bind both native resume and compaction history" do
    session_key = unique_session_key("scoped-history")
    meta = %{invocation_context_key: "same", memory_context_key: "private-room", mcp_servers: []}

    initial = %{
      request(session_key, %{agent_id: "test", meta: meta})
      | origin: :channel,
        prompt: "private bootstrap"
    }

    assert {:ok, owner} = SubmissionBuilder.build(initial, orchestrator_state())
    token = %ResumeToken{engine: "lemon", value: session_key}
    assert :ok = ResumeResolver.bind_run(owner.execution_request)
    assert :ok = ResumeResolver.bind(token, owner.execution_request)

    assert :ok =
             LemonCore.ChatStateStore.put(session_key, %{
               last_engine: "lemon",
               last_resume_token: token.value
             })

    assert :ok =
             LemonCore.RunHistoryStore.put(
               session_key,
               System.system_time(:millisecond),
               initial.run_id,
               %{summary: %{prompt: initial.prompt, answer: "private answer", meta: meta}}
             )

    marker = %{set_at_ms: System.system_time(:millisecond)}
    assert :ok = PendingCompactionStore.put(session_key, marker)

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(session_key)
      LemonCore.RunHistoryStore.delete_session(session_key)
      PendingCompactionStore.delete(session_key)
    end)

    same = %{
      request(session_key, %{agent_id: "test", meta: meta})
      | origin: :channel,
        prompt: "continue private work"
    }

    assert {:ok, resumed} = SubmissionBuilder.build(same, orchestrator_state())
    assert resumed.execution_request.resume == token
    assert resumed.execution_request.prompt =~ "private bootstrap"
    assert resumed.pending_compaction_marker == marker

    for other_meta <- [
          %{meta | invocation_context_key: "other"},
          %{meta | memory_context_key: "shared-room"},
          Map.delete(meta, :mcp_servers)
        ] do
      incoming = %{
        request(session_key, %{agent_id: "test", meta: other_meta})
        | origin: :channel,
          prompt: "public room prompt"
      }

      assert {:ok, fresh} = SubmissionBuilder.build(incoming, orchestrator_state())
      assert fresh.execution_request.resume == nil
      assert fresh.execution_request.prompt == "public room prompt"
      assert fresh.pending_compaction_marker == nil
      assert PendingCompactionStore.get(session_key) == marker
      assert LemonCore.ChatStateStore.get(session_key).last_resume_token == token.value
    end

    restricted = %{
      same
      | run_id: "#{same.run_id}-restricted",
        tool_policy: %{blocked_tools: ["read"]}
    }

    assert {:ok, fresh} = SubmissionBuilder.build(restricted, orchestrator_state())
    assert fresh.execution_request.resume == nil
    assert fresh.execution_request.prompt == same.prompt
    assert "read" in fresh.execution_request.tool_policy.blocked_tools

    assert {:ok, parent} =
             ExecutionContext.new(
               run_id: "history-parent",
               cwd: owner.execution_request.cwd,
               tool_policy: %{blocked_tools: ["read"]}
             )

    context_restricted = %{same | execution_context: parent}
    assert {:ok, fresh} = SubmissionBuilder.build(context_restricted, orchestrator_state())
    assert fresh.execution_request.resume == nil
    assert fresh.execution_request.prompt == same.prompt
    assert fresh.pending_compaction_marker == nil
    assert "read" in fresh.execution_request.tool_policy.blocked_tools
    assert PendingCompactionStore.get(session_key) == marker
  end

  test "legacy unknown journals retain default policy resume but explicit overrides start fresh" do
    session_key = unique_session_key("legacy-resume")
    token = %ResumeToken{engine: "lemon", value: session_key}

    assert :ok =
             LemonCore.ChatStateStore.put(session_key, %{
               last_engine: "lemon",
               last_resume_token: token.value
             })

    on_exit(fn -> LemonCore.ChatStateStore.delete(session_key) end)

    assert {:ok, legacy} =
             SubmissionBuilder.build(
               request(session_key, %{agent_id: "test"}),
               orchestrator_state()
             )

    assert is_map(legacy.execution_request.tool_policy)
    assert legacy.execution_request.resume == token

    assert {:ok, parent} = ExecutionContext.new(run_id: "legacy-parent")

    for attrs <- [
          %{agent_id: "test", tool_policy: %{blocked_tools: ["bash"]}},
          %{agent_id: "test", execution_context: parent},
          %{agent_id: "test", meta: %{mcp_servers: []}},
          %{agent_id: "test", meta: %{invocation_context_key: "scoped"}},
          %{agent_id: "test", meta: %{memory_context_key: "shared-room"}}
        ] do
      assert {:ok, fresh} =
               SubmissionBuilder.build(request(session_key, attrs), orchestrator_state())

      assert fresh.execution_request.resume == nil
    end

    assert LemonCore.ChatStateStore.get(session_key).last_resume_token == token.value
  end

  @tag :tmp_dir
  test "builder binds proof comparison to the actual fixed ID for resume and compaction", %{
    tmp_dir: root
  } do
    profile = managed_profile(root, "local")
    session_key = profile["canonicalSessionKey"]
    identity = %{profile_id: profile["id"], node: profile["node"]}

    initial = %{
      request(session_key, %{agent_id: profile["id"]})
      | origin: :channel,
        prompt: "prior work"
    }

    initial = %{initial | meta: Map.merge(proof_meta(initial.run_id), identity)}
    assert {:ok, owner} = SubmissionBuilder.build(initial, orchestrator_state())
    token = %ResumeToken{engine: "lemon", value: session_key}
    assert :ok = ResumeResolver.bind_run(owner.execution_request)
    assert :ok = ResumeResolver.bind(token, owner.execution_request)

    assert :ok =
             LemonCore.ChatStateStore.put(session_key, %{
               last_engine: "lemon",
               last_resume_token: token.value
             })

    assert :ok =
             LemonCore.RunHistoryStore.put(
               session_key,
               System.system_time(:millisecond),
               initial.run_id,
               %{summary: %{prompt: initial.prompt, answer: "done", meta: initial.meta}}
             )

    marker = %{set_at_ms: System.system_time(:millisecond)}
    assert :ok = PendingCompactionStore.put(session_key, marker)

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(session_key)
      LemonCore.RunHistoryStore.delete_session(session_key)
      PendingCompactionStore.delete(session_key)
    end)

    next = %{
      request(session_key, %{agent_id: profile["id"]})
      | origin: :channel,
        prompt: "next work"
    }

    next = %{next | meta: Map.merge(proof_meta(next.run_id), identity)}
    assert {:ok, resumed} = SubmissionBuilder.build(next, orchestrator_state())
    assert resumed.execution_request.resume == token
    assert resumed.execution_request.prompt =~ "prior work"
    assert resumed.pending_compaction_marker == marker
    assert resumed.execution_request.meta.mcp_servers == next.meta.mcp_servers

    borrowed = %{next | meta: initial.meta}
    assert {:ok, fresh} = SubmissionBuilder.build(borrowed, orchestrator_state())
    assert fresh.execution_request.resume == nil
    assert fresh.execution_request.prompt == "next work"
    assert fresh.pending_compaction_marker == nil
    assert PendingCompactionStore.get(session_key) == marker
  end

  defp managed_profile(root, node) do
    config = Path.join(root, "profiles.toml")
    File.write!(config, "")
    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      (previous_paths || [])
      |> Keyword.put(:global_config, config)
      |> Keyword.put(:home_state_dir, root)
    )

    on_exit(fn ->
      if is_nil(previous_paths) do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, previous_paths)
      end
    end)

    assert {:ok, profile} =
             LemonCore.ProfileStore.create(%{id: "submission-builder-managed", node: node})

    profile
  end

  defp proof_meta(run_id) do
    name = "lemon_bot/invocations/#{run_id}"

    servers = [
      %{
        name: "core",
        url: "https://core.invalid/mcp",
        headers: %{
          "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:#{name}}",
          "Authorization" => "${LEMON_SECRET:connector/same}"
        }
      }
    ]

    descriptor = %{
      "runId" => run_id,
      "serverName" => "core",
      "serverUrl" => "https://core.invalid/mcp",
      "headerName" => "X-Lemon-Bot-Invocation",
      "secretName" => name
    }

    assert {:ok, proof} = LemonCore.InvocationProof.validate(descriptor, run_id, servers)

    %{
      invocation_context_key: "same-actor",
      memory_context_key: "same-room",
      memory_context_verified: true,
      invocation_proof_verified: true,
      invocation_proof: proof,
      mcp_servers: servers
    }
  end

  test "malformed supplied policy rejects admission instead of broadening authority" do
    session_key = unique_session_key("invalid-tool-policy")

    assert {:error, {:invalid_policy_field, :allow}} =
             SubmissionBuilder.build(
               request(session_key, %{
                 agent_id: "test",
                 tool_policy: %{"allow" => %{"unexpected" => true}}
               }),
               orchestrator_state()
             )
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
