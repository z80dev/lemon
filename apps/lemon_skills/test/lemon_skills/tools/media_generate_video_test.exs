defmodule LemonSkills.Tools.MediaGenerateVideoTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias LemonSkills.Tools.MediaGenerateVideo
  alias LemonMedia.MediaJobs

  @moduletag :tmp_dir

  test "generates a supervised local MP4 video without leaking the prompt", %{tmp_dir: tmp_dir} do
    prompt = "private video prompt 123"
    tool = LemonSkills.Tools.MediaGenerateVideo.tool(tmp_dir)

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{"prompt" => prompt, "filename" => "preview-video", "sendToChannel" => true},
               nil,
               nil
             )

    assert result.details["status"] == "completed"
    assert result.details["type"] == "video"
    assert result.details["provider"] == "local_mp4"
    assert result.details["model"] == "local_mp4_preview"
    assert result.details["prompt_chars"] == String.length(prompt)
    assert is_binary(result.details["prompt_hash"])

    artifact = result.details["artifact"]
    assert artifact["filename"] == "preview-video.mp4"
    assert artifact["mime_type"] == "video/mp4"
    assert String.starts_with?(artifact["path"], Path.join(tmp_dir, ".lemon/media-artifacts"))
    assert File.regular?(artifact["path"])
    assert artifact["bytes"] == File.stat!(artifact["path"]).size
    assert File.read!(artifact["path"]) =~ "ftyp"

    refute inspect(result.details) =~ prompt

    assert [
             %{
               "path" => path,
               "filename" => "preview-video.mp4",
               "caption" => "generated video preview",
               "source" => "generated"
             }
           ] = result.details["auto_send_files"]

    assert path == artifact["path"]

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.type == :video
    assert job.prompt_hash == result.details["prompt_hash"]
    assert job.artifact.exists == true
    refute inspect(job) =~ prompt
  end

  test "generates OpenAI video artifact through create poll and download",
       %{tmp_dir: tmp_dir} do
    prompt = "private provider video prompt"
    video_bytes = "video-bytes"
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{:post, url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => "video-secret-id", "status" => "queued"}
       }}
    end

    http_get = fn url, request_opts ->
      Agent.update(requests, &[{:get, url, request_opts} | &1])

      cond do
        String.ends_with?(url, "/videos/video-secret-id") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"id" => "video-secret-id", "status" => "completed"}
           }}

        String.ends_with?(url, "/videos/video-secret-id/content") ->
          {:ok, %Req.Response{status: 200, body: video_bytes}}
      end
    end

    tool =
      MediaGenerateVideo.tool(tmp_dir,
        openai_video_api_key: "sk-test-video-key",
        openai_video_base_url: "https://api.openai.test/v1/",
        media_video_http_post: http_post,
        media_video_http_get: http_get
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "prompt" => prompt,
                 "provider" => "openai_video",
                 "model" => "sora-2-test",
                 "filename" => "provider-video",
                 "size" => "1280x720",
                 "seconds" => "4",
                 "pollIntervalMs" => 0,
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [
             {:post, "https://api.openai.test/v1/videos", post_opts},
             {:get, "https://api.openai.test/v1/videos/video-secret-id", status_opts},
             {:get, "https://api.openai.test/v1/videos/video-secret-id/content", download_opts}
           ] = Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer sk-test-video-key"} in post_opts[:headers]
    assert {"authorization", "Bearer sk-test-video-key"} in status_opts[:headers]
    assert {"authorization", "Bearer sk-test-video-key"} in download_opts[:headers]
    assert post_opts[:json]["prompt"] == prompt
    assert post_opts[:json]["model"] == "sora-2-test"
    assert post_opts[:json]["size"] == "1280x720"
    assert post_opts[:json]["seconds"] == "4"

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "openai_video"
    assert result.details["model"] == "sora-2-test"
    assert result.details["prompt_chars"] == String.length(prompt)

    artifact = result.details["artifact"]
    assert artifact["filename"] == "provider-video.mp4"
    assert artifact["mime_type"] == "video/mp4"
    assert File.read!(artifact["path"]) == video_bytes
    assert artifact["bytes"] == byte_size(video_bytes)

    refute inspect(result.details) =~ prompt
    refute inspect(result.details) =~ "video-secret-id"

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "openai_video"
    assert job.model == "sora-2-test"
    refute inspect(job) =~ prompt
    refute inspect(job) =~ "video-secret-id"
  end

  test "generates Vertex Veo video artifact through long-running operation",
       %{tmp_dir: tmp_dir} do
    prompt = "private vertex video prompt"
    video_bytes = "vertex-video-bytes"
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      cond do
        String.ends_with?(url, ":predictLongRunning") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"name" => "operations/private-veo-operation"}
           }}

        String.ends_with?(url, ":fetchPredictOperation") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "name" => "operations/private-veo-operation",
               "done" => true,
               "response" => %{
                 "generatedVideos" => [
                   %{
                     "video" => %{
                       "bytesBase64Encoded" => Base.encode64(video_bytes),
                       "mimeType" => "video/mp4"
                     }
                   }
                 ]
               }
             }
           }}
      end
    end

    tool =
      MediaGenerateVideo.tool(tmp_dir,
        vertex_veo_access_token: "vertex-test-token",
        vertex_veo_project: "test-project",
        vertex_veo_location: "us-central1",
        media_video_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "prompt" => prompt,
                 "provider" => "vertex_veo",
                 "model" => "veo-test-model",
                 "filename" => "vertex-video",
                 "size" => "1280x720",
                 "seconds" => "4",
                 "pollIntervalMs" => 0,
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [
             {create_url, create_opts},
             {fetch_url, fetch_opts}
           ] = Agent.get(requests, &Enum.reverse/1)

    assert create_url ==
             "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google/models/veo-test-model:predictLongRunning"

    assert fetch_url ==
             "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google/models/veo-test-model:fetchPredictOperation"

    assert {"authorization", "Bearer vertex-test-token"} in create_opts[:headers]
    assert {"authorization", "Bearer vertex-test-token"} in fetch_opts[:headers]
    assert create_opts[:json]["instances"] == [%{"prompt" => prompt}]
    assert create_opts[:json]["parameters"]["sampleCount"] == 1
    assert create_opts[:json]["parameters"]["durationSeconds"] == 4
    assert create_opts[:json]["parameters"]["aspectRatio"] == "16:9"
    assert fetch_opts[:json]["operationName"] == "operations/private-veo-operation"

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "vertex_veo"
    assert result.details["model"] == "veo-test-model"

    artifact = result.details["artifact"]
    assert artifact["filename"] == "vertex-video.mp4"
    assert artifact["mime_type"] == "video/mp4"
    assert File.read!(artifact["path"]) == video_bytes
    assert artifact["bytes"] == byte_size(video_bytes)

    refute inspect(result.details) =~ prompt
    refute inspect(result.details) =~ "private-veo-operation"

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "vertex_veo"
    assert job.model == "veo-test-model"
    refute inspect(job) =~ prompt
    refute inspect(job) =~ "private-veo-operation"
  end

  test "retries transient OpenAI video create failures", %{tmp_dir: tmp_dir} do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    http_post = fn _url, _request_opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        {:ok, %Req.Response{status: 429, body: %{"error" => %{"type" => "rate_limit"}}}}
      else
        {:ok, %Req.Response{status: 200, body: %{"id" => "video-id", "status" => "completed"}}}
      end
    end

    http_get = fn _url, _request_opts ->
      {:ok, %Req.Response{status: 200, body: "retry-video"}}
    end

    tool =
      MediaGenerateVideo.tool(tmp_dir,
        openai_video_api_key: "sk-test-video-key",
        media_video_http_post: http_post,
        media_video_http_get: http_get
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "prompt" => "private retry video prompt",
                 "provider" => "openai_video",
                 "filename" => "retry-video",
                 "maxRetries" => 1
               },
               nil,
               nil
             )

    assert Agent.get(attempts, & &1) == 2
    assert File.read!(result.details["artifact"]["path"]) == "retry-video"
  end

  test "redacts OpenAI video provider errors from failed jobs", %{tmp_dir: tmp_dir} do
    prompt = "private rejected video prompt"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 400,
         body: %{"error" => %{"type" => "invalid_request_error", "message" => prompt}}
       }}
    end

    tool =
      MediaGenerateVideo.tool(tmp_dir,
        openai_video_api_key: "sk-test-video-key",
        media_video_http_post: http_post
      )

    assert {:error, "media job failed: openai_video_create_http_error:invalid_request_error"} =
             tool.execute.(
               "call-1",
               %{"prompt" => prompt, "provider" => "openai_video"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "openai_video_create_http_error:invalid_request_error"
    refute inspect(job) =~ prompt
  end

  test "redacts Vertex Veo provider errors from failed jobs", %{tmp_dir: tmp_dir} do
    prompt = "private rejected vertex video prompt"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 403,
         body: %{"error" => %{"status" => "PERMISSION_DENIED", "message" => prompt}}
       }}
    end

    tool =
      MediaGenerateVideo.tool(tmp_dir,
        vertex_veo_access_token: "vertex-test-token",
        vertex_veo_project: "test-project",
        vertex_veo_location: "us-central1",
        media_video_http_post: http_post
      )

    assert {:error, "media job failed: vertex_veo_create_http_error:permission_denied"} =
             tool.execute.(
               "call-1",
               %{"prompt" => prompt, "provider" => "vertex_veo"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "vertex_veo_create_http_error:permission_denied"
    refute inspect(job) =~ prompt
  end

  test "rejects unsupported providers", %{tmp_dir: tmp_dir} do
    tool = LemonSkills.Tools.MediaGenerateVideo.tool(tmp_dir)

    assert {:error, "unsupported media video provider: remote"} =
             tool.execute.(
               "call-1",
               %{"prompt" => "make a clip", "provider" => "remote"},
               nil,
               nil
             )
  end
end
