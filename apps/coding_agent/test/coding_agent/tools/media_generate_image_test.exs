defmodule CodingAgent.Tools.MediaGenerateImageTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools
  alias CodingAgent.Tools.MediaGenerateImage
  alias LemonCore.MediaJobs

  @moduletag :tmp_dir

  test "generates a supervised local SVG image without leaking the prompt", %{tmp_dir: tmp_dir} do
    prompt = "private launch prompt 123"
    tool = Tools.get_tool("media_generate_image", tmp_dir)

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{"prompt" => prompt, "filename" => "launch-card", "sendToChannel" => true},
               nil,
               nil
             )

    assert result.details["status"] == "completed"
    assert result.details["type"] == "image"
    assert result.details["provider"] == "local_svg"
    assert result.details["model"] == "local_svg_preview"
    assert result.details["prompt_chars"] == String.length(prompt)
    assert is_binary(result.details["prompt_hash"])

    artifact = result.details["artifact"]
    assert artifact["filename"] == "launch-card.svg"
    assert artifact["mime_type"] == "image/svg+xml"
    assert String.starts_with?(artifact["path"], Path.join(tmp_dir, ".lemon/media-artifacts"))
    assert File.regular?(artifact["path"])
    assert artifact["bytes"] == File.stat!(artifact["path"]).size

    refute inspect(result.details) =~ prompt
    refute File.read!(artifact["path"]) =~ prompt

    assert [
             %{
               "path" => path,
               "filename" => "launch-card.svg",
               "caption" => "generated image preview",
               "source" => "generated"
             }
           ] = result.details["auto_send_files"]

    assert path == artifact["path"]

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.type == :image
    assert job.prompt_hash == result.details["prompt_hash"]
    assert job.artifact.exists == true
    refute inspect(job) =~ prompt
  end

  test "rejects unsupported providers", %{tmp_dir: tmp_dir} do
    tool = Tools.get_tool("media_generate_image", tmp_dir)

    assert {:error, "unsupported media provider: remote"} =
             tool.execute.("call-1", %{"prompt" => "draw this", "provider" => "remote"}, nil, nil)
  end

  test "generates an OpenAI image artifact through the supervised worker without leaking prompt",
       %{tmp_dir: tmp_dir} do
    prompt = "private provider prompt 456"
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"data" => [%{"b64_json" => Base.encode64(image_bytes)}]}
       }}
    end

    tool =
      MediaGenerateImage.tool(tmp_dir,
        openai_image_api_key: "sk-test-image-key",
        openai_image_base_url: "https://api.openai.test/v1/",
        media_image_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "prompt" => prompt,
                 "provider" => "openai_image",
                 "model" => "gpt-image-test",
                 "filename" => "provider-card",
                 "size" => "1024x1024",
                 "quality" => "high",
                 "outputFormat" => "png",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [{"https://api.openai.test/v1/images/generations", request_opts}] =
             Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer sk-test-image-key"} in request_opts[:headers]
    assert request_opts[:json]["prompt"] == prompt
    assert request_opts[:json]["model"] == "gpt-image-test"
    assert request_opts[:json]["size"] == "1024x1024"
    assert request_opts[:json]["quality"] == "high"
    assert request_opts[:json]["output_format"] == "png"

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "openai_image"
    assert result.details["model"] == "gpt-image-test"
    assert result.details["prompt_chars"] == String.length(prompt)

    artifact = result.details["artifact"]
    assert artifact["filename"] == "provider-card.png"
    assert artifact["mime_type"] == "image/png"
    assert File.read!(artifact["path"]) == image_bytes
    assert artifact["bytes"] == byte_size(image_bytes)

    refute inspect(result.details) =~ prompt

    assert [
             %{
               "path" => path,
               "filename" => "provider-card.png",
               "caption" => "generated image preview",
               "source" => "generated"
             }
           ] = result.details["auto_send_files"]

    assert path == artifact["path"]

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "openai_image"
    assert job.model == "gpt-image-test"
    assert job.artifact.mime_type == "image/png"
    refute inspect(job) =~ prompt
  end

  test "redacts OpenAI provider errors from failed jobs", %{tmp_dir: tmp_dir} do
    prompt = "private rejected provider prompt"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 400,
         body: %{"error" => %{"type" => "invalid_request_error", "message" => prompt}}
       }}
    end

    tool =
      MediaGenerateImage.tool(tmp_dir,
        openai_image_api_key: "sk-test-image-key",
        media_image_http_post: http_post
      )

    assert {:error, "media job failed: openai_image_http_error:invalid_request_error"} =
             tool.execute.(
               "call-1",
               %{"prompt" => prompt, "provider" => "openai_image"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "openai_image_http_error:invalid_request_error"
    refute inspect(job) =~ prompt
  end

  test "generates a Vertex Imagen artifact through the supervised worker without leaking prompt",
       %{tmp_dir: tmp_dir} do
    prompt = "private vertex image prompt"
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 4, 5, 6>>
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "predictions" => [
             %{"bytesBase64Encoded" => Base.encode64(image_bytes), "mimeType" => "image/png"}
           ]
         }
       }}
    end

    tool =
      MediaGenerateImage.tool(tmp_dir,
        vertex_imagen_access_token: "vertex-access-token",
        vertex_imagen_project: "lemon-test-project",
        vertex_imagen_location: "us-central1",
        media_image_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "prompt" => prompt,
                 "provider" => "vertex_imagen",
                 "model" => "imagen-4.0-generate-001",
                 "filename" => "vertex-card",
                 "size" => "1:1",
                 "outputFormat" => "png",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [
             {"https://us-central1-aiplatform.googleapis.com/v1/projects/lemon-test-project/locations/us-central1/publishers/google/models/imagen-4.0-generate-001:predict",
              request_opts}
           ] = Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer vertex-access-token"} in request_opts[:headers]
    assert request_opts[:json]["instances"] == [%{"prompt" => prompt}]
    assert request_opts[:json]["parameters"]["sampleCount"] == 1
    assert request_opts[:json]["parameters"]["aspectRatio"] == "1:1"
    assert request_opts[:json]["parameters"]["outputOptions"] == %{"mimeType" => "image/png"}

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "vertex_imagen"
    assert result.details["model"] == "imagen-4.0-generate-001"

    artifact = result.details["artifact"]
    assert artifact["filename"] == "vertex-card.png"
    assert artifact["mime_type"] == "image/png"
    assert File.read!(artifact["path"]) == image_bytes

    refute inspect(result.details) =~ prompt

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "vertex_imagen"
    assert job.model == "imagen-4.0-generate-001"
    refute inspect(job) =~ prompt
  end

  test "redacts Vertex Imagen provider errors using safe Google status labels", %{
    tmp_dir: tmp_dir
  } do
    prompt = "private vertex rejected prompt"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 403,
         body: %{
           "error" => %{
             "code" => 403,
             "status" => "PERMISSION_DENIED",
             "message" => prompt
           }
         }
       }}
    end

    tool =
      MediaGenerateImage.tool(tmp_dir,
        vertex_imagen_access_token: "vertex-access-token",
        vertex_imagen_project: "lemon-test-project",
        vertex_imagen_location: "us-central1",
        media_image_http_post: http_post
      )

    assert {:error, "media job failed: vertex_imagen_http_error:permission_denied"} =
             tool.execute.(
               "call-1",
               %{"prompt" => prompt, "provider" => "vertex_imagen"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "vertex_imagen_http_error:permission_denied"
    refute inspect(job) =~ prompt
  end

  test "retries transient OpenAI image provider failures", %{tmp_dir: tmp_dir} do
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 9, 8, 7>>
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    http_post = fn _url, _request_opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        {:ok, %Req.Response{status: 429, body: %{"error" => %{"type" => "rate_limit"}}}}
      else
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"data" => [%{"b64_json" => Base.encode64(image_bytes)}]}
         }}
      end
    end

    tool =
      MediaGenerateImage.tool(tmp_dir,
        openai_image_api_key: "sk-test-image-key",
        media_image_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "prompt" => "private retry prompt",
                 "provider" => "openai_image",
                 "filename" => "retry-card",
                 "maxRetries" => 1
               },
               nil,
               nil
             )

    assert Agent.get(attempts, & &1) == 2
    assert File.read!(result.details["artifact"]["path"]) == image_bytes
  end
end
