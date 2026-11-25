defmodule LemonMedia.Providers do
  @moduledoc """
  The single entry point for media provider drivers.

  `run/1` takes a request map and returns media-job updates
  (`{:ok, %{artifact_path: _, mime_type: _, bytes: _, ...}}`) or a redacted
  `{:error, reason}`. It is the runner body of a `LemonMedia.MediaJobSupervisor`
  job. Request keys:

    * `:provider` - provider id, e.g. `"openai_image"` or `"local_svg"`
    * `:attrs` - the running job attrs (`:prompt` carries the prompt/text)
    * `:artifact_path` - where the artifact is written
    * `:generation` - validated provider parameters (model, format, retries, ...)
    * `:runtime` - resolved endpoint and credentials: `:credential` (0-arity
      function returning `{:ok, key}` or `{:error, reason}`), `:base_url`,
      `:http_post`/`:http_get`, or for Google providers `:access_token` /
      `:service_account_json`, `:token_http_post`, `:project`, `:location`
    * `:input` - local inputs (`:image` and `:prompt` for vision, `:audio` for
      transcription)

  Callers (the lemon_skills media tools) only validate parameters and resolve
  credentials; every provider HTTP client lives under `LemonMedia.Providers.*`.
  """

  alias LemonMedia.Providers.{Image, Speech, Transcription, Video, Vision}

  @drivers %{
    "local_svg" => Image,
    "openai_image" => Image,
    "vertex_imagen" => Image,
    "local_wav" => Speech,
    "openai_tts" => Speech,
    "elevenlabs_tts" => Speech,
    "google_tts" => Speech,
    "local_mp4" => Video,
    "openai_video" => Video,
    "vertex_veo" => Video,
    "local_vision" => Vision,
    "openai_vision" => Vision,
    "local_transcript" => Transcription,
    "openai_transcribe" => Transcription,
    "deepgram_transcribe" => Transcription
  }

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(%{provider: provider} = request) do
    case Map.fetch(@drivers, provider) do
      {:ok, driver} -> driver.run(request)
      :error -> {:error, :unsupported_media_provider}
    end
  end
end
