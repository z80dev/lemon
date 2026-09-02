defmodule LemonAutomation.SkillCuratorManagerTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.SkillCuratorManager

  @pid_key {__MODULE__, :test_pid}

  defmodule UnexpectedCurator do
    def should_run_now?(_opts) do
      send(
        :persistent_term.get({LemonAutomation.SkillCuratorManagerTest, :test_pid}),
        :curator_queried
      )

      true
    end

    def run(_opts) do
      send(
        :persistent_term.get({LemonAutomation.SkillCuratorManagerTest, :test_pid}),
        :curator_run
      )

      {:ok, %{review_required: false}}
    end
  end

  setup do
    :persistent_term.put(@pid_key, self())

    on_exit(fn ->
      reset_manager()
      :persistent_term.erase(@pid_key)
    end)

    :ok
  end

  test "active-session query failures fail closed without launching curator work" do
    failing_queries = [
      fn -> {:error, :unavailable} end,
      fn -> raise "registry unavailable" end,
      fn -> exit(:registry_unavailable) end
    ]

    Enum.each(failing_queries, fn active_sessions_fun ->
      set_opts(
        enabled: true,
        min_idle_hours: 0,
        curator_mod: UnexpectedCurator,
        active_sessions_fun: active_sessions_fun,
        tick_interval_ms: 3_600_000
      )

      :ok = SkillCuratorManager.tick()
      _ = :sys.get_state(SkillCuratorManager)

      refute_receive :curator_queried, 100
      refute_receive :curator_run, 100
      assert is_nil(:sys.get_state(SkillCuratorManager).in_flight_ref)
    end)
  end

  defp set_opts(opts) do
    :sys.replace_state(SkillCuratorManager, fn state ->
      %{state | opts: opts, last_busy_at_ms: 0, in_flight_ref: nil}
    end)
  end

  defp reset_manager do
    if Process.whereis(SkillCuratorManager) do
      :sys.replace_state(SkillCuratorManager, fn state ->
        %{state | opts: [], last_busy_at_ms: LemonCore.Clock.now_ms(), in_flight_ref: nil}
      end)
    end
  end
end
