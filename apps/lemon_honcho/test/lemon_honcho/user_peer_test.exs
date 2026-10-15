defmodule LemonHoncho.UserPeerTest do
  use ExUnit.Case, async: true

  alias LemonHoncho.{Config, UserPeer}

  @telegram %{channel_id: "telegram", sender_id: "123", is_bot: false}

  test "pin wins over aliases, aliases over prefix, then configured fallback" do
    config = %Config{
      user_peer: "owner",
      pin_user_peer: true,
      user_peer_aliases: %{"telegram_123" => "alice", "discord_456" => "alice"},
      runtime_peer_prefix: "gateway_"
    }

    assert UserPeer.resolve(config, @telegram) == "owner"
    config = %{config | pin_user_peer: false}
    assert UserPeer.resolve(config, @telegram) == "alice"
    assert UserPeer.resolve(config, %{channel_id: "discord", sender_id: "456"}) == "alice"
    config = %{config | user_peer_aliases: %{}}
    assert UserPeer.resolve(config, @telegram) == "gateway_telegram_123"
    assert UserPeer.resolve(%{config | runtime_peer_prefix: ""}, @telegram) == "owner"
  end

  test "equal sender ids on different platforms never share a prefixed peer" do
    config = %Config{runtime_peer_prefix: "gateway_"}
    assert UserPeer.resolve(config, @telegram) == "gateway_telegram_123"

    assert UserPeer.resolve(config, %{channel_id: "discord", sender_id: "123"}) ==
             "gateway_discord_123"
  end

  test "CLI, TUI and web with no channel identity keep the configured user" do
    config = %Config{user_peer: "owner", runtime_peer_prefix: "gateway_"}

    for identity <- [nil, %{}, %{sender_id: "123"}] do
      assert UserPeer.resolve(config, identity) == "owner"
      assert UserPeer.cache_key("local", config, identity) == "local"
    end
  end

  test "unsafe and long runtime names are bounded collision-resistant Honcho ids" do
    config = %Config{runtime_peer_prefix: "gateway_"}
    one = UserPeer.resolve(config, %{channel_id: "telegram", sender_id: "a/b"})
    two = UserPeer.resolve(config, %{channel_id: "telegram", sender_id: "a.b"})
    assert one != two

    long =
      UserPeer.resolve(config, %{channel_id: "telegram", sender_id: String.duplicate("x", 600)})

    for peer <- [one, two, long], do: assert(Regex.match?(~r/^[A-Za-z0-9_-]{1,512}$/, peer))
  end
end
