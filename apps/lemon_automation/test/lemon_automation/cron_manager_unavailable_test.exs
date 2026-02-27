defmodule LemonAutomation.CronManagerUnavailableTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.CronManager

  @moduledoc """
  Tests verifying that CronManager GenServer.call sites with explicit
  @call_timeout_ms 10_000 raise :exit when the process is unavailable,
  and that the Gateway tool layer handles this gracefully.
  """

  describe "CronManager calls when process is unavailable" do
    setup do
      # Unregister the CronManager name so GenServer.call exits with
      # :noproc. We cannot simply GenServer.stop because the supervision
      # tree restarts it immediately.
      unregister_cron_manager!()

      on_exit(fn ->
        re_register_cron_manager()
      end)

      :ok
    end

    test "list/0 exits when CronManager is not running" do
      assert catch_exit(CronManager.list()) != nil
    end

    test "add/1 exits when CronManager is not running" do
      assert catch_exit(CronManager.add(%{name: "test"})) != nil
    end

    test "remove/1 exits when CronManager is not running" do
      assert catch_exit(CronManager.remove("cron_nonexistent")) != nil
    end

    test "run_now/1 exits when CronManager is not running" do
      assert catch_exit(CronManager.run_now("cron_nonexistent")) != nil
    end

    test "runs/1 exits when CronManager is not running" do
      assert catch_exit(CronManager.runs("cron_nonexistent")) != nil
    end

    test "update/2 exits when CronManager is not running" do
      assert catch_exit(CronManager.update("cron_nonexistent", %{enabled: false})) != nil
    end
  end

  describe "Gateway tool layer handles CronManager unavailability" do
    setup do
      unregister_cron_manager!()

      on_exit(fn ->
        re_register_cron_manager()
      end)

      :ok
    end

    test "cron tool list action returns error instead of crashing" do
      tool_mod = Module.concat([LemonGateway, Tools, Cron])

      if Code.ensure_loaded?(tool_mod) and function_exported?(tool_mod, :tool, 2) do
        session_key = LemonCore.SessionKey.main("default")
        tool = tool_mod.tool(".", session_key: session_key, agent_id: "default")

        # The tool's execute wraps GenServer.call in a try/catch :exit block
        # via cron_call/2, so it should return an error result, not crash.
        result = tool.execute.("call_1", %{"action" => "list"}, nil, nil)

        text = AgentCore.get_text(result)

        # ensure_scheduler_started checks Process.whereis first, and since
        # the name is unregistered, it returns an error about unavailability.
        assert text =~ "unavailable" or text =~ "not running" or
                 text =~ "failed" or text =~ "not started"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unregister_cron_manager! do
    pid = Process.whereis(CronManager)

    if pid do
      Process.unregister(CronManager)
    end
  end

  defp re_register_cron_manager do
    case Process.whereis(CronManager) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        # The process may still be alive under the supervisor but unnamed.
        # Walk LemonAutomation.Supervisor children to find it and re-register.
        supervisor = Module.concat([LemonAutomation, Supervisor])

        children =
          try do
            Supervisor.which_children(supervisor)
          rescue
            _ -> []
          catch
            :exit, _ -> []
          end

        cm_child =
          Enum.find(children, fn
            {LemonAutomation.CronManager, pid, _, _} when is_pid(pid) -> Process.alive?(pid)
            _ -> false
          end)

        case cm_child do
          {_, pid, _, _} ->
            try do
              Process.register(pid, CronManager)
            rescue
              ArgumentError -> :ok
            end

          nil ->
            # Process was actually terminated. Start fresh.
            case CronManager.start_link([]) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
            end
        end
    end
  end
end
