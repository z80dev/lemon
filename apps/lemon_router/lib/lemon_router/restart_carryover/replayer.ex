defmodule LemonRouter.RestartCarryover.Replayer do
  @moduledoc """
  Boot task that replays work carried across the previous graceful restart.

  Replies to carried conversations are delivered by channel adapters, so replay
  waits until the applications named by
  `config :lemon_router, :restart_replay_after` (default: `:lemon_channels` and
  `:lemon_control_plane`) have started, for at most two minutes. With nothing
  persisted it exits immediately.
  """

  use Task, restart: :temporary

  require Logger

  alias LemonRouter.RestartCarryover

  @wait_ms 120_000
  @poll_ms 250

  def start_link(_opts), do: Task.start_link(&run/0)

  defp run do
    case LemonCore.Store.fetch_all(RestartCarryover.table()) do
      {:ok, [_ | _]} ->
        await_apps(after_apps(), System.monotonic_time(:millisecond) + @wait_ms)
        RestartCarryover.replay()

      _nothing_or_unavailable ->
        :ok
    end
  end

  defp after_apps,
    do: Application.get_env(:lemon_router, :restart_replay_after, [:lemon_channels, :lemon_control_plane])

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
