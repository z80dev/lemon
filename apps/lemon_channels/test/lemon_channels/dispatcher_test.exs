defmodule LemonChannels.DispatcherTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Dispatcher
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  test "dispatch/1 enqueues a simple text intent" do
    intent =
      struct!(DeliveryIntent,
        intent_id: "intent-1",
        run_id: "run-1",
        session_key: "agent:default:main",
        route:
          struct!(DeliveryRoute,
            channel_id: "unknown-test-channel",
            account_id: "default",
            peer_kind: :dm,
            peer_id: "123"
          ),
        kind: :final_text,
        body: %{text: "hello world"}
      )

    assert :ok = Dispatcher.dispatch(intent)
  end

  test "dispatch/1 returns error when text is missing" do
    intent =
      struct!(DeliveryIntent,
        intent_id: "intent-2",
        run_id: "run-2",
        session_key: "agent:default:main",
        route:
          struct!(DeliveryRoute,
            channel_id: "unknown-test-channel",
            account_id: "default",
            peer_kind: :dm,
            peer_id: "123"
          ),
        kind: :final_text,
        body: %{}
      )

    assert {:error, :missing_text} = Dispatcher.dispatch(intent)
  end
end
