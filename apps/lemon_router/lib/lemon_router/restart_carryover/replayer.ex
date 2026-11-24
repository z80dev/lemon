defmodule LemonRouter.RestartCarryover.Replayer do
  @moduledoc """
  Boot task that reconciles crash-orphaned admissions and graceful carryover.

  Replies to carried conversations are delivered by channel adapters, so replay
  waits until the applications named by
  `config :lemon_router, :restart_replay_after` (default: `:lemon_channels` and
  `:lemon_control_plane`) have started, for at most two minutes. Admissions are
  snapshotted before waiting, so newly accepted work is never a crash candidate.

  A recovery or replay call that exits is an unknown outcome for that fixed run
  ID alone: it stays pending for the next boot while the remaining admissions
  and carried items proceed. Carryover replay still waits for reconciliation,
  which abandons the carried items' interrupted sources first.
  """

  use Task, restart: :temporary

  require Logger

  alias LemonRouter.RestartCarryover
  alias LemonRouter.RestartCarryover.CrashRecovery

  @wait_ms 120_000
  @poll_ms 250

  def start_link(_opts), do: Task.start_link(&run/0)

  defp run do
    with {:ok, admissions} <-
           LemonCore.Store.fetch_all(LemonRouter.RunOrchestrator.admission_table()),
         {:ok, carryover} <- LemonCore.Store.fetch_all(RestartCarryover.table()) do
      if admissions != [] or carryover != [] do
        await_apps(after_apps(), System.monotonic_time(:millisecond) + @wait_ms)
        summary = CrashRecovery.reconcile(admissions, carryover: carryover)
        Logger.info("Crash recovery reconciled: #{inspect(summary)}")
        RestartCarryover.replay()
      end
    else
      _ -> Logger.error("Restart reconciliation unavailable; durable work was not dispatched")
    end
  end

  defp after_apps,
    do:
      Application.get_env(:lemon_router, :restart_replay_after, [
        :lemon_channels,
        :lemon_control_plane
      ])

  defp await_apps(apps, deadline) do
    started = MapSet.new(Application.started_applications(), &elem(&1, 0))

    cond do
      Enum.all?(apps, &MapSet.member?(started, &1)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("Restart carryover replay proceeding before #{inspect(apps)} started")

      true ->
        Process.sleep(@poll_ms)
        await_apps(apps, deadline)
    end
  end
end
