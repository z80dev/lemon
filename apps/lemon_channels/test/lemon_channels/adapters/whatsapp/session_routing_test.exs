defmodule LemonChannels.Adapters.WhatsApp.Transport.SessionRoutingTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.WhatsApp.Transport.SessionRouting
  alias LemonCore.{ChatScope, SessionKey}

  test "a fork sub-session keyed by a colon-bearing message id stays a canonical key" do
    inbound = %{
      peer: %{kind: :group, id: "123@g.us", thread_id: nil},
      meta: %{agent_id: "default"}
    }

    scope = %ChatScope{transport: :whatsapp, chat_id: "123@g.us"}

    {key, forked?} =
      SessionRouting.resolve_session_key(
        "default",
        inbound,
        scope,
        %{fork_when_busy: true, user_msg_id: "3EB0:ABCD:1"},
        0
      )

    assert forked?
    assert %{kind: :channel_peer, peer_id: "123@g.us", sub_id: sub} = SessionKey.parse(key)
    assert sub == SessionKey.component("3EB0:ABCD:1")
  end
end
