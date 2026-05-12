defmodule LemonChannels.Adapters.Discord.TransportTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LemonChannels.Adapters.Discord.Transport

  @bot_user_id 1_476_753_643_834_183_690

  test "ignores messages authored by the bot" do
    state = %{bot_user_id: @bot_user_id}

    message = %{
      "id" => "1503803470493257890",
      "channel_id" => "1475727417372049419",
      "content" => "bot API smoke",
      "author" => %{"id" => "1476753643834183690", "bot" => true}
    }

    assert capture_log(fn ->
             assert {:noreply, ^state} =
                      Transport.handle_info(
                        {:discord_event, {:MESSAGE_CREATE, message, nil}},
                        state
                      )
           end) == ""
  end

  test "ignores webhook messages" do
    state = %{bot_user_id: @bot_user_id}

    message = %{
      "id" => "1503803470493257891",
      "channel_id" => "1475727417372049419",
      "content" => "webhook smoke",
      "webhook_id" => "1503800000000000000",
      "author" => %{"id" => "1476753643834183691", "bot" => false}
    }

    assert capture_log(fn ->
             assert {:noreply, ^state} =
                      Transport.handle_info(
                        {:discord_event, {:MESSAGE_CREATE, message, nil}},
                        state
                      )
           end) == ""
  end
end
