defmodule LemonControlPlane.Methods.TalkMode do
  @moduledoc """
  Handler for the talk.mode control plane method.

  Gets or sets the talk mode (voice interaction mode) for a session.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "talk.mode"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    session_key = params["sessionKey"] || params["session_key"]
    mode = params["mode"]

    if is_nil(mode) do
      # Get current mode
      get_talk_mode(session_key, ctx)
    else
      # Set mode
      set_talk_mode(session_key, mode, ctx)
    end
  end

  defp get_talk_mode(session_key, _ctx) do
    mode = LemonCore.Store.get(:talk_mode, session_key) || %{mode: :off}

    {:ok, %{
      "sessionKey" => session_key,
      "mode" => to_string(mode[:mode] || :off),
      "provider" => mode[:provider],
      "voice" => mode[:voice]
    }}
  end

  defp set_talk_mode(session_key, mode, ctx) do
    valid_modes = ["off", "push-to-talk", "voice-activity", "continuous"]

    if mode in valid_modes do
      config = %{
        mode: String.to_atom(mode),
        provider: ctx[:tts_provider],
        voice: ctx[:tts_voice],
        updated_at_ms: System.system_time(:millisecond)
      }

      LemonCore.Store.put(:talk_mode, session_key, config)

      # Broadcast talk.mode event
      event = LemonCore.Event.new(:talk_mode_changed, %{
        session_key: session_key,
        mode: mode
      })
      LemonCore.Bus.broadcast("system", event)

      {:ok, %{
        "sessionKey" => session_key,
        "mode" => mode,
        "set" => true
      }}
    else
      {:error, LemonControlPlane.Protocol.Errors.invalid_request(
        "Invalid mode. Must be one of: #{Enum.join(valid_modes, ", ")}"
      )}
    end
  end
end
