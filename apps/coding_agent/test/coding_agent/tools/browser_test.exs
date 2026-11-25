defmodule CodingAgent.Tools.BrowserTest do
  use ExUnit.Case, async: false
  # Page URL the driver reports with every capture.
  @page_url "https://example.com/"

  alias CodingAgent.TestHostCapabilities
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.ImageContent
  alias LemonBrowser.LocalServer

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "coding_agent_browser_tool_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    # Browser file paths resolve to physical paths (`/var` -> `/private/var` on macOS).
    {:ok, tmp_dir} = LemonCore.TrustedRoot.realpath(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "truncated snapshots and page content save full session artifacts", %{tmp_dir: dir} do
    full = String.duplicate("browser text ", 500) <> "BROWSER_TAIL"

    for {name, method, field, flag} <- [
          {"browser_snapshot", "browser.snapshot", "snapshot", "truncated"},
          {"browser_get_content", "browser.getContent", "text", "textTruncated"}
        ] do
      request = fn ^method, _, _ ->
        {:ok, %{field => "preview", flag => true, "__full_content" => %{field => full}}}
      end

      opts = [
        browser_request: request,
        session_id: name,
        context_guardrails: %{spill_dir: Path.join(dir, name)}
      ]

      tool = browser_tool(name, dir, opts)

      assert %AgentToolResult{trust: :untrusted, details: details, content: [%{text: text}]} =
               run_browser_tool(tool, %{})

      uri = details["artifact_uri"]
      assert uri =~ "artifact://"
      assert text =~ uri
      assert details["artifactNotice"] =~ uri
      assert {:ok, path} = CodingAgent.Artifacts.resolve(uri, dir, opts)
      assert Jason.decode!(File.read!(path)) == %{field => full}
      refute Map.has_key?(details, "__full_content")
      refute text =~ "BROWSER_TAIL"
    end
  end

  test "untruncated browser content does not create an artifact", %{tmp_dir: dir} do
    tool =
      browser_tool("browser_snapshot", dir,
        browser_request: fn _, _, _ ->
          {:ok, %{"snapshot" => "complete", "truncated" => false}}
        end,
        session_id: "complete"
      )

    assert %AgentToolResult{details: details} = run_browser_tool(tool, %{})
    refute Map.has_key?(details, "artifact_uri")
    refute File.exists?(Path.join(dir, ".lemon"))
  end

  test "browser_navigate calls the supervised browser server" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"url" => args["url"], "status" => 200, "title" => "Example"}}
    end

    tool = browser_tool("browser_navigate", "/tmp", browser_request: request)

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

  test "an unknown-outcome click is reported once as unknown, never retried" do
    parent = self()

    request = fn method, _args, _timeout_ms ->
      send(parent, {:browser_request, method})
      {:error, :outcome_unknown}
    end

    tool = browser_tool("browser_click", "/tmp", browser_request: request)

    assert %AgentToolResult{is_error: true, details: details, content: content} =
             tool.execute.("call-1", %{"selector" => "#buy"}, nil, nil)

    assert details.outcome == :unknown
    assert details.tool == "browser_click"

    assert Enum.any?(
             content,
             &(&1.text =~ "Do not assume it did not run or automatically repeat it")
           )

    assert_received {:browser_request, "browser.click"}
    refute_received {:browser_request, _}
  end

  test "browser tab lifecycle tools expose and forward stable target IDs" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})

      {:ok,
       %{
         "targetId" => args["targetId"] || "target-new",
         "activeTargetId" => args["targetId"] || "target-new",
         "tabs" => []
       }}
    end

    tabs = browser_tool("browser_tabs", "/tmp", browser_request: request)
    open = browser_tool("browser_tab_open", "/tmp", browser_request: request)
    activate = browser_tool("browser_tab_activate", "/tmp", browser_request: request)
    close = browser_tool("browser_tab_close", "/tmp", browser_request: request)

    assert %AgentToolResult{} = run_browser_tool(tabs, %{"timeoutMs" => 500})

    assert %AgentToolResult{} =
             run_browser_tool(open, %{"url" => "https://example.com", "timeoutMs" => 500})

    assert %AgentToolResult{} =
             run_browser_tool(activate, %{"targetId" => "target-1", "timeoutMs" => 500})

    assert %AgentToolResult{} =
             run_browser_tool(close, %{"targetId" => "target-1", "timeoutMs" => 500})

    assert_received {:browser_request, "browser.tabs", %{}, 500}

    assert_received {:browser_request, "browser.tabOpen", %{"url" => "https://example.com"}, 500}

    assert_received {:browser_request, "browser.tabActivate", %{"targetId" => "target-1"}, 500}

    assert_received {:browser_request, "browser.tabClose", %{"targetId" => "target-1"}, 500}
  end

  test "page tools accept an explicit targetId without exposing it as content" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"url" => args["url"], "title" => "Example"}}
    end

    tool = browser_tool("browser_navigate", "/tmp", browser_request: request)
    assert tool.parameters["properties"]["targetId"]["type"] == "string"

    assert %AgentToolResult{} =
             run_browser_tool(tool, %{
               "url" => "https://example.com",
               "targetId" => "target-2",
               "timeoutMs" => 500
             })

    assert_received {:browser_request, "browser.navigate",
                     %{"url" => "https://example.com", "targetId" => "target-2"}, 500}
  end

  test "browser_navigate enforces public and local route guards before the browser worker" do
    request = fn _method, _args, _timeout_ms ->
      flunk("browser request should not run for blocked navigation")
    end

    tool = browser_tool("browser_navigate", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_navigate", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_navigate", "/tmp", browser_request: request)

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

    assert started.trust == :untrusted
    assert completed.trust == :untrusted
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

    tool = browser_tool("browser_click", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_snapshot", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_wait_for_selector", "/tmp", browser_request: request)

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

    request = fn
      "browser.tabs", _args, _timeout_ms ->
        {:ok,
         %{
           "tabs" => [%{"targetId" => "t1", "url" => @page_url, "active" => true}],
           "activeTargetId" => "t1"
         }}

      method, args, timeout_ms ->
        send(parent, {:browser_request, method, args, timeout_ms})
        {:ok, %{"result" => %{"title" => "Example", "ready" => true}}}
    end

    on_update = fn update ->
      send(parent, {:browser_update, update})
      :ok
    end

    tool = browser_tool("browser_evaluate", "/tmp", browser_request: request)

    expression = "(() => ({title: document.title, ready: !!window.secretReady}))()"

    result =
      tool.execute.(
        "call-1",
        %{"expression" => expression, "timeoutMs" => 500},
        nil,
        on_update
      )

    # Pinned to the probed target, so a later tab switch cannot redirect it.
    assert_received {:browser_request, "browser.evaluate",
                     %{"expression" => ^expression, "targetId" => "t1"}, 500}

    assert result.trust == :untrusted
    assert result.details["result"]["ready"] == true
    assert_receive {:browser_update, %AgentToolResult{} = started}
    assert started.details["browser"]["sensitiveArgumentCount"] == 1
    refute inspect(started) =~ "secretReady"
    refute inspect(started) =~ "document.title"
  end

  test "browser_evaluate runs only on http:, https: and about: pages" do
    cookie = LemonCore.Paths.home_path("cookie")
    File.mkdir_p!(Path.dirname(cookie))
    File.write!(cookie, "evaluate-cookie-secret\n")
    on_exit(fn -> File.rm(cookie) end)
    credential_url = "file://" <> URI.encode(cookie)
    parent = self()

    tabs = fn listing ->
      fn
        "browser.tabs", _args, _timeout ->
          listing

        method, _args, _timeout ->
          send(parent, {:executed, method})
          {:ok, %{"result" => "x"}}
      end
    end

    active = fn url ->
      {:ok,
       %{
         "tabs" => [%{"targetId" => "a", "url" => url, "active" => true}],
         "activeTargetId" => "a"
       }}
    end

    # Any page outside the allow-list (the active tab or a named target, local
    # or extension or view-source), approved or not, or a backend that cannot
    # say which page it would run in.
    for {listing, params} <- [
          {{:ok,
            %{
              "tabs" => [
                %{"targetId" => "a", "url" => @page_url, "active" => false},
                %{"targetId" => "b", "url" => credential_url, "active" => true}
              ],
              "activeTargetId" => "b"
            }}, %{}},
          {{:ok,
            %{
              "tabs" => [
                %{"targetId" => "a", "url" => @page_url, "active" => true},
                %{"targetId" => "b", "url" => "FILE://" <> cookie}
              ],
              "activeTargetId" => "a"
            }}, %{"targetId" => "b"}},
          {active.("file:///tmp/ordinary.html"), %{"allowLocalDocument" => true}},
          {active.("data:text/html,<p>x</p>"), %{}},
          {active.("blob:https://example.com/123"), %{}},
          {active.("chrome-extension://abc/page.html"), %{}},
          {active.("view-source:https://example.com/"), %{}},
          {active.("devtools://devtools/bundled/inspector.html"), %{}},
          {active.("not a url"), %{}},
          {{:ok, %{"tabs" => [%{"targetId" => "a", "active" => true}]}}, %{}},
          {{:ok, %{"tabs" => [%{"targetId" => "a", "url" => @page_url}]}}, %{"targetId" => "z"}},
          {{:error, {:unsupported_camofox_method, "browser.tabs"}}, %{}}
        ] do
      tool = browser_tool("browser_evaluate", "/tmp", browser_request: tabs.(listing))
      params = Map.put(params, "expression", "document.body.innerText")

      assert {:error, message} = tool.execute.("call-1", params, nil, nil)
      assert message =~ "browser_evaluate refused"
      assert message =~ "http:, https:"
      refute_received {:executed, _}
    end
  end

  test "browser_evaluate allows http:, https: and about: pages" do
    for url <- ["http://example.com/", "HTTPS://example.com/", "about:blank"] do
      parent = self()

      request = fn
        "browser.tabs", _args, _timeout ->
          {:ok,
           %{
             "tabs" => [%{"targetId" => 7, "url" => url, "active" => true}],
             "activeTargetId" => 7
           }}

        method, args, _timeout ->
          send(parent, {:executed, method, args})
          {:ok, %{"result" => 1}}
      end

      tool = browser_tool("browser_evaluate", "/tmp", browser_request: request)
      refute match?({:error, _}, tool.execute.("call-1", %{"expression" => "1"}, nil, nil))
      assert_received {:executed, "browser.evaluate", %{"targetId" => "7"}}
    end

    # A backend guard's refusal sentinel is an error, never a result.
    sentinel = fn
      "browser.tabs", _args, _timeout ->
        {:ok, %{"tabs" => [%{"targetId" => "a", "url" => @page_url, "active" => true}]}}

      _method, _args, _timeout ->
        {:ok, %{"result" => %{"__lemon_refused" => true}}}
    end

    tool = browser_tool("browser_evaluate", "/tmp", browser_request: sentinel)
    assert {:error, message} = tool.execute.("call-1", %{"expression" => "1"}, nil, nil)
    assert message =~ "only on http:, https: and about:"
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

    tool = browser_tool("browser_hover", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_select_option", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_upload_file", tmp_dir, browser_request: request)

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

    tool = browser_tool("browser_upload_file", tmp_dir, browser_request: request)

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

    tool = browser_tool("browser_download", tmp_dir, browser_request: request)

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

    tool = browser_tool("browser_download", tmp_dir, browser_request: request)

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

  describe "project containment for browser file paths" do
    setup %{tmp_dir: tmp_dir} do
      outside =
        Path.join(
          System.tmp_dir!(),
          "lemon-browser-outside-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)

      secret = Path.join(outside, "secret.txt")
      File.write!(secret, "outside-secret")
      File.ln_s!(outside, Path.join(tmp_dir, "linked-dir"))
      File.ln_s!(secret, Path.join(tmp_dir, "linked-secret.txt"))

      {:ok, outside: outside, secret: secret}
    end

    test "browser_screenshot rejects absolute paths outside the project", %{tmp_dir: tmp_dir} do
      target = "/tmp/lemon-browser-shot-#{System.unique_integer([:positive])}.png"
      on_exit(fn -> File.rm(target) end)

      tool = browser_tool("browser_screenshot", tmp_dir, browser_request: png_request())

      assert {:error, "browser_screenshot output path must be under the current project"} =
               tool.execute.("call-1", %{"path" => target}, nil, nil)

      refute File.exists?(target)
    end

    test "browser_screenshot rejects relative escapes and symlinked directories", %{
      tmp_dir: tmp_dir,
      outside: outside
    } do
      tool = browser_tool("browser_screenshot", tmp_dir, browser_request: png_request())
      escape = "../#{Path.basename(outside)}/escape.png"

      for path <- [escape, "linked-dir/shot.png", "linked-secret.txt"] do
        assert {:error, "browser_screenshot output path must be under the current project"} =
                 tool.execute.("call-1", %{"path" => path}, nil, nil)
      end

      refute File.exists?(Path.join(outside, "escape.png"))
      refute File.exists?(Path.join(outside, "shot.png"))
      assert File.read!(Path.join(outside, "secret.txt")) == "outside-secret"
    end

    test "browser_screenshot rejects a dangling symlink leaf", %{
      tmp_dir: tmp_dir,
      outside: outside
    } do
      target = Path.join(outside, "dangling.png")
      File.ln_s!(target, Path.join(tmp_dir, "dangling.png"))
      tool = browser_tool("browser_screenshot", tmp_dir, browser_request: png_request())

      assert {:error, _} = tool.execute.("call-1", %{"path" => "dangling.png"}, nil, nil)
      refute File.exists?(target)
    end

    test "browser_analyze rejects symlinked output directories", %{
      tmp_dir: tmp_dir,
      outside: outside
    } do
      tool = browser_tool("browser_analyze", tmp_dir, browser_request: png_request())

      assert {:error, "path must be under the current project for browser_analyze"} =
               tool.execute.(
                 "call-1",
                 %{"path" => "linked-dir/vision.png", "provider" => "local_vision"},
                 nil,
                 nil
               )

      refute File.exists?(Path.join(outside, "vision.png"))
    end

    test "browser_upload_file rejects symlinked and hard-linked files", %{
      tmp_dir: tmp_dir,
      secret: secret
    } do
      File.ln!(secret, Path.join(tmp_dir, "hard-secret.txt"))

      request = fn _method, _args, _timeout ->
        flunk("browser request should not run for rejected upload files")
      end

      tool = browser_tool("browser_upload_file", tmp_dir, browser_request: request)

      for path <- ["linked-secret.txt", "linked-dir/secret.txt", "hard-secret.txt"] do
        assert {:error, "browser_upload_file path must be under the current project"} =
                 tool.execute.("call-1", %{"selector" => "#f", "path" => path}, nil, nil)
      end
    end

    test "browser_download rejects symlinked output paths", %{tmp_dir: tmp_dir} do
      request = fn _method, _args, _timeout ->
        flunk("browser request should not run for rejected download paths")
      end

      tool = browser_tool("browser_download", tmp_dir, browser_request: request)

      for path <- ["linked-dir/out.txt", "linked-secret.txt"] do
        assert {:error, "browser_download output path must be under the current project"} =
                 tool.execute.("call-1", %{"selector" => "#d", "path" => path}, nil, nil)
      end
    end

    test "default screenshot and analyze destinations are checked too", %{
      tmp_dir: tmp_dir,
      outside: outside
    } do
      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
      File.ln_s!(outside, Path.join(tmp_dir, ".lemon/browser-artifacts"))

      shot = browser_tool("browser_screenshot", tmp_dir, browser_request: png_request())

      assert {:error, "browser_screenshot output path must be under the current project"} =
               shot.execute.("call-1", %{}, nil, nil)

      analyze = browser_tool("browser_analyze", tmp_dir, browser_request: png_request())

      assert {:error, "path must be under the current project for browser_analyze"} =
               analyze.execute.("call-1", %{"provider" => "local_vision"}, nil, nil)

      assert File.ls!(outside) == ["secret.txt"]
    end

    test "browser_download forwards the validated path unchanged", %{tmp_dir: tmp_dir} do
      parent = self()
      File.ln_s!(System.tmp_dir!(), Path.join(tmp_dir, "escape"))

      request = fn method, args, _timeout ->
        send(parent, {:browser_request, method, args})
        {:ok, %{"downloaded" => true}}
      end

      tool = browser_tool("browser_download", tmp_dir, browser_request: request)
      tool.execute.("call-1", %{"selector" => "#d", "path" => "escape "}, nil, nil)

      expected = Path.join(tmp_dir, "escape ")
      assert_received {:browser_request, "browser.download", %{"path" => ^expected}}
    end
  end

  describe "local documents" do
    test "file:, data: and blob: navigation needs allowLocalDocument" do
      request = fn method, args, _timeout ->
        send(self(), {:browser_request, method, args})
        {:ok, %{"url" => args["url"]}}
      end

      for {name, url} <- [
            {"browser_navigate", "file:///etc/passwd"},
            {"browser_navigate", "FILE:///etc/passwd"},
            {"browser_navigate", "data:text/html,hi"},
            {"browser_tab_open", "blob:https://example.com/x"}
          ] do
        tool = browser_tool(name, "/tmp", browser_request: request)

        assert {:error, message} = tool.execute.("call-1", %{"url" => url}, nil, nil)
        assert message =~ "requires allowLocalDocument"
        refute_received {:browser_request, _, _}

        result =
          tool.execute.("call-1", %{"url" => url, "allowLocalDocument" => true}, nil, nil)

        refute match?({:error, _}, result)
        assert_received {:browser_request, _, %{"url" => ^url}}
      end
    end

    test "screenshot and analyze of an open local document need allowLocalDocument", %{
      tmp_dir: tmp_dir
    } do
      png = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)
      # The media analysis path consumes the test mailbox, so record captures in an Agent.
      {:ok, captures} = Agent.start_link(fn -> [] end)

      request = fn "browser.screenshot", args, _timeout ->
        Agent.update(captures, &[args | &1])
        {:ok, %{"url" => "file:///etc/passwd", "contentType" => "image/png", "base64" => png}}
      end

      artifacts = Path.join(tmp_dir, ".lemon/browser-artifacts")

      for {name, params} <- [
            {"browser_screenshot", %{"includeImage" => true}},
            {"browser_analyze", %{"includeImage" => true, "provider" => "local_vision"}}
          ] do
        Agent.update(captures, fn _ -> [] end)
        tool = browser_tool(name, tmp_dir, browser_request: request)

        assert {:error, message} = tool.execute.("call-1", params, nil, nil)
        assert message =~ "allowLocalDocument"
        refute message =~ png
        assert [args] = Agent.get(captures, & &1)
        refute Map.has_key?(args, "allowLocalDocument")
        # Nothing was written, so no image reached the model or a vision provider.
        assert File.ls(artifacts) in [{:error, :enoent}, {:ok, []}]
        refute File.exists?(Path.join(tmp_dir, ".lemon/media-artifacts"))

        result =
          tool.execute.("call-2", Map.put(params, "allowLocalDocument", true), nil, nil)

        refute match?({:error, _}, result)
        assert [%{"allowLocalDocument" => true}, _] = Agent.get(captures, & &1)
        File.rm_rf!(Path.join(tmp_dir, ".lemon"))
      end
    end

    test "a capture without URL metadata fails closed for every backend", %{
      tmp_dir: tmp_dir
    } do
      # The pre-fix Tern screenshot answer: image bytes, no page URL.
      tern_shape = %{"base64" => Base.encode64("image"), "contentType" => "image/jpeg"}

      for name <- ["browser_screenshot", "browser_analyze"] do
        tool =
          browser_tool(name, tmp_dir, browser_request: fn _, _, _ -> {:ok, tern_shape} end)

        assert {:error, message} =
                 tool.execute.("call-1", %{"provider" => "local_vision"}, nil, nil)

        assert message =~ "did not report the page URL"
        refute File.exists?(Path.join(tmp_dir, ".lemon"))
      end

      # No backend attestation can stand in for the URL.
      attested = Map.put(tern_shape, "localDocumentGuarded", true)

      tool =
        browser_tool("browser_screenshot", tmp_dir,
          browser_request: fn _, _, _ -> {:ok, attested} end
        )

      assert {:error, _} = tool.execute.("call-1", %{}, nil, nil)
    end

    test "content reads of a local document are refused without approval" do
      for {name, payload} <- [
            {"browser_get_content", %{"url" => "file:///etc/passwd", "text" => "root:x:0:0"}},
            {"browser_snapshot", %{"snapshot" => "URL: file:///etc/passwd\n\nroot:x:0:0"}}
          ] do
        parent = self()

        request = fn _method, args, _timeout ->
          send(parent, {:args, args})
          {:ok, payload}
        end

        tool = browser_tool(name, "/tmp", browser_request: request)

        assert {:error, message} = tool.execute.("call-1", %{}, nil, nil)
        assert message =~ "local document" or message =~ "file:, data: or blob:"
        refute message =~ "root:x"
        assert_received {:args, args}
        refute Map.has_key?(args, "allowLocalDocument")

        result = tool.execute.("call-1", %{"allowLocalDocument" => true}, nil, nil)
        refute match?({:error, _}, result)
        assert_received {:args, %{"allowLocalDocument" => true}}
      end
    end

    test "Lemon credential documents are refused even with allowLocalDocument" do
      cookie = LemonCore.Paths.home_path("cookie")
      File.mkdir_p!(Path.dirname(cookie))
      File.write!(cookie, "browser-cookie-secret\n")
      on_exit(fn -> File.rm(cookie) end)
      url = "file://" <> URI.encode(cookie)
      approved = %{"allowLocalDocument" => true}

      for name <- ["browser_navigate", "browser_tab_open"] do
        tool =
          browser_tool(name, "/tmp",
            browser_request: fn _, _, _ -> flunk("navigation reached the backend") end
          )

        assert {:error, message} =
                 tool.execute.("call-1", Map.put(approved, "url", url), nil, nil)

        assert message =~ "credential"
      end

      # An attached tab (or back-navigation) already showing the credential.
      for {name, payload} <- [
            {"browser_get_content", %{"url" => url, "text" => "browser-cookie-secret"}},
            {"browser_snapshot", %{"snapshot" => "URL: #{url}\n\nbrowser-cookie-secret"}},
            {"browser_screenshot",
             %{"url" => url, "contentType" => "image/png", "base64" => Base.encode64("png")}}
          ] do
        tool = browser_tool(name, "/tmp", browser_request: fn _, _, _ -> {:ok, payload} end)
        assert {:error, message} = tool.execute.("call-1", approved, nil, nil)
        assert message =~ "credential"
        refute message =~ "browser-cookie-secret"
      end

      # A project that encloses the Lemon home cannot upload its credentials.
      home = LemonCore.Paths.home_dir()

      upload =
        browser_tool("browser_upload_file", home,
          browser_request: fn _, _, _ -> flunk("upload reached the backend") end
        )

      assert {:error, message} =
               upload.execute.(
                 "call-1",
                 %{"selector" => "#f", "path" => ".lemon/cookie"},
                 nil,
                 nil
               )

      assert message =~ "credential"
    end
  end

  test "browser_snapshot forwards optional snapshot limits" do
    parent = self()

    request = fn method, args, timeout_ms ->
      send(parent, {:browser_request, method, args, timeout_ms})
      {:ok, %{"snapshot" => "URL: https://example.com/page.html", "displayedNodes" => 1}}
    end

    tool = browser_tool("browser_snapshot", "/tmp", browser_request: request)

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
      {:ok, %{"url" => @page_url, "contentType" => "image/png", "base64" => Base.encode64(png)}}
    end

    path = Path.join(tmp_dir, "shot.png")
    tool = browser_tool("browser_screenshot", tmp_dir, browser_request: request)

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
      {:ok, %{"url" => @page_url, "contentType" => "image/png", "base64" => encoded}}
    end

    path = Path.join(tmp_dir, "vision.png")
    tool = browser_tool("browser_screenshot", tmp_dir, browser_request: request)

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
      {:ok, %{"url" => @page_url, "contentType" => "image/png", "base64" => encoded}}
    end

    on_update = fn update ->
      Agent.update(updates_agent, fn existing -> [update | existing] end)
      :ok
    end

    path = Path.join(tmp_dir, "browser-vision.png")
    tool = browser_tool("browser_analyze", tmp_dir, browser_request: request)

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
      {:ok, %{"url" => @page_url, "contentType" => "image/png", "base64" => encoded}}
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
      browser_tool("browser_analyze", tmp_dir,
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
      {:ok, %{"url" => @page_url, "contentType" => "image/png", "base64" => Base.encode64(png)}}
    end

    path = Path.join(tmp_dir, "channel-shot.png")
    tool = browser_tool("browser_screenshot", tmp_dir, browser_request: request)

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
      {:ok, %{"url" => @page_url, "contentType" => "image/png", "base64" => Base.encode64(png)}}
    end

    tool = browser_tool("browser_screenshot", tmp_dir, browser_request: request)

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

    tool = browser_tool("browser_events", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_get_cookies", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_get_cookies", "/tmp", browser_request: request)

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
    tool = browser_tool("browser_set_cookies", "/tmp", browser_request: request)

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

    tool = browser_tool("browser_clear_state", "/tmp", browser_request: request)

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

  # Needs node, the built clients/lemon-browser-node driver and Chrome; the
  # coding_agent test_helper excludes :browser_driver when one is missing.
  @tag :browser_driver
  test "browser tools drive a deterministic page through the supervised local server", %{
    tmp_dir: tmp_dir
  } do
    chrome = TestHostCapabilities.chrome_executable()
    server = :"browser_smoke_#{System.unique_integer([:positive])}"
    port = free_port()
    profile_dir = Path.join(tmp_dir, "browser-profile")

    with_env(
      %{
        "LEMON_BROWSER_CDP_PORT" => Integer.to_string(port),
        "LEMON_BROWSER_DRIVER_PATH" => TestHostCapabilities.browser_driver_path(),
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

        # A loopback http: page: data:/file: documents are approval-gated and
        # never evaluable.
        url = serve_html(html)

        navigate =
          "browser_navigate"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{"url" => url, "timeoutMs" => 60_000})

        assert navigate.trust == :untrusted
        assert navigate.details["title"] == "Lemon Browser Proof"

        snapshot =
          "browser_snapshot"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{"selector" => "main", "maxChars" => 2_000})

        assert snapshot.trust == :untrusted
        assert snapshot.details["snapshot"] =~ "Hermes on BEAM"

        waited =
          "browser_wait_for_selector"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{"selector" => "#message", "timeoutMs" => 1_000})

        assert waited.details["found"] == true

        evaluated =
          "browser_evaluate"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{
            "expression" =>
              "(() => ({title: document.title, hasMessage: !!document.querySelector('#message')}))()",
            "timeoutMs" => 1_000
          })

        assert evaluated.details["result"]["title"] == "Lemon Browser Proof"
        assert evaluated.details["result"]["hasMessage"] == true

        hovered =
          "browser_hover"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{"selector" => "#menu", "timeoutMs" => 1_000})

        assert hovered.details["hovered"] == true

        selected =
          "browser_select_option"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{
            "selector" => "#mode",
            "value" => "otp-mode",
            "timeoutMs" => 1_000
          })

        assert selected.details["selected"] == ["otp-mode"]

        typed =
          "browser_type"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{
            "selector" => "#message",
            "text" => "OTP supervision",
            "useFill" => true
          })

        assert typed.details["typed"] == true
        assert typed.details["length"] == String.length("OTP supervision")

        clicked =
          "browser_click"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{"selector" => "#save"})

        assert clicked.details["clicked"] == true

        content =
          "browser_get_content"
          |> browser_tool(tmp_dir, browser_request: request)
          |> run_browser_tool(%{"includeHtml" => false, "includeText" => true})

        assert content.trust == :untrusted
        assert content.details["text"] =~ "hovered"
        assert content.details["text"] =~ "saved: OTP supervision (otp-mode)"

        events =
          "browser_events"
          |> browser_tool(tmp_dir, browser_request: request)
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
  end

  test "browser_click validates selector" do
    tool =
      browser_tool("browser_click", "/tmp", browser_request: fn _, _, _ -> flunk("unused") end)

    assert {:error, "selector is required"} = tool.execute.("call-1", %{}, nil, nil)
  end

  defp run_browser_tool(tool, params) do
    result = tool.execute.("call-1", params, nil, nil)
    refute match?({:error, _}, result), inspect(result)
    # An unknown-outcome timeout is an error result, not a success.
    refute result.is_error, inspect(result)
    result
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Serves `html` to every request on a loopback port until the test exits.
  defp serve_html(html) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn(fn -> serve_html_loop(listener, html) end)
    :ok = :gen_tcp.controlling_process(listener, server)
    on_exit(fn -> Process.exit(server, :kill) end)
    "http://127.0.0.1:#{port}/"
  end

  defp serve_html_loop(listener, html) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        handler = spawn(fn -> serve_html_response(html) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, {:socket, socket})
        serve_html_loop(listener, html)

      {:error, _reason} ->
        :ok
    end
  end

  # One handler per connection, so an idle preconnect never blocks the page load.
  defp serve_html_response(html) do
    receive do
      {:socket, socket} ->
        _request = :gen_tcp.recv(socket, 0, 5_000)

        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\ncontent-type: text/html; charset=utf-8\r\n",
          "content-length: #{byte_size(html)}\r\nconnection: close\r\n\r\n",
          html
        ])

        :gen_tcp.close(socket)
    end
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

  # Builds a browser tool straight from its module (`browser_navigate` ->
  # `CodingAgent.Tools.BrowserNavigate`) so tests control every tool option.
  defp browser_tool(name, cwd, opts) do
    module = Module.concat(CodingAgent.Tools, Macro.camelize(name))
    module.tool(cwd, opts)
  end

  defp png_request do
    fn
      "browser.screenshot", _args, _timeout ->
        {:ok,
         %{
           "url" => @page_url,
           "contentType" => "image/png",
           "base64" => Base.encode64(<<137, 80>>)
         }}

      method, _args, _timeout ->
        flunk("unexpected browser request #{method}")
    end
  end
end
