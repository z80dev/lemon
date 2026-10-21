defmodule LemonControlPlane.Methods.NullableUsageTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{SessionDetail, UsageStatus}
  alias LemonCore.{RunStore, UsageStore}

  test "quota projections preserve unknown spend and counters without arithmetic errors" do
    previous_summary = UsageStore.get_summary(:current)

    limits =
      for key <- [:runs_limit, :tokens_limit, :cost_limit],
          do: {key, Application.fetch_env(:lemon_control_plane, key)}

    on_exit(fn ->
      if previous_summary,
        do: UsageStore.put_summary(:current, previous_summary),
        else: LemonCore.Store.delete(:usage_data, :current)

      for {key, value} <- limits do
        case value do
          {:ok, original} -> Application.put_env(:lemon_control_plane, key, original)
          :error -> Application.delete_env(:lemon_control_plane, key)
        end
      end
    end)

    Application.put_env(:lemon_control_plane, :runs_limit, 10)
    Application.put_env(:lemon_control_plane, :tokens_limit, 100)
    Application.put_env(:lemon_control_plane, :cost_limit, 1.0)

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

  test "session detail preserves missing usage across rows and summary totals" do
    session_key = "agent:nullable-detail:#{LemonCore.Id.uuid()}"
    run_ids = Enum.map(1..3, fn _ -> LemonCore.Id.uuid() end)

    on_exit(fn ->
      for run_id <- run_ids, do: LemonCore.Store.delete(:runs, run_id)
      RunStore.delete_session(session_key)
    end)

    usages = [
      %{input: 1, output: 2, total_tokens: 3, cost: %{total: 0.0}},
      %LemonAi.Types.Usage{input: nil, output: 4, total_tokens: nil},
      nil
    ]

    for {run_id, usage} <- Enum.zip(run_ids, usages) do
      assert :ok =
               RunStore.finalize(run_id, %{
                 session_key: session_key,
                 agent_id: "nullable-detail",
                 completed: %{ok: true, usage: usage}
               })
    end

    assert {:ok, detail} = SessionDetail.handle(%{"sessionKey" => session_key}, %{})
    rows = Map.new(detail["runs"], &{&1["runId"], &1["tokens"]})

    assert rows[Enum.at(run_ids, 0)] == %{
             "input" => 1,
             "output" => 2,
             "total" => 3,
             "costUsd" => 0.0
           }

    assert rows[Enum.at(run_ids, 1)] == %{
             "input" => nil,
             "output" => 4,
             "total" => nil,
             "costUsd" => nil
           }

    assert rows[Enum.at(run_ids, 2)] == %{
             "input" => nil,
             "output" => nil,
             "total" => nil,
             "costUsd" => nil
           }

    assert detail["summary"]["tokenTotals"] == %{"input" => nil, "output" => nil, "total" => nil}
  end
end
