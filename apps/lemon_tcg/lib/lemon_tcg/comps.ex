defmodule LemonTcg.Comps do
  @moduledoc """
  Facade over physical-card comp sources with a slow-moving cache.

  Comps are sold-listing aggregates and move on the order of days, so the
  default cache TTL is 10 minutes (vs 30s for token quotes). The source is
  resolved per call from `opts[:comp_source]`, then the
  `:lemon_tcg, :comp_source` app env, then the live
  `Sources.PriceCharting`.
  """

  alias LemonTcg.Comps.{Comp, Grade}
  alias LemonTcg.Comps.Sources.PriceCharting
  alias LemonTcg.MarketData.Cache

  @default_ttl_ms 600_000

  @spec comp(String.t(), keyword()) :: {:ok, Comp.t()} | {:error, term()}
  def comp(query, opts \\ []) when is_binary(query) do
    source = source(opts)
    ttl_ms = Keyword.get(opts, :comp_ttl_ms, @default_ttl_ms)

    Cache.get_or_run(
      {:comp, source.source_name(), query},
      fn -> source.comp(query, opts) end,
      ttl_ms: ttl_ms,
      fresh?: Keyword.get(opts, :fresh?, false)
    )
  end

  @doc """
  Grade-matched USD comp for a card.

  `grade` may be a parsed grade tuple, a label ("PSA 10", "ungraded"),
  or nil — in which case the grade is parsed from the query itself.
  Returns the bucket used alongside the price so callers can surface
  approximations (mid grades map to the grade-9 bucket).
  """
  @spec comp_for_grade(String.t(), Grade.parsed() | String.t() | nil, keyword()) ::
          {:ok, %{comp: Comp.t(), bucket: String.t(), price_usd: float()}} | {:error, term()}
  def comp_for_grade(query, grade \\ nil, opts \\ []) do
    parsed =
      case grade do
        nil -> Grade.parse(query)
        label when is_binary(label) -> Grade.parse_label(label)
        parsed -> parsed
      end

    bucket = Grade.bucket(parsed)

    with {:ok, comp} <- comp(query, opts) do
      case Comp.price(comp, bucket) do
        nil -> {:error, {:no_comp_for_grade, query, bucket}}
        price_usd -> {:ok, %{comp: comp, bucket: bucket, price_usd: price_usd}}
      end
    end
  end

  def source(opts) do
    Keyword.get(opts, :comp_source) ||
      Application.get_env(:lemon_tcg, :comp_source, PriceCharting)
  end
end
