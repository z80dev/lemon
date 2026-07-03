defmodule CodingAgent.Tools.BrowserTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.ImageContent
  alias CodingAgent.Tools
  alias LemonBrowser.LocalServer

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "coding_agent_browser_tool_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "browser_navigate calls the supervised browser server" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"url" => args["url"], "status" => 200, "title" => "Example"}}
    end

    tool = Tools.get_tool("browser_navigate", "/tmp", browser_request: request)

    result =
      tool.execute.("call-1", %{"url" => "https://example.com", "timeoutMs" => 500}, nil, nil)

    assert_received {:browser_request, "browser.navigate", %{"url" => "https://example.com"}, 500}
    assert result.trust == :untrusted
    assert result.details["tool"] == "browser_navigate"
    assert result.details["url"] == "https://example.com"
    assert result.details["networkPolicy"]["route"] == "auto"
    assert result.details["networkPolicy"]["effectiveRoute"] == "public"
    assert result.details["networkPolicy"]["targetKind"] == "public_network"
  end

  test "browser_navigate enforces public and local route guards before the browser worker" do
    request = fn _method, _args, _timeout_ms ->
      flunk("browser request should not run for blocked navigation")
    end

    tool = Tools.get_tool("browser_navigate", "/tmp", browser_request: request)

    assert {:error, "browser navigation requires a public http(s) URL"} =
             tool.execute.(
               "call-1",
               %{"url" => "http://127.0.0.1:4000", "route" => "public"},
               nil,
               nil
             )

    assert {:error, "browser navigation requires a local or private URL"} =
             tool.execute.(
               "call-2",
               %{"url" => "https://example.com", "route" => "local"},
               nil,
               nil
             )
  end

  test "browser_navigate always blocks cloud metadata endpoints" do
    request = fn _method, _args, _timeout_ms ->
      flunk("browser request should not run for blocked metadata navigation")
    end

    tool = Tools.get_tool("browser_navigate", "/tmp", browser_request: request)

    assert {:error, "browser navigation blocked metadata endpoint"} =
             tool.execute.(
               "call-1",
               %{"url" => "http://169.254.169.254/latest/meta-data"},
               nil,
               nil
             )

    assert {:error, "browser navigation blocked metadata endpoint"} =
             tool.execute.(
               "call-2",
               %{"url" => "http://metadata.google.internal/computeMetadata/v1"},
               nil,
               nil
             )
  end

  test "browser_navigate emits redacted channel-safe progress updates" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"url" => args["url"], "status" => 200, "title" => "Example"}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_navigate", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"url" => "https://secret.example.com/path?token=abc", "timeoutMs" => 500},
        nil,
        on_update
      )

    assert result.details["status"] == 200

    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert_receive {:browser_update, %AgentToolResult{} = completed}

    assert started.trust == :trusted
    assert started.details["tool"] == "browser_navigate"
    assert started.details["method"] == "browser.navigate"
    assert started.details["phase"] == "started"
    assert started.details["current_action"]["kind"] == "browser"
    assert started.details["current_action"]["phase"] == "started"
    assert started.details["browser"]["scheme"] == "https"
    assert is_binary(started.details["browser"]["hostHash"])
    assert started.details["browser"]["route"] == "auto"
    assert started.details["browser"]["effectiveRoute"] == "public"
    assert started.details["browser"]["targetKind"] == "public_network"

    assert completed.details["phase"] == "completed"
    assert completed.details["result"]["eventCount"] == nil

    rendered = inspect([started, completed])
    refute rendered =~ "secret.example.com"
    refute rendered =~ "/path"
    refute rendered =~ "token=abc"
  end

  test "browser_click progress omits selectors and reports sensitive argument count" do
    parent = self()

    request = fn "browser.click", _args, _timeout_ms ->
      {:ok, %{"ok" => true}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_click", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"selector" => "#secret-button", "timeoutMs" => 250},
        nil,
        on_update
      )

    assert result.details["ok"] == true
    assert_receive {:browser_update, %AgentToolResult{} = started}

    assert started.details["browser"]["sensitiveArgumentCount"] == 1
    refute inspect(started) =~ "#secret-button"
  end

  test "browser progress reports failures without raw error detail" do
    parent = self()

    request = fn "browser.snapshot", _args, _timeout_ms ->
      {:error, "selector #secret failed: private text"}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_snapshot", "/tmp", browser_request: request)

    assert {:error, "selector #secret failed: private text"} =
             tool.execute.("call-1", %{"selector" => "#secret"}, nil, on_update)

    assert_receive {:browser_update, %AgentToolResult{}}
    assert_receive {:browser_update, %AgentToolResult{} = failed}

    assert failed.details["phase"] == "failed"
    assert failed.details["result"]["errorKind"] == "selector_error"
    refute inspect(failed) =~ "#secret"
    refute inspect(failed) =~ "private text"
  end

  test "browser_wait_for_selector forwards selector and keeps progress redacted" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"found" => true}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_wait_for_selector", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"selector" => "#private-ready", "timeoutMs" => 750},
        nil,
        on_update
      )

    assert_received {:browser_request, "browser.waitForSelector",
                     %{"selector" => "#private-ready", "timeoutMs" => 750}, 750}

    assert result.details["found"] == true
    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert started.details["browser"]["sensitiveArgumentCount"] == 1
    refute inspect(started) =~ "#private-ready"
  end

  test "browser_evaluate forwards expression and keeps progress redacted" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"result" => %{"title" => "Example", "ready" => true}}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_evaluate", "/tmp", browser_request: request)

    expression = "(() => ({title: document.title, ready: !!window.secretReady}))()"

    result =
      tool.execute.(
        "call-1",
        %{"expression" => expression, "timeoutMs" => 500},
        nil,
        on_update
      )

    assert_received {:browser_request, "browser.evaluate", %{"expression" => ^expression}, 500}

    assert result.trust == :untrusted
    assert result.details["result"]["ready"] == true
    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert started.details["browser"]["sensitiveArgumentCount"] == 1
    refute inspect(started) =~ "secretReady"
    refute inspect(started) =~ "document.title"
  end

  test "browser_hover forwards selector and keeps progress redacted" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"hovered" => true}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_hover", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"selector" => "#private-menu", "timeoutMs" => 500},
        nil,
        on_update
      )

    assert_received {:browser_request, "browser.hover",
                     %{"selector" => "#private-menu", "timeoutMs" => 500}, 500}

    assert result.trust == :untrusted
    assert result.details["hovered"] == true
    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert started.details["browser"]["sensitiveArgumentCount"] == 1
    refute inspect(started) =~ "#private-menu"
  end

  test "browser_select_option forwards values and keeps progress redacted" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"selected" => ["otp-mode"], "count" => 1}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_select_option", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"selector" => "#private-mode", "value" => "otp-mode", "timeoutMs" => 500},
        nil,
        on_update
      )

    assert_received {:browser_request, "browser.selectOption",
                     %{"selector" => "#private-mode", "value" => "otp-mode", "timeoutMs" => 500},
                     500}

    assert result.trust == :untrusted
    assert result.details["selected"] == ["otp-mode"]
    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert started.details["browser"]["sensitiveArgumentCount"] == 2
    refute inspect(started) =~ "#private-mode"
    refute inspect(started) =~ "beam"
  end

  test "browser_upload_file resolves project files and keeps progress redacted", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    upload_path = Path.join(tmp_dir, "upload-secret.txt")
    File.write!(upload_path, "upload-secret")

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"uploaded" => true, "count" => 1}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_upload_file", tmp_dir, browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"selector" => "#private-upload", "path" => "upload-secret.txt", "timeoutMs" => 500},
        nil,
        on_update
      )

    assert_received {:browser_request, "browser.setInputFiles",
                     %{
                       "selector" => "#private-upload",
                       "path" => ^upload_path,
                       "timeoutMs" => 500
                     }, 500}

    assert result.trust == :untrusted
    assert result.details["uploaded"] == true
    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert started.details["browser"]["sensitiveArgumentCount"] == 2
    refute inspect(started) =~ "#private-upload"
    refute inspect(started) =~ "upload-secret"
  end

  test "browser_upload_file rejects files outside the project", %{tmp_dir: tmp_dir} do
    parent = self()

    outside_path =
      Path.join(System.tmp_dir!(), "lemon-upload-outside-#{System.unique_integer()}.txt")

    File.write!(outside_path, "outside")

    on_exit(fn -> File.rm(outside_path) end)

    request = fn _method, _args, _timeout_ms ->
      flunk("browser request should not run for rejected upload files")
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_upload_file", tmp_dir, browser_request: request)

    assert {:error, "browser_upload_file path must be under the current project"} =
             tool.execute.(
               "call-1",
               %{"selector" => "#private-upload", "path" => outside_path},
               nil,
               on_update
             )

    assert_receive {:browser_update, %AgentToolResult{}}
    assert_receive {:browser_update, %AgentToolResult{} = failed}
    assert failed.details["phase"] == "failed"
    assert failed.details["result"]["errorKind"] == "browser_error"
    refute inspect(failed) =~ outside_path
  end

  test "browser_download resolves managed artifact dir and keeps progress redacted", %{
    tmp_dir: tmp_dir
  } do
    parent = self()
    artifacts_dir = Path.join(tmp_dir, ".lemon/browser-artifacts")

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})

      {:ok,
       %{
         "downloaded" => true,
         "path" => Path.join(artifacts_dir, "proof-download.txt"),
         "suggestedFilename" => "proof-download.txt",
         "bytes" => 14
       }}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_download", tmp_dir, browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"selector" => "#private-download", "timeoutMs" => 500},
        nil,
        on_update
      )

    assert_received {:browser_request, "browser.download",
                     %{
                       "selector" => "#private-download",
                       "dir" => ^artifacts_dir,
                       "timeoutMs" => 500
                     }, 500}

    assert result.trust == :untrusted
    assert result.details["downloaded"] == true
    assert result.details["bytes"] == 14
    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert_receive {:browser_update, %AgentToolResult{} = completed}
    assert started.details["browser"]["sensitiveArgumentCount"] == 1
    assert completed.details["browser"]["sensitiveArgumentCount"] == 2

    rendered = inspect([started, completed])
    refute rendered =~ "#private-download"
    refute rendered =~ ".lemon/browser-artifacts"
    refute rendered =~ "proof-download"
  end

  test "browser_download rejects output paths outside the project", %{tmp_dir: tmp_dir} do
    parent = self()

    outside_path =
      Path.join(System.tmp_dir!(), "lemon-download-outside-#{System.unique_integer()}.txt")

    request = fn _method, _args, _timeout_ms ->
      flunk("browser request should not run for rejected download paths")
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = Tools.get_tool("browser_download", tmp_dir, browser_request: request)

    assert {:error, "browser_download output path must be under the current project"} =
             tool.execute.(
               "call-1",
               %{"selector" => "#private-download", "path" => outside_path},
               nil,
               on_update
             )

    assert_receive {:browser_update, %AgentToolResult{}}
    assert_receive {:browser_update, %AgentToolResult{} = failed}
    assert failed.details["phase"] == "failed"
    assert failed.details["result"]["errorKind"] == "browser_error"
    refute inspect(failed) =~ outside_path
  end

  test "browser_snapshot forwards optional snapshot limits" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"snapshot" => "URL: file:///tmp/page.html", "displayedNodes" => 1}}
    end

    tool = Tools.get_tool("browser_snapshot", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"selector" => "main", "maxChars" => 1000, "interactiveOnly" => true},
        nil,
        nil
      )

    assert_received {:browser_request, "browser.snapshot",
                     %{"selector" => "main", "maxChars" => 1000, "interactiveOnly" => true},
                     30_000}

    assert result.details["tool"] == "browser_snapshot"
    assert result.details["snapshot"] =~ "URL:"
  end

  test "browser_screenshot writes base64 screenshot output as an artifact", %{tmp_dir: tmp_dir} do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    request = fn "browser.screenshot", %{"type" => "png"}, 30_000 ->
      {:ok, %{"contentType" => "image/png", "base64" => Base.encode64(png)}}
    end

    path = Path.join(tmp_dir, "shot.png")
    tool = Tools.get_tool("browser_screenshot", tmp_dir, browser_request: request)

    result = tool.execute.("call-1", %{"path" => path}, nil, nil)

    assert File.read!(path) == png
    assert result.details["path"] == path
    assert result.details["bytes"] == byte_size(png)
    assert result.details["imageIncluded"] == false
    refute Map.has_key?(result.details, "base64")
    refute Enum.any?(result.content, &match?(%ImageContent{}, &1))
  end

  test "browser_screenshot can return model-visible image content", %{tmp_dir: tmp_dir} do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>
    encoded = Base.encode64(png)
    parent = self()

    request = fn "browser.screenshot", args, 30_000 ->
      send(parent, {:browser_args, args})
      {:ok, %{"contentType" => "image/png", "base64" => encoded}}
    end

    path = Path.join(tmp_dir, "vision.png")
    tool = Tools.get_tool("browser_screenshot", tmp_dir, browser_request: request)

    result = tool.execute.("call-1", %{"path" => path, "includeImage" => true}, nil, nil)

    assert_received {:browser_args, %{"type" => "png"}}
    assert File.read!(path) == png
    assert result.details["path"] == path
    assert result.details["bytes"] == byte_size(png)
    assert result.details["imageIncluded"] == true
    refute Map.has_key?(result.details, "base64")

    assert [%ImageContent{data: ^encoded, mime_type: "image/png"}] =
             Enum.filter(result.content, &match?(%ImageContent{}, &1))
  end

  test "browser_analyze captures a screenshot and runs local image analysis", %{tmp_dir: tmp_dir} do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>
    encoded = Base.encode64(png)
    {:ok, args_agent} = Agent.start_link(fn -> [] end)
    {:ok, updates_agent} = Agent.start_link(fn -> [] end)

    request = fn "browser.screenshot", args, 30_000 ->
      Agent.update(args_agent, fn existing -> [args | existing] end)
      {:ok, %{"contentType" => "image/png", "base64" => encoded}}
    end

    on_update = fn update ->
      Agent.update(updates_agent, fn existing -> [update | existing] end)
      :ok
    end

    path = Path.join(tmp_dir, "browser-vision.png")
    tool = Tools.get_tool("browser_analyze", tmp_dir, browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{
          "path" => path,
          "includeImage" => true,
          "provider" => "local_vision",
          "prompt" => "Describe the current browser page.",
          "filename" => "browser-vision-analysis"
        },
        nil,
        on_update
      )

    assert [%{"type" => "png"}] = Agent.get(args_agent, & &1)
    assert File.read!(path) == png
    assert result.trust == :untrusted
    assert result.details["tool"] == "browser_analyze"
    assert result.details["status"] == "completed"
    assert result.details["provider"] == "local_vision"
    assert result.details["screenshot"]["path"] == path
    assert result.details["screenshot"]["bytes"] == byte_size(png)
    assert result.details["analysis"]["provider"] == "local_vision"
    assert result.details["analysis"]["artifact"]["filename"] == "browser-vision-analysis.json"
    assert File.exists?(result.details["analysis"]["artifact"]["path"])
    assert result.details["text"] =~ "local image analysis preview"
    refute inspect(result.details) =~ encoded

    assert [%ImageContent{data: ^encoded, mime_type: "image/png"}] =
             Enum.filter(result.content, &match?(%ImageContent{}, &1))

    [started, completed] = Agent.get(updates_agent, &Enum.reverse/1)
    assert started.details["method"] == "browser.analyze"
    assert completed.details["result"]["analysisProvider"] == "local_vision"
    assert completed.details["result"]["analysisArtifactWritten"] == true
  end

  test "browser_analyze routes provider-prefixed vision models through media worker config", %{
    tmp_dir: tmp_dir
  } do
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>
    encoded = Base.encode64(png)
    {:ok, requests} = Agent.start_link(fn -> [] end)

    browser_request = fn "browser.screenshot", %{"type" => "png"}, 30_000 ->
      {:ok, %{"contentType" => "image/png", "base64" => encoded}}
    end

    http_post = fn url, request_opts ->
      Agent.update(requests, &[{url, request_opts} | &1])

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"choices" => [%{"message" => %{"content" => "browser compatible analysis"}}]}
       }}
    end

    tool =
      Tools.get_tool("browser_analyze", tmp_dir,
        browser_request: browser_request,
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

    result =
      tool.execute.(
        "call-1",
        %{
          "provider" => "openai_vision",
          "model" => "openrouter:openai/gpt-4o-mini",
          "detail" => "low",
          "filename" => "browser-compatible-analysis"
        },
        nil,
        nil
      )

    assert %AgentToolResult{} = result

    assert [{"https://openrouter.test/api/v1/chat/completions", request_opts}] =
             Agent.get(requests, &Enum.reverse/1)

    assert {"authorization", "Bearer sk-openrouter-test"} in request_opts[:headers]
    assert request_opts[:json]["model"] == "openai/gpt-4o-mini"

    [%{"content" => content}] = request_opts[:json]["messages"]

    assert %{
             "type" => "image_url",
             "image_url" => %{"url" => image_url, "detail" => "low"}
           } = Enum.at(content, 1)

    assert String.starts_with?(image_url, "data:image/png;base64,")
    assert result.details["provider"] == "openai_vision"
    assert result.details["model"] == "openrouter:openai/gpt-4o-mini"
    assert result.details["text"] == "browser compatible analysis"

    assert result.details["analysis"]["artifact"]["filename"] ==
             "browser-compatible-analysis.json"

    refute inspect(result.details) =~ encoded
  end

  test "browser_screenshot can request final channel delivery", %{tmp_dir: tmp_dir} do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>

    request = fn "browser.screenshot", %{"type" => "png"}, 30_000 ->
      {:ok, %{"contentType" => "image/png", "base64" => Base.encode64(png)}}
    end

    path = Path.join(tmp_dir, "channel-shot.png")
    tool = Tools.get_tool("browser_screenshot", tmp_dir, browser_request: request)

    result = tool.execute.("call-1", %{"path" => path, "sendToChannel" => true}, nil, nil)

    assert File.read!(path) == png
    refute Map.has_key?(result.details, "base64")

    assert [
             %{
               "path" => ^path,
               "filename" => "channel-shot.png",
               "caption" => "browser screenshot",
               "source" => "explicit"
             }
           ] = result.details["auto_send_files"]
  end

  test "browser_screenshot prunes stale default artifacts", %{tmp_dir: tmp_dir} do
    png = <<137, 80, 78, 71, 13, 10, 26, 10>>
    artifacts_dir = Path.join([tmp_dir, ".lemon", "browser-artifacts"])
    File.mkdir_p!(artifacts_dir)
    stale = Path.join(artifacts_dir, "stale.png")
    File.write!(stale, "stale")
    File.touch!(stale, {{2020, 1, 1}, {0, 0, 0}})

    request = fn "browser.screenshot", %{"type" => "png"}, 30_000 ->
      {:ok, %{"contentType" => "image/png", "base64" => Base.encode64(png)}}
    end

    tool = Tools.get_tool("browser_screenshot", tmp_dir, browser_request: request)

    result = tool.execute.("call-1", %{}, nil, nil)

    assert File.exists?(result.details["path"])
    refute File.exists?(stale)
  end

  test "browser_events reads and optionally clears buffered page events" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})

      {:ok,
       %{
         "events" => [
           %{
             "type" => "console",
             "level" => "error",
             "text" => "boom",
             "timestamp" => "2026-05-15T00:00:00.000Z"
           }
         ],
         "count" => 1,
         "cleared" => true
       }}
    end

    tool = Tools.get_tool("browser_events", "/tmp", browser_request: request)

    result = tool.execute.("call-1", %{"limit" => 20, "clear" => true}, nil, nil)

    assert_received {:browser_request, "browser.events", %{"limit" => 20, "clear" => true},
                     30_000}

    assert result.trust == :untrusted
    assert result.details["tool"] == "browser_events"
    assert result.details["count"] == 1
    assert [%{"type" => "console", "text" => "boom"}] = result.details["events"]
  end

  test "browser_get_cookies can scope cookies by URL" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})

      {:ok,
       %{
         "cookies" => [
           %{
             "name" => "session",
             "value" => "abc",
             "domain" => "example.com",
             "path" => "/"
           }
         ]
       }}
    end

    tool = Tools.get_tool("browser_get_cookies", "/tmp", browser_request: request)

    result =
      tool.execute.("call-1", %{"url" => "https://example.com", "timeoutMs" => 250}, nil, nil)

    assert_received {:browser_request, "browser.getCookies", %{"url" => "https://example.com"},
                     250}

    assert result.details["tool"] == "browser_get_cookies"
    assert [%{"name" => "session", "value" => "[redacted]"}] = result.details["cookies"]
  end

  test "browser_get_cookies can explicitly include cookie values" do
    request = fn "browser.getCookies", %{}, 30_000 ->
      {:ok, %{"cookies" => [%{"name" => "session", "value" => "abc"}]}}
    end

    tool = Tools.get_tool("browser_get_cookies", "/tmp", browser_request: request)

    result = tool.execute.("call-1", %{"includeValues" => true}, nil, nil)

    assert [%{"name" => "session", "value" => "abc"}] = result.details["cookies"]
  end

  test "browser_set_cookies forwards cookie objects" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"set" => length(args["cookies"])}}
    end

    cookie = %{"name" => "session", "value" => "abc", "url" => "https://example.com"}
    tool = Tools.get_tool("browser_set_cookies", "/tmp", browser_request: request)

    result = tool.execute.("call-1", %{"cookies" => [cookie]}, nil, nil)

    assert_received {:browser_request, "browser.setCookies", %{"cookies" => [^cookie]}, 30_000}
    assert result.details["tool"] == "browser_set_cookies"
    assert result.details["set"] == 1
  end

  test "browser_clear_state forwards reset controls" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})

      {:ok,
       %{
         "cookiesCleared" => true,
         "storageCleared" => false,
         "eventsCleared" => true,
         "url" => "https://example.com"
       }}
    end

    tool = Tools.get_tool("browser_clear_state", "/tmp", browser_request: request)

    result =
      tool.execute.(
        "call-1",
        %{"clearCookies" => true, "clearStorage" => false, "clearEvents" => true},
        nil,
        nil
      )

    assert_received {:browser_request, "browser.clearState",
                     %{
                       "clearCookies" => true,
                       "clearStorage" => false,
                       "clearEvents" => true
                     }, 30_000}

    assert result.details["tool"] == "browser_clear_state"
    assert result.details["cookiesCleared"] == true
    assert result.details["storageCleared"] == false
    assert result.details["eventsCleared"] == true
  end

  test "browser tools drive a deterministic page through the supervised local server", %{
    tmp_dir: tmp_dir
  } do
    if browser_smoke_available?() do
      chrome = chrome_executable()
      server = :"browser_smoke_#{System.unique_integer([:positive])}"
      port = free_port()
      profile_dir = Path.join(tmp_dir, "browser-profile")

      with_env(
        %{
          "LEMON_BROWSER_CDP_PORT" => Integer.to_string(port),
          "LEMON_BROWSER_DRIVER_PATH" => browser_driver_path(),
          "LEMON_BROWSER_HEADLESS" => "true",
          "LEMON_BROWSER_NO_SANDBOX" => "true",
          "LEMON_BROWSER_USER_DATA_DIR" => profile_dir,
          "LEMON_BROWSER_EXECUTABLE" => chrome
        },
        fn ->
          {:ok, pid} = LocalServer.start_link(name: server)
          on_exit(fn -> if Process.alive?(pid), do: LocalServer.stop(server) end)

          request = fn method, args, timeout_ms ->
            LocalServer.request(server, method, args, timeout_ms)
          end

          html = """
          <!doctype html>
          <html>
            <head>
              <meta charset="utf-8">
              <title>Lemon Browser Proof</title>
            </head>
            <body>
              <main>
                <h1 id="title">Hermes on BEAM</h1>
                <div id="menu" aria-label="Menu">Menu</div>
                <output id="hover-result"></output>
                <select id="mode" aria-label="Mode">
                  <option value="classic">Classic</option>
                  <option value="otp-mode">OTP Mode</option>
                </select>
                <input id="message" aria-label="Message" value="">
                <button id="save" type="button">Save</button>
                <output id="result"></output>
              </main>
              <script>
                console.log("lemon-browser-proof-ready");
                document.getElementById("menu").addEventListener("mouseover", () => {
                  document.getElementById("hover-result").textContent = "hovered";
                });
                document.getElementById("save").addEventListener("click", () => {
                  const value = document.getElementById("message").value;
                  const mode = document.getElementById("mode").value;
                  document.getElementById("result").textContent = `saved: ${value} (${mode})`;
                });
              </script>
            </body>
          </html>
          """

          url = "data:text/html;base64,#{Base.encode64(html)}"

          navigate =
            "browser_navigate"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{"url" => url, "timeoutMs" => 20_000})

          assert navigate.trust == :untrusted
          assert navigate.details["title"] == "Lemon Browser Proof"

          snapshot =
            "browser_snapshot"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{"selector" => "main", "maxChars" => 2_000})

          assert snapshot.trust == :untrusted
          assert snapshot.details["snapshot"] =~ "Hermes on BEAM"

          waited =
            "browser_wait_for_selector"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{"selector" => "#message", "timeoutMs" => 1_000})

          assert waited.details["found"] == true

          evaluated =
            "browser_evaluate"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{
              "expression" =>
                "(() => ({title: document.title, hasMessage: !!document.querySelector('#message')}))()",
              "timeoutMs" => 1_000
            })

          assert evaluated.details["result"]["title"] == "Lemon Browser Proof"
          assert evaluated.details["result"]["hasMessage"] == true

          hovered =
            "browser_hover"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{"selector" => "#menu", "timeoutMs" => 1_000})

          assert hovered.details["hovered"] == true

          selected =
            "browser_select_option"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{
              "selector" => "#mode",
              "value" => "otp-mode",
              "timeoutMs" => 1_000
            })

          assert selected.details["selected"] == ["otp-mode"]

          typed =
            "browser_type"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{
              "selector" => "#message",
              "text" => "OTP supervision",
              "useFill" => true
            })

          assert typed.details["typed"] == true
          assert typed.details["length"] == String.length("OTP supervision")

          clicked =
            "browser_click"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{"selector" => "#save"})

          assert clicked.details["clicked"] == true

          content =
            "browser_get_content"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{"includeHtml" => false, "includeText" => true})

          assert content.trust == :untrusted
          assert content.details["text"] =~ "hovered"
          assert content.details["text"] =~ "saved: OTP supervision (otp-mode)"

          events =
            "browser_events"
            |> Tools.get_tool(tmp_dir, browser_request: request)
            |> run_browser_tool(%{"limit" => 10, "clear" => true})

          assert Enum.any?(events.details["events"], fn event ->
                   event["type"] == "console" and event["text"] =~ "lemon-browser-proof-ready"
                 end)

          status = LocalServer.status(server)
          assert status.running == true
          assert status.completed_count >= 6
          assert status.failed_count == 0
          assert status.pending_requests == 0
        end
      )
    else
      assert true
    end
  end

  test "browser_click validates selector" do
    tool =
      Tools.get_tool("browser_click", "/tmp", browser_request: fn _, _, _ -> flunk("unused") end)

    assert {:error, "selector is required"} = tool.execute.("call-1", %{}, nil, nil)
  end

  defp run_browser_tool(tool, params) do
    result = tool.execute.("call-1", params, nil, nil)
    refute match?({:error, _}, result)
    result
  end

  defp browser_smoke_available? do
    System.find_executable("node") &&
      File.exists?(browser_driver_path()) &&
      chrome_executable()
  end

  defp browser_driver_path do
    Path.expand("../../../../../clients/lemon-browser-node/dist/local-driver.js", __DIR__)
  end

  defp chrome_executable do
    [
      System.get_env("LEMON_BROWSER_EXECUTABLE"),
      System.get_env("LEMON_CHROME_EXECUTABLE"),
      System.get_env("CHROME_EXECUTABLE"),
      System.find_executable("google-chrome"),
      System.find_executable("google-chrome-stable"),
      System.find_executable("chromium"),
      System.find_executable("chromium-browser")
    ]
    |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(vars, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
