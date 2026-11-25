defmodule LemonPlatformTest.AppRestartTest do
  use ExUnit.Case, async: false

  import LemonPlatformTest.AppRestart

  @running :lemon_test_running_app
  @stopped :lemon_test_stopped_app
  @dependency :lemon_test_app_dependency
  @unrelated :lemon_test_unrelated_app
  @system_key "LEMON_PLATFORM_TEST_APP_RESTART"
  @event [:lemon_platform_test, :app_restart]

  defmodule FixtureApp do
    use Application

    @impl true
    def start(_type, name) do
      Supervisor.start_link([], strategy: :one_for_one, name: name)
    end
  end

  setup do
    load_app(@running)
    load_app(@dependency)
    load_app(@stopped, [@dependency])
    load_app(@unrelated)
    :ok = Application.start(@running)
    :ok = Application.start(@unrelated)

    on_exit(fn ->
      for app <- [@unrelated, @stopped, @dependency, @running] do
        Application.stop(app)
        Application.unload(app)
      end
    end)

    :ok
  end

  test "restores the original running set, env, and owned handlers after a failure" do
    running_set = started_apps()
    original_pid = Process.whereis(@running)
    unrelated_pid = Process.whereis(@unrelated)
    old_system = System.get_env(@system_key)

    on_exit(fn ->
      if old_system,
        do: System.put_env(@system_key, old_system),
        else: System.delete_env(@system_key)
    end)

    System.put_env(@system_key, "original")

    test_handler = make_ref()
    existing_handler = make_ref()
    baseline = length(:telemetry.list_handlers(@event))
    :ok = :telemetry.attach(existing_handler, @event, &__MODULE__.handle_event/4, nil)
    on_exit(fn -> :telemetry.detach(existing_handler) end)

    # A configured nil and a missing key are distinct application env states.
    Application.put_env(@running, :present, nil)

    env = [
      app_env: [{@running, :present}, {@running, :absent}],
      system_env: [@system_key],
      telemetry: [test_handler]
    ]

    assert_raise RuntimeError, "failed test", fn ->
      with_app_restart([@running, @stopped], env, fn ->
        refute Process.whereis(@running)
        refute Process.whereis(@stopped)
        assert Process.whereis(@unrelated) == unrelated_pid

        assert {:ok, [@dependency, @stopped]} = Application.ensure_all_started(@stopped)
        :ok = Application.start(@running)
        Application.put_env(@running, :present, :changed)
        Application.put_env(@running, :absent, :introduced)
        System.put_env(@system_key, "changed")
        :ok = :telemetry.attach(test_handler, @event, &__MODULE__.handle_event/4, nil)
        assert length(:telemetry.list_handlers(@event)) == baseline + 2
        raise "failed test"
      end)
    end

    assert started_apps() == running_set
    assert is_pid(Process.whereis(@running))
    refute Process.whereis(@running) == original_pid
    assert Process.whereis(@unrelated) == unrelated_pid
    assert Application.fetch_env(@running, :present) == {:ok, nil}
    assert Application.fetch_env(@running, :absent) == :error
    assert System.get_env(@system_key) == "original"
    assert length(:telemetry.list_handlers(@event)) == baseline + 1
    assert Enum.any?(:telemetry.list_handlers(@event), &(&1.id == existing_handler))
  end

  test "can defer restoration until ExUnit teardown" do
    on_exit(fn -> assert @running in started_apps() end)
    assert :ok = setup_app_restart([@running], [])
    refute @running in started_apps()
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp started_apps do
    Application.started_applications() |> MapSet.new(&elem(&1, 0))
  end

  defp load_app(name, dependencies \\ []) do
    :ok =
      :application.load(
        {:application, name,
         [
           vsn: ~c"1",
           applications: [:kernel, :stdlib | dependencies],
           mod: {FixtureApp, name}
         ]}
      )
  end
end
