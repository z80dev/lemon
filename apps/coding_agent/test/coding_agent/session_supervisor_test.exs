defmodule CodingAgent.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SessionRegistry
  alias CodingAgent.SessionSupervisor

  import LemonPlatformTest.Testing.AsyncHelpers

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

  describe "supervisor and registry overrides" do
    setup do
      unique = System.unique_integer([:positive])
      registry = Module.concat([__MODULE__, "Registry#{unique}"])
      supervisor = Module.concat([__MODULE__, "Supervisor#{unique}"])
      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({SessionSupervisor, name: supervisor})
      {:ok, target: [supervisor: supervisor, registry: registry]}
    end

    defp start_isolated(target, opts \\ []) do
      [
        cwd: session_cwd(),
        model: mock_model(),
        tools: [],
        extension_inventory: {[], []},
        mcp_tools: []
      ]
      |> Keyword.merge(target)
      |> Keyword.merge(opts)
      |> SessionSupervisor.start_session()
    end

    test "start_session(supervisor:) starts the session under the supplied supervisor", %{
      target: target
    } do
      session_id = "override-#{System.unique_integer([:positive])}"
      {:ok, pid} = start_isolated(target, session_id: session_id)

      assert SessionSupervisor.list_sessions(target) == [pid]
      refute pid in SessionSupervisor.list_sessions()
      assert {:ok, ^pid} = SessionSupervisor.lookup(session_id, target)
      assert :error = SessionSupervisor.lookup(session_id)
      assert {:error, :not_found} = SessionSupervisor.stop_session(session_id)

      ref = Process.monitor(pid)
      assert :ok = SessionSupervisor.stop_session(session_id, target)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert SessionSupervisor.list_sessions(target) == []

      # Registry cleanup: the id is released once the session is gone.
      assert_eventually(fn -> SessionSupervisor.lookup(session_id, target) == :error end,
        message: "session id still registered"
      )
    end

    test "unknown ids and stopped pids return {:error, :not_found}", %{target: target} do
      assert :error = SessionSupervisor.lookup("unknown-session", target)
      assert {:error, :not_found} = SessionSupervisor.stop_session("unknown-session", target)

      {:ok, pid} = start_isolated(target)
      assert :ok = SessionSupervisor.stop_session(pid, target)
      assert {:error, :not_found} = SessionSupervisor.stop_session(pid, target)
    end

    test "a crashed session is not restarted and leaves its siblings running", %{target: target} do
      session_id = "crash-#{System.unique_integer([:positive])}"
      {:ok, crashed} = start_isolated(target, session_id: session_id)
      {:ok, sibling} = start_isolated(target)
      supervisor = GenServer.whereis(target[:supervisor])

      kill_and_await(crashed)

      assert_eventually(fn -> SessionSupervisor.list_sessions(target) == [sibling] end,
        message: "crashed session still listed or restarted"
      )

      assert_eventually(fn -> SessionSupervisor.lookup(session_id, target) == :error end,
        message: "crashed session id still registered"
      )

      assert Process.alive?(sibling)
      assert GenServer.whereis(target[:supervisor]) == supervisor
    end

    test "list_sessions returns [] when the supervisor is not running" do
      assert SessionSupervisor.list_sessions(supervisor: Module.concat(__MODULE__, Missing)) == []
    end

    test "very long session ids get a bounded journal file name", %{target: target} do
      long_id =
        String.duplicate("a", 256) <> Integer.to_string(System.unique_integer([:positive]))

      {:ok, pid} = start_isolated(target, session_id: long_id)

      assert {:ok, ^pid} = SessionSupervisor.lookup(long_id, target)
      state = CodingAgent.Session.get_state(pid)
      assert File.regular?(state.session_file)
      assert byte_size(Path.basename(state.session_file)) < 255
      assert {:ok, journal} = CodingAgent.SessionManager.load_from_file(state.session_file)
      assert journal.header.id == long_id
    end

    test "native identities cannot escape the session journal directory", %{target: target} do
      session_id = "../escaped-session-#{System.unique_integer([:positive])}"
      {:ok, pid} = start_isolated(target, session_id: session_id)
      state = CodingAgent.Session.get_state(pid)

      assert Path.dirname(state.session_file) ==
               CodingAgent.SessionManager.get_session_dir(state.cwd)

      assert {:ok, journal} = CodingAgent.SessionManager.load_from_file(state.session_file)
      assert journal.header.id == session_id
    end
  end
end
