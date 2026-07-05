defmodule LemonTcg.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonTcg.MarketData.Cache,
      LemonTcg.Fixtures.Tables
    ]

    opts = [strategy: :one_for_one, name: LemonTcg.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
