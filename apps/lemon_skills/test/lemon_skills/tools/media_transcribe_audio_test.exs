defmodule LemonSkills.Tools.MediaTranscribeAudioTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias LemonSkills.Tools.MediaTranscribeAudio
  alias LemonCore.MediaJobs

  @moduletag :tmp_dir

  test "generates a supervised local transcript preview without leaking audio bytes", %{
    tmp_dir: tmp_dir
  } do
    audio_path = Path.join(tmp_dir, "sample.wav")
    audio_bytes = wav_bytes()
    File.write!(audio_path, audio_bytes)

    tool = LemonSkills.Tools.MediaTranscribeAudio.tool(tmp_dir)

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "audioPath" => "sample.wav",
                 "filename" => "sample-transcript",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert result.details["status"] == "completed"
    assert result.details["type"] == "stt"
    assert result.details["provider"] == "local_transcript"
    assert result.details["model"] == "local_transcript_preview"
    assert result.trust == :untrusted
    assert result.details["trustMetadata"]["untrusted"] == true
    assert result.details["trustMetadata"]["wrappedFields"] == ["text"]
    assert is_binary(result.details["input_hash"])
    assert result.details["text"] =~ "local transcript preview"

    artifact = result.details["artifact"]
    assert artifact["filename"] == "sample-transcript.json"
    assert artifact["mime_type"] == "application/json"
    assert String.starts_with?(artifact["path"], Path.join(tmp_dir, ".lemon/media-artifacts"))
    assert File.regular?(artifact["path"])
    assert artifact["bytes"] == File.stat!(artifact["path"]).size

    refute inspect(result.details) =~ audio_bytes

    assert [
             %{
               "path" => path,
               "filename" => "sample-transcript.json",
               "caption" => "generated transcript",
               "source" => "generated"
             }
           ] = result.details["auto_send_files"]

    assert path == artifact["path"]

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.type == :stt
    assert job.prompt_hash == result.details["input_hash"]
    assert job.artifact.exists == true
    refute inspect(job) =~ audio_bytes
    refute inspect(job) =~ audio_path
  end

  test "generates OpenAI transcription artifact through the supervised worker",
       %{tmp_dir: tmp_dir} do
    audio_path = Path.join(tmp_dir, "provider.wav")
    File.write!(audio_path, wav_bytes())
    transcript = "redacted transcript output"
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])
      {:ok, %Req.Response{status: 200, body: %{"text" => transcript}}}
    end

    tool =
      MediaTranscribeAudio.tool(tmp_dir,
        openai_transcription_api_key: "sk-test-stt-key",
        openai_transcription_base_url: "https://api.openai.test/v1/",
        media_transcription_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "audioPath" => "provider.wav",
                 "provider" => "openai_transcribe",
                 "model" => "gpt-4o-mini-transcribe-test",
                 "language" => "en",
                 "prompt" => "project vocabulary",
                 "filename" => "provider-transcript",
                 "responseFormat" => "json",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [{"https://api.openai.test/v1/audio/transcriptions", request_opts}] =
             Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer sk-test-stt-key"} in request_opts[:headers]

    assert {"content-type", content_type} =
             List.keyfind(request_opts[:headers], "content-type", 0)

    assert content_type =~ "multipart/form-data"
    assert request_opts[:body] =~ "gpt-4o-mini-transcribe-test"
    assert request_opts[:body] =~ "provider.wav"
    assert request_opts[:body] =~ "project vocabulary"

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "openai_transcribe"
    assert result.details["model"] == "gpt-4o-mini-transcribe-test"
    assert result.trust == :untrusted
    assert result.details["trust_metadata"]["wrapped_fields"] == ["text"]
    assert result.details["text"] == transcript

    artifact = result.details["artifact"]
    assert artifact["filename"] == "provider-transcript.json"
    assert artifact["mime_type"] == "application/json"
    assert Jason.decode!(File.read!(artifact["path"]))["text"] == transcript

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "openai_transcribe"
    assert job.model == "gpt-4o-mini-transcribe-test"
    refute inspect(job) =~ transcript
  end

  test "generates Deepgram transcription artifact through the supervised worker",
       %{tmp_dir: tmp_dir} do
    audio_path = Path.join(tmp_dir, "deepgram.wav")
    File.write!(audio_path, wav_bytes())
    transcript = "deepgram transcript output"
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "results" => %{
             "channels" => [
               %{"alternatives" => [%{"transcript" => transcript}]}
             ]
           }
         }
       }}
    end

    tool =
      MediaTranscribeAudio.tool(tmp_dir,
        deepgram_transcription_api_key: "dg-test-key",
        deepgram_transcription_base_url: "https://api.deepgram.test/v1",
        media_transcription_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "audioPath" => "deepgram.wav",
                 "provider" => "deepgram_transcribe",
                 "model" => "nova-3",
                 "language" => "en",
                 "filename" => "deepgram-transcript",
                 "responseFormat" => "json",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [{url, request_opts}] = Agent.get(requests, &Enum.reverse/1)
    assert url =~ "https://api.deepgram.test/v1/listen?"
    assert url =~ "model=nova-3"
    assert url =~ "smart_format=true"
    assert url =~ "language=en"
    assert {"authorization", "Token dg-test-key"} in request_opts[:headers]
    assert {"content-type", "audio/wav"} in request_opts[:headers]
    assert request_opts[:body] == wav_bytes()

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "deepgram_transcribe"
    assert result.details["model"] == "nova-3"
    assert result.details["text"] == transcript
    assert result.trust == :untrusted

    artifact = result.details["artifact"]
    assert artifact["filename"] == "deepgram-transcript.json"
    assert artifact["mime_type"] == "application/json"

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "deepgram_transcribe"
    refute inspect(job) =~ transcript
  end

  test "retries transient OpenAI transcription provider failures", %{tmp_dir: tmp_dir} do
    audio_path = Path.join(tmp_dir, "retry.wav")
    File.write!(audio_path, wav_bytes())
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    http_post = fn _url, _request_opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        {:ok, %Req.Response{status: 429, body: %{"error" => %{"type" => "rate_limit"}}}}
      else
        {:ok, %Req.Response{status: 200, body: %{"text" => "retry transcript"}}}
      end
    end

    tool =
      MediaTranscribeAudio.tool(tmp_dir,
        openai_transcription_api_key: "sk-test-stt-key",
        media_transcription_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "audioPath" => "retry.wav",
                 "provider" => "openai_transcribe",
                 "filename" => "retry-transcript",
                 "maxRetries" => 1
               },
               nil,
               nil
             )

    assert Agent.get(attempts, & &1) == 2
    assert result.details["text"] == "retry transcript"
  end

  test "redacts OpenAI transcription provider errors from failed jobs", %{tmp_dir: tmp_dir} do
    audio_path = Path.join(tmp_dir, "rejected.wav")
    File.write!(audio_path, wav_bytes())
    provider_message = "private provider rejection"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 400,
         body: %{"error" => %{"type" => "invalid_request_error", "message" => provider_message}}
       }}
    end

    tool =
      MediaTranscribeAudio.tool(tmp_dir,
        openai_transcription_api_key: "sk-test-stt-key",
        media_transcription_http_post: http_post
      )

    assert {:error, "media job failed: openai_transcription_http_error:invalid_request_error"} =
             tool.execute.(
               "call-1",
               %{"audioPath" => "rejected.wav", "provider" => "openai_transcribe"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "openai_transcription_http_error:invalid_request_error"
    refute inspect(job) =~ provider_message
  end

  test "rejects audio paths outside the project", %{tmp_dir: tmp_dir} do
    tool = LemonSkills.Tools.MediaTranscribeAudio.tool(tmp_dir)

    assert {:error, "audioPath must be under the current project"} =
             tool.execute.("call-1", %{"audioPath" => "/etc/passwd"}, nil, nil)
  end

  defp wav_bytes do
    "RIFF" <> <<36::little-32>> <> "WAVEfmt " <> <<16::little-32>> <> "data"
  end
end
