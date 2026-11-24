defmodule LemonChannels.OpenAIVoiceProvider do
  @moduledoc """
  Channel voice-reply provider backed by `LemonMedia.Providers.SpeechStream`.

  Audio is bounded by `LemonChannels.VoiceReply.max_audio_bytes/0`.
  """
  @behaviour LemonChannels.VoiceProvider

  @impl true
  def synthesize(text, config, context) do
    context = Map.put_new(context, :max_audio_bytes, LemonChannels.VoiceReply.max_audio_bytes())
    LemonMedia.Providers.SpeechStream.synthesize(text, config, context)
  end
end
