defmodule LemonTcg.Desk do
  @moduledoc """
  A trading desk session: one portfolio, one risk policy, one venue.

  All mutation goes through the desk process so risk checks and portfolio
  updates are serialized. Every order follows the same path:
  quote → `LemonTcg.Risk.check/3` → venue → portfolio/ledger.

  Options:

    * `:starting_cash_usd` — default 1_000.0
    * `:policy` — `LemonTcg.Risk.Policy` struct (default policy applies)
    * `:venue` — module implementing `LemonTcg.Execution.Venue` (default
      Paper), or a map routing by the listing's market, e.g.
      `%{"collector_crypt" => Venues.CollectorCrypt, :default => Paper}`
    * `:wallet` — `{module, config}` implementing `LemonTcg.Wallet`;
      passed to live venues (default refuses to sign)
    * `:watchlist` — collection symbols the desk trades; entries may be
      venue-qualified per `LemonTcg.Markets` ("collector_crypt:Pokemon",
      "opensea:courtyard-nft")
    * `:market_opts` — keyword passed to market data and venue calls
      (`:source`, `:req_options`, fee/haircut tuning)
  """

  use GenServer

  alias LemonTcg.Execution.Venues.Paper
  alias LemonTcg.{Basis, Comps, Fx, MarketData, Portfolio, Risk}
  alias LemonTcg.Risk.Policy

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Portfolio marked against current floors, plus session config."
  def snapshot(desk), do: GenServer.call(desk, :snapshot, 30_000)

  def watchlist(desk), do: GenServer.call(desk, :watchlist)

  def floor(desk, collection), do: GenServer.call(desk, {:floor, collection}, 30_000)

  def listings(desk, collection, limit \\ 10),
    do: GenServer.call(desk, {:listings, collection, limit}, 30_000)

  @doc "Grade-matched physical comp for a card (see `LemonTcg.Comps.comp_for_grade/3`)."
  def comp(desk, query, grade \\ nil), do: GenServer.call(desk, {:comp, query, grade}, 30_000)

  @doc """
  Token-vs-physical basis for a live listing: finds the ask for `mint`,
  fetches the grade-matched comp for `query`, and evaluates the full
  buy → redeem → sell-physical round trip (see `LemonTcg.Basis`).
  """
  def basis(desk, collection, mint, query, grade \\ nil),
    do: GenServer.call(desk, {:basis, collection, mint, query, grade}, 60_000)

  @doc "Buy a specific listed token by mint at its current ask."
  def buy(desk, collection, mint), do: GenServer.call(desk, {:buy, collection, mint}, 60_000)

  @doc "Sell a held position at the current floor (venue applies haircut/fees)."
  def sell(desk, mint), do: GenServer.call(desk, {:sell, mint}, 60_000)

  @doc "Engage the kill switch: blocks buys, sells stay available."
  def halt(desk), do: GenServer.call(desk, {:set_kill_switch, true})

  def resume(desk), do: GenServer.call(desk, {:set_kill_switch, false})

  # -- Server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    market_opts =
      opts
      |> Keyword.get(:market_opts, [])
      |> Keyword.put_new(:wallet, Keyword.get(opts, :wallet))

    state = %{
      portfolio: Portfolio.new(Keyword.get(opts, :starting_cash_usd, 1_000.0)),
      policy: Keyword.get(opts, :policy, %Policy{}),
      venue: Keyword.get(opts, :venue, Paper),
      watchlist: Keyword.get(opts, :watchlist, []),
      market_opts: market_opts
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call(:watchlist, _from, state) do
    {:reply, state.watchlist, state}
  end

  def handle_call({:floor, collection}, _from, state) do
    {:reply, MarketData.floor(collection, state.market_opts), state}
  end

  def handle_call({:listings, collection, limit}, _from, state) do
    opts = Keyword.put(state.market_opts, :limit, limit)
    {:reply, MarketData.listings(collection, opts), state}
  end

  def handle_call({:comp, query, grade}, _from, state) do
    {:reply, Comps.comp_for_grade(query, grade, state.market_opts), state}
  end

  def handle_call({:basis, collection, mint, query, grade}, _from, state) do
    {:reply, evaluate_basis(state, collection, mint, query, grade), state}
  end

  def handle_call({:buy, collection, mint}, _from, state) do
    case execute_buy(state, collection, mint) do
      {:ok, fill, portfolio} -> {:reply, {:ok, fill}, %{state | portfolio: portfolio}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:sell, mint}, _from, state) do
    case execute_sell(state, mint) do
      {:ok, fill, portfolio} -> {:reply, {:ok, fill}, %{state | portfolio: portfolio}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_kill_switch, engaged?}, _from, state) do
    state = %{state | policy: %{state.policy | kill_switch: engaged?}}
    {:reply, :ok, state}
  end

  # -- Order flow ---------------------------------------------------------

  defp execute_buy(state, collection, mint) do
    with {:ok, listing} <- find_listing(state, collection, mint),
         {:ok, total_usd} <- estimated_total_usd(state, listing),
         :ok <- Risk.check(state.policy, state.portfolio, {:buy, collection, total_usd}),
         {:ok, fill} <- venue_for(state.venue, listing.venue).buy(listing, state.market_opts),
         {:ok, portfolio} <- Portfolio.apply_buy(state.portfolio, fill) do
      {:ok, fill, portfolio}
    end
  end

  defp execute_sell(state, mint) do
    with {:ok, position} <- fetch_position(state.portfolio, mint),
         :ok <- Risk.check(state.policy, state.portfolio, {:sell, mint}),
         {:ok, fill} <- venue_for(state.venue, position.venue).sell(position, state.market_opts),
         {:ok, portfolio} <- Portfolio.apply_sell(state.portfolio, fill) do
      {:ok, fill, portfolio}
    end
  end

  defp venue_for(venue, _market) when is_atom(venue), do: venue

  defp venue_for(%{} = venues, market) do
    Map.get(venues, market) || Map.get(venues, :default, Paper)
  end

  defp evaluate_basis(state, collection, mint, query, grade) do
    with {:ok, listing} <- find_listing(state, collection, mint),
         {:ok, ask_usd} <- Fx.listing_usd(listing, state.market_opts),
         {:ok, matched} <- Comps.comp_for_grade(query, grade, state.market_opts) do
      evaluation = Basis.evaluate(ask_usd, matched.price_usd, state.market_opts)

      {:ok,
       Map.merge(evaluation, %{
         mint: listing.mint,
         listing_name: listing.name,
         comp_name: matched.comp.name,
         comp_bucket: matched.bucket,
         comp_source: matched.comp.source
       })}
    end
  end

  defp find_listing(state, collection, mint) do
    opts = Keyword.put(state.market_opts, :limit, 100)

    with {:ok, listings} <- MarketData.listings(collection, opts) do
      case Enum.find(listings, &(&1.mint == mint)) do
        nil -> {:error, {:listing_not_found, mint}}
        listing -> {:ok, listing}
      end
    end
  end

  defp estimated_total_usd(state, listing) do
    # Risk sees ask + fee headroom; the venue computes the exact fee.
    with {:ok, price_usd} <- Fx.listing_usd(listing, state.market_opts) do
      {:ok, Float.round(price_usd * 1.03, 2)}
    end
  end

  defp fetch_position(portfolio, mint) do
    case Map.fetch(portfolio.positions, mint) do
      {:ok, position} -> {:ok, position}
      :error -> {:error, {:not_holding, mint}}
    end
  end

  defp build_snapshot(state) do
    floors_usd =
      state.watchlist
      |> Enum.reduce(%{}, fn collection, acc ->
        with {:ok, floor} <- MarketData.floor(collection, state.market_opts),
             {:ok, usd} <- Fx.floor_usd(floor, state.market_opts) do
          Map.put(acc, collection, usd)
        else
          _ -> acc
        end
      end)

    %{
      mark: Portfolio.mark_to_market(state.portfolio, floors_usd),
      positions: Map.values(state.portfolio.positions),
      policy: Map.from_struct(state.policy),
      venue: state.venue.name(),
      watchlist: state.watchlist,
      floors_usd: floors_usd
    }
  end
end
