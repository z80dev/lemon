defmodule LemonControlPlane.Methods.IntrospectionMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
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
    requirements_cwd = Path.join(System.tmp_dir!(), "cp_introspection_requirements_#{token}")
    registry_available? = is_pid(Process.whereis(LemonRouter.SessionRegistry))

    File.mkdir_p!(requirements_cwd)

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    :ok =
      CodingAgent.Tools.FeatureRequirements.save_requirements(
        %{
          project_name: "Control Plane Harness Projection",
          original_prompt: "Track long-running task progress",
          created_at: now,
          version: "1.0",
          features: [
            %{
              id: "feature-001",
              description: "Expose harness data",
              status: :completed,
              dependencies: [],
              priority: :high,
              acceptance_criteria: ["harness appears in sessions.active.list"],
              notes: "",
              created_at: now,
              updated_at: now
            },
            %{
              id: "feature-002",
              description: "Validate requirements progress",
              status: :pending,
              dependencies: ["feature-001"],
              priority: :medium,
              acceptance_criteria: ["requirements section is included"],
              notes: "",
              created_at: now,
              updated_at: nil
            }
          ]
        },
        requirements_cwd
      )

    if registry_available? do
      {:ok, _} = Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id})
    end

    LemonCore.Store.put(:runs, run_id, %{started_at: System.system_time(:millisecond)})

    :ok =
      LemonCore.Introspection.record(
        :session_started,
        %{cwd: requirements_cwd},
        run_id: run_id,
        session_key: session_key,
        agent_id: agent_id
      )

    CodingAgent.Tools.TodoStore.put(session_key, [
      %{
        "id" => "todo-introspection-1",
        "content" => "verify harness projection",
        "status" => "pending"
      }
    ])

    {:ok, checkpoint} =
      CodingAgent.Checkpoint.create(session_key,
        todos: [%{"id" => "todo-introspection-1", "content" => "verify harness projection"}],
        metadata: %{source: "introspection-methods-test"}
      )

    on_exit(fn ->
      if registry_available? do
        Registry.unregister(LemonRouter.SessionRegistry, session_key)
      end

      LemonCore.Store.delete(:runs, run_id)
      CodingAgent.Tools.TodoStore.delete(session_key)
      CodingAgent.Checkpoint.delete(checkpoint.id)
      File.rm_rf(requirements_cwd)
    end)

    {:ok,
     %{
       agent_id: agent_id,
       session_key: session_key,
       run_id: run_id,
       requirements_cwd: requirements_cwd,
       registry_available?: registry_available?
     }}
  end

  describe "sessions.active.list" do
    test "lists active sessions with filters", %{
      agent_id: agent_id,
      session_key: session_key,
      requirements_cwd: requirements_cwd,
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

        assert session = Enum.find(result["sessions"], &(&1["sessionKey"] == session_key))
        assert is_map(session["harness"])
        assert session["harness"]["todos"]["total"] == 1
        assert session["harness"]["checkpoints"]["count"] >= 1
        assert session["harness"]["requirements"]["project_name"] == "Control Plane Harness Projection"
        assert session["harness"]["requirements"]["percentage"] == 50
        assert session["harness"]["requirements"]["cwd"] == requirements_cwd
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
      requirements_cwd: requirements_cwd,
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

        assert session = Enum.find(result["activeSessions"], &(&1["sessionKey"] == session_key))
        assert is_map(session["harness"])
        assert session["harness"]["todos"]["total"] == 1
        assert session["harness"]["requirements"]["project_name"] == "Control Plane Harness Projection"
        assert session["harness"]["requirements"]["cwd"] == requirements_cwd
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
end
