defmodule LemonScripts.LiveBrowserSmoke do
  alias Ai.Types.ImageContent
  alias CodingAgent.Tools
  alias LemonBrowser.LocalServer

  @default_timeout_ms 20_000

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          executable: :string,
          driver: :string,
          out: :string,
          headless: :boolean,
          no_sandbox: :boolean
        ]
      )

    project_dir = File.cwd!()
    executable = opts[:executable] || browser_executable()

    driver =
      opts[:driver] || Path.expand("clients/lemon-browser-node/dist/local-driver.js", project_dir)

    require_file!(driver, "browser driver")
    executable = require_executable!(executable)

    stamp =
      DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9A-Za-z]/, "")

    profile_dir = Path.join([project_dir, ".lemon", "browser-smoke", "profile-#{stamp}"])

    screenshot_path =
      Path.join([project_dir, ".lemon", "browser-artifacts", "browser-smoke-#{stamp}.png"])

    vision_screenshot_path =
      Path.join([
        project_dir,
        ".lemon",
        "browser-artifacts",
        "browser-vision-smoke-#{stamp}.png"
      ])

    browser_analysis_path =
      Path.join([
        project_dir,
        ".lemon",
        "browser-artifacts",
        "browser-analysis-smoke-#{stamp}.png"
      ])

    upload_path =
      Path.join([project_dir, ".lemon", "browser-smoke", "upload-proof-#{stamp}.txt"])

    proof_path =
      opts[:out] || Path.join([project_dir, ".lemon", "proofs", "browser-smoke-latest.json"])

    archive_path = Path.join([Path.dirname(proof_path), "browser-smoke-#{stamp}.json"])
    server = :"live_browser_smoke_#{System.unique_integer([:positive])}"
    port = free_port()

    env = %{
      "LEMON_BROWSER_CDP_PORT" => Integer.to_string(port),
      "LEMON_BROWSER_DRIVER_PATH" => driver,
      "LEMON_BROWSER_EXECUTABLE" => executable,
      "LEMON_BROWSER_HEADLESS" => if(opts[:headless] == false, do: "false", else: "true"),
      "LEMON_BROWSER_NO_SANDBOX" => if(opts[:no_sandbox] == false, do: "false", else: "true"),
      "LEMON_BROWSER_USER_DATA_DIR" => profile_dir
    }

    File.mkdir_p!(Path.dirname(upload_path))
    File.write!(upload_path, "browser upload proof #{stamp}\n")

    with_env(env, fn ->
      {:ok, pid} = LocalServer.start_link(name: server)
      {:ok, progress_agent} = Agent.start_link(fn -> [] end)

      try do
        request = fn method, method_args, timeout_ms ->
          LocalServer.request(server, method, method_args, timeout_ms)
        end

        html = proof_page()
        url = "data:text/html;base64,#{Base.encode64(html)}"

        navigate =
          run_tool("browser_navigate", project_dir, request, progress_agent, %{"url" => url})

        assert_detail(navigate, ["title"], "Lemon Browser Live Smoke")
        assert_detail(navigate, ["networkPolicy", "route"], "auto")
        assert_detail(navigate, ["networkPolicy", "effectiveRoute"], "local")
        assert_detail(navigate, ["networkPolicy", "targetKind"], "local_document")
        assert_detail(navigate, ["networkPolicy", "private"], true)

        waited =
          run_tool("browser_wait_for_selector", project_dir, request, progress_agent, %{
            "selector" => "main",
            "timeoutMs" => 5_000
          })

        assert_detail(waited, ["found"], true)

        evaluated =
          run_tool("browser_evaluate", project_dir, request, progress_agent, %{
            "expression" =>
              "(() => ({title: document.title, ready: !!document.querySelector('main')}))()",
            "timeoutMs" => 5_000
          })

        assert_detail(evaluated, ["result", "title"], "Lemon Browser Live Smoke")
        assert_detail(evaluated, ["result", "ready"], true)

        hovered =
          run_tool("browser_hover", project_dir, request, progress_agent, %{
            "selector" => "#menu",
            "timeoutMs" => 5_000
          })

        assert_detail(hovered, ["hovered"], true)

        selected =
          run_tool("browser_select_option", project_dir, request, progress_agent, %{
            "selector" => "#mode",
            "value" => "otp-mode",
            "timeoutMs" => 5_000
          })

        assert_detail(selected, ["selected"], ["otp-mode"])

        uploaded =
          run_tool("browser_upload_file", project_dir, request, progress_agent, %{
            "selector" => "#upload",
            "path" => upload_path,
            "timeoutMs" => 5_000
          })

        assert_detail(uploaded, ["uploaded"], true)
        assert_detail(uploaded, ["count"], 1)

        downloaded =
          run_tool("browser_download", project_dir, request, progress_agent, %{
            "selector" => "#download",
            "timeoutMs" => 5_000
          })

        assert_detail(downloaded, ["downloaded"], true)
        assert_detail(downloaded, ["suggestedFilename"], "download-proof.txt")
        assert_detail(downloaded, ["bytes"], fn bytes -> is_integer(bytes) and bytes > 0 end)
        require_file!(downloaded.details["path"], "browser download artifact")
        require_contains!(File.read!(downloaded.details["path"]), "browser download proof")

        assert_tool_error!(
          "browser_navigate",
          project_dir,
          %{"url" => "http://169.254.169.254/latest/meta-data"},
          "browser navigation blocked metadata endpoint"
        )

        assert_tool_error!(
          "browser_navigate",
          project_dir,
          %{"url" => "http://127.0.0.1:4000", "route" => "public"},
          "browser navigation requires a public http(s) URL"
        )

        snapshot =
          run_tool("browser_snapshot", project_dir, request, progress_agent, %{
            "selector" => "main",
            "maxChars" => 6_000
          })

        require_contains!(snapshot.details["snapshot"], "Hermes on BEAM")

        typed =
          run_tool("browser_type", project_dir, request, progress_agent, %{
            "selector" => "#message",
            "text" => "supervised browser worker",
            "useFill" => true
          })

        assert_detail(typed, ["typed"], true)

        clicked =
          run_tool("browser_click", project_dir, request, progress_agent, %{"selector" => "#save"})

        assert_detail(clicked, ["clicked"], true)

        screenshot =
          run_tool("browser_screenshot", project_dir, request, progress_agent, %{
            "path" => screenshot_path,
            "fullPage" => true
          })

        require_file!(screenshot.details["path"], "screenshot artifact")
        assert_detail(screenshot, ["bytes"], fn bytes -> is_integer(bytes) and bytes > 100 end)

        vision_screenshot =
          run_tool("browser_screenshot", project_dir, request, progress_agent, %{
            "path" => vision_screenshot_path,
            "fullPage" => true,
            "includeImage" => true
          })

        require_file!(vision_screenshot.details["path"], "vision screenshot artifact")
        assert_detail(vision_screenshot, ["imageIncluded"], true)

        {vision_image, vision_image_bytes} = require_image_content!(vision_screenshot.content)

        vision_analysis =
          run_tool("media_analyze_image", project_dir, request, progress_agent, %{
            "imagePath" => vision_screenshot.details["path"],
            "provider" => "local_vision",
            "prompt" => "Summarize the browser screenshot.",
            "filename" => "browser-vision-smoke-#{stamp}"
          })

        assert_detail(vision_analysis, ["status"], "completed")
        assert_detail(vision_analysis, ["provider"], "local_vision")
        assert_detail(vision_analysis, ["trustMetadata", "untrusted"], true)
        require_file!(vision_analysis.details["artifact"]["path"], "browser vision analysis")

        browser_analysis =
          run_tool("browser_analyze", project_dir, request, progress_agent, %{
            "path" => browser_analysis_path,
            "fullPage" => true,
            "includeImage" => true,
            "provider" => "local_vision",
            "prompt" => "Summarize the browser screenshot.",
            "filename" => "browser-analysis-smoke-#{stamp}"
          })

        assert_detail(browser_analysis, ["status"], "completed")
        assert_detail(browser_analysis, ["provider"], "local_vision")
        assert_detail(browser_analysis, ["screenshot", "imageIncluded"], true)
        assert_detail(browser_analysis, ["analysis", "provider"], "local_vision")

        require_file!(
          browser_analysis.details["screenshot"]["path"],
          "browser analysis screenshot"
        )

        require_file!(
          browser_analysis.details["analysis"]["artifact"]["path"],
          "browser analysis artifact"
        )

        {browser_analysis_image, browser_analysis_image_bytes} =
          require_image_content!(browser_analysis.content)

        content =
          run_tool("browser_get_content", project_dir, request, progress_agent, %{
            "includeHtml" => false,
            "includeText" => true
          })

        require_contains!(content.details["text"], "saved: supervised browser worker")
        require_contains!(content.details["text"], "upload-ready: upload-proof-")

        events =
          run_tool("browser_events", project_dir, request, progress_agent, %{
            "limit" => 20,
            "clear" => true
          })

        require_event!(events.details["events"], "console", "lemon-browser-live-smoke-ready")

        cookie = %{
          "name" => "lemon_browser_smoke",
          "value" => "cookie-proof",
          "url" => "https://example.com"
        }

        set_cookies =
          run_tool("browser_set_cookies", project_dir, request, progress_agent, %{
            "cookies" => [cookie]
          })

        assert_detail(set_cookies, ["set"], 1)

        redacted_cookies =
          run_tool("browser_get_cookies", project_dir, request, progress_agent, %{
            "url" => "https://example.com"
          })

        require_cookie!(redacted_cookies.details["cookies"], "lemon_browser_smoke", "[redacted]")

        raw_cookies =
          run_tool("browser_get_cookies", project_dir, request, progress_agent, %{
            "url" => "https://example.com",
            "includeValues" => true
          })

        require_cookie!(raw_cookies.details["cookies"], "lemon_browser_smoke", "cookie-proof")

        clear_state =
          run_tool("browser_clear_state", project_dir, request, progress_agent, %{
            "clearStorage" => false
          })

        assert_detail(clear_state, ["cookiesCleared"], true)
        assert_detail(clear_state, ["eventsCleared"], true)

        cleared_cookies =
          run_tool("browser_get_cookies", project_dir, request, progress_agent, %{
            "url" => "https://example.com",
            "includeValues" => true
          })

        assert_detail(cleared_cookies, ["cookies"], [])

        status = LocalServer.status(server)
        assert_map_value!(status, :running, true)
        assert_map_value!(status, :pending_requests, 0)

        attach_proof = run_cdp_attach_smoke(project_dir, executable, driver, stamp, opts)

        progress_updates = Agent.get(progress_agent, &Enum.reverse/1)
        progress = progress_summary(progress_updates)

        if progress.cleanup.contains_raw_sensitive_values do
          raise "browser progress updates leaked sensitive values"
        end

        exercised_tools = [
          "browser_navigate",
          "browser_wait_for_selector",
          "browser_evaluate",
          "browser_hover",
          "browser_select_option",
          "browser_upload_file",
          "browser_download",
          "browser_snapshot",
          "browser_type",
          "browser_click",
          "browser_screenshot",
          "browser_screenshot_include_image",
          "media_analyze_image_local_vision",
          "browser_analyze_local_vision",
          "browser_get_content",
          "browser_events",
          "browser_set_cookies",
          "browser_get_cookies",
          "browser_clear_state",
          "browser_cdp_attach_mode"
        ]

        proof = %{
          generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          status: "completed",
          proof: "browser_smoke",
          proof_scope: "browser_smoke",
          project_dir_hash: hash_value(project_dir),
          driver_path_hash: hash_value(driver),
          executable_path_hash: hash_value(executable),
          cdp_port: port,
          screenshot_path_hash: hash_value(screenshot.details["path"]),
          screenshot_bytes: screenshot.details["bytes"],
          vision_screenshot_path_hash: hash_value(vision_screenshot.details["path"]),
          vision_screenshot_bytes: vision_screenshot.details["bytes"],
          model_visible_image_included: true,
          model_visible_image_mime_type: vision_image.mime_type,
          model_visible_image_byte_size: vision_image_bytes,
          model_visible_image_hash: hash_value(vision_image.data),
          browser_to_media_vision_completed: true,
          browser_to_media_vision_provider: vision_analysis.details["provider"],
          browser_to_media_vision_text_hash: hash_value(vision_analysis.details["text"]),
          browser_to_media_vision_artifact_path_hash:
            hash_value(vision_analysis.details["artifact"]["path"]),
          browser_to_media_vision_artifact_bytes: vision_analysis.details["artifact"]["bytes"],
          browser_analyze_completed: true,
          browser_analyze_provider: browser_analysis.details["provider"],
          browser_analyze_text_hash: hash_value(browser_analysis.details["text"]),
          browser_analyze_screenshot_path_hash:
            hash_value(browser_analysis.details["screenshot"]["path"]),
          browser_analyze_screenshot_bytes: browser_analysis.details["screenshot"]["bytes"],
          browser_analyze_artifact_path_hash:
            hash_value(browser_analysis.details["analysis"]["artifact"]["path"]),
          browser_analyze_artifact_bytes:
            browser_analysis.details["analysis"]["artifact"]["bytes"],
          browser_analyze_model_visible_image_included: true,
          browser_analyze_model_visible_image_mime_type: browser_analysis_image.mime_type,
          browser_analyze_model_visible_image_byte_size: browser_analysis_image_bytes,
          browser_analyze_model_visible_image_hash: hash_value(browser_analysis_image.data),
          title: navigate.details["title"],
          browser_navigation_route: navigate.details["networkPolicy"]["route"],
          browser_navigation_effective_route: navigate.details["networkPolicy"]["effectiveRoute"],
          browser_navigation_target_kind: navigate.details["networkPolicy"]["targetKind"],
          browser_navigation_private: navigate.details["networkPolicy"]["private"] == true,
          browser_navigation_metadata_blocked: true,
          browser_navigation_public_route_guarded: true,
          browser_wait_for_selector_completed: waited.details["found"] == true,
          browser_evaluate_completed: evaluated.details["result"]["ready"] == true,
          browser_evaluate_result_hash: hash_value(Jason.encode!(evaluated.details["result"])),
          browser_hover_completed: hovered.details["hovered"] == true,
          browser_select_option_completed: selected.details["selected"] == ["otp-mode"],
          browser_upload_file_completed: uploaded.details["uploaded"] == true,
          browser_upload_file_count: uploaded.details["count"],
          browser_download_completed: downloaded.details["downloaded"] == true,
          browser_download_path_hash: hash_value(downloaded.details["path"]),
          browser_download_bytes: downloaded.details["bytes"],
          browser_cdp_attach_completed: true,
          browser_cdp_attach_status: attach_proof.status,
          browser_cdp_attach_title: attach_proof.title,
          browser_cdp_attach_endpoint_hash: hash_value(attach_proof.endpoint),
          completed_count: status.completed_count,
          failed_count: status.failed_count,
          skipped_count: 0,
          progress_update_count: progress.update_count,
          progress_phase_counts: progress.phase_counts,
          progress_method_counts: progress.method_counts,
          progress_navigation_route_counts: progress.navigation_route_counts,
          progress_navigation_target_kind_counts: progress.navigation_target_kind_counts,
          progress_browser_child_action_count: progress.browser_child_action_count,
          progress_cleanup: progress.cleanup,
          cleanup: progress.cleanup,
          checks:
            Enum.map(exercised_tools, fn tool ->
              %{name: "browser_smoke_#{tool}", status: "completed", proof_scope: "browser_smoke"}
            end),
          exercised_tools: exercised_tools,
          result: "passed"
        }

        write_json!(proof_path, proof)
        write_json!(archive_path, proof)

        IO.puts(Jason.encode!(proof, pretty: true))
      after
        if Process.alive?(progress_agent), do: Agent.stop(progress_agent)
        if Process.alive?(pid), do: LocalServer.stop(server)
      end
    end)
  end

  defp proof_page do
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Lemon Browser Live Smoke</title>
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
          <input id="upload" type="file" aria-label="Upload">
          <output id="upload-result"></output>
          <a
            id="download"
            href="data:text/plain;base64,YnJvd3NlciBkb3dubG9hZCBwcm9vZg=="
            download="download-proof.txt"
          >Download</a>
          <input id="message" aria-label="Message" value="">
          <button id="save" type="button">Save</button>
          <output id="result"></output>
        </main>
        <script>
          console.log("lemon-browser-live-smoke-ready");
          document.getElementById("menu").addEventListener("mouseover", () => {
            document.getElementById("hover-result").textContent = "hovered";
          });
          document.getElementById("upload").addEventListener("change", (event) => {
            const file = event.target.files && event.target.files[0];
            document.getElementById("upload-result").textContent = file ? `upload-ready: ${file.name}` : "";
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
  end

  defp run_cdp_attach_smoke(project_dir, executable, driver, stamp, opts) do
    port = free_port()
    endpoint = "http://127.0.0.1:#{port}"
    profile_dir = Path.join([project_dir, ".lemon", "browser-smoke", "attach-profile-#{stamp}"])
    File.mkdir_p!(profile_dir)

    chrome_port = start_chrome_for_cdp(executable, port, profile_dir, opts)

    try do
      wait_for_cdp!(endpoint, 15_000)

      env = %{
        "LEMON_BROWSER_DRIVER_PATH" => driver,
        "LEMON_BROWSER_CDP_ENDPOINT" => endpoint,
        "LEMON_BROWSER_ATTACH_ONLY" => "true"
      }

      with_env(env, fn ->
        server = :"live_browser_attach_smoke_#{System.unique_integer([:positive])}"
        {:ok, pid} = LocalServer.start_link(name: server)

        try do
          request = fn method, method_args, timeout_ms ->
            LocalServer.request(server, method, method_args, timeout_ms)
          end

          html = """
          <!doctype html>
          <html><head><title>Lemon Browser CDP Attach</title></head><body>attach mode</body></html>
          """

          url = "data:text/html;base64,#{Base.encode64(html)}"

          result =
            "browser_navigate"
            |> Tools.get_tool(project_dir, browser_request: request)
            |> Map.fetch!(:execute)
            |> then(fn execute ->
              execute.(
                "live-browser-attach-smoke",
                %{"url" => url, "timeoutMs" => @default_timeout_ms},
                nil,
                nil
              )
            end)

          case result do
            %{details: %{"title" => "Lemon Browser CDP Attach", "status" => status}} ->
              %{endpoint: endpoint, title: "Lemon Browser CDP Attach", status: status}

            {:error, reason} ->
              raise "browser CDP attach smoke failed: #{reason}"

            other ->
              raise "browser CDP attach smoke returned unexpected result: #{inspect(other)}"
          end
        after
          if Process.alive?(pid), do: LocalServer.stop(server)
        end
      end)
    after
      close_chrome_port(chrome_port)
    end
  end

  defp run_tool(name, project_dir, request, progress_agent, params) do
    result =
      name
      |> Tools.get_tool(project_dir, browser_request: request)
      |> Map.fetch!(:execute)
      |> then(fn execute ->
        execute.(
          "live-browser-smoke",
          Map.put_new(params, "timeoutMs", @default_timeout_ms),
          nil,
          progress_collector(progress_agent)
        )
      end)

    case result do
      {:error, reason} -> raise "#{name} failed: #{reason}"
      %{details: details} when is_map(details) -> result
      other -> raise "#{name} returned unexpected result: #{inspect(other)}"
    end
  end

  defp progress_collector(progress_agent) do
    fn update ->
      Agent.update(progress_agent, fn updates -> [update | updates] end)
      :ok
    end
  end

  defp progress_summary(updates) do
    details = Enum.map(updates, & &1.details)

    encoded =
      details
      |> Jason.encode!()
      |> String.downcase()

    %{
      update_count: length(updates),
      phase_counts: count_by(details, "phase"),
      method_counts: count_by(details, "method"),
      navigation_route_counts: count_in(details, ["browser", "effectiveRoute"]),
      navigation_target_kind_counts: count_in(details, ["browser", "targetKind"]),
      browser_child_action_count:
        Enum.count(details, fn detail ->
          get_in(detail, ["current_action", "kind"]) == "browser"
        end),
      cleanup: %{
        contains_raw_sensitive_values:
          Enum.any?([
            String.contains?(encoded, "supervised browser worker"),
            String.contains?(encoded, "#message"),
            String.contains?(encoded, "#save"),
            String.contains?(encoded, "#menu"),
            String.contains?(encoded, "#mode"),
            String.contains?(encoded, "#upload"),
            String.contains?(encoded, "#download"),
            String.contains?(encoded, "otp-mode"),
            String.contains?(encoded, "upload-proof"),
            String.contains?(encoded, "download-proof"),
            String.contains?(encoded, "browser download proof"),
            String.contains?(encoded, "cookie-proof"),
            String.contains?(encoded, "saved:"),
            String.contains?(encoded, "data:text/html"),
            String.contains?(encoded, "browser-smoke-"),
            String.contains?(encoded, ".lemon/browser-artifacts")
          ]),
        includes_raw_urls: false,
        includes_selectors: false,
        includes_typed_text: false,
        includes_cookie_values: false,
        includes_page_text: false,
        includes_artifact_paths: false,
        includes_raw_paths: false,
        includes_screenshot_bytes: false
      }
    }
  end

  defp count_by(details, key) do
    details
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp count_in(details, keys) do
    details
    |> Enum.map(&get_in(&1, keys))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp browser_executable do
    [
      System.get_env("LEMON_BROWSER_EXECUTABLE"),
      System.get_env("LEMON_CHROME_EXECUTABLE"),
      System.get_env("CHROME_EXECUTABLE"),
      System.find_executable("google-chrome"),
      System.find_executable("google-chrome-stable"),
      System.find_executable("chromium"),
      System.find_executable("chromium-browser")
    ]
    |> Kernel.++(
      Path.wildcard(Path.expand("~/.cache/ms-playwright/chromium-*/chrome-linux64/chrome"))
    )
    |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  defp require_executable!(nil) do
    raise "Chrome/Chromium executable not found. Pass --executable or set LEMON_BROWSER_EXECUTABLE."
  end

  defp require_executable!(path) do
    cond do
      File.exists?(path) -> Path.expand(path)
      System.find_executable(path) -> path
      true -> raise "Chrome/Chromium executable does not exist: #{path}"
    end
  end

  defp require_file!(path, label) when is_binary(path) do
    unless File.exists?(path), do: raise("#{label} does not exist: #{path}")
    path
  end

  defp require_file!(path, label), do: raise("#{label} path missing: #{inspect(path)}")

  defp require_contains!(value, expected) when is_binary(value) do
    unless String.contains?(value, expected) do
      raise "expected #{inspect(value)} to contain #{inspect(expected)}"
    end
  end

  defp require_contains!(value, expected),
    do: raise("expected string containing #{expected}, got: #{inspect(value)}")

  defp require_event!(events, type, text) when is_list(events) do
    found? =
      Enum.any?(events, fn event ->
        event["type"] == type and
          String.contains?(to_string(event["text"] || event["message"] || ""), text)
      end)

    unless found?, do: raise("expected #{type} event containing #{inspect(text)}")
  end

  defp require_event!(events, _type, _text),
    do: raise("expected browser events list, got: #{inspect(events)}")

  defp require_image_content!(content) when is_list(content) do
    case Enum.filter(content, &match?(%ImageContent{}, &1)) do
      [%ImageContent{data: data, mime_type: mime_type} = image] when is_binary(data) ->
        case Base.decode64(data) do
          {:ok, bytes} when byte_size(bytes) > 100 and mime_type in ["image/png", "image/jpeg"] ->
            {image, byte_size(bytes)}

          {:ok, bytes} ->
            raise "unexpected image content size or mime type: #{byte_size(bytes)} #{mime_type}"

          :error ->
            raise "model-visible image content was not valid base64"
        end

      images ->
        raise "expected one model-visible image content block, got: #{inspect(images)}"
    end
  end

  defp require_image_content!(content),
    do: raise("expected content list with image block, got: #{inspect(content)}")

  defp require_cookie!(cookies, name, value) when is_list(cookies) do
    found? =
      Enum.any?(cookies, fn cookie ->
        cookie["name"] == name and cookie["value"] == value
      end)

    unless found?,
      do:
        raise(
          "expected cookie #{inspect(name)} with value #{inspect(value)}, got: #{inspect(cookies)}"
        )
  end

  defp require_cookie!(cookies, name, _value),
    do:
      raise("expected browser cookies list containing #{inspect(name)}, got: #{inspect(cookies)}")

  defp assert_detail(result, keys, expected) when is_function(expected, 1) do
    value = get_in(result.details, keys)
    unless expected.(value), do: raise("unexpected #{Enum.join(keys, ".")}: #{inspect(value)}")
  end

  defp assert_detail(result, keys, expected) do
    value = get_in(result.details, keys)

    unless value == expected,
      do: raise("expected #{Enum.join(keys, ".")} #{inspect(expected)}, got #{inspect(value)}")
  end

  defp assert_tool_error!(name, project_dir, params, expected_reason) do
    request = fn _method, _args, _timeout_ms ->
      raise "blocked browser navigation reached the browser worker"
    end

    result =
      name
      |> Tools.get_tool(project_dir, browser_request: request)
      |> Map.fetch!(:execute)
      |> then(fn execute -> execute.("live-browser-smoke-blocked", params, nil, nil) end)

    unless result == {:error, expected_reason} do
      raise "expected #{name} to fail with #{inspect(expected_reason)}, got: #{inspect(result)}"
    end
  end

  defp assert_map_value!(map, key, expected) do
    value = Map.fetch!(map, key)

    unless value == expected,
      do: raise("expected #{key} #{inspect(expected)}, got #{inspect(value)}")
  end

  defp write_json!(path, payload) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload, pretty: true) <> "\n")
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp start_chrome_for_cdp(executable, port, profile_dir, opts) do
    args = [
      "--remote-debugging-port=#{port}",
      "--remote-debugging-address=127.0.0.1",
      "--user-data-dir=#{profile_dir}",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-sync",
      "--disable-background-networking",
      "--disable-component-update",
      "--disable-features=Translate,MediaRouter",
      "--disable-session-crashed-bubble",
      "--hide-crash-restore-bubble",
      "--password-store=basic",
      "about:blank"
    ]

    args =
      if opts[:headless] == false do
        args
      else
        ["--headless=new", "--disable-gpu" | args]
      end

    args =
      if opts[:no_sandbox] == false do
        args
      else
        ["--no-sandbox", "--disable-setuid-sandbox" | args]
      end

    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      {:args, args}
    ])
  end

  defp wait_for_cdp!(endpoint, timeout_ms) do
    {:ok, _} = Application.ensure_all_started(:inets)
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_cdp_until!(endpoint, deadline)
  end

  defp wait_for_cdp_until!(endpoint, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "timed out waiting for CDP attach endpoint"
    end

    url = String.to_charlist(endpoint <> "/json/version")

    case :httpc.request(:get, {url, []}, [{:timeout, 500}], []) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        :ok

      _ ->
        Process.sleep(100)
        wait_for_cdp_until!(endpoint, deadline)
    end
  end

  defp close_chrome_port(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        case System.find_executable("kill") do
          nil -> :ok
          _ -> System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        end

      _ ->
        :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end

  defp hash_value(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
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

LemonScripts.LiveBrowserSmoke.main(System.argv())
