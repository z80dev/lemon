defmodule LemonCore.ChannelRouteTest do
  use ExUnit.Case, async: true

  alias LemonCore.ChannelRoute

  describe "struct creation" do
    test "creates a route with all required fields" do
      route = %ChannelRoute{
        channel_id: "telegram",
        account_id: "bot_123",
        peer_kind: :dm,
        peer_id: "456"
      }

      assert route.channel_id == "telegram"
      assert route.account_id == "bot_123"
      assert route.peer_kind == :dm
      assert route.peer_id == "456"
      assert route.thread_id == nil
    end

    test "creates a route with thread_id" do
      route = %ChannelRoute{
        channel_id: "discord",
        account_id: "acc_1",
        peer_kind: :group,
        peer_id: "789",
        thread_id: "thread_42"
      }

      assert route.thread_id == "thread_42"
    end

    test "supports all peer_kind atoms" do
      for kind <- [:dm, :group, :channel, :unknown] do
        route = %ChannelRoute{
          channel_id: "test",
          account_id: "acc",
          peer_kind: kind,
          peer_id: "id"
        }

        assert route.peer_kind == kind
      end
    end
  end

  describe "enforce_keys" do
    test "raises when channel_id is missing" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(ChannelRoute, %{
          account_id: "acc",
          peer_kind: :dm,
          peer_id: "123"
        })
      end
    end

    test "raises when account_id is missing" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(ChannelRoute, %{
          channel_id: "telegram",
          peer_kind: :dm,
          peer_id: "123"
        })
      end
    end

    test "raises when peer_kind is missing" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(ChannelRoute, %{
          channel_id: "telegram",
          account_id: "acc",
          peer_id: "123"
        })
      end
    end

    test "raises when peer_id is missing" do
      assert_raise ArgumentError, ~r/keys must also be given/, fn ->
        struct!(ChannelRoute, %{
          channel_id: "telegram",
          account_id: "acc",
          peer_kind: :dm
        })
      end
    end
  end

  describe "struct!/2" do
    test "creates route from keyword list via struct!" do
      route =
        struct!(ChannelRoute,
          channel_id: "xmtp",
          account_id: "acc_x",
          peer_kind: :dm,
          peer_id: "peer_x",
          thread_id: "t1"
        )

      assert %ChannelRoute{} = route
      assert route.channel_id == "xmtp"
      assert route.thread_id == "t1"
    end
  end
end
