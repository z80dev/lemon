defmodule LemonTcg.LedgerTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Ledger

  test "records entries oldest-first via entries/1" do
    ledger =
      Ledger.new()
      |> Ledger.record(:deposit, 100.0)
      |> Ledger.record(:buy, 25.0, %{mint: "abc"})

    assert [%{type: :deposit}, %{type: :buy, amount_usd: 25.0, meta: %{mint: "abc"}}] =
             Ledger.entries(ledger)
  end

  test "spent_within counts buys and fees but not deposits or sells" do
    ledger =
      Ledger.new()
      |> Ledger.record(:deposit, 1_000.0)
      |> Ledger.record(:buy, 40.0)
      |> Ledger.record(:fee, 1.5)
      |> Ledger.record(:sell, 90.0)

    assert Ledger.spent_within(ledger) == 41.5
  end

  test "spent_within ignores entries outside the window" do
    old_entry = %{
      type: :buy,
      amount_usd: 500.0,
      at_ms: System.system_time(:millisecond) - 100_000,
      meta: %{}
    }

    ledger = %Ledger{entries: [old_entry]}
    assert Ledger.spent_within(ledger, 50_000) == 0.0
  end
end
