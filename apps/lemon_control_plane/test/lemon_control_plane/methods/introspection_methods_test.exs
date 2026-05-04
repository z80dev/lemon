defmodule LemonControlPlane.Methods.IntrospectionMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    IntrospectionSnapshot,
    SessionsActiveList,
    TransportsStatus
  }

  alias LemonCore.SessionKey

  defmodule RouterBridgeStub do
    @active_sessions_key {__MODULE__, :active_sessions}

    def set_active_sessions(entries) when is_list(entries) do
      :persistent_term.put(@active_sessions_key, entries)
    end

    def clear_active_sessions do
      :persistent_term.erase(@active_sessions_key)
    end

    def active_run(session_key) do
      case Enum.find(active_sessions(), &(&1.session_key == session_key)) do
        %{run_id: run_id} -> {:ok, run_id}
        _ -> :none
      end
    end

    def list_active_sessions do
      active_sessions()
    end

    defp active_sessions do
      :persistent_term.get(@active_sessions_key, [])
    end
  end

  defmodule SessionCoordinatorStub do
    @active_sessions_key {__MODULE__, :active_sessions}

    def set_active_sessions(entries) when is_list(entries) do
      :persistent_term.put(@active_sessions_key, entries)
    end

    def clear_active_sessions do
      :persistent_term.erase(@active_sessions_key)
    end

    def active_run_for_session(session_key) do
      case Enum.find(active_sessions(), &(&1.session_key == session_key)) do
        %{run_id: run_id} -> {:ok, run_id}
        _ -> :none
      end
    end

    def busy?(session_key), do: active_run_for_session(session_key) != :none

    def list_active_sessions do
      active_sessions()
    end

    defp active_sessions do
      :persistent_term.get(@active_sessions_key, [])
    end
  end

  defmodule TransportRegistryStub do
    use GenServer

    def start_link(state) do
      GenServer.start(__MODULE__, state, name: __MODULE__)
    end

    def list_transports, do: GenServer.call(__MODULE__, :list_transports)
    def enabled_transports, do: GenServer.call(__MODULE__, :enabled_transports)
    def get_transport(id), do: GenServer.call(__MODULE__, {:get_transport, id})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:list_transports, _from, state) do
      {:reply, Map.keys(state.transports), state}
    end

    def handle_call(:enabled_transports, _from, state) do
      enabled =
        state.transports
        |> Enum.filter(fn {id, _mod} -> id in state.enabled end)
        |> Enum.into([])

      {:reply, enabled, state}
    end

    def handle_call({:get_transport, id}, _from, state) do
      {:reply, Map.get(state.transports, id), state}
    end
  end

  defmodule TransportRegistryMissingApiStub do
    use GenServer

    def start_link(state) do
      GenServer.start(__MODULE__, state, name: __MODULE__)
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule TransportRegistryCrashingStub do
    use GenServer

    def start_link(state) do
      GenServer.start(__MODULE__, state, name: __MODULE__)
    end

    def list_transports, do: GenServer.call(__MODULE__, :list_transports)
    def enabled_transports, do: GenServer.call(__MODULE__, :enabled_transports)
    def get_transport(_id), do: raise("registry API failure")

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:list_transports, _from, state), do: {:reply, ["email"], state}
    def handle_call(:enabled_transports, _from, state), do: {:reply, [], state}
  end

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
    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_session_coordinator = Application.get_env(:lemon_router, :session_coordinator)

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

    LemonCore.RouterBridge.configure(router: RouterBridgeStub)
    RouterBridgeStub.set_active_sessions([%{session_key: session_key, run_id: run_id}])
    Application.put_env(:lemon_router, :session_coordinator, SessionCoordinatorStub)
    SessionCoordinatorStub.set_active_sessions([%{session_key: session_key, run_id: run_id}])

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
      RouterBridgeStub.clear_active_sessions()
      SessionCoordinatorStub.clear_active_sessions()
      restore_router_bridge(old_router_bridge)
      restore_session_coordinator(old_session_coordinator)
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
       requirements_cwd: requirements_cwd
     }}
  end

  describe "sessions.active.list" do
    test "lists active sessions with filters", %{
      agent_id: agent_id,
      session_key: session_key,
      requirements_cwd: requirements_cwd
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

      assert Enum.any?(result["sessions"], &(&1["sessionKey"] == session_key))

      assert session = Enum.find(result["sessions"], &(&1["sessionKey"] == session_key))
      assert is_map(session["harness"])
      assert session["harness"]["todos"]["total"] == 1
      assert session["harness"]["checkpoints"]["count"] >= 1

      assert session["harness"]["requirements"]["project_name"] ==
               "Control Plane Harness Projection"

      assert session["harness"]["requirements"]["percentage"] == 50
      assert session["harness"]["requirements"]["cwd"] == requirements_cwd
    end
  end

  describe "transports.status" do
    setup do
      old_registry_module = Application.get_env(:lemon_control_plane, :transport_registry_module)

      on_exit(fn ->
        restore_transport_registry_module(old_registry_module)
      end)

      :ok
    end

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

    test "returns empty snapshot when the gateway registry module is not loaded" do
      Application.put_env(
        :lemon_control_plane,
        :transport_registry_module,
        :"Elixir.LemonControlPlane.MissingTransportRegistryForTest"
      )

      {:ok, result} = TransportsStatus.handle(%{}, %{})

      assert result["registryRunning"] == false
      assert result["transports"] == []
      assert result["total"] == 0
      assert result["enabled"] == 0
    end

    test "returns empty snapshot when the gateway registry module is loaded but stopped" do
      Application.put_env(:lemon_control_plane, :transport_registry_module, TransportRegistryStub)

      {:ok, result} = TransportsStatus.handle(%{}, %{})

      assert result["registryRunning"] == false
      assert result["transports"] == []
    end

    test "returns configured and enabled transports when the legacy registry is running" do
      Application.put_env(:lemon_control_plane, :transport_registry_module, TransportRegistryStub)

      {:ok, pid} =
        TransportRegistryStub.start_link(%{
          transports: %{"email" => Example.EmailTransport, "webhook" => Example.WebhookTransport},
          enabled: ["webhook"]
        })

      try do
        {:ok, result} = TransportsStatus.handle(%{}, %{})

        assert result["registryRunning"] == true
        assert result["total"] == 2
        assert result["enabled"] == 1

        assert result["transports"] == [
                 %{
                   "transportId" => "email",
                   "module" => "Elixir.Example.EmailTransport",
                   "enabled" => false,
                   "status" => "disabled"
                 },
                 %{
                   "transportId" => "webhook",
                   "module" => "Elixir.Example.WebhookTransport",
                   "enabled" => true,
                   "status" => "enabled"
                 }
               ]
      after
        Process.unlink(pid)
        Process.exit(pid, :kill)
      end
    end

    test "degrades safely when the registry API is missing or fails" do
      Application.put_env(
        :lemon_control_plane,
        :transport_registry_module,
        TransportRegistryMissingApiStub
      )

      {:ok, missing_api_pid} = TransportRegistryMissingApiStub.start_link(%{})

      try do
        {:ok, result} = TransportsStatus.handle(%{}, %{})
        assert result["registryRunning"] == true
        assert result["transports"] == []
      after
        Process.unlink(missing_api_pid)
        Process.exit(missing_api_pid, :kill)
      end

      Application.put_env(
        :lemon_control_plane,
        :transport_registry_module,
        TransportRegistryCrashingStub
      )

      {:ok, crashing_pid} = TransportRegistryCrashingStub.start_link(%{})

      try do
        {:ok, result} = TransportsStatus.handle(%{}, %{})

        assert result["registryRunning"] == true

        assert result["transports"] == [
                 %{
                   "transportId" => "email",
                   "module" => nil,
                   "enabled" => false,
                   "status" => "disabled"
                 }
               ]
      after
        Process.unlink(crashing_pid)
        Process.exit(crashing_pid, :kill)
      end
    end
  end

  describe "introspection.snapshot" do
    test "returns a consolidated introspection payload", %{
      agent_id: agent_id,
      session_key: session_key,
      requirements_cwd: requirements_cwd
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

      assert Enum.any?(result["activeSessions"], &(&1["sessionKey"] == session_key))

      assert session = Enum.find(result["activeSessions"], &(&1["sessionKey"] == session_key))
      assert is_map(session["harness"])
      assert session["harness"]["todos"]["total"] == 1

      assert session["harness"]["requirements"]["project_name"] ==
               "Control Plane Harness Projection"

      assert session["harness"]["requirements"]["cwd"] == requirements_cwd
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

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)

  defp restore_session_coordinator(nil),
    do: Application.delete_env(:lemon_router, :session_coordinator)

  defp restore_session_coordinator(config) do
    Application.put_env(:lemon_router, :session_coordinator, config)
  end

  defp restore_transport_registry_module(nil) do
    Application.delete_env(:lemon_control_plane, :transport_registry_module)
  end

  defp restore_transport_registry_module(config) do
    Application.put_env(:lemon_control_plane, :transport_registry_module, config)
  end
end
