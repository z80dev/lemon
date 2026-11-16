defmodule LemonAi.StreamTaskSupervisorTest do
  use ExUnit.Case, async: false

  alias LemonAi.{CallDispatcher, StreamTaskSupervisor}
  alias LemonAi.Providers.StreamingHelper
  alias LemonAi.Types.{Context, Model, StreamOptions}

  test "child specs have a finite default and honor local configuration" do
    previous = Application.fetch_env(:lemon_ai, :task_supervisor_max_children)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lemon_ai, :task_supervisor_max_children, value)
        :error -> Application.delete_env(:lemon_ai, :task_supervisor_max_children)
      end
    end)

    Application.delete_env(:lemon_ai, :task_supervisor_max_children)

    assert %{start: {Task.Supervisor, :start_link, [defaults]}} =
             StreamTaskSupervisor.child_spec([])

    assert defaults[:max_children] == 1024
    assert defaults[:name] == StreamTaskSupervisor

    Application.put_env(:lemon_ai, :task_supervisor_max_children, %{StreamTaskSupervisor => 3})

    assert %{start: {Task.Supervisor, :start_link, [configured]}} =
             StreamTaskSupervisor.child_spec([])

    assert configured[:max_children] == 3

    assert %{start: {Task.Supervisor, :start_link, [explicit]}} =
             StreamTaskSupervisor.child_spec(max_children: 2)

    assert explicit[:max_children] == 2

    for limit <- [0, -1, :infinity] do
      assert_raise ArgumentError, fn -> StreamTaskSupervisor.child_spec(max_children: limit) end
    end
  end

  describe "bounded stream admission" do
    setup do
      :ok = Supervisor.terminate_child(LemonAi.Supervisor, StreamTaskSupervisor)

      on_exit(fn ->
        {:ok, _pid} = Supervisor.restart_child(LemonAi.Supervisor, StreamTaskSupervisor)
      end)

      supervisor = start_supervised!({StreamTaskSupervisor, max_children: 1})
      %{supervisor: supervisor}
    end

    test "capacity rejects work once and admits new work after a slot is released", %{
      supervisor: supervisor
    } do
      parent = self()
      {:ok, blocker} = StreamTaskSupervisor.start_child(fn -> receive do: (:finish -> :ok) end)

      assert {:error, :task_capacity_reached} =
               StreamTaskSupervisor.start_child(fn -> send(parent, :rejected_work_ran) end)

      refute_received :rejected_work_ran
      assert Task.Supervisor.children(supervisor) == [blocker]
      :ok = Task.Supervisor.terminate_child(supervisor, blocker)

      assert {:ok, _pid} =
               StreamTaskSupervisor.start_child(fn -> send(parent, :accepted_work_ran) end)

      assert_receive :accepted_work_ran
      refute_received :rejected_work_ran
    end

    test "provider launch rejection returns an error and closes its unused stream" do
      parent = self()
      {:ok, _blocker} = StreamTaskSupervisor.start_child(fn -> receive do: (:finish -> :ok) end)
      {:links, before_links} = Process.info(self(), :links)

      assert {:error, :task_capacity_reached} =
               StreamingHelper.start_streaming(%Model{}, %Context{}, %StreamOptions{}, fn _,
                                                                                          _,
                                                                                          _,
                                                                                          _ ->
                 send(parent, :provider_invoked)
               end)

      {:links, after_links} = Process.info(self(), :links)
      assert MapSet.new(after_links) == MapSet.new(before_links)
      refute_received :provider_invoked
    end

    test "an unavailable supervisor rejects helper and provider work without exiting" do
      stop_supervised!(StreamTaskSupervisor)
      parent = self()

      assert {:error, :task_supervisor_unavailable} =
               StreamTaskSupervisor.start_child(fn -> send(parent, :unexpected_work) end)

      assert {:error, :task_supervisor_unavailable} =
               StreamingHelper.start_streaming(%Model{}, %Context{}, %StreamOptions{}, fn _,
                                                                                          _,
                                                                                          _,
                                                                                          _ ->
                 send(parent, :unexpected_work)
               end)

      refute_received :unexpected_work
    end

    test "tracker rejection cancels already-started work and reports an unknown outcome" do
      parent = self()
      provider = "task_capacity_#{System.unique_integer([:positive])}"
      model = %Model{id: "capacity-test", api: :test, provider: provider}

      assert {:error, :outcome_unknown} =
               CallDispatcher.dispatch(provider, fn ->
                 {:ok, stream} =
                   StreamingHelper.start_streaming(model, %Context{}, %StreamOptions{}, fn _,
                                                                                           _,
                                                                                           _,
                                                                                           _ ->
                     send(parent, {:provider_invoked, self()})
                     receive do: (:finish -> :ok)
                   end)

                 assert_receive {:provider_invoked, worker}
                 monitor = Process.monitor(worker)
                 send(parent, {:tracked_worker, worker, monitor, stream})
                 {:ok, stream}
               end)

      assert_receive {:tracked_worker, worker, monitor, stream}
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
      refute Process.alive?(stream)
      assert CallDispatcher.get_active_requests(provider) == 0
      refute_received {:provider_invoked, _}
    end
  end

  test "task admission and unknown-outcome errors never trigger automatic provider retry" do
    for reason <- [:task_capacity_reached, :task_supervisor_unavailable, :outcome_unknown] do
      refute LemonAi.Error.retryable?(reason)
    end
  end
end
