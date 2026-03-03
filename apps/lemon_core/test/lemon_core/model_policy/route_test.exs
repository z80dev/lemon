defmodule LemonCore.ModelPolicy.RouteTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias LemonCore.ModelPolicy.Route

  describe "new/4" do
    test "creates a route with all fields" do
      route = Route.new("telegram", "default", "123", "456")

      assert route.channel_id == "telegram"
      assert route.account_id == "default"
      assert route.peer_id == "123"
      assert route.thread_id == "456"
    end

    test "creates a route with only channel_id" do
      route = Route.new("discord")

      assert route.channel_id == "discord"
      assert route.account_id == nil
      assert route.peer_id == nil
      assert route.thread_id == nil
    end

    test "creates a route with partial fields" do
      route = Route.new("telegram", "account1")

      assert route.channel_id == "telegram"
      assert route.account_id == "account1"
      assert route.peer_id == nil
      assert route.thread_id == nil
    end
  end

  describe "to_key/1" do
    test "converts full route to key tuple" do
      route = Route.new("telegram", "default", "123", "456")
      assert Route.to_key(route) == {"telegram", "default", "123", "456"}
    end

    test "converts minimal route to key tuple" do
      route = Route.new("discord")
      assert Route.to_key(route) == {"discord", nil, nil, nil}
    end
  end

  describe "from_key/1" do
    test "creates route from 4-tuple" do
      route = Route.from_key({"telegram", "default", "123", "456"})

      assert route.channel_id == "telegram"
      assert route.account_id == "default"
      assert route.peer_id == "123"
      assert route.thread_id == "456"
    end

    test "creates route from 3-tuple" do
      route = Route.from_key({"telegram", "default", "123"})

      assert route.channel_id == "telegram"
      assert route.account_id == "default"
      assert route.peer_id == "123"
      assert route.thread_id == nil
    end

    test "creates route from 2-tuple" do
      route = Route.from_key({"telegram", "default"})

      assert route.channel_id == "telegram"
      assert route.account_id == "default"
      assert route.peer_id == nil
      assert route.thread_id == nil
    end

    test "creates route from 1-tuple" do
      route = Route.from_key({"telegram"})

      assert route.channel_id == "telegram"
      assert route.account_id == nil
      assert route.peer_id == nil
      assert route.thread_id == nil
    end
  end

  describe "precedence_keys/1" do
    test "returns hierarchy for full route (most to least specific)" do
      route = Route.new("telegram", "default", "123", "456")
      keys = Route.precedence_keys(route)

      assert keys == [
               {"telegram", "default", "123", "456"},
               {"telegram", "default", "123", nil},
               {"telegram", "default", nil, nil},
               {"telegram", nil, nil, nil}
             ]
    end

    test "returns hierarchy for route without thread (most to least specific)" do
      route = Route.new("telegram", "default", "123", nil)
      keys = Route.precedence_keys(route)

      assert keys == [
               {"telegram", "default", "123", nil},
               {"telegram", "default", nil, nil},
               {"telegram", nil, nil, nil}
             ]
    end

    test "returns hierarchy for route with only channel and account (most to least specific)" do
      route = Route.new("telegram", "default", nil, nil)
      keys = Route.precedence_keys(route)

      assert keys == [
               {"telegram", "default", nil, nil},
               {"telegram", nil, nil, nil}
             ]
    end

    test "returns single key for channel-only route" do
      route = Route.new("telegram")
      keys = Route.precedence_keys(route)

      assert keys == [{"telegram", nil, nil, nil}]
    end
  end

  describe "channel_wide/1" do
    test "creates channel-wide route" do
      route = Route.channel_wide("discord")

      assert route.channel_id == "discord"
      assert route.account_id == nil
      assert route.peer_id == nil
      assert route.thread_id == nil
    end
  end

  describe "more_specific?/2" do
    test "thread is more specific than peer" do
      thread = Route.new("telegram", "default", "123", "456")
      peer = Route.new("telegram", "default", "123", nil)

      assert Route.more_specific?(thread, peer) == true
      assert Route.more_specific?(peer, thread) == false
    end

    test "peer is more specific than account" do
      peer = Route.new("telegram", "default", "123", nil)
      account = Route.new("telegram", "default", nil, nil)

      assert Route.more_specific?(peer, account) == true
      assert Route.more_specific?(account, peer) == false
    end

    test "account is more specific than channel" do
      account = Route.new("telegram", "default", nil, nil)
      channel = Route.new("telegram")

      assert Route.more_specific?(account, channel) == true
      assert Route.more_specific?(channel, account) == false
    end

    test "equal specificity returns false" do
      route1 = Route.new("telegram", "default", "123", "456")
      route2 = Route.new("telegram", "default", "123", "456")

      assert Route.more_specific?(route1, route2) == false
    end
  end
end
