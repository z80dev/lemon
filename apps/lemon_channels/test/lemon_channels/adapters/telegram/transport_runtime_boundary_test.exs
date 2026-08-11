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
  @model_catalog_file Path.expand(
                        "../../../../../agent_core/lib/lemon_agent/model_runtime/model_catalog.ex",
                        __DIR__
                      )

  test "telegram provider availability goes through model runtime credentials" do
    model_picker_source = File.read!(@model_picker_file)
    callback_handler_source = File.read!(@callback_handler_file)
    model_catalog_source = File.read!(@model_catalog_file)

    # Both transport modules delegate provider/model catalog resolution to the
    # shared LemonAgent.ModelRuntime.ModelCatalog facade instead of duplicating
    # credential-lookup logic locally.
    assert model_picker_source =~ "LemonAgent.ModelRuntime.ModelCatalog"
    assert callback_handler_source =~ "LemonAgent.ModelRuntime.ModelCatalog"

    # The facade itself is the one place that must go through model runtime
    # credentials.
    assert model_catalog_source =~ "Credentials.provider_has_credentials?"

    refute model_picker_source =~ "provider_secret_candidates("
    refute callback_handler_source =~ "provider_secret_candidates("
    refute model_catalog_source =~ "provider_secret_candidates("
  end
end
