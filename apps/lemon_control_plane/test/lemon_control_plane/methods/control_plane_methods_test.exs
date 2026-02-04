defmodule LemonControlPlane.Methods.ControlPlaneMethodsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for control-plane method implementations.
  """

  describe "AgentsFilesList" do
    alias LemonControlPlane.Methods.AgentsFilesList

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
    end

    test "handle/2 uses default agent_id when not provided" do
      {:ok, result} = AgentsFilesList.handle(%{}, %{})

      assert result["agentId"] == "default"
    end
  end

  describe "AgentsFilesGet" do
    alias LemonControlPlane.Methods.AgentsFilesGet

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
    end

    test "handle/2 uses default agent_id when not provided" do
      {:ok, result} = AgentIdentityGet.handle(%{}, %{})

      assert result["agentId"] == "default"
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
    end

    test "NodeList returns list of nodes" do
      {:ok, result} = NodeList.handle(%{}, %{})

      assert is_map(result)
      assert is_list(result["nodes"])
    end
  end
end
