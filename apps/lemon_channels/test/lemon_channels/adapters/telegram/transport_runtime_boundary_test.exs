defmodule LemonChannels.Adapters.Telegram.TransportRuntimeBoundaryTest do
  use ExUnit.Case, async: true

  @model_picker_file Path.expand(
                       "../../../../lib/lemon_channels/adapters/telegram/transport/model_picker.ex",
                       __DIR__
                     )
  @callback_handler_file Path.expand(
                           "../../../../lib/lemon_channels/adapters/telegram/transport/callback_handler.ex",
                           __DIR__
                         )

  test "telegram provider availability goes through LemonAiRuntime" do
    model_picker_source = File.read!(@model_picker_file)
    callback_handler_source = File.read!(@callback_handler_file)

    assert model_picker_source =~ "LemonAiRuntime.provider_has_credentials?"
    assert callback_handler_source =~ "LemonAiRuntime.provider_has_credentials?"
    refute model_picker_source =~ "provider_secret_candidates("
    refute callback_handler_source =~ "provider_secret_candidates("
  end
end
