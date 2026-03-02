defmodule LemonRouter.RunProcess.OutputTrackerTest do
  @moduledoc """
  Tests for ARCH-011 migration of OutputTracker fanout from OutboundPayload
  to OutputIntent.

  Verifies that the fanout intent round-trip through the Dispatcher produces
  the correct payload structure.
  """

  use ExUnit.Case, async: true

  alias LemonCore.{ChannelRoute, OutputIntent}
  alias LemonChannels.{Dispatcher, OutboundPayload}

  @route %ChannelRoute{
    channel_id: "telegram",
    account_id: "bot_42",
    peer_kind: :group,
    peer_id: "chat_555",
    thread_id: "thread_8"
  }

  @discord_route %ChannelRoute{
    channel_id: "discord",
    account_id: "acc_d",
    peer_kind: :group,
    peer_id: "guild_2",
    thread_id: nil
  }

  describe "fanout intent round-trip" do
    test "fanout_text intent translates to :text payload" do
      intent = %OutputIntent{
        route: @route,
        op: :fanout_text,
        body: %{text: "Final answer to broadcast"},
        meta: %{
          idempotency_key: "run_1:fanout:1",
          run_id: "run_1",
          session_key: "agent:a1:telegram:bot_42:group:chat_555:thread:thread_8",
          fanout: true,
          fanout_index: 1
        }
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert %OutboundPayload{} = payload
      assert payload.kind == :text
      assert payload.content == "Final answer to broadcast"
      assert payload.channel_id == "telegram"
      assert payload.account_id == "bot_42"
      assert payload.peer == %{kind: :group, id: "chat_555", thread_id: "thread_8"}
      assert payload.idempotency_key == "run_1:fanout:1"
      assert payload.meta[:fanout] == true
      assert payload.meta[:fanout_index] == 1
    end

    test "fanout intent for different channels produces correct payload" do
      intent = %OutputIntent{
        route: @discord_route,
        op: :fanout_text,
        body: %{text: "Discord fanout message"},
        meta: %{
          idempotency_key: "run_2:fanout:1",
          run_id: "run_2",
          fanout: true,
          fanout_index: 1
        }
      }

      payload = Dispatcher.intent_to_payload(intent)

      assert payload.channel_id == "discord"
      assert payload.account_id == "acc_d"
      assert payload.peer == %{kind: :group, id: "guild_2", thread_id: nil}
      assert payload.kind == :text
      assert payload.content == "Discord fanout message"
    end

    test "fanout intent dispatch succeeds when Outbox is running" do
      intent = %OutputIntent{
        route: @route,
        op: :fanout_text,
        body: %{text: "Broadcast test"},
        meta: %{
          idempotency_key: "fanout-dispatch-#{System.unique_integer([:positive])}",
          run_id: "run_fanout",
          fanout: true,
          fanout_index: 1
        }
      }

      assert :ok = Dispatcher.dispatch(intent)
    end

    test "multiple fanout intents have distinct idempotency keys" do
      run_id = "run_multi_fanout"

      intents =
        for idx <- 1..3 do
          %OutputIntent{
            route: @route,
            op: :fanout_text,
            body: %{text: "Fanout #{idx}"},
            meta: %{
              idempotency_key: "#{run_id}:fanout:#{idx}",
              run_id: run_id,
              fanout: true,
              fanout_index: idx
            }
          }
        end

      keys = Enum.map(intents, fn i -> Dispatcher.intent_to_payload(i).idempotency_key end)
      assert length(Enum.uniq(keys)) == 3
    end
  end
end
