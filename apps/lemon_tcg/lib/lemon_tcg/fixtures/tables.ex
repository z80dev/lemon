defmodule LemonTcg.Fixtures.Tables do
  @moduledoc """
  Long-lived owner for the deterministic fixture override tables.

  Fixture sources let tests inject specific quotes via public ETS tables.
  If those tables were created lazily by whichever test process first
  touched them, they would die when that (short-lived, async) process
  exits — silently dropping another still-running test's overrides. This
  process owns them for the lifetime of the app so overrides survive
  across concurrent tests.
  """

  use GenServer

  @tables [
    :lemon_tcg_fixture_overrides,
    :lemon_tcg_comp_fixture_overrides
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Table names this process owns."
  def tables, do: @tables

  @impl true
  def init(_opts) do
    for table <- @tables, :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end
end
