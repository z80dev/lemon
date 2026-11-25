defmodule LemonControlPlane.Methods.NullableUsageTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.UsageStatus
  alias LemonCore.UsageStore

  test "quota projections preserve unknown spend and counters without arithmetic errors" do
    previous_summary = UsageStore.get_summary(:current)

    limits =
      for key <- [:runs_limit, :tokens_limit, :cost_limit],
          do: {key, Application.fetch_env(:lemon_core, key)}

    on_exit(fn ->
      if previous_summary,
        do: UsageStore.put_summary(:current, previous_summary),
        else: LemonCore.Store.delete(:usage_data, :current)

      for {key, value} <- limits do
        case value do
          {:ok, original} -> Application.put_env(:lemon_core, key, original)
          :error -> Application.delete_env(:lemon_core, key)
        end
      end
    end)

    Application.put_env(:lemon_core, :runs_limit, 10)
    Application.put_env(:lemon_core, :tokens_limit, 100)
    Application.put_env(:lemon_core, :cost_limit, 1.0)

    UsageStore.put_summary(:current, %{
      total_requests: 1,
      total_cost: nil,
      total_tokens: %{input: nil, output: 2}
    })

    assert {:ok, result} = UsageStatus.handle(%{}, %{})
    assert result["cost"] == nil
    assert result["tokens"] == %{"input" => nil, "output" => 2}
    assert result["summary"]["totalTokens"] == nil
    assert result["summary"]["remainingTokens"] == nil
    assert result["summary"]["remainingCost"] == nil
    assert result["summary"]["remainingRuns"] == 9
    assert result["summary"]["status"] == "unknown"

    UsageStore.put_summary(:current, %{
      total_requests: 11,
      total_cost: nil,
      total_tokens: %{input: nil, output: 2}
    })

    assert {:ok, exceeded} = UsageStatus.handle(%{}, %{})
    assert exceeded["summary"]["status"] == "over_limit"
  end
end
