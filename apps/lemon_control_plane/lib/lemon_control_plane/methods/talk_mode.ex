defmodule LemonControlPlane.Methods.TalkMode do
  @moduledoc """
  Handler for the talk.mode control plane method.

  Gets or sets the talk mode (voice interaction mode) for a session.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.TalkModeStore

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
    mode = TalkModeStore.get(session_key) || %{mode: :off}
    mode_value = to_string(mode[:mode] || :off)

    {:ok,
     %{
       "sessionKey" => session_key,
       "mode" => mode_value,
       "provider" => mode[:provider],
       "voice" => mode[:voice],
       "summary" => summary(session_key, mode_value, false)
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

      TalkModeStore.put(session_key, config)

      # Broadcast talk.mode event
      event =
        LemonCore.Event.new(:talk_mode_changed, %{
          session_key: session_key,
          mode: mode
        })

      LemonCore.Bus.broadcast("system", event)

      {:ok,
       %{
         "sessionKey" => session_key,
         "mode" => mode,
         "set" => true,
         "summary" => summary(session_key, mode, true)
       }}
    else
      {:error,
       LemonControlPlane.Protocol.Errors.invalid_request(
         "Invalid mode. Must be one of: #{Enum.join(valid_modes, ", ")}"
       )}
    end
  end

  defp summary(session_key, mode, set?) do
    %{
      "sessionKey" => session_key,
      "mode" => mode,
      "set" => set?,
      "cleanup" => %{
        "includesAudio" => false,
        "includesTranscript" => false,
        "includesSecretValues" => false
      }
    }
  end
end
