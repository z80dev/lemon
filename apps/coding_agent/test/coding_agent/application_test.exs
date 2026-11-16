defmodule CodingAgent.ApplicationTest do
  use ExUnit.Case, async: false

  describe "SessionSupervisor functionality" do
    test "can look up non-existent session" do
      result = CodingAgent.SessionSupervisor.lookup("non-existent-session-id")
      assert result == :error
    end
  end

  test "session and process registries own dependency-ordered subtrees" do
    for {name, expected} <- [
          {CodingAgent.SessionTree,
           [
             CodingAgent.SessionRegistry,
             CodingAgent.SessionSupervisor,
             CodingAgent.Tools.Task.LiveBridgeSupervisor
           ]},
          {CodingAgent.ProcessSupervisor,
           [
             CodingAgent.ProcessRegistry,
             CodingAgent.ProcessStoreServer,
             CodingAgent.ProcessManager,
             CodingAgent.LaneQueue
           ]}
        ] do
      assert {:ok, %{start: {Supervisor, :start_link, [children, opts]}}} =
               :supervisor.get_childspec(CodingAgent.Supervisor, name)

      assert opts[:strategy] == :rest_for_one
      assert opts[:max_restarts] == 10
      assert opts[:max_seconds] == 5

      assert Enum.map(children, &Supervisor.child_spec(&1, []).id) == expected
    end
  end
end
