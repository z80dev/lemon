defmodule LemonCore.DeliveryIntentTest do
  use ExUnit.Case, async: true

  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  test "enforces required fields via struct!/2" do
    assert_raise ArgumentError, fn ->
      struct!(DeliveryIntent, run_id: "run-1")
    end
  end

  test "builds with semantic defaults" do
    route =
      struct!(DeliveryRoute,
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "123"
      )

    intent =
      struct!(DeliveryIntent,
        intent_id: "intent-1",
        run_id: "run-1",
        session_key: "agent:default:main",
        route: route,
        kind: :final_text
      )

    assert intent.body == %{}
    assert intent.attachments == []
    assert intent.controls == %{}
    assert intent.meta == %{}
  end
end
