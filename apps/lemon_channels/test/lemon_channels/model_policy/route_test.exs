defmodule LemonChannels.ModelPolicy.RouteTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LemonChannels.ModelPolicy.Route

  test "keys round-trip and short stored keys pad missing levels with nil" do
    route = Route.new("telegram", "default", "123", "456")

    assert Route.to_key(route) == {"telegram", "default", "123", "456"}
    assert Route.from_key(Route.to_key(route)) == route

    assert Route.from_key({"telegram", "default", "123"}) ==
             Route.new("telegram", "default", "123", nil)

    assert Route.from_key({"telegram", "default"}) == Route.new("telegram", "default", nil, nil)
    assert Route.from_key({"telegram"}) == Route.new("telegram")
  end

  describe "precedence_keys/1" do
    test "walks from thread to channel, most specific first" do
      assert Route.precedence_keys(Route.new("telegram", "default", "123", "456")) == [
               {"telegram", "default", "123", "456"},
               {"telegram", "default", "123", nil},
               {"telegram", "default", nil, nil},
               {"telegram", nil, nil, nil}
             ]
    end

    test "skips levels the route does not have" do
      assert Route.precedence_keys(Route.new("telegram", "default", "123", nil)) == [
               {"telegram", "default", "123", nil},
               {"telegram", "default", nil, nil},
               {"telegram", nil, nil, nil}
             ]

      assert Route.precedence_keys(Route.new("telegram", "default", nil, nil)) == [
               {"telegram", "default", nil, nil},
               {"telegram", nil, nil, nil}
             ]

      assert Route.precedence_keys(Route.new("telegram")) == [
               {"telegram", nil, nil, nil}
             ]
    end
  end

  test "more_specific?/2 orders thread > peer > account > channel and is strict" do
    thread = Route.new("telegram", "default", "123", "456")
    peer = Route.new("telegram", "default", "123", nil)
    account = Route.new("telegram", "default", nil, nil)
    channel = Route.new("telegram")

    assert Route.more_specific?(thread, peer)
    assert Route.more_specific?(peer, account)
    assert Route.more_specific?(account, channel)
    refute Route.more_specific?(channel, account)
    refute Route.more_specific?(thread, Route.new("telegram", "default", "123", "456"))
  end
end
