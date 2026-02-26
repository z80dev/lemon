defmodule MarketIntel.Scheduler do
  @moduledoc """
  Schedules periodic market commentary generation.
  
  Intervals:
  - Every 30 min: Regular market update
  - Every 2 hours: Deep analysis thread
  - Daily: Performance recap
  """
  
  use GenServer
  require Logger
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    schedule_regular()
    schedule_deep_analysis()
    {:ok, %{last_regular: nil, last_deep: nil}}
  end
  
  @impl true
  def handle_info(:regular_commentary, state) do
    Logger.info("[MarketIntel] Triggering scheduled commentary")
    
    MarketIntel.Commentary.Pipeline.trigger(:scheduled, %{
      time_of_day: time_context()
    })
    
    schedule_regular()
    {:noreply, %{state | last_regular: DateTime.utc_now()}}
  end
  
  @impl true
  def handle_info(:deep_analysis, state) do
    Logger.info("[MarketIntel] Triggering deep analysis")
    
    # Generate longer-form analysis
    # Could be a thread instead of single tweet
    
    schedule_deep_analysis()
    {:noreply, %{state | last_deep: DateTime.utc_now()}}
  end
  
  # Private
  
  defp schedule_regular do
    # Every 30 minutes
    Process.send_after(self(), :regular_commentary, :timer.minutes(30))
  end
  
  defp schedule_deep_analysis do
    # Every 2 hours
    Process.send_after(self(), :deep_analysis, :timer.hours(2))
  end
  
  defp time_context do
    hour = DateTime.utc_now().hour
    
    cond do
      hour < 6 -> "early morning"
      hour < 12 -> "morning"
      hour < 18 -> "afternoon"
      hour < 22 -> "evening"
      true -> "late night"
    end
  end
end
