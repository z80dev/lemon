defmodule LemonControlPlane.Methods.ControlPlaneMethodsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for control-plane method implementations.
  """

  defmodule CompactSessionStub do
    use GenServer

    def start_link({test_pid, session_key}) do
      GenServer.start_link(__MODULE__, {test_pid, session_key})
    end

    @impl true
    def init({test_pid, session_key}) do
      Registry.register(CodingAgent.SessionRegistry, session_key, :test)
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_call({:compact, opts}, _from, state) do
      send(state.test_pid, {:compact_opts, opts})
      {:reply, :ok, state}
    end
  end

  describe "AgentsFilesList" do
    alias LemonControlPlane.Methods.{AgentsFilesList, AgentsFilesSet}

    test "name/0 returns correct method name" do
      assert AgentsFilesList.name() == "agents.files.list"
    end

    test "scopes/0 returns read scope" do
      assert AgentsFilesList.scopes() == [:read]
    end

    test "handle/2 returns files list for agent" do
      {:ok, result} = AgentsFilesList.handle(%{"agentId" => "test-agent"}, %{})

      assert result["agentId"] == "test-agent"
      assert is_list(result["files"])
      assert result["summary"]["agentId"] == "test-agent"
      assert result["summary"]["fileCount"] == length(result["files"])
      assert result["summary"]["cleanup"]["includesFileContent"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "handle/2 uses default agent_id when not provided" do
      {:ok, result} = AgentsFilesList.handle(%{}, %{})

      assert result["agentId"] == "default"
      assert result["summary"]["agentId"] == "default"
    end

    test "handle/2 summarizes stored files without content" do
      agent_id = "files-list-#{System.unique_integer([:positive, :monotonic])}"

      {:ok, _} =
        AgentsFilesSet.handle(
          %{"agentId" => agent_id, "fileName" => "profile.md", "content" => "private profile"},
          %{}
        )

      {:ok, result} = AgentsFilesList.handle(%{"agentId" => agent_id}, %{})

      assert result["summary"]["fileCount"] == 1
      assert result["summary"]["totalSizeBytes"] == byte_size("private profile")
      assert result["summary"]["typeCounts"]["text"] == 1
      assert result["summary"]["hasFiles"] == true
      refute inspect(result["summary"]) =~ "private profile"
    end
  end

  describe "AgentsFilesGet" do
    alias LemonControlPlane.Methods.{AgentsFilesGet, AgentsFilesSet}

    test "name/0 returns correct method name" do
      assert AgentsFilesGet.name() == "agents.files.get"
    end

    test "scopes/0 returns read scope" do
      assert AgentsFilesGet.scopes() == [:read]
    end

    test "handle/2 returns error when fileName is missing" do
      {:error, error} = AgentsFilesGet.handle(%{"agentId" => "test"}, %{})

      # Error is returned as tuple {code, message}
      case error do
        {:invalid_request, _msg} -> assert true
        %{code: :invalid_request} -> assert true
        %{code: "INVALID_REQUEST"} -> assert true
        _ -> flunk("Expected invalid_request error, got: #{inspect(error)}")
      end
    end

    test "handle/2 returns file content with bounded summary" do
      agent_id = "files-get-#{System.unique_integer([:positive, :monotonic])}"

      {:ok, _} =
        AgentsFilesSet.handle(
          %{"agentId" => agent_id, "fileName" => "memory.md", "content" => "remember this"},
          %{}
        )

      {:ok, result} =
        AgentsFilesGet.handle(%{"agentId" => agent_id, "fileName" => "memory.md"}, %{})

      assert result["content"] == "remember this"
      assert result["summary"]["agentId"] == agent_id
      assert result["summary"]["fileName"] == "memory.md"
      assert result["summary"]["sizeBytes"] == byte_size("remember this")
      assert result["summary"]["contentReturned"] == true
      assert result["summary"]["hasUpdatedAt"] == true
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result["summary"]) =~ "remember this"
    end
  end

  describe "AgentsFilesSet" do
    alias LemonControlPlane.Methods.AgentsFilesSet

    test "name/0 returns correct method name" do
      assert AgentsFilesSet.name() == "agents.files.set"
    end

    test "scopes/0 returns admin scope" do
      assert AgentsFilesSet.scopes() == [:admin]
    end

    test "handle/2 returns error when fileName is missing" do
      {:error, _} = AgentsFilesSet.handle(%{"content" => "test"}, %{})
    end

    test "handle/2 returns error when content is missing" do
      {:error, _} = AgentsFilesSet.handle(%{"fileName" => "test.txt"}, %{})
    end

    test "handle/2 stores file and returns content cleanup summary" do
      agent_id = "files-set-#{System.unique_integer([:positive, :monotonic])}"

      {:ok, result} =
        AgentsFilesSet.handle(
          %{"agentId" => agent_id, "fileName" => "system.md", "content" => "private system"},
          %{}
        )

      assert result["agentId"] == agent_id
      assert result["fileName"] == "system.md"
      assert result["size"] == byte_size("private system")
      assert result["summary"]["sizeBytes"] == byte_size("private system")
      assert result["summary"]["updated"] == true
      assert result["summary"]["cleanup"]["includesFileContent"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private system"
    end
  end

  describe "Agent" do
    alias LemonControlPlane.Methods.Agent

    test "name/0 returns correct method name" do
      assert Agent.name() == "agent"
    end

    test "scopes/0 returns write scope" do
      assert Agent.scopes() == [:write]
    end

    test "handle/2 returns idempotent submission with prompt cleanup summary" do
      key = "agent-submit-#{System.unique_integer([:positive, :monotonic])}"

      LemonCore.Idempotency.put(:agent, key, %{
        "run_id" => "run_cached",
        "session_key" => "agent:builder:main"
      })

      on_exit(fn -> LemonCore.Idempotency.delete(:agent, key) end)

      {:ok, result} =
        Agent.handle(
          %{
            "prompt" => "private prompt body",
            "agent_id" => "builder",
            "queue_mode" => "steer",
            "model" => "openai:gpt-4.1",
            "idempotency_key" => key
          },
          %{}
        )

      assert result["run_id"] == "run_cached"
      assert result["summary"]["agentId"] == "builder"
      assert result["summary"]["sessionKey"] == "agent:builder:main"
      assert result["summary"]["runId"] == "run_cached"
      assert result["summary"]["queueMode"] == "steer"
      assert result["summary"]["promptBytes"] == byte_size("private prompt body")
      assert result["summary"]["hasModelOverride"] == true
      assert result["summary"]["hasIdempotencyKey"] == true
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private prompt body"
    end
  end

  describe "AgentWait" do
    alias LemonControlPlane.Methods.AgentWait

    test "name/0 returns correct method name" do
      assert AgentWait.name() == "agent.wait"
    end

    test "scopes/0 returns read scope" do
      assert AgentWait.scopes() == [:read]
    end

    test "handle/2 returns completed run with bounded answer summary" do
      run_id = "run_wait_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:wait:main:#{System.unique_integer([:positive])}"

      LemonCore.RunStore.finalize(run_id, %{
        completed: %{run_id: run_id, ok: true, answer: "private answer body"},
        prompt: "private prompt body",
        session_key: session_key
      })

      {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})

      assert result["runId"] == run_id
      assert result["ok"] == true
      assert result["answer"] == "private answer body"
      assert result["summary"]["runId"] == run_id
      assert result["summary"]["answerReturned"] == true
      assert result["summary"]["answerBytes"] == byte_size("private answer body")
      assert result["summary"]["hasError"] == false
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["redactsSensitiveAnswerValues"] == true
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result["summary"]) =~ "private answer body"
      refute inspect(result["summary"]) =~ "private prompt body"
    end

    test "handle/2 redacts sensitive answer and error values" do
      run_id = "run_wait_redaction_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:wait:redaction:#{System.unique_integer([:positive])}"
      answer_secret = "ANSWER_WAIT_TOKEN_#{System.unique_integer([:positive])}"
      error_secret = "ERROR_WAIT_BEARER_#{System.unique_integer([:positive])}"

      LemonCore.RunStore.finalize(run_id, %{
        completed: %{
          run_id: run_id,
          ok: false,
          answer: "done token=#{answer_secret}",
          error: "failed Bearer #{error_secret}"
        },
        prompt: "private prompt body",
        session_key: session_key
      })

      {:ok, result} = AgentWait.handle(%{"runId" => run_id, "timeoutMs" => 1}, %{})

      refute inspect(result) =~ answer_secret
      refute inspect(result) =~ error_secret
      assert result["ok"] == false
      assert result["answer"] == "done token=[REDACTED]"
      assert result["error"] == "failed Bearer [REDACTED]"
      assert result["summary"]["cleanup"]["redactsSensitiveAnswerValues"] == true
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end
  end

  describe "SessionsCompact" do
    alias LemonControlPlane.Methods.SessionsCompact

    test "name/0 returns correct method name" do
      assert SessionsCompact.name() == "sessions.compact"
    end

    test "scopes/0 returns admin scope" do
      assert SessionsCompact.scopes() == [:admin]
    end

    test "handle/2 returns compact cleanup summary without custom summary text" do
      unless Process.whereis(CodingAgent.SessionRegistry) do
        start_supervised!({Registry, keys: :unique, name: CodingAgent.SessionRegistry})
      end

      session_key = "compact-session-#{System.unique_integer([:positive, :monotonic])}"
      custom_summary = "private compaction summary token=COMPACT_SECRET"

      start_supervised!({CompactSessionStub, {self(), session_key}})

      {:ok, result} =
        SessionsCompact.handle(
          %{"sessionKey" => session_key, "force" => true, "summary" => custom_summary},
          %{}
        )

      assert_received {:compact_opts, opts}
      assert Keyword.fetch!(opts, :force) == true
      assert Keyword.fetch!(opts, :summary) == custom_summary
      assert result["success"] == true
      assert result["sessionKey"] == session_key
      assert result["summary"]["sessionKeyReturned"] == true
      assert result["summary"]["compacted"] == true
      assert result["summary"]["force"] == true
      assert result["summary"]["customSummaryProvided"] == true
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["includesSummaryText"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private compaction summary"
      refute inspect(result) =~ "COMPACT_SECRET"
    end
  end

  describe "SkillsBins" do
    alias LemonControlPlane.Methods.SkillsBins

    test "name/0 returns correct method name" do
      assert SkillsBins.name() == "skills.bins"
    end

    test "scopes/0 returns read scope" do
      assert SkillsBins.scopes() == [:read]
    end

    test "handle/2 returns bins list" do
      {:ok, result} = SkillsBins.handle(%{}, %{})

      assert is_map(result)
      assert is_list(result["bins"])
      assert result["summary"]["action"] == "skills.bins"
      assert result["summary"]["binCount"] == length(result["bins"])
      assert result["summary"]["requiredCount"] >= 0
      assert result["summary"]["cwdReturned"] == false
      assert result["summary"]["cleanup"]["includesCwd"] == false
      assert result["summary"]["cleanup"]["includesSkillSources"] == false
      assert result["summary"]["cleanup"]["includesEnvironmentValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end
  end

  describe "ExecApprovalRequest" do
    alias LemonControlPlane.Methods.ExecApprovalRequest

    test "name/0 returns correct method name" do
      assert ExecApprovalRequest.name() == "exec.approval.request"
    end

    test "scopes/0 returns approvals scope" do
      assert ExecApprovalRequest.scopes() == [:approvals]
    end

    test "handle/2 returns error when tool is missing" do
      {:error, _} = ExecApprovalRequest.handle(%{"runId" => "run-1"}, %{})
    end
  end

  describe "BrowserRequest" do
    alias LemonControlPlane.Methods.BrowserRequest

    test "name/0 returns correct method name" do
      assert BrowserRequest.name() == "browser.request"
    end

    test "scopes/0 returns write scope" do
      assert BrowserRequest.scopes() == [:write]
    end

    test "handle/2 returns error when no browser node available" do
      {:error, error} = BrowserRequest.handle(%{"method" => "navigate"}, %{})

      # Error is returned as tuple {code, message}
      # With full implementation, returns not_found when no browser node
      case error do
        {:not_found, _msg} -> assert true
        {:not_implemented, _msg} -> assert true
        %{code: :not_found} -> assert true
        %{code: :not_implemented} -> assert true
        _ -> flunk("Unexpected error: #{inspect(error)}")
      end
    end
  end

  describe "ChatAbort" do
    alias LemonControlPlane.Methods.ChatAbort

    test "summarizes run-scoped abort without message payloads" do
      {:ok, result} = ChatAbort.handle(%{"runId" => "run-abort-summary"}, %{})

      assert result["aborted"] == true
      assert result["runId"] == "run-abort-summary"
      assert result["summary"]["targetType"] == "run"
      assert result["summary"]["targetId"] == "run-abort-summary"
      assert result["summary"]["reason"] == "user_requested"
      assert result["summary"]["dispatchStatus"] in ["sent", "router_unavailable"]
      assert result["summary"]["cleanup"]["includesPrompt"] == false
      assert result["summary"]["cleanup"]["includesMessages"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "summarizes session-scoped abort without message payloads" do
      {:ok, result} = ChatAbort.handle(%{"sessionKey" => "session-abort-summary"}, %{})

      assert result["aborted"] == true
      assert result["sessionKey"] == "session-abort-summary"
      assert result["summary"]["targetType"] == "session"
      assert result["summary"]["targetId"] == "session-abort-summary"
      assert result["summary"]["dispatchStatus"] in ["sent", "router_unavailable"]
      assert result["summary"]["cleanup"]["includesMessages"] == false
    end
  end

  describe "ChatSend" do
    alias LemonControlPlane.Methods.ChatSend

    test "name/0 returns correct method name" do
      assert ChatSend.name() == "chat.send"
    end

    test "scopes/0 returns write scope" do
      assert ChatSend.scopes() == [:write]
    end

    test "handle/2 submits echo run with prompt cleanup summary" do
      {:ok, _} = Application.ensure_all_started(:lemon_router)

      session_key = "agent:chat-send:main:#{System.unique_integer([:positive, :monotonic])}"
      prompt = "with echo private chat prompt"

      {:ok, result} =
        ChatSend.handle(
          %{
            "sessionKey" => session_key,
            "agentId" => "default",
            "prompt" => prompt,
            "queueMode" => "steer"
          },
          %{}
        )

      assert is_binary(result["runId"])
      assert result["sessionKey"] == session_key
      assert result["summary"]["runId"] == result["runId"]
      assert result["summary"]["sessionKey"] == session_key
      assert result["summary"]["agentId"] == "default"
      assert result["summary"]["queueMode"] == "steer"
      assert result["summary"]["promptBytes"] == byte_size(prompt)
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private chat prompt"
    end
  end

  describe "Wake" do
    alias LemonControlPlane.Methods.Wake

    test "name/0 returns correct method name" do
      assert Wake.name() == "wake"
    end

    test "scopes/0 returns write scope" do
      assert Wake.scopes() == [:write]
    end

    test "handle/2 returns error when prompt is missing" do
      {:error, _} = Wake.handle(%{"agentId" => "test"}, %{})
    end
  end

  describe "SetHeartbeats" do
    alias LemonControlPlane.Methods.SetHeartbeats

    test "name/0 returns correct method name" do
      assert SetHeartbeats.name() == "set-heartbeats"
    end

    test "scopes/0 returns admin scope" do
      assert SetHeartbeats.scopes() == [:admin]
    end

    test "handle/2 returns error when enabled is missing" do
      {:error, _} = SetHeartbeats.handle(%{"agentId" => "test"}, %{})
    end
  end

  describe "LastHeartbeat" do
    alias LemonControlPlane.Methods.LastHeartbeat

    test "name/0 returns correct method name" do
      assert LastHeartbeat.name() == "last-heartbeat"
    end

    test "scopes/0 returns read scope" do
      assert LastHeartbeat.scopes() == [:read]
    end

    test "handle/2 returns heartbeat status" do
      {:ok, result} = LastHeartbeat.handle(%{"agentId" => "test"}, %{})

      assert is_map(result)
      assert result["agentId"] == "test"
      assert Map.has_key?(result, "enabled")
    end
  end

  describe "TalkMode" do
    alias LemonControlPlane.Methods.TalkMode

    test "name/0 returns correct method name" do
      assert TalkMode.name() == "talk.mode"
    end

    test "scopes/0 returns write scope" do
      assert TalkMode.scopes() == [:write]
    end

    test "handle/2 gets current mode when mode param is nil" do
      {:ok, result} = TalkMode.handle(%{"sessionKey" => "test-session"}, %{})

      assert is_map(result)
      assert result["sessionKey"] == "test-session"
      assert Map.has_key?(result, "mode")
      assert result["summary"]["sessionKey"] == "test-session"
      assert result["summary"]["mode"] == result["mode"]
      assert result["summary"]["set"] == false
      assert result["summary"]["cleanup"]["includesAudio"] == false
      assert result["summary"]["cleanup"]["includesTranscript"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "handle/2 sets mode with cleanup summary" do
      {:ok, result} =
        TalkMode.handle(%{"sessionKey" => "test-session-set", "mode" => "push-to-talk"}, %{})

      assert result["sessionKey"] == "test-session-set"
      assert result["mode"] == "push-to-talk"
      assert result["set"] == true
      assert result["summary"]["sessionKey"] == "test-session-set"
      assert result["summary"]["mode"] == "push-to-talk"
      assert result["summary"]["set"] == true
      assert result["summary"]["cleanup"]["includesAudio"] == false
      assert result["summary"]["cleanup"]["includesTranscript"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end
  end

  describe "AgentIdentityGet" do
    alias LemonControlPlane.Methods.AgentIdentityGet

    test "name/0 returns correct method name" do
      assert AgentIdentityGet.name() == "agent.identity.get"
    end

    test "scopes/0 returns read scope" do
      assert AgentIdentityGet.scopes() == [:read]
    end

    test "handle/2 returns default identity when agent not found" do
      {:ok, result} = AgentIdentityGet.handle(%{"agentId" => "nonexistent"}, %{})

      assert is_map(result)
      # The method may return the queried agent_id or a default
      assert result["agentId"] in ["nonexistent", "default"]
      assert Map.has_key?(result, "capabilities")

      assert result["summary"]["agentId"] == result["agentId"]
      assert result["summary"]["defaultEngine"] == result["defaultEngine"]
      assert result["summary"]["capabilityCount"] == map_size(result["capabilities"])
      assert "streaming" in result["summary"]["enabledCapabilities"]
      assert "tools" in result["summary"]["enabledCapabilities"]
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "handle/2 uses default agent_id when not provided" do
      {:ok, result} = AgentIdentityGet.handle(%{}, %{})

      assert result["agentId"] == "default"
      assert result["summary"]["agentId"] == "default"
    end
  end

  describe "AgentProgress" do
    alias CodingAgent.Tools.TodoStore
    alias LemonControlPlane.Methods.AgentProgress

    test "name/0 returns correct method name" do
      assert AgentProgress.name() == "agent.progress"
    end

    test "scopes/0 returns read scope" do
      assert AgentProgress.scopes() == [:read]
    end

    test "handle/2 returns progress snapshot with cleanup summary" do
      session_id = "agent-progress-#{System.unique_integer([:positive, :monotonic])}"
      cwd = Path.join(System.tmp_dir!(), "agent-progress-#{System.unique_integer([:positive])}")

      File.mkdir_p!(cwd)

      on_exit(fn ->
        TodoStore.put(session_id, [])
        File.rm_rf(cwd)
      end)

      TodoStore.put(session_id, [
        %{id: "t1", content: "Done", status: :completed, dependencies: [], priority: :high},
        %{
          id: "t2",
          content: "Pending details",
          status: :pending,
          dependencies: [],
          priority: :medium
        }
      ])

      {:ok, result} = AgentProgress.handle(%{"sessionId" => session_id, "cwd" => cwd}, %{})

      assert result["sessionId"] == session_id
      assert result["cwd"] == cwd
      assert result["snapshot"].todos.total == 2
      assert result["summary"]["sessionId"] == session_id
      assert result["summary"]["cwd"] == cwd
      assert result["summary"]["overallPercentage"] == 50
      assert result["summary"]["todos"]["total"] == 2
      assert result["summary"]["todos"]["completed"] == 1
      assert result["summary"]["todos"]["pending"] == 1
      assert result["summary"]["features"]["total"] == 0
      assert result["summary"]["hasFeatures"] == false
      assert result["summary"]["checkpoints"]["count"] == 0
      assert result["summary"]["nextActionCounts"]["todos"] == 1
      assert result["summary"]["nextActionCounts"]["features"] == 0
      assert result["summary"]["cleanup"]["includesNextActionContent"] == false
      assert result["summary"]["cleanup"]["includesPromptText"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false

      refute inspect(result["summary"]) =~ "Pending details"
    end
  end

  describe "Node pairing methods" do
    alias LemonControlPlane.Methods.{NodePairRequest, NodePairList, NodeList}

    test "NodePairRequest returns error when nodeName is missing" do
      {:error, _} = NodePairRequest.handle(%{"nodeType" => "browser"}, %{})
    end

    test "NodePairList returns list of pending requests" do
      {:ok, result} = NodePairList.handle(%{}, %{})

      assert is_map(result)
      assert is_list(result["requests"])
      assert result["summary"]["pendingCount"] == length(result["requests"])
      assert is_map(result["summary"]["nodeTypeCounts"])
      assert is_map(result["summary"]["capabilityCounts"])
      assert result["summary"]["cleanup"]["includesPairingCodes"] == true
      assert result["summary"]["cleanup"]["includesApprovedTokens"] == false
      assert result["summary"]["cleanup"]["includesChallengeTokens"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "NodeList returns list of nodes" do
      {:ok, result} = NodeList.handle(%{}, %{})

      assert is_map(result)
      assert is_list(result["nodes"])
      assert result["summary"]["nodeCount"] == length(result["nodes"])
      assert is_map(result["summary"]["statusCounts"])
      assert is_map(result["summary"]["typeCounts"])
      assert result["summary"]["cleanup"]["includesCapabilities"] == true
      assert result["summary"]["cleanup"]["includesInvocationResults"] == false
      assert result["summary"]["cleanup"]["includesPairingSecrets"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end
  end
end
