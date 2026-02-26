defmodule LemonGames.Matches.DeadlineSweeper do
  @moduledoc "Periodic sweeper for expired match deadlines."

  use GenServer
  require Logger

  @sweep_interval_ms 1_000
  @match_table :game_matches

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep do
    now = System.system_time(:millisecond)

    @match_table
    |> LemonCore.Store.list()
    |> Enum.each(fn {_key, match} ->
      cond do
        match["status"] in ["finished", "expired", "aborted"] ->
          :ok

        match["deadline_at_ms"] > 0 and match["deadline_at_ms"] < now ->
          reason =
            if match["status"] == "pending_accept",
              do: "accept_timeout",
              else: "turn_timeout"

          case LemonGames.Matches.Service.expire_match(match["id"], reason) do
            {:ok, _} ->
              Logger.info("[DeadlineSweeper] Expired match #{match["id"]}: #{reason}")

            {:error, _, _} ->
              :ok
          end

        true ->
          :ok
      end
    end)
  end
end
