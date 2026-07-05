defmodule LemonTcg.Comps.Source do
  @moduledoc """
  Behaviour for a physical-card comp source.

  A comp source answers one question: what does this card sell for in the
  physical market, per grade. Implementations must be swappable for
  `LemonTcg.Comps.Sources.Fixture` in tests and offline runs.
  """

  alias LemonTcg.Comps.Comp

  @callback comp(query :: String.t(), opts :: keyword()) :: {:ok, Comp.t()} | {:error, term()}

  @callback source_name() :: String.t()
end
