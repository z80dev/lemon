defmodule CodingAgent.ApplicationTest do
  use ExUnit.Case, async: false

  describe "SessionSupervisor functionality" do
    test "can look up non-existent session" do
      result = CodingAgent.SessionSupervisor.lookup("non-existent-session-id")
      assert result == :error
    end
  end

  test "session, process and task registries own dependency-ordered subtrees" do
    for {name, expected} <- [
          {CodingAgent.SessionTree,
           [
             CodingAgent.SessionRegistry,
             CodingAgent.SessionSupervisor
           ]},
          {CodingAgent.ProcessSupervisor,
           [
             CodingAgent.ProcessRegistry,
             # Sessions precede the store: a store restart must not stop them.
             CodingAgent.ProcessManager,
             CodingAgent.ProcessStoreServer,
             CodingAgent.LaneQueue
           ]},
          {CodingAgent.TaskRuntime.Tree,
           [
             # The journal must survive a restart of either registry or the child owners.
             CodingAgent.TaskRuntime.Journal,
             CodingAgent.TaskRuntime.Registry,
             CodingAgent.TaskRuntime.Parents,
             CodingAgent.TaskRuntime.Supervisor
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
