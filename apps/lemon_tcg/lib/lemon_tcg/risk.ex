defmodule LemonTcg.Risk do
  @moduledoc """
  Policy gate every order must pass before it reaches a venue.

  The kill switch blocks buys but never sells — de-risking must stay
  possible when the desk is halted. Daily spend is measured from the
  ledger over a trailing 24h window, so restarts don't reset the budget
  as long as the session state survives.
  """

  alias LemonTcg.{Ledger, Portfolio}

  defmodule Policy do
    @moduledoc "Risk limits for one desk session."

    defstruct max_trade_usd: 250.0,
              max_daily_spend_usd: 1_000.0,
              min_cash_reserve_usd: 50.0,
              allowed_collections: [],
              kill_switch: false

    @type t :: %__MODULE__{
            max_trade_usd: float(),
            max_daily_spend_usd: float(),
            min_cash_reserve_usd: float(),
            allowed_collections: [String.t()],
            kill_switch: boolean()
          }
  end

  @type order :: {:buy, collection :: String.t(), total_usd :: number()} | {:sell, String.t()}

  @spec check(Policy.t(), Portfolio.t(), order()) :: :ok | {:error, {:risk_blocked, term()}}
  def check(%Policy{} = policy, %Portfolio{} = portfolio, {:buy, collection, total_usd}) do
    spent_today = Ledger.spent_within(portfolio.ledger)

    cond do
      policy.kill_switch ->
        blocked(:kill_switch_engaged)

      policy.allowed_collections != [] and collection not in policy.allowed_collections ->
        blocked({:collection_not_allowed, collection})

      total_usd > policy.max_trade_usd ->
        blocked({:max_trade_exceeded, total_usd, policy.max_trade_usd})

      spent_today + total_usd > policy.max_daily_spend_usd ->
        blocked({:daily_spend_exceeded, spent_today, policy.max_daily_spend_usd})

      portfolio.cash_usd - total_usd < policy.min_cash_reserve_usd ->
        blocked({:cash_reserve_breached, portfolio.cash_usd, policy.min_cash_reserve_usd})

      true ->
        :ok
    end
  end

  def check(%Policy{}, %Portfolio{}, {:sell, _mint}), do: :ok

  defp blocked(reason), do: {:error, {:risk_blocked, reason}}
end
