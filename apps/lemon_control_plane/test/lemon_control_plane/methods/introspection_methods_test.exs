defmodule LemonControlPlane.Methods.IntrospectionMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    AgentProgress,
    IntrospectionSnapshot,
    SessionsActiveList,
    TransportsStatus
  }

  alias LemonCore.SessionKey

  setup do
    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cp_introspection_#{token}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: agent_id,
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(1_000_000 + token)
      })

    run_id = "run_cp_introspection_#{token}"
    registry_available? = is_pid(Process.whereis(LemonRouter.SessionRegistry))

    if registry_available? do
      {:ok, _} = Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id})
    end

    LemonCore.Store.put(:runs, run_id, %{started_at: System.system_time(:millisecond)})

    on_exit(fn ->
      if registry_available? do
        Registry.unregister(LemonRouter.SessionRegistry, session_key)
      end

      LemonCore.Store.delete(:runs, run_id)
    end)

    {:ok,
     %{
       agent_id: agent_id,
       session_key: session_key,
       run_id: run_id,
       registry_available?: registry_available?
     }}
  end

  describe "sessions.active.list" do
    test "lists active sessions with filters", %{
      agent_id: agent_id,
      session_key: session_key,
      registry_available?: registry_available?
    } do
      assert SessionsActiveList.name() == "sessions.active.list"
      assert SessionsActiveList.scopes() == [:read]

      {:ok, result} =
        SessionsActiveList.handle(
          %{
            "agentId" => agent_id,
            "limit" => 20,
            "route" => %{"channelId" => "telegram"}
          },
          %{}
        )

      assert is_list(result["sessions"])
      assert is_integer(result["total"])
      assert result["total"] == length(result["sessions"])
      assert result["filters"]["agentId"] == agent_id
      assert result["filters"]["route"]["channelId"] == "telegram"

      if registry_available? do
        assert Enum.any?(result["sessions"], &(&1["sessionKey"] == session_key))
      end
    end
  end

  describe "transports.status" do
    test "returns transport visibility snapshot" do
      assert TransportsStatus.name() == "transports.status"
      assert TransportsStatus.scopes() == [:read]

      {:ok, result} = TransportsStatus.handle(%{}, %{})

      assert is_boolean(result["registryRunning"])
      assert is_list(result["transports"])
      assert is_integer(result["total"])
      assert is_integer(result["enabled"])
      assert result["total"] == length(result["transports"])
      assert result["enabled"] <= result["total"]

      Enum.each(result["transports"], fn transport ->
        assert is_binary(transport["transportId"])
        assert is_boolean(transport["enabled"])
        assert transport["status"] in ["enabled", "disabled"]
      end)
    end
  end

  describe "introspection.snapshot" do
    test "returns a consolidated introspection payload", %{
      agent_id: agent_id,
      session_key: session_key,
      registry_available?: registry_available?
    } do
      assert IntrospectionSnapshot.name() == "introspection.snapshot"
      assert IntrospectionSnapshot.scopes() == [:read]

      {:ok, result} =
        IntrospectionSnapshot.handle(
          %{
            "agentId" => agent_id,
            "route" => %{"channelId" => "telegram"},
            "includeAgents" => true,
            "includeSessions" => true,
            "includeActiveSessions" => true,
            "includeChannels" => true,
            "includeTransports" => true
          },
          %{}
        )

      assert is_integer(result["generatedAtMs"])
      assert is_map(result["includes"])
      assert is_map(result["filters"])
      assert is_list(result["agents"])
      assert is_list(result["sessions"])
      assert is_list(result["activeSessions"])
      assert is_list(result["channels"])
      assert is_list(result["transports"])
      assert is_map(result["runs"])
      assert is_map(result["counts"])
      assert is_list(result["errors"])

      assert result["filters"]["agentId"] == agent_id
      assert result["filters"]["route"]["channelId"] == "telegram"
      assert result["counts"]["sessions"] == length(result["sessions"])
      assert result["counts"]["activeSessions"] == length(result["activeSessions"])
      assert result["counts"]["transports"] == length(result["transports"])

      if registry_available? do
        assert Enum.any?(result["activeSessions"], &(&1["sessionKey"] == session_key))
      end
    end

    test "honors include toggles" do
      {:ok, result} =
        IntrospectionSnapshot.handle(
          %{
            "includeAgents" => false,
            "includeSessions" => false,
            "includeActiveSessions" => false,
            "includeChannels" => false,
            "includeTransports" => false
          },
          %{}
        )

      assert result["agents"] == []
      assert result["sessions"] == []
      assert result["activeSessions"] == []
      assert result["channels"] == []
      assert result["transports"] == []
    end
  end

  describe "agent.progress" do
    test "returns coding-agent harness progress and records introspection event" do
      token = System.unique_integer([:positive, :monotonic])
      session_id = "progress_session_#{token}"
      run_id = "run_progress_#{token}"
      cwd = Path.join(System.tmp_dir!(), "agent_progress_#{token}")

      File.mkdir_p!(cwd)

      requirements = %{
        project_name: "progress-test",
        original_prompt: "build feature",
        features: [
          %{
            id: "f1",
            description: "done",
            status: :completed,
            dependencies: [],
            priority: :high,
            acceptance_criteria: ["works"],
            created_at: DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            id: "f2",
            description: "next",
            status: :pending,
            dependencies: ["f1"],
            priority: :medium,
            acceptance_criteria: ["works"],
            created_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ],
        created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        version: "1.0"
      }

      :ok = CodingAgent.Tools.FeatureRequirements.save_requirements(requirements, cwd)

      :ok =
        CodingAgent.Tools.TodoStore.put(session_id, [
          %{id: "t1", content: "done", status: :completed, dependencies: [], priority: :high},
          %{id: "t2", content: "next", status: :pending, dependencies: ["t1"], priority: :medium}
        ])

      assert AgentProgress.name() == "agent.progress"
      assert AgentProgress.scopes() == [:read]

      {:ok, result} =
        AgentProgress.handle(
          %{
            "sessionId" => session_id,
            "cwd" => cwd,
            "runId" => run_id
          },
          %{}
        )

      assert result["sessionId"] == session_id
      assert result["cwd"] == cwd
      assert result["snapshot"][:todos][:total] == 2
      assert result["snapshot"][:features][:total] == 2
      assert result["snapshot"][:overall_percentage] == 50

      events =
        LemonCore.Introspection.list(
          run_id: run_id,
          event_type: :agent_progress_snapshot,
          limit: 5
        )

      assert Enum.any?(events, &(Map.get(&1, :event_type) == :agent_progress_snapshot))

      on_exit(fn ->
        CodingAgent.Tools.TodoStore.put(session_id, [])
        File.rm_rf(cwd)
      end)
    end
  end
end
