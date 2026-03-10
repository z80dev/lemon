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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
