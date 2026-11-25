defmodule LemonGateway.ApplicationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{Health, IngressSupervisor, TaskSupervisor, TransportSupervisor}

  setup do
    keys = [:gateway_ingress_enabled, :health_enabled, :health_port]
    previous = Map.new(keys, &{&1, Application.fetch_env(:lemon_gateway, &1)})
    was_running? = is_pid(Process.whereis(LemonGateway.Supervisor))

    on_exit(fn ->
      Application.stop(:lemon_gateway)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_gateway, key, value)
        {key, :error} -> Application.delete_env(:lemon_gateway, key)
      end)

      if was_running?, do: Application.ensure_all_started(:lemon_gateway)
    end)

    Application.stop(:lemon_gateway)
    Application.delete_env(:lemon_gateway, :gateway_ingress_enabled)
    Application.put_env(:lemon_gateway, :health_enabled, true)
    Application.put_env(:lemon_gateway, :health_port, 0)
    :ok
  end

  test "default startup is an empty satellite even with health enabled" do
    Application.delete_env(:lemon_gateway, :health_port)
    assert {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    assert Process.whereis(LemonGateway.Supervisor)
    assert Supervisor.which_children(LemonGateway.Supervisor) == []
    refute Process.whereis(TransportSupervisor)
  end

  test "opt-in starts only the ingress, bounded voice tasks and health listener" do
    enable_ingress()

    assert child_ids() == Enum.sort([TaskSupervisor, Health.Server, IngressSupervisor])
    assert Process.whereis(TransportSupervisor)

    assert {:ok, %{start: {Task.Supervisor, :start_link, [opts]}}} =
             :supervisor.get_childspec(LemonGateway.Supervisor, TaskSupervisor)

    assert opts[:max_children] == 1024

    ingress_ids = for {id, _pid, _, _} <- Supervisor.which_children(IngressSupervisor), do: id

    for child <- [
          LemonGateway.TransportRegistry,
          TransportSupervisor,
          LemonGateway.Voice.CallRegistry,
          LemonGateway.Voice.DeepgramRegistry,
          LemonGateway.Voice.CallSessionSupervisor,
          LemonGateway.Voice.DeepgramSupervisor
        ] do
      assert child in ingress_ids
    end
  end

  test "health can be independently disabled without disabling ingress" do
    Application.put_env(:lemon_gateway, :health_enabled, false)
    enable_ingress()

    assert child_ids() == Enum.sort([TaskSupervisor, IngressSupervisor])
  end

  test "stopping ingress terminates its children and frees names for restart" do
    enable_ingress()

    children =
      for {_id, pid, _type, _modules} <- Supervisor.which_children(LemonGateway.Supervisor),
          do: {pid, Process.monitor(pid)}

    assert :ok = Application.stop(:lemon_gateway)

    for {pid, monitor} <- children do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}
    end

    for name <- [LemonGateway.Supervisor, TaskSupervisor, IngressSupervisor, TransportSupervisor] do
      refute Process.whereis(name)
    end

    assert {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    assert child_ids() == Enum.sort([TaskSupervisor, Health.Server, IngressSupervisor])
  end

  defp enable_ingress do
    Application.put_env(:lemon_gateway, :gateway_ingress_enabled, true)
    assert {:ok, _} = Application.ensure_all_started(:lemon_gateway)
  end

  defp child_ids do
    LemonGateway.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {id, pid, _type, _modules} ->
      assert is_pid(pid) and Process.alive?(pid)
      id
    end)
    |> Enum.sort()
  end
end
