defmodule LemonSkills.Tools.MediaToolSchemasTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Tools.{
    MediaAnalyzeImage,
    MediaGenerateImage,
    MediaGenerateSpeech,
    MediaGenerateVideo,
    MediaStatus,
    MediaTranscribeAudio
  }

  @cases [
    {MediaAnalyzeImage, "media_analyze_image", ~w(imagePath provider),
     ~w(imagePath prompt provider model detail filename responseFormat maxRetries sendToChannel timeoutMs),
     ~w(local_vision openai_vision)},
    {MediaGenerateImage, "media_generate_image", ~w(prompt provider),
     ~w(prompt provider model filename size quality outputFormat maxRetries sendToChannel timeoutMs),
     ~w(local_svg openai_image vertex_imagen)},
    {MediaGenerateSpeech, "media_generate_speech", ~w(text provider),
     ~w(text provider model voice languageCode instructions filename responseFormat speed maxRetries sendToChannel timeoutMs),
     ~w(local_wav openai_tts elevenlabs_tts google_tts)},
    {MediaGenerateVideo, "media_generate_video", ~w(prompt provider),
     ~w(prompt provider model filename size seconds storageUri maxRetries maxPolls pollIntervalMs sendToChannel timeoutMs),
     ~w(local_mp4 openai_video vertex_veo)},
    {MediaStatus, "media_status", [], ["limit"], nil},
    {MediaTranscribeAudio, "media_transcribe_audio", ~w(audioPath provider),
     ~w(audioPath provider model language prompt filename responseFormat maxRetries sendToChannel timeoutMs),
     ~w(local_transcript openai_transcribe deepgram_transcribe)}
  ]

  for {module, name, required, keys, providers} <- @cases do
    test "#{name} preserves its tool schema" do
      tool = unquote(module).tool(File.cwd!())

      assert tool.name == unquote(name)

      assert %{"type" => "object", "required" => unquote(required), "properties" => properties} =
               tool.parameters

      assert Enum.sort(Map.keys(properties)) == Enum.sort(unquote(keys))
      assert get_in(properties, ["provider", "enum"]) == unquote(providers)
    end
  end
end
