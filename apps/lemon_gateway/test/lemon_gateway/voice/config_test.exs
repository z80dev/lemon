defmodule LemonGateway.Voice.ConfigTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Voice.Config

  @gateway_config_key :"Elixir.LemonGateway.Config"

  setup do
    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)
    old_voice_enabled = Application.get_env(:lemon_gateway, :voice_enabled)
    old_voice_timeout = Application.get_env(:lemon_gateway, :voice_silence_timeout_ms)

    on_exit(fn ->
      restore_env(:lemon_gateway, @gateway_config_key, old_gateway_env)
      restore_env(:lemon_gateway, :voice_enabled, old_voice_enabled)
      restore_env(:lemon_gateway, :voice_silence_timeout_ms, old_voice_timeout)
    end)

    :ok
  end

  test "reads canonical gateway voice config before legacy app env" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      voice: %{
        enabled: true,
        websocket_port: 4101,
        silence_timeout_ms: 2345,
        llm_model: "gpt-4.1-mini"
      }
    })

    Application.put_env(:lemon_gateway, :voice_enabled, false)
    Application.put_env(:lemon_gateway, :voice_silence_timeout_ms, 9999)

    assert Config.enabled?() == true
    assert Config.websocket_port() == 4101
    assert Config.silence_timeout_ms() == 2345
    assert Config.llm_model() == "gpt-4.1-mini"
  end

  test "an explicit enabled = false is not overridden by legacy voice_enabled" do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{voice: %{enabled: false}})
    Application.put_env(:lemon_gateway, :voice_enabled, true)

    refute Config.enabled?()
  end

  test "a public_url that passes validation reaches the consumer unchanged as https" do
    {:ok, settings} =
      Toml.decode("""
      [gateway.voice]
      public_url = "https://voice.example.com/base/"
      """)

    assert {:ok, config} = LemonCore.Config.Modular.validate_settings(settings)
    Application.put_env(:lemon_gateway, @gateway_config_key, config.gateway)

    assert Config.public_url() == "https://voice.example.com/base/"
    assert String.starts_with?(Config.public_url(), "https://")

    for bad <- [
          " https://voice.example.com",
          "HTTPS://voice.example.com",
          "http://voice.example.com"
        ] do
      assert {:error, errors} =
               LemonCore.Config.Modular.validate_settings(%{
                 "gateway" => %{"voice" => %{"public_url" => bad}}
               })

      assert "gateway.voice.public_url: must be an absolute https URL" in errors
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
