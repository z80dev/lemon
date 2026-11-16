defmodule LemonRouter.SupervisionTest do
  use ExUnit.Case, async: false

  test "conversation and output registries precede their supervised dependants" do
    expected_groups = [
      {LemonRouter.ConversationSupervisor,
       [
         LemonRouter.RunRegistry,
         LemonRouter.SessionRegistry,
         LemonRouter.ConversationRegistry,
         LemonRouter.RunSupervisor,
         LemonRouter.SessionCoordinatorSupervisor,
         LemonRouter.RunCountTracker,
         LemonRouter.RunOrchestrator,
         LemonRouter.AgentMessaging,
         LemonRouter.RestartCarryover.Replayer
       ]},
      {LemonRouter.CoalescingSupervisor,
       [LemonRouter.CoalescerRegistry, LemonRouter.CoalescerSupervisor]},
      {LemonRouter.ToolStatusTree,
       [LemonRouter.ToolStatusRegistry, LemonRouter.ToolStatusSupervisor]},
      {LemonRouter.AsyncTaskSurfaceTree,
       [LemonRouter.AsyncTaskSurfaceRegistry, LemonRouter.AsyncTaskSurfaceSupervisor]}
    ]

    for {name, expected} <- expected_groups do
      assert {:ok, %{start: {Supervisor, :start_link, [children, opts]}}} =
               :supervisor.get_childspec(LemonRouter.Supervisor, name)

      assert opts[:strategy] == :rest_for_one
      assert opts[:max_restarts] == 10
      assert opts[:max_seconds] == 5
      assert Enum.map(children, &Supervisor.child_spec(&1, []).id) == expected
    end
  end
end
