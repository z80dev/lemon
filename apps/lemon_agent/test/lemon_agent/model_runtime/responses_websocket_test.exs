defmodule LemonAgent.ModelRuntime.ResponsesWebSocketTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.StreamOptions
  alias LemonAi.Types.Model

  test "TOML provider opt-in survives config and runtime resolution" do
    {:ok, settings} =
      Toml.decode("""
      [providers.openai.provider_options]
      responses_websocket = true

      [providers.openai-codex.provider_options]
      responses_websocket = true

      [providers.responses-gateway]
      api = "openai_responses"
      base_url = "https://example.invalid/v1"
      auth = "none"

      [providers.responses-gateway.provider_options]
      responses_websocket = true
      """)

    providers = LemonCore.Config.Providers.resolve(settings).providers

    for {provider, api} <- [
          {:openai, :openai_responses},
          {:openai_codex, :openai_codex_responses},
          {"responses-gateway", :openai_responses}
        ] do
      model = model(provider, api)
      options = StreamOptions.build_stream_options(model, providers, nil, nil)
      assert options.provider_options.responses_websocket
      refute Map.has_key?(options.provider_options, :responses_transport)

      resolved = StreamOptions.build_stream_options(model, providers, options, nil)
      assert resolved.provider_options.responses_websocket
    end
  end

  test "caller false overrides configured true and runtime transport is retained" do
    providers = %{"openai" => %{provider_options: %{"responses_websocket" => true}}}
    model = model(:openai, :openai_responses)

    options =
      StreamOptions.build_stream_options(
        model,
        providers,
        %{provider_options: %{responses_websocket: false}},
        nil
      )

    refute options.provider_options.responses_websocket

    options =
      StreamOptions.build_stream_options(
        model,
        providers,
        %{provider_options: %{responses_transport: self()}},
        nil
      )

    assert options.provider_options.responses_websocket
    assert options.provider_options.responses_transport == self()
  end

  test "provider switches resolve the destination opt-in without carrying the transport" do
    providers = %{
      "openai" => %{provider_options: %{"responses_websocket" => true}},
      "openai-codex" => %{provider_options: %{"responses_websocket" => false}}
    }

    original =
      StreamOptions.build_stream_options(
        model(:openai, :openai_responses),
        providers,
        %{provider_options: %{responses_transport: self()}},
        nil
      )

    options =
      StreamOptions.build_stream_options(
        model(:openai_codex, :openai_codex_responses),
        providers,
        StreamOptions.sanitize_for_provider_switch(original),
        nil
      )

    refute options.provider_options.responses_websocket
    refute Map.has_key?(options.provider_options, :responses_transport)
  end

  test "default and unsupported wire APIs do not opt in" do
    default = StreamOptions.build_stream_options(model(:openai, :openai_responses), %{}, nil, nil)
    refute Map.has_key?(default.provider_options, :responses_websocket)

    providers = %{"openai" => %{provider_options: %{"responses_websocket" => true}}}

    for api <- [:openai_completions, :azure_openai_responses] do
      options = StreamOptions.build_stream_options(model(:openai, api), providers, nil, nil)
      refute Map.has_key?(options.provider_options, :responses_websocket)
      refute Map.has_key?(options.provider_options, :responses_transport)
    end
  end

  defp model(provider, api),
    do: %Model{provider: provider, api: api, id: "responses-fixture", name: "Responses fixture"}
end
