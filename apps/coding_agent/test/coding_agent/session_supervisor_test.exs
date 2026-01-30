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

    {:ok, pid2} = SessionSupervisor.start_session(cwd: System.tmp_dir!(), model: mock_model(id: "mock-2"))
    stats2 = CodingAgent.Session.get_stats(pid2)

    ref2 = Process.monitor(pid2)
    assert :ok = SessionSupervisor.stop_session(stats2.session_id)
    assert_receive {:DOWN, ^ref2, :process, ^pid2, _}, 1_000
  end
end
