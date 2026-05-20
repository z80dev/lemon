defmodule CodingAgent.Tools.MediaGenerateSpeechTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools
  alias CodingAgent.Tools.MediaGenerateSpeech
  alias LemonCore.MediaJobs

  @moduletag :tmp_dir

  test "generates a supervised local WAV preview without leaking text", %{tmp_dir: tmp_dir} do
    text = "private spoken phrase 123"
    tool = Tools.get_tool("media_generate_speech", tmp_dir)

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{"text" => text, "filename" => "speech-card", "sendToChannel" => true},
               nil,
               nil
             )

    assert result.details["status"] == "completed"
    assert result.details["type"] == "tts"
    assert result.details["provider"] == "local_wav"
    assert result.details["model"] == "local_wav_preview"
    assert result.details["prompt_chars"] == String.length(text)
    assert is_binary(result.details["prompt_hash"])

    artifact = result.details["artifact"]
    assert artifact["filename"] == "speech-card.wav"
    assert artifact["mime_type"] == "audio/wav"
    assert String.starts_with?(artifact["path"], Path.join(tmp_dir, ".lemon/media-artifacts"))
    assert File.regular?(artifact["path"])
    assert File.read!(artifact["path"]) =~ "WAVE"
    assert artifact["bytes"] == File.stat!(artifact["path"]).size

    refute inspect(result.details) =~ text
    refute File.read!(artifact["path"]) =~ text

    assert [
             %{
               "path" => path,
               "filename" => "speech-card.wav",
               "caption" => "generated speech",
               "source" => "generated"
             }
           ] = result.details["auto_send_files"]

    assert path == artifact["path"]

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.type == :tts
    assert job.prompt_hash == result.details["prompt_hash"]
    assert job.artifact.exists == true
    refute inspect(job) =~ text
  end

  test "generates OpenAI TTS artifact through the supervised worker without leaking text",
       %{tmp_dir: tmp_dir} do
    text = "private provider speech 456"
    audio_bytes = "fake-mp3-bytes"
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])
      {:ok, %Req.Response{status: 200, body: audio_bytes}}
    end

    tool =
      MediaGenerateSpeech.tool(tmp_dir,
        openai_tts_api_key: "sk-test-tts-key",
        openai_tts_base_url: "https://api.openai.test/v1/",
        media_speech_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "text" => text,
                 "provider" => "openai_tts",
                 "model" => "gpt-4o-mini-tts-test",
                 "voice" => "alloy",
                 "instructions" => "calm",
                 "filename" => "provider-speech",
                 "responseFormat" => "mp3",
                 "speed" => 1.25,
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [{"https://api.openai.test/v1/audio/speech", request_opts}] =
             Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer sk-test-tts-key"} in request_opts[:headers]
    assert request_opts[:json]["input"] == text
    assert request_opts[:json]["model"] == "gpt-4o-mini-tts-test"
    assert request_opts[:json]["voice"] == "alloy"
    assert request_opts[:json]["instructions"] == "calm"
    assert request_opts[:json]["response_format"] == "mp3"
    assert request_opts[:json]["speed"] == 1.25

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "openai_tts"
    assert result.details["model"] == "gpt-4o-mini-tts-test"
    assert result.details["prompt_chars"] == String.length(text)

    artifact = result.details["artifact"]
    assert artifact["filename"] == "provider-speech.mp3"
    assert artifact["mime_type"] == "audio/mpeg"
    assert File.read!(artifact["path"]) == audio_bytes
    assert artifact["bytes"] == byte_size(audio_bytes)

    refute inspect(result.details) =~ text

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "openai_tts"
    assert job.model == "gpt-4o-mini-tts-test"
    assert job.artifact.mime_type == "audio/mpeg"
    refute inspect(job) =~ text
  end

  test "generates ElevenLabs TTS artifact through the supervised worker without leaking text",
       %{tmp_dir: tmp_dir} do
    text = "private elevenlabs speech"
    audio_bytes = "fake-elevenlabs-mp3"
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])
      {:ok, %Req.Response{status: 200, body: audio_bytes}}
    end

    tool =
      MediaGenerateSpeech.tool(tmp_dir,
        elevenlabs_tts_api_key: "el-test-tts-key",
        elevenlabs_tts_base_url: "https://api.elevenlabs.test/v1",
        media_speech_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "text" => text,
                 "provider" => "elevenlabs_tts",
                 "model" => "eleven_turbo_v2_5",
                 "voice" => "voice_123",
                 "filename" => "elevenlabs-speech",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [{url, request_opts}] = Agent.get(requests, &Enum.reverse/1)

    assert url ==
             "https://api.elevenlabs.test/v1/text-to-speech/voice_123/stream?output_format=mp3_44100_128"

    assert {"xi-api-key", "el-test-tts-key"} in request_opts[:headers]
    assert request_opts[:json]["text"] == text
    assert request_opts[:json]["model_id"] == "eleven_turbo_v2_5"

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "elevenlabs_tts"
    assert result.details["model"] == "eleven_turbo_v2_5"

    artifact = result.details["artifact"]
    assert artifact["filename"] == "elevenlabs-speech.mp3"
    assert artifact["mime_type"] == "audio/mpeg"
    assert File.read!(artifact["path"]) == audio_bytes

    refute inspect(result.details) =~ text

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "elevenlabs_tts"
    assert job.artifact.mime_type == "audio/mpeg"
    refute inspect(job) =~ text
  end

  test "generates Google TTS artifact through the supervised worker without leaking text",
       %{tmp_dir: tmp_dir} do
    text = "private google speech"
    audio_bytes = "fake-google-mp3"
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"audioContent" => Base.encode64(audio_bytes)}
       }}
    end

    tool =
      MediaGenerateSpeech.tool(tmp_dir,
        google_tts_access_token: "google-access-token",
        google_tts_base_url: "https://texttospeech.googleapis.test/v1",
        media_speech_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "text" => text,
                 "provider" => "google_tts",
                 "model" => "cloud_tts_v1",
                 "voice" => "en-US-Neural2-C",
                 "languageCode" => "en-US",
                 "filename" => "google-speech",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [{"https://texttospeech.googleapis.test/v1/text:synthesize", request_opts}] =
             Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer google-access-token"} in request_opts[:headers]
    assert request_opts[:json]["input"] == %{"text" => text}

    assert request_opts[:json]["voice"] == %{
             "languageCode" => "en-US",
             "name" => "en-US-Neural2-C"
           }

    assert request_opts[:json]["audioConfig"] == %{"audioEncoding" => "MP3"}

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "google_tts"
    assert result.details["model"] == "cloud_tts_v1"

    artifact = result.details["artifact"]
    assert artifact["filename"] == "google-speech.mp3"
    assert artifact["mime_type"] == "audio/mpeg"
    assert File.read!(artifact["path"]) == audio_bytes

    refute inspect(result.details) =~ text

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "google_tts"
    assert job.artifact.mime_type == "audio/mpeg"
    refute inspect(job) =~ text
  end

  test "retries transient OpenAI TTS provider failures", %{tmp_dir: tmp_dir} do
    audio_bytes = "retry-audio"
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    http_post = fn _url, _request_opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        {:ok, %Req.Response{status: 500, body: %{"error" => %{"type" => "server_error"}}}}
      else
        {:ok, %Req.Response{status: 200, body: audio_bytes}}
      end
    end

    tool =
      MediaGenerateSpeech.tool(tmp_dir,
        openai_tts_api_key: "sk-test-tts-key",
        media_speech_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "text" => "private retry speech",
                 "provider" => "openai_tts",
                 "filename" => "retry-speech",
                 "maxRetries" => 1
               },
               nil,
               nil
             )

    assert Agent.get(attempts, & &1) == 2
    assert File.read!(result.details["artifact"]["path"]) == audio_bytes
  end

  test "redacts OpenAI TTS provider errors from failed jobs", %{tmp_dir: tmp_dir} do
    text = "private rejected speech"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 400,
         body: %{"error" => %{"type" => "invalid_request_error", "message" => text}}
       }}
    end

    tool =
      MediaGenerateSpeech.tool(tmp_dir,
        openai_tts_api_key: "sk-test-tts-key",
        media_speech_http_post: http_post
      )

    assert {:error, "media job failed: openai_tts_http_error:invalid_request_error"} =
             tool.execute.(
               "call-1",
               %{"text" => text, "provider" => "openai_tts"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "openai_tts_http_error:invalid_request_error"
    refute inspect(job) =~ text
  end

  test "records ElevenLabs detail status without leaking provider messages", %{tmp_dir: tmp_dir} do
    provider_message = "private authorization detail"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 401,
         body: %{"detail" => %{"status" => "needs_authorization", "message" => provider_message}}
       }}
    end

    tool =
      MediaGenerateSpeech.tool(tmp_dir,
        elevenlabs_tts_api_key: "el-test-tts-key",
        media_speech_http_post: http_post
      )

    assert {:error, "media job failed: elevenlabs_tts_http_error:needs_authorization"} =
             tool.execute.(
               "call-1",
               %{"text" => "private speech", "provider" => "elevenlabs_tts"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "elevenlabs_tts_http_error:needs_authorization"
    refute inspect(job) =~ provider_message
  end

  test "records Google TTS error status without leaking provider messages", %{tmp_dir: tmp_dir} do
    provider_message = "private Google TTS permission detail"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 403,
         body: %{
           "error" => %{
             "status" => "PERMISSION_DENIED",
             "message" => provider_message
           }
         }
       }}
    end

    tool =
      MediaGenerateSpeech.tool(tmp_dir,
        google_tts_access_token: "google-access-token",
        media_speech_http_post: http_post
      )

    assert {:error, "media job failed: google_tts_http_error:permission_denied"} =
             tool.execute.(
               "call-1",
               %{"text" => "private speech", "provider" => "google_tts"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "google_tts_http_error:permission_denied"
    refute inspect(job) =~ provider_message
  end
end
