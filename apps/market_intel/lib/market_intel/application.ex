defmodule MarketIntel.Application do
  @moduledoc """
  MarketIntel OTP Application

  Supervises:
  - Core infrastructure (ETS cache, SQLite repo) — always started
  - Data ingestion workers (DEX, Polymarket, Twitter, On-chain) — gated by config
  - Commentary generation pipeline — gated by config
  - Scheduler for periodic ingestion — gated by config
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = core_children() ++ optional_ingestors()

    opts = [strategy: :one_for_one, name: MarketIntel.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp core_children do
    [
      # ETS table for hot market data cache
      MarketIntel.Cache,
      # SQLite repo for time-series data
      MarketIntel.Repo
    ]
  end

  defp optional_ingestors do
    config = Application.get_env(:market_intel, :ingestion, %{})

    []
    |> maybe_add(config[:enable_dex], MarketIntel.Ingestion.DexScreener)
    |> maybe_add(config[:enable_polymarket], MarketIntel.Ingestion.Polymarket)
    |> maybe_add(config[:enable_twitter], MarketIntel.Ingestion.TwitterMentions)
    |> maybe_add(config[:enable_onchain], MarketIntel.Ingestion.OnChain)
    |> maybe_add(config[:enable_commentary], MarketIntel.Commentary.Pipeline)
    |> maybe_add(config[:enable_scheduler], MarketIntel.Scheduler)
    |> tap(fn enabled ->
      if enabled == [] do
        Logger.info("[MarketIntel] All ingestors disabled by config")
      else
        names = Enum.map(enabled, &inspect/1)
        Logger.info("[MarketIntel] Starting optional workers: #{Enum.join(names, ", ")}")
      end
    end)
  end

  defp maybe_add(children, true, child), do: children ++ [child]
  defp maybe_add(children, _falsy, _child), do: children
end
