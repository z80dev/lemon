defmodule LemonRouter.RunProcess.WatchdogTest do
  @moduledoc """
  Tests for ARCH-011 migration of Watchdog from OutboundPayload to OutputIntent.

  Verifies that the watchdog builds channel-agnostic OutputIntents with
  correct keepalive prompt actions, and that the Dispatcher's
  channel-specific rendering produces the right markup.
  """

  use ExUnit.Case, async: true

  alias LemonCore.{ChannelRoute, OutputIntent}
  alias LemonChannels.Dispatcher

  # ---------------------------------------------------------------
  # Watchdog intent structure (integration-level)
  #
  # The Watchdog module builds intents internally via private functions.
  # We test the full round-trip: intent -> payload with actions.
  # ---------------------------------------------------------------

  @telegram_route %ChannelRoute{
    channel_id: "telegram",
    account_id: "bot_42",
    peer_kind: :dm,
    peer_id: "100",
    thread_id: nil
  }

  @discord_route %ChannelRoute{
    channel_id: "discord",
    account_id: "acc_d",
    peer_kind: :group,
    peer_id: "guild_1",
    thread_id: "thread_99"
  }

  @xmtp_route %ChannelRoute{
    channel_id: "xmtp",
    account_id: "acc_x",
    peer_kind: :dm,
    peer_id: "0xabc",
    thread_id: nil
  }

  describe "watchdog keepalive intent round-trip" do
    test "Telegram keepalive intent produces inline keyboard payload" do
      run_id = "run_#{System.unique_integer([:positive])}"

      intent = build_watchdog_intent(@telegram_route, run_id, 120)

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      assert payload.kind == :text
      assert payload.channel_id == "telegram"
      assert payload.content =~ "Still running"
      assert payload.content =~ "120 minutes"

      # Telegram should get inline_keyboard
      assert %{"inline_keyboard" => [buttons]} = payload.meta[:reply_markup]
      assert length(buttons) == 2

      [keep_btn, stop_btn] = buttons
      assert keep_btn["text"] == "Keep Waiting"
      assert keep_btn["callback_data"] == "lemon:idle:c:#{run_id}"
      assert stop_btn["text"] == "Stop Run"
      assert stop_btn["callback_data"] == "lemon:idle:k:#{run_id}"
    end

    test "Discord keepalive intent produces structured actions" do
      run_id = "run_#{System.unique_integer([:positive])}"

      intent = build_watchdog_intent(@discord_route, run_id, 60)

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      assert payload.kind == :text
      assert payload.channel_id == "discord"

      # Non-Telegram channels get structured actions
      assert %{"actions" => actions} = payload.meta[:reply_markup]
      assert length(actions) == 2

      [keep_action, stop_action] = actions
      assert keep_action[:id] == "lemon:idle:c:#{run_id}"
      assert keep_action[:label] == "Keep Waiting"
      assert stop_action[:id] == "lemon:idle:k:#{run_id}"
      assert stop_action[:label] == "Stop Run"
    end

    test "XMTP keepalive intent produces structured actions" do
      run_id = "run_#{System.unique_integer([:positive])}"

      intent = build_watchdog_intent(@xmtp_route, run_id, 30)

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      assert payload.channel_id == "xmtp"
      assert %{"actions" => _} = payload.meta[:reply_markup]
    end

    test "keepalive intent preserves idempotency_key and run metadata" do
      run_id = "run_idem_test"
      session_key = "agent:a1:telegram:bot_42:dm:100"

      intent = %OutputIntent{
        route: @telegram_route,
        op: :keepalive_prompt,
        body: %{
          text: "Still running...",
          actions: [
            %{id: "lemon:idle:c:#{run_id}", label: "Keep Waiting"},
            %{id: "lemon:idle:k:#{run_id}", label: "Stop Run"}
          ]
        },
        meta: %{
          idempotency_key: "#{run_id}:watchdog:prompt:7200000",
          run_id: run_id,
          session_key: session_key
        }
      }

      payload = Dispatcher.intent_to_payload_with_actions(intent)

      assert payload.idempotency_key == "#{run_id}:watchdog:prompt:7200000"
      assert payload.meta[:run_id] == run_id
      assert payload.meta[:session_key] == session_key
    end

    test "keepalive intent is channel-agnostic (no Telegram-specific fields in intent)" do
      run_id = "run_agnostic"

      intent = build_watchdog_intent(@telegram_route, run_id, 120)

      # The intent itself should not contain any Telegram-specific markup.
      # The channel-specific rendering happens in the Dispatcher.
      refute Map.has_key?(intent.body, :reply_markup)
      refute Map.has_key?(intent.body, :inline_keyboard)
      refute Map.has_key?(intent.meta, :reply_markup)

      # Actions are plain data with :id and :label
      for action <- intent.body.actions do
        assert is_binary(action[:id])
        assert is_binary(action[:label])
      end
    end
  end

  # ---------------------------------------------------------------
  # Helper: build a watchdog-style keepalive intent
  #
  # This mirrors what Watchdog.watchdog_confirmation_intent/1 produces
  # but is constructed directly for testability.
  # ---------------------------------------------------------------

  defp build_watchdog_intent(route, run_id, idle_minutes) do
    text =
      "Still running, but no output for about #{idle_minutes} minutes.\n" <>
        "Keep waiting?"

    actions = [
      %{id: "lemon:idle:c:#{run_id}", label: "Keep Waiting"},
      %{id: "lemon:idle:k:#{run_id}", label: "Stop Run"}
    ]

    %OutputIntent{
      route: route,
      op: :keepalive_prompt,
      body: %{text: text, actions: actions},
      meta: %{
        idempotency_key: "#{run_id}:watchdog:prompt:#{idle_minutes * 60_000}",
        run_id: run_id,
        session_key: "agent:a1:#{route.channel_id}:#{route.account_id}:#{route.peer_kind}:#{route.peer_id}"
      }
    }
  end
end
