defmodule LemonTcg do
  @moduledoc """
  Live market data and execution for an agent-operated on-chain TCG shop.

  This app is the real-world counterpart of `LemonSim.Examples.TcgShop`: the
  same shop-operator tool surface, but backed by live marketplace data
  (tokenized graded cards on Solana/EVM venues) instead of a simulated world.

  ## Layers

    * `LemonTcg.MarketData` — normalized floors/listings/FX from pluggable
      sources (`Sources.MagicEden` live, `Sources.Fixture` deterministic).
    * `LemonTcg.Portfolio` + `LemonTcg.Ledger` — cash, positions,
      mark-to-market net worth, and an append-only audit trail.
    * `LemonTcg.Risk` — policy checks every order must pass (trade caps,
      daily spend, collection allowlist, cash reserve, kill switch).
    * `LemonTcg.Execution` — venue behaviour with a paper-trading venue
      (`Execution.Venues.Paper`) that fills against live quotes. On-chain
      signing venues plug in behind the same behaviour.
    * `LemonTcg.Desk` — a GenServer trading desk that owns one session and
      routes every order through risk → venue → ledger.
    * `LemonTcg.Agent.Tools` — `LemonAgent.Types.AgentTool` surface so an
      agent loop can operate the desk the same way it plays the sim.

  Paper trading works with zero credentials. `MAGIC_EDEN_API_KEY` raises
  rate limits but is optional.
  """
end
