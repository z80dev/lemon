defmodule LemonSkills.Tools.MediaAnalyzeImageTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonSkills.Tools.MediaAnalyzeImage
  alias LemonMedia.MediaJobs

  @moduletag :tmp_dir

  test "generates a supervised local image analysis without leaking image bytes or prompt", %{
    tmp_dir: tmp_dir
  } do
    image_path = Path.join(tmp_dir, "sample.svg")
    image_bytes = svg_bytes("private label")
    prompt = "private vision prompt 123"
    File.write!(image_path, image_bytes)

    tool = LemonSkills.Tools.MediaAnalyzeImage.tool(tmp_dir)

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "imagePath" => "sample.svg",
                 "prompt" => prompt,
                 "filename" => "sample-analysis",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert result.details["status"] == "completed"
    assert result.details["type"] == "vision"
    assert result.details["provider"] == "local_vision"
    assert result.details["model"] == "local_vision_preview"
    assert result.trust == :untrusted
    assert result.details["trustMetadata"]["untrusted"] == true
    assert result.details["trustMetadata"]["wrappedFields"] == ["text"]
    assert is_binary(result.details["input_hash"])
    assert result.details["text"] =~ "local image analysis preview"

    artifact = result.details["artifact"]
    assert artifact["filename"] == "sample-analysis.json"
    assert artifact["mime_type"] == "application/json"
    assert String.starts_with?(artifact["path"], Path.join(tmp_dir, ".lemon/media-artifacts"))
    assert File.regular?(artifact["path"])
    assert artifact["bytes"] == File.stat!(artifact["path"]).size

    refute inspect(result.details) =~ image_bytes
    refute inspect(result.details) =~ prompt

    assert [
             %{
               "path" => path,
               "filename" => "sample-analysis.json",
               "caption" => "generated image analysis",
               "source" => "generated"
             }
           ] = result.details["auto_send_files"]

    assert path == artifact["path"]

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.type == :vision
    assert job.prompt_hash == result.details["input_hash"]
    assert job.artifact.exists == true
    refute inspect(job) =~ image_bytes
    refute inspect(job) =~ image_path
    refute inspect(job) =~ prompt
  end

  test "generates OpenAI vision analysis through the supervised worker", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "provider.png")
    image_bytes = png_bytes()
    prompt = "private image question"
    analysis = "The image contains a red square."
    File.write!(image_path, image_bytes)
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => analysis}}]}
       }}
    end

    tool =
      MediaAnalyzeImage.tool(tmp_dir,
        openai_vision_api_key: "sk-test-vision-key",
        openai_vision_base_url: "https://api.openai.test/v1/",
        media_vision_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "imagePath" => "provider.png",
                 "provider" => "openai_vision",
                 "model" => "gpt-4o-mini-test",
                 "detail" => "low",
                 "prompt" => prompt,
                 "filename" => "provider-analysis",
                 "sendToChannel" => true
               },
               nil,
               nil
             )

    assert [{"https://api.openai.test/v1/chat/completions", request_opts}] =
             Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer sk-test-vision-key"} in request_opts[:headers]
    assert request_opts[:json]["model"] == "gpt-4o-mini-test"

    [%{"content" => content}] = request_opts[:json]["messages"]
    assert %{"type" => "text", "text" => ^prompt} = Enum.at(content, 0)

    assert %{
             "type" => "image_url",
             "image_url" => %{"url" => image_url, "detail" => "low"}
           } = Enum.at(content, 1)

    assert String.starts_with?(image_url, "data:image/png;base64,")

    assert result.details["status"] == "completed"
    assert result.details["provider"] == "openai_vision"
    assert result.details["model"] == "gpt-4o-mini-test"
    assert result.trust == :untrusted
    assert result.details["trust_metadata"]["wrapped_fields"] == ["text"]
    assert result.details["text"] == analysis

    artifact = result.details["artifact"]
    assert artifact["filename"] == "provider-analysis.json"
    assert artifact["mime_type"] == "application/json"
    assert Jason.decode!(File.read!(artifact["path"]))["text"] == analysis

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :completed
    assert job.provider == "openai_vision"
    assert job.model == "gpt-4o-mini-test"
    refute inspect(job) =~ analysis
    refute inspect(job) =~ prompt
  end

  test "retries transient OpenAI vision provider failures", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "retry.png")
    File.write!(image_path, png_bytes())
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    http_post = fn _url, _request_opts ->
      attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

      if attempt == 1 do
        {:ok, %Req.Response{status: 429, body: %{"error" => %{"type" => "rate_limit"}}}}
      else
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => "retry analysis"}}]}
         }}
      end
    end

    tool =
      MediaAnalyzeImage.tool(tmp_dir,
        openai_vision_api_key: "sk-test-vision-key",
        media_vision_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "imagePath" => "retry.png",
                 "provider" => "openai_vision",
                 "filename" => "retry-analysis",
                 "maxRetries" => 1
               },
               nil,
               nil
             )

    assert Agent.get(attempts, & &1) == 2
    assert result.details["text"] == "retry analysis"
  end

  test "routes provider-prefixed OpenAI-compatible vision models through provider config", %{
    tmp_dir: tmp_dir
  } do
    image_path = Path.join(tmp_dir, "compatible.png")
    File.write!(image_path, png_bytes())
    {:ok, requests} = Agent.start_link(fn -> [] end)

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => "compatible analysis"}}]}
       }}
    end

    tool =
      MediaAnalyzeImage.tool(tmp_dir,
        media_vision_config: %{
          providers: %{
            "openrouter" => %{
              "api_key" => "sk-openrouter-test",
              "base_url" => "https://openrouter.test/api/v1"
            }
          }
        },
        media_vision_http_post: http_post
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "imagePath" => "compatible.png",
                 "provider" => "openai_vision",
                 "model" => "openrouter:openai/gpt-4o-mini",
                 "filename" => "compatible-analysis"
               },
               nil,
               nil
             )

    assert [{"https://openrouter.test/api/v1/chat/completions", request_opts}] =
             Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer sk-openrouter-test"} in request_opts[:headers]
    assert request_opts[:json]["model"] == "openai/gpt-4o-mini"
    assert result.details["model"] == "openrouter:openai/gpt-4o-mini"
    assert result.details["text"] == "compatible analysis"

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.provider == "openai_vision"
    assert job.model == "openrouter:openai/gpt-4o-mini"
  end

  describe "provider credential/host pairing" do
    setup do
      saved =
        for var <- ~w(OPENROUTER_API_KEY ANTHROPIC_API_KEY KIMI_API_KEY MOONSHOT_API_KEY),
            do: {var, System.get_env(var)}

      Enum.each(saved, fn {var, _} -> System.delete_env(var) end)

      on_exit(fn ->
        Enum.each(saved, fn
          {var, nil} -> System.delete_env(var)
          {var, value} -> System.put_env(var, value)
        end)
      end)

      {:ok, requests} = Agent.start_link(fn -> [] end)

      http_post = fn url, request_opts ->
        Agent.update(requests, &[{url, request_opts} | &1])

        {:ok,
         %Req.Response{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => "ok analysis"}}]}
         }}
      end

      %{requests: requests, http_post: http_post}
    end

    test "anthropic model with only an Anthropic key errors without any HTTP request", %{
      tmp_dir: tmp_dir,
      requests: requests,
      http_post: http_post
    } do
      File.write!(Path.join(tmp_dir, "a.png"), png_bytes())

      tool =
        MediaAnalyzeImage.tool(tmp_dir,
          media_vision_config: %{
            providers: %{"anthropic" => %{"api_key" => "sk-ant-secret"}}
          },
          media_vision_http_post: http_post
        )

      assert {:error, message} =
               tool.execute.(
                 "call-1",
                 %{
                   "imagePath" => "a.png",
                   "provider" => "openai_vision",
                   "model" => "anthropic:claude-x"
                 },
                 nil,
                 nil
               )

      assert message =~ "base_url"
      refute message =~ "sk-ant-secret"
      assert Agent.get(requests, & &1) == []
      assert MediaJobs.recent(project_dir: tmp_dir, limit: 1) == []
    end

    test "explicit OpenAI override key/host never apply to another provider", %{
      tmp_dir: tmp_dir,
      requests: requests,
      http_post: http_post
    } do
      File.write!(Path.join(tmp_dir, "b.png"), png_bytes())

      tool =
        MediaAnalyzeImage.tool(tmp_dir,
          openai_vision_api_key: "sk-openai-secret",
          openai_vision_base_url: "https://api.openai.test/v1",
          media_vision_config: %{
            providers: %{"anthropic" => %{"api_key" => "sk-ant-secret"}}
          },
          media_vision_http_post: http_post
        )

      assert {:error, _} =
               tool.execute.(
                 "call-1",
                 %{
                   "imagePath" => "b.png",
                   "provider" => "openai_vision",
                   "model" => "anthropic:claude-x"
                 },
                 nil,
                 nil
               )

      assert Agent.get(requests, & &1) == []
    end

    test "custom base_url for a provider only accepts that provider's credential", %{
      tmp_dir: tmp_dir,
      requests: requests,
      http_post: http_post
    } do
      File.write!(Path.join(tmp_dir, "c.png"), png_bytes())

      tool =
        MediaAnalyzeImage.tool(tmp_dir,
          openai_vision_api_key: "sk-openai-secret",
          media_vision_config: %{
            providers: %{
              "openai" => %{"api_key" => "sk-openai-config-secret"},
              "openrouter" => %{"base_url" => "https://openrouter.test/api/v1"}
            }
          },
          media_vision_http_post: http_post
        )

      params = %{
        "imagePath" => "c.png",
        "provider" => "openai_vision",
        "model" => "openrouter:openai/gpt-4o-mini"
      }

      assert {:error, _} = tool.execute.("call-1", params, nil, nil)
      assert Agent.get(requests, & &1) == []

      System.put_env("OPENROUTER_API_KEY", "sk-or-env-key")

      assert %AgentToolResult{} = tool.execute.("call-2", params, nil, nil)

      assert [{"https://openrouter.test/api/v1/chat/completions", request_opts}] =
               Agent.get(requests, & &1)

      assert request_opts[:headers] == [{"authorization", "Bearer sk-or-env-key"}]
      refute inspect(request_opts) =~ "sk-openai"
    end

    test "openai models still use the OpenAI key and default OpenAI host", %{
      tmp_dir: tmp_dir,
      requests: requests,
      http_post: http_post
    } do
      File.write!(Path.join(tmp_dir, "d.png"), png_bytes())

      tool =
        MediaAnalyzeImage.tool(tmp_dir,
          media_vision_config: %{providers: %{"openai" => %{"api_key" => "sk-openai-key"}}},
          media_vision_http_post: http_post
        )

      for model <- ["gpt-4o-mini", "openai:gpt-4o-mini"] do
        assert %AgentToolResult{} =
                 tool.execute.(
                   "call-1",
                   %{"imagePath" => "d.png", "provider" => "openai_vision", "model" => model},
                   nil,
                   nil
                 )
      end

      assert [{url1, opts1}, {url2, opts2}] = Agent.get(requests, &Enum.reverse/1)
      assert url1 == "https://api.openai.com/v1/chat/completions"
      assert url2 == url1
      assert {"authorization", "Bearer sk-openai-key"} in opts1[:headers]
      assert {"authorization", "Bearer sk-openai-key"} in opts2[:headers]
      assert opts2[:json]["model"] == "gpt-4o-mini"
    end
  end

  test "redacts OpenAI vision provider errors from failed jobs", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "rejected.png")
    File.write!(image_path, png_bytes())
    provider_message = "private provider rejection"

    http_post = fn _url, _request_opts ->
      {:ok,
       %Req.Response{
         status: 400,
         body: %{"error" => %{"type" => "invalid_request_error", "message" => provider_message}}
       }}
    end

    tool =
      MediaAnalyzeImage.tool(tmp_dir,
        openai_vision_api_key: "sk-test-vision-key",
        media_vision_http_post: http_post
      )

    assert {:error, "media job failed: openai_vision_http_error:invalid_request_error"} =
             tool.execute.(
               "call-1",
               %{"imagePath" => "rejected.png", "provider" => "openai_vision"},
               nil,
               nil
             )

    [job] = MediaJobs.recent(project_dir: tmp_dir, limit: 1)
    assert job.status == :failed
    assert job.error_kind == "openai_vision_http_error:invalid_request_error"
    refute inspect(job) =~ provider_message
  end

  test "rejects image paths outside the project", %{tmp_dir: tmp_dir} do
    tool = LemonSkills.Tools.MediaAnalyzeImage.tool(tmp_dir)

    assert {:error, "imagePath must be under the current project"} =
             tool.execute.("call-1", %{"imagePath" => "/etc/passwd"}, nil, nil)
  end

  test "rejects OpenAI vision for local-only SVG input", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "preview.svg")
    File.write!(image_path, svg_bytes("label"))
    tool = LemonSkills.Tools.MediaAnalyzeImage.tool(tmp_dir)

    assert {:error, "openai_vision supports png, jpeg, webp, or gif images"} =
             tool.execute.(
               "call-1",
               %{"imagePath" => "preview.svg", "provider" => "openai_vision"},
               nil,
               nil
             )
  end

  defp png_bytes do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>
  end

  defp svg_bytes(label) do
    ~s(<svg xmlns="http://www.w3.org/2000/svg"><text>#{label}</text></svg>)
  end
end
