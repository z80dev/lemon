defmodule CodingAgent.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SessionRegistry
  alias CodingAgent.SessionSupervisor

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
    %Ai.Types.Model{
      id: Keyword.get(opts, :id, "mock-model"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: :mock_api,
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: "",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 10_000,
      max_tokens: 1_000,
      headers: %{},
      compat: nil
    }
  end

  test "starts supervised sessions without linking to caller and registers them" do
    {:ok, pid} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())
    assert Process.alive?(pid)

    {:links, links} = Process.info(self(), :links)
    refute pid in links

    stats = CodingAgent.Session.get_stats(pid)
    assert {:ok, ^pid} = SessionRegistry.lookup(stats.session_id)
  end

  test "stop_session terminates by pid and session_id" do
    {:ok, pid} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())
    ref = Process.monitor(pid)
    assert :ok = SessionSupervisor.stop_session(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

    {:ok, pid2} =
      SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-2"))

    stats2 = CodingAgent.Session.get_stats(pid2)

    ref2 = Process.monitor(pid2)
    assert :ok = SessionSupervisor.stop_session(stats2.session_id)
    assert_receive {:DOWN, ^ref2, :process, ^pid2, _}, 1_000
  end

  describe "health_all/0" do
    test "returns empty list when no sessions" do
      # Stop any existing sessions
      for pid <- SessionSupervisor.list_sessions() do
        SessionSupervisor.stop_session(pid)
      end

      Process.sleep(50)

      assert SessionSupervisor.health_all() == []
    end

    test "returns health status for all sessions" do
      {:ok, _pid1} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-2"))

      health_results = SessionSupervisor.health_all()

      assert length(health_results) >= 2
      assert Enum.all?(health_results, &Map.has_key?(&1, :status))
      assert Enum.all?(health_results, &Map.has_key?(&1, :session_id))
    end

    test "new sessions are healthy" do
      {:ok, _pid} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())

      health_results = SessionSupervisor.health_all()
      healthy_sessions = Enum.filter(health_results, &(&1.status == :healthy))

      assert length(healthy_sessions) >= 1
    end

    test "sorts by status (unhealthy first)" do
      {:ok, pid1} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-2"))

      # Kill the agent of the first session to make it unhealthy
      state = CodingAgent.Session.get_state(pid1)
      Process.exit(state.agent, :kill)
      Process.sleep(50)

      health_results = SessionSupervisor.health_all()

      # First result should be unhealthy
      assert List.first(health_results).status == :unhealthy
    end
  end

  describe "health_summary/0" do
    test "returns no_sessions when no active sessions" do
      # Stop any existing sessions
      for pid <- SessionSupervisor.list_sessions() do
        SessionSupervisor.stop_session(pid)
      end

      Process.sleep(50)

      summary = SessionSupervisor.health_summary()

      assert summary.total == 0
      assert summary.healthy == 0
      assert summary.degraded == 0
      assert summary.unhealthy == 0
      assert summary.overall == :no_sessions
    end

    test "returns healthy when all sessions are healthy" do
      # Stop any existing sessions to ensure a clean slate
      for pid <- SessionSupervisor.list_sessions() do
        SessionSupervisor.stop_session(pid)
      end

      Process.sleep(50)

      {:ok, _pid1} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-2"))

      summary = SessionSupervisor.health_summary()

      assert summary.total >= 2
      assert summary.healthy >= 2
      assert summary.overall == :healthy
    end

    test "returns unhealthy when any session is unhealthy" do
      {:ok, pid1} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-2"))

      # Kill the agent of the first session to make it unhealthy
      state = CodingAgent.Session.get_state(pid1)
      Process.exit(state.agent, :kill)
      Process.sleep(50)

      summary = SessionSupervisor.health_summary()

      assert summary.unhealthy >= 1
      assert summary.overall == :unhealthy
    end

    test "returns correct counts" do
      # Clear existing sessions
      for pid <- SessionSupervisor.list_sessions() do
        SessionSupervisor.stop_session(pid)
      end

      Process.sleep(50)

      # Start exactly 3 sessions
      {:ok, _pid1} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model())

      {:ok, _pid2} =
        SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-2"))

      {:ok, _pid3} =
        SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-3"))

      summary = SessionSupervisor.health_summary()

      assert summary.total == 3
      assert summary.healthy + summary.degraded + summary.unhealthy == 3
    end
  end
end
