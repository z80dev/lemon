defmodule LemonAi.Auth.OAuthFlowTest do
  use ExUnit.Case, async: true

  alias LemonAi.Auth.OAuthFlow

  defp poll(results, opts) do
    {:ok, queue} = Agent.start_link(fn -> results end)
    test_pid = self()

    OAuthFlow.poll_device_token(
      fn ->
        Agent.get_and_update(queue, fn
          [n | r] -> {n, r}
          [] -> {:pending, []}
        end)
      end,
      Keyword.put(opts, :sleep, &send(test_pid, {:slept, &1}))
    )
  end

  defp waited(acc \\ 0) do
    receive do
      {:slept, ms} -> waited(acc + ms)
    after
      0 -> acc
    end
  end

  test "stops polling when the device code expires instead of polling forever" do
    assert {:error, :device_flow_timed_out} = poll([], interval_s: 5, expires_in_s: 30)
    assert waited() <= 30_000
  end

  test "slow_down widens the interval and names clock drift when the code then expires" do
    assert {:error, :device_flow_timed_out_after_slow_down} =
             poll([:slow_down], interval_s: 5, expires_in_s: 60)

    assert_received {:slept, 10_000}
  end
end
