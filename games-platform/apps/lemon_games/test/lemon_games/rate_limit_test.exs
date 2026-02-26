defmodule LemonGames.RateLimitTest do
  use ExUnit.Case, async: false

  alias LemonGames.RateLimit

  test "check_read allows under limit" do
    hash = "rl_test_#{System.unique_integer()}"
    assert :ok = RateLimit.check_read(hash)
  end

  test "check_move allows under limit" do
    hash = "rl_move_#{System.unique_integer()}"
    assert :ok = RateLimit.check_move(hash, "match_1")
  end

  test "check_move rejects after burst limit" do
    hash = "rl_burst_#{System.unique_integer()}"

    for _ <- 1..4 do
      assert :ok = RateLimit.check_move(hash, "match_burst")
    end

    assert {:error, :rate_limited, retry_after} = RateLimit.check_move(hash, "match_burst")
    assert is_integer(retry_after)
    assert retry_after >= 0
  end
end
