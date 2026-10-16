defmodule CodingAgent.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SessionRegistry
  alias CodingAgent.SessionSupervisor

  import CodingAgent.AsyncHelpers

  defp stop_all_sessions do
    for pid <- SessionSupervisor.list_sessions() do
      SessionSupervisor.stop_session(pid)
    end

    assert_eventually(fn -> SessionSupervisor.list_sessions() == [] end,
      message: "sessions were not stopped"
    )
  end

  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    :ok
  end

  setup_all do
    cwd =
      Path.join(System.tmp_dir!(), "session_supervisor_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)
    :persistent_term.put({__MODULE__, :cwd}, cwd)

    on_exit(fn ->
      :persistent_term.erase({__MODULE__, :cwd})
      File.rm_rf(cwd)
    end)

    :ok
  end

  # Session init scans the working directory; use a small, empty one.
  defp session_cwd, do: :persistent_term.get({__MODULE__, :cwd})

  setup do
    unless Process.whereis(SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: SessionRegistry})
    end

    unless Process.whereis(SessionSupervisor) do
      start_supervised!(SessionSupervisor)
    end

    :ok
  end

  defp mock_model(opts \\ []) do
    %LemonAi.Types.Model{
      id: Keyword.get(opts, :id, "mock-model"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: :mock_api,
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: "",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 10_000,
      max_tokens: 1_000,
      headers: %{},
      compat: nil
    }
  end

  test "starts supervised sessions without linking to caller and registers them" do
    {:ok, pid} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())
    assert Process.alive?(pid)

    {:links, links} = Process.info(self(), :links)
    refute pid in links

    stats = CodingAgent.Session.get_stats(pid)
    assert {:ok, ^pid} = SessionRegistry.lookup(stats.session_id)
  end

  for registration <- [:supervised, :unregistered, :custom_registry] do
    @registration registration
    test "killing #{@registration} native session expires untimed approval after pre-approval worker restart" do
      alias LemonCore.{ExecApprovalExpiry, ExecApprovals, ExecApprovalStore}

      pid =
        case @registration do
          :supervised ->
            {:ok, pid} =
              SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())

            pid

          :unregistered ->
            start_supervised!(
              Supervisor.child_spec(
                {CodingAgent.Session, cwd: session_cwd(), model: mock_model(), register: false},
                restart: :temporary
              )
            )

          :custom_registry ->
            registry = Module.concat(__MODULE__, CustomRegistry)
            start_supervised!({Registry, keys: :unique, name: registry})

            opts = [
              cwd: session_cwd(),
              model: mock_model(),
              register: true,
              registry: registry
            ]

            start_supervised!(
              Supervisor.child_spec({CodingAgent.Session, opts}, restart: :temporary)
            )
        end

      :ok = Supervisor.terminate_child(LemonCore.Supervisor, ExecApprovalExpiry)
      {:ok, _worker} = Supervisor.restart_child(LemonCore.Supervisor, ExecApprovalExpiry)
      %{session_id: session_id} = CodingAgent.Session.get_stats(pid)
      session_key = "agent:session_death:#{session_id}"
      agent_id = "session_death_#{session_id}"
      action = %{command: "native-session-death-#{session_id}"}
      :ok = LemonCore.Bus.subscribe("exec_approvals")

      waiter =
        Task.async(fn ->
          ExecApprovals.request(%{
            session_id: session_id,
            session_key: session_key,
            agent_id: agent_id,
            tool: "bash",
            action: action,
            expires_in_ms: :infinity
          })
        end)

      assert_receive %LemonCore.Event{
                       type: :approval_requested,
                       payload: %{pending: %{id: approval_id, session_id: ^session_id} = pending}
                     },
                     2_000

      assert pending.run_id == nil
      assert pending.expires_at_ms == nil
      assert {:ok, ^pending} = ExecApprovalStore.fetch_pending(approval_id)
      assert pending.owner_session_pid == pid
      kill_and_await(pid)
      assert {:ok, :denied} = Task.await(waiter, 2_000)

      assert_receive %LemonCore.Event{
                       type: :approval_resolved,
                       payload: %{approval_id: ^approval_id, decision: :expired}
                     },
                     2_000

      assert {:ok, nil} = ExecApprovalStore.fetch_pending(approval_id)

      assert {:ok, %{resolution: %{outcome: :expired, decision: :expired, run_id: nil}}} =
               ExecApprovalStore.fetch_record(approval_id)

      for decision <- [:approve_once, :approve_session, :approve_agent, :approve_global, :deny] do
        assert {:error, :expired} = ExecApprovals.resolve(approval_id, decision)
      end

      action_hash =
        :crypto.hash(:sha256, :erlang.term_to_binary(action))
        |> Base.encode16(case: :lower)
        |> String.slice(0, 16)

      assert ExecApprovalStore.get_global_policy("bash", action_hash) == nil
      assert ExecApprovalStore.get_session_policy(session_key, "bash", action_hash) == nil
      assert ExecApprovalStore.get_agent_policy(agent_id, "bash", action_hash) == nil
      assert {:ok, 0} = ExecApprovals.expire_owner({:session, session_id})
    end
  end

  test "stop_session terminates by pid and session_id" do
    {:ok, pid} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())
    ref = Process.monitor(pid)
    assert :ok = SessionSupervisor.stop_session(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    {:ok, pid2} =
      SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model(id: "mock-2"))

    stats2 = CodingAgent.Session.get_stats(pid2)

    ref2 = Process.monitor(pid2)
    assert :ok = SessionSupervisor.stop_session(stats2.session_id)
    assert_receive {:DOWN, ^ref2, :process, ^pid2, _}, 1_000
  end

  describe "health_all/0" do
    test "returns empty list when no sessions" do
      stop_all_sessions()

      assert SessionSupervisor.health_all() == []
    end

    test "returns health status for all sessions" do
      {:ok, _pid1} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model(id: "mock-2"))

      health_results = SessionSupervisor.health_all()

      assert length(health_results) >= 2
      assert Enum.all?(health_results, &Map.has_key?(&1, :status))
      assert Enum.all?(health_results, &Map.has_key?(&1, :session_id))
    end

    test "new sessions are healthy" do
      {:ok, _pid} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())

      health_results = SessionSupervisor.health_all()
      healthy_sessions = Enum.filter(health_results, &(&1.status == :healthy))

      assert healthy_sessions != []
    end

    test "sorts by status (unhealthy first)" do
      {:ok, pid1} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model(id: "mock-2"))

      # Kill the agent of the first session to make it unhealthy
      state = CodingAgent.Session.get_state(pid1)
      kill_and_await(state.agent)

      health_results = SessionSupervisor.health_all()

      # First result should be unhealthy
      assert List.first(health_results).status == :unhealthy
    end
  end

  describe "health_summary/0" do
    test "returns no_sessions when no active sessions" do
      stop_all_sessions()

      summary = SessionSupervisor.health_summary()

      assert summary.total == 0
      assert summary.healthy == 0
      assert summary.degraded == 0
      assert summary.unhealthy == 0
      assert summary.overall == :no_sessions
    end

    test "returns healthy when all sessions are healthy" do
      stop_all_sessions()

      {:ok, _pid1} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model(id: "mock-2"))

      summary = SessionSupervisor.health_summary()

      assert summary.total >= 2
      assert summary.healthy >= 2
      assert summary.overall == :healthy
    end

    test "returns unhealthy when any session is unhealthy" do
      {:ok, pid1} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model(id: "mock-2"))

      # Kill the agent of the first session to make it unhealthy
      state = CodingAgent.Session.get_state(pid1)
      kill_and_await(state.agent)

      summary = SessionSupervisor.health_summary()

      assert summary.unhealthy >= 1
      assert summary.overall == :unhealthy
    end

    test "returns correct counts" do
      stop_all_sessions()

      # Start exactly 3 sessions
      {:ok, _pid1} = SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model(id: "mock-2"))

      {:ok, _pid3} =
        SessionSupervisor.start_session(cwd: session_cwd(), model: mock_model(id: "mock-3"))

      summary = SessionSupervisor.health_summary()

      assert summary.total == 3
      assert summary.healthy + summary.degraded + summary.unhealthy == 3
    end
  end
end
