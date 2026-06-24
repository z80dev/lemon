defmodule LemonChannels.TargetDirectoryTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Discord.KnownTargetStore, as: DiscordKnownTargetStore
  alias LemonChannels.TargetDirectory
  alias LemonChannels.Telegram.KnownTargetStore, as: TelegramKnownTargetStore
  alias LemonCore.Store

  setup do
    clear_known_targets()
    on_exit(&clear_known_targets/0)
    :ok
  end

  test "lists normalized Telegram known routes" do
    :ok =
      TelegramKnownTargetStore.put({"default", -100_606, 88}, %{
        peer_kind: :group,
        chat_title: "Ops Room",
        chat_username: "ops_room",
        topic_name: "Deployments",
        updated_at_ms: 4_000
      })

    assert [%{channel_id: "telegram"} = route] =
             TargetDirectory.list_known_routes(platforms: ["telegram"])

    assert route.account_id == "default"
    assert route.peer_kind == :group
    assert route.peer_id == "-100606"
    assert route.thread_id == "88"
    assert route.target == "tg:-100606/88"
    assert route.peer_label == "Ops Room"
    assert route.peer_username == "ops_room"
    assert route.topic_name == "Deployments"
    assert route.updated_at_ms == 4_000
  end

  test "lists normalized Discord known routes" do
    :ok =
      DiscordKnownTargetStore.put({"work", 123_456, 789}, %{
        peer_kind: :channel,
        channel_name: "ops",
        thread_name: "deployments",
        updated_at_ms: 5_000
      })

    assert [%{channel_id: "discord"} = route] =
             TargetDirectory.list_known_routes(platforms: ["discord"])

    assert route.account_id == "work"
    assert route.peer_kind == :channel
    assert route.peer_id == "123456"
    assert route.thread_id == "789"
    assert route.target == "discord:work@123456/789"
    assert route.peer_label == "ops"
    assert route.topic_name == "deployments"
    assert route.updated_at_ms == 5_000
  end

  defp clear_known_targets do
    TelegramKnownTargetStore.list()
    |> Enum.each(fn {key, _value} -> Store.delete(:telegram_known_targets, key) end)

    DiscordKnownTargetStore.list()
    |> Enum.each(fn {key, _value} -> Store.delete(:discord_known_targets, key) end)
  end
end
