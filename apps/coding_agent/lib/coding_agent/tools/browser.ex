defmodule CodingAgent.Tools.Browser do
  @moduledoc """
  Shared browser tool execution over the supervised LemonCore local browser server.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.{ImageContent, TextContent}
  alias CodingAgent.Security.ExternalContent
  alias CodingAgent.Tools.PathHelpers
  alias LemonBrowser.Artifacts
  alias LemonBrowser.LocalServer
  alias LemonBrowser.RoutePolicy

  import CodingAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @default_timeout_ms 30_000
  @max_timeout_ms 120_000
  @screenshot_types ~w(png jpeg)

  @spec tool(String.t(), keyword(), map()) :: AgentTool.t()
  def tool(cwd, opts, spec) do
    runtime = %{
      browser_request: Keyword.get(opts, :browser_request, &LocalServer.request/3),
      artifacts_dir: Keyword.get(opts, :browser_artifacts_dir),
      tool_opts: opts
    }

    %AgentTool{
      name: spec.name,
      description: spec.description,
      label: spec.label,
      parameters: spec.parameters,
      execute: fn tool_call_id, params, signal, on_update ->
        execute(tool_call_id, params, signal, on_update, cwd, runtime, spec)
      end
    }
  end

  def execute(_tool_call_id, params, signal, on_update, cwd, runtime, spec) do
    with :ok <- check_abort(signal),
         {:ok, request} <- spec.normalize.(params),
         :ok <- check_abort(signal) do
      emit_browser_update(on_update, spec.name, request, "started")

      case request.method do
        "browser.analyze" ->
          execute_browser_analyze(request, signal, on_update, cwd, runtime, spec.name)

        _ ->
          execute_browser_request(request, signal, on_update, cwd, runtime, spec.name)
      end
    end
  end

  defp execute_browser_request(request, signal, on_update, cwd, runtime, tool_name) do
    case prepare_browser_request(request, cwd, runtime) do
      {:ok, request} ->
        case runtime.browser_request.(request.method, request.args, request.timeout_ms) do
          {:ok, result} ->
            with :ok <- check_abort(signal) do
              final_result =
                result
                |> maybe_redact_browser_result(request)
                |> maybe_add_navigation_policy(request)
                |> maybe_write_screenshot(request, cwd, runtime)

              emit_browser_update(on_update, tool_name, request, "completed", final_result)

              wrap_result(final_result, tool_name)
            end

          {:error, reason} = error ->
            emit_browser_update(on_update, tool_name, request, "failed", %{
              "errorKind" => safe_error_kind(reason)
            })

            error
        end

      {:error, reason} = error ->
        emit_browser_update(on_update, tool_name, request, "failed", %{
          "errorKind" => safe_error_kind(reason)
        })

        error
    end
  end

  defp prepare_browser_request(
         %{method: "browser.setInputFiles", args: args} = request,
         cwd,
         _runtime
       ) do
    with {:ok, paths} <- validate_upload_file_paths(args, cwd) do
      args =
        case paths do
          [path] -> args |> Map.delete("paths") |> Map.put("path", path)
          paths -> args |> Map.delete("path") |> Map.put("paths", paths)
        end

      {:ok, %{request | args: args}}
    end
  end

  defp prepare_browser_request(%{method: "browser.download", args: args} = request, cwd, runtime) do
    with {:ok, args} <- validate_download_output_args(args, cwd, runtime) do
      {:ok, %{request | args: args}}
    end
  end

  defp prepare_browser_request(request, _cwd, _runtime), do: {:ok, request}

  defp execute_browser_analyze(request, signal, on_update, cwd, runtime, tool_name) do
    with :ok <- validate_project_relative_artifact(request.path, cwd),
         {:ok, screenshot} <- capture_analysis_screenshot(request, signal, cwd, runtime),
         {:ok, analysis} <- analyze_screenshot(screenshot, request, signal, cwd, runtime),
         :ok <- check_abort(signal) do
      final_result = browser_analysis_result(screenshot, analysis, request)
      emit_browser_update(on_update, tool_name, request, "completed", final_result)
      wrap_result(final_result, tool_name)
    else
      {:error, reason} = error ->
        emit_browser_update(on_update, tool_name, request, "failed", %{
          "errorKind" => safe_error_kind(reason)
        })

        error
    end
  end

  defp maybe_redact_browser_result(%{"cookies" => cookies} = result, %{
         redact_cookie_values: true
       })
       when is_list(cookies) do
    Map.put(result, "cookies", Enum.map(cookies, &redact_cookie_value/1))
  end

  defp maybe_redact_browser_result(result, _request), do: result

  defp redact_cookie_value(cookie) when is_map(cookie) do
    if Map.has_key?(cookie, "value") do
      Map.put(cookie, "value", "[redacted]")
    else
      cookie
    end
  end

  defp redact_cookie_value(cookie), do: cookie

  def spec(:navigate) do
    %{
      name: "browser_navigate",
      label: "Browser Navigate",
      description:
        "Navigate the supervised local browser session to a URL and return page metadata.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string", "description" => "HTTP, HTTPS, or local URL."},
          "route" => %{
            "type" => "string",
            "description" =>
              "Optional navigation route guard: auto, public, or local. Auto preserves local-first behavior while blocking metadata endpoints.",
            "enum" => ["auto", "public", "local"]
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => ["url"]
      },
      normalize: fn params ->
        with {:ok, url} <- required_string(params, ["url"]),
             {:ok, network_policy} <-
               RoutePolicy.validate_navigation(url, optional_string(params, ["route"])) do
          {:ok,
           %{
             method: "browser.navigate",
             args: %{"url" => url},
             network_policy: network_policy,
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:snapshot) do
    %{
      name: "browser_snapshot",
      label: "Browser Snapshot",
      description:
        "Inspect the current page as a compact DOM snapshot with visible text and interactive elements.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{"type" => "string", "description" => "Optional root selector."},
          "maxChars" => %{"type" => "integer", "description" => "Maximum snapshot characters."},
          "maxNodes" => %{"type" => "integer", "description" => "Maximum DOM nodes to inspect."},
          "interactiveOnly" => %{
            "type" => "boolean",
            "description" => "Only include interactive elements."
          },
          "includeText" => %{"type" => "boolean", "description" => "Include visible text."},
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok,
         %{
           method: "browser.snapshot",
           args:
             params
             |> copy_optional([
               "selector",
               "maxChars",
               "maxNodes",
               "interactiveOnly",
               "includeText"
             ]),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:get_content) do
    %{
      name: "browser_get_content",
      label: "Browser Get Content",
      description: "Return text and optionally sanitized HTML from the current browser page.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "includeHtml" => %{"type" => "boolean", "description" => "Include sanitized HTML."},
          "includeText" => %{"type" => "boolean", "description" => "Include page text."},
          "maxChars" => %{"type" => "integer", "description" => "Maximum HTML characters."},
          "textMaxChars" => %{"type" => "integer", "description" => "Maximum text characters."},
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok,
         %{
           method: "browser.getContent",
           args:
             params
             |> copy_optional(["includeHtml", "includeText", "maxChars", "textMaxChars"]),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:click) do
    %{
      name: "browser_click",
      label: "Browser Click",
      description: "Click a selector in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{"type" => "string", "description" => "CSS selector to click."},
          "timeoutMs" => timeout_schema()
        },
        "required" => ["selector"]
      },
      normalize: fn params ->
        with {:ok, selector} <- required_string(params, ["selector"]) do
          {:ok,
           %{
             method: "browser.click",
             args: %{"selector" => selector, "timeoutMs" => timeout_ms(params)},
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:type) do
    %{
      name: "browser_type",
      label: "Browser Type",
      description: "Type or fill text into a selector in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{"type" => "string", "description" => "CSS selector to type into."},
          "text" => %{"type" => "string", "description" => "Text to enter."},
          "clear" => %{"type" => "boolean", "description" => "Clear the field first."},
          "useFill" => %{
            "type" => "boolean",
            "description" => "Use Playwright fill instead of type."
          },
          "delayMs" => %{"type" => "integer", "description" => "Delay between keystrokes."},
          "timeoutMs" => timeout_schema()
        },
        "required" => ["selector", "text"]
      },
      normalize: fn params ->
        with {:ok, selector} <- required_string(params, ["selector"]),
             {:ok, text} <- required_string(params, ["text"], allow_empty: true) do
          {:ok,
           %{
             method: "browser.type",
             args:
               params
               |> copy_optional(["clear", "useFill", "delayMs"])
               |> Map.merge(%{
                 "selector" => selector,
                 "text" => text,
                 "timeoutMs" => timeout_ms(params)
               }),
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:hover) do
    %{
      name: "browser_hover",
      label: "Browser Hover",
      description: "Hover over an element in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{"type" => "string", "description" => "CSS selector to hover."},
          "timeoutMs" => timeout_schema()
        },
        "required" => ["selector"]
      },
      normalize: fn params ->
        with {:ok, selector} <- required_string(params, ["selector"]) do
          {:ok,
           %{
             method: "browser.hover",
             args: %{"selector" => selector, "timeoutMs" => timeout_ms(params)},
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:select_option) do
    %{
      name: "browser_select_option",
      label: "Browser Select Option",
      description:
        "Select one or more values in a select element in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "CSS selector for the select element."
          },
          "value" => %{"type" => "string", "description" => "Single option value to select."},
          "values" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Multiple option values to select."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => ["selector"]
      },
      normalize: fn params ->
        with {:ok, selector} <- required_string(params, ["selector"]),
             {:ok, values} <- select_option_values(params) do
          {:ok,
           %{
             method: "browser.selectOption",
             args:
               %{"selector" => selector, "timeoutMs" => timeout_ms(params)}
               |> Map.merge(select_option_args(values)),
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:upload_file) do
    %{
      name: "browser_upload_file",
      label: "Browser Upload File",
      description:
        "Attach one or more project-local files to a file input in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "CSS selector for the file input element."
          },
          "path" => %{
            "type" => "string",
            "description" => "Project-local file path to upload."
          },
          "paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Project-local file paths to upload."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => ["selector"]
      },
      normalize: fn params ->
        with {:ok, selector} <- required_string(params, ["selector"]),
             {:ok, paths} <- upload_file_paths(params) do
          {:ok,
           %{
             method: "browser.setInputFiles",
             args:
               %{"selector" => selector, "timeoutMs" => timeout_ms(params)}
               |> Map.merge(upload_file_args(paths)),
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:download) do
    %{
      name: "browser_download",
      label: "Browser Download",
      description:
        "Wait for a browser download, optionally after clicking a selector, and save it as a managed project artifact.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "Optional CSS selector to click before waiting for the download."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Optional project-local output path. If omitted, the download is saved under .lemon/browser-artifacts/."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok,
         %{
           method: "browser.download",
           args:
             params
             |> copy_optional(["selector", "path"])
             |> Map.put("timeoutMs", timeout_ms(params)),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:press) do
    %{
      name: "browser_press",
      label: "Browser Press",
      description: "Press a keyboard key, optionally scoped to a selector.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "key" => %{"type" => "string", "description" => "Playwright key name, such as Enter."},
          "selector" => %{"type" => "string", "description" => "Optional selector."},
          "timeoutMs" => timeout_schema()
        },
        "required" => ["key"]
      },
      normalize: fn params ->
        with {:ok, key} <- required_string(params, ["key"]) do
          {:ok,
           %{
             method: "browser.press",
             args:
               params
               |> copy_optional(["selector"])
               |> Map.merge(%{"key" => key, "timeoutMs" => timeout_ms(params)}),
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:scroll) do
    %{
      name: "browser_scroll",
      label: "Browser Scroll",
      description: "Scroll the page, scroll to coordinates, or bring a selector into view.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{
            "type" => "string",
            "description" => "Optional selector to scroll into view."
          },
          "x" => %{"type" => "number", "description" => "Horizontal scroll amount or target."},
          "y" => %{"type" => "number", "description" => "Vertical scroll amount or target."},
          "deltaX" => %{"type" => "number", "description" => "Horizontal scroll delta."},
          "deltaY" => %{"type" => "number", "description" => "Vertical scroll delta."},
          "absolute" => %{
            "type" => "boolean",
            "description" => "Treat x/y as absolute coordinates."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok,
         %{
           method: "browser.scroll",
           args:
             params
             |> copy_optional(["selector", "x", "y", "deltaX", "deltaY", "absolute"])
             |> Map.put("timeoutMs", timeout_ms(params)),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:back) do
    %{
      name: "browser_back",
      label: "Browser Back",
      description: "Go back in the supervised local browser session history.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok, %{method: "browser.back", args: %{}, timeout_ms: timeout_ms(params)}}
      end
    }
  end

  def spec(:wait_for_selector) do
    %{
      name: "browser_wait_for_selector",
      label: "Browser Wait For Selector",
      description: "Wait until a selector appears in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "selector" => %{"type" => "string", "description" => "CSS selector to wait for."},
          "timeoutMs" => timeout_schema()
        },
        "required" => ["selector"]
      },
      normalize: fn params ->
        with {:ok, selector} <- required_string(params, ["selector"]) do
          {:ok,
           %{
             method: "browser.waitForSelector",
             args: %{"selector" => selector, "timeoutMs" => timeout_ms(params)},
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:evaluate) do
    %{
      name: "browser_evaluate",
      label: "Browser Evaluate",
      description:
        "Evaluate a JavaScript expression in the current page context and return untrusted JSON-serializable output.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "expression" => %{
            "type" => "string",
            "description" => "JavaScript expression to evaluate in the current page."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => ["expression"]
      },
      normalize: fn params ->
        with {:ok, expression} <- required_string(params, ["expression"]) do
          {:ok,
           %{
             method: "browser.evaluate",
             args: %{"expression" => expression},
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  def spec(:events) do
    %{
      name: "browser_events",
      label: "Browser Events",
      description:
        "Return buffered console, dialog, page error, and request failure events from the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{"type" => "integer", "description" => "Maximum events to return."},
          "clear" => %{
            "type" => "boolean",
            "description" => "Clear buffered events after reading."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok,
         %{
           method: "browser.events",
           args: copy_optional(params, ["limit", "clear"]),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:get_cookies) do
    %{
      name: "browser_get_cookies",
      label: "Browser Get Cookies",
      description: "Return cookies from the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "Optional URL to scope returned cookies."
          },
          "includeValues" => %{
            "type" => "boolean",
            "description" => "Include raw cookie values. Defaults to false."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok,
         %{
           method: "browser.getCookies",
           args: copy_optional(params, ["url"]),
           redact_cookie_values: not boolean_value(params, ["includeValues", "include_values"]),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:set_cookies) do
    %{
      name: "browser_set_cookies",
      label: "Browser Set Cookies",
      description: "Set cookies in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "cookies" => %{
            "type" => "array",
            "description" => "Playwright cookie objects to add to the browser context.",
            "items" => %{"type" => "object"}
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => ["cookies"]
      },
      normalize: fn params ->
        case Map.get(params, "cookies") do
          cookies when is_list(cookies) ->
            {:ok,
             %{
               method: "browser.setCookies",
               args: %{"cookies" => cookies},
               timeout_ms: timeout_ms(params)
             }}

          _ ->
            {:error, "cookies is required"}
        end
      end
    }
  end

  def spec(:clear_state) do
    %{
      name: "browser_clear_state",
      label: "Browser Clear State",
      description:
        "Clear browser cookies, page storage, and buffered page events in the supervised local browser session.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "clearCookies" => %{
            "type" => "boolean",
            "description" => "Clear browser-context cookies. Defaults to true."
          },
          "clearStorage" => %{
            "type" => "boolean",
            "description" =>
              "Clear current-page localStorage and sessionStorage. Defaults to true."
          },
          "clearEvents" => %{
            "type" => "boolean",
            "description" => "Clear buffered browser events. Defaults to true."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        {:ok,
         %{
           method: "browser.clearState",
           args: copy_optional(params, ["clearCookies", "clearStorage", "clearEvents"]),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:screenshot) do
    %{
      name: "browser_screenshot",
      label: "Browser Screenshot",
      description:
        "Capture a screenshot from the supervised local browser session and save it as a local artifact.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Optional artifact path."},
          "fullPage" => %{"type" => "boolean", "description" => "Capture the full page."},
          "includeImage" => %{
            "type" => "boolean",
            "description" => "Also return the screenshot as model-visible image content."
          },
          "sendToChannel" => %{
            "type" => "boolean",
            "description" => "Request final Telegram/Discord delivery of the screenshot artifact."
          },
          "type" => %{
            "type" => "string",
            "description" => "Screenshot format.",
            "enum" => @screenshot_types
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        type = screenshot_type(params)

        {:ok,
         %{
           method: "browser.screenshot",
           args:
             params
             |> copy_optional(["fullPage"])
             |> Map.put("type", type),
           path: optional_string(params, ["path"]),
           extension: if(type == "jpeg", do: ".jpg", else: ".png"),
           include_image: boolean_value(params, ["includeImage", "include_image"]),
           send_to_channel: boolean_value(params, ["sendToChannel", "send_to_channel"]),
           timeout_ms: timeout_ms(params)
         }}
      end
    }
  end

  def spec(:analyze) do
    %{
      name: "browser_analyze",
      label: "Browser Analyze",
      description:
        "Capture the current browser page and analyze the screenshot through Lemon's supervised media vision path.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Optional project-local screenshot artifact path."
          },
          "fullPage" => %{"type" => "boolean", "description" => "Capture the full page."},
          "includeImage" => %{
            "type" => "boolean",
            "description" => "Also return the screenshot as model-visible image content."
          },
          "sendToChannel" => %{
            "type" => "boolean",
            "description" => "Request final Telegram/Discord delivery of the analysis artifact."
          },
          "sendScreenshotToChannel" => %{
            "type" => "boolean",
            "description" => "Request final Telegram/Discord delivery of the screenshot artifact."
          },
          "type" => %{
            "type" => "string",
            "description" => "Screenshot format.",
            "enum" => @screenshot_types
          },
          "provider" => %{
            "type" => "string",
            "enum" => ["local_vision", "openai_vision"],
            "description" => "Vision provider used by media_analyze_image."
          },
          "prompt" => %{
            "type" => "string",
            "description" => "Optional analysis instruction. Stored only as redacted metadata."
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional provider model."
          },
          "detail" => %{
            "type" => "string",
            "enum" => ["auto", "low", "high"],
            "description" => "Optional OpenAI image detail setting."
          },
          "filename" => %{
            "type" => "string",
            "description" => "Optional analysis artifact filename."
          },
          "responseFormat" => %{
            "type" => "string",
            "enum" => ["json", "text"],
            "description" => "Analysis artifact format. Defaults to json."
          },
          "maxRetries" => %{
            "type" => "integer",
            "description" => "Maximum transient provider retries for OpenAI vision jobs."
          },
          "timeoutMs" => timeout_schema()
        },
        "required" => []
      },
      normalize: fn params ->
        with {:ok, provider} <- analysis_provider(params) do
          type = screenshot_type(params)

          {:ok,
           %{
             method: "browser.analyze",
             args:
               params
               |> copy_optional(["fullPage"])
               |> Map.put("type", type),
             path: optional_string(params, ["path"]),
             extension: if(type == "jpeg", do: ".jpg", else: ".png"),
             include_image: boolean_value(params, ["includeImage", "include_image"]),
             send_to_channel: boolean_value(params, ["sendToChannel", "send_to_channel"]),
             send_screenshot_to_channel:
               boolean_value(params, ["sendScreenshotToChannel", "send_screenshot_to_channel"]),
             analysis: analysis_request(params, provider),
             timeout_ms: timeout_ms(params)
           }}
        end
      end
    }
  end

  defp analysis_provider(params) do
    case optional_string(params, ["provider"]) || "local_vision" do
      provider when provider in ["local_vision", "openai_vision"] -> {:ok, provider}
      provider -> {:error, "unsupported browser analysis provider: #{provider}"}
    end
  end

  defp analysis_request(params, provider) do
    %{
      provider: provider,
      prompt: optional_string(params, ["prompt"]),
      model: optional_string(params, ["model"]),
      detail: optional_string(params, ["detail"]),
      filename: optional_string(params, ["filename"]),
      response_format: optional_string(params, ["responseFormat", "response_format"]),
      max_retries: value_for(params, ["maxRetries", "max_retries"])
    }
  end

  defp validate_project_relative_artifact(nil, _cwd), do: :ok

  defp validate_project_relative_artifact(path, cwd) do
    cwd = Path.expand(cwd)

    resolved =
      if Path.type(path) == :absolute, do: Path.expand(path), else: Path.expand(path, cwd)

    if resolved == cwd or String.starts_with?(resolved, cwd <> "/") do
      :ok
    else
      {:error, "path must be under the current project for browser_analyze"}
    end
  end

  defp validate_upload_file_paths(args, cwd) do
    with {:ok, paths} <- upload_file_paths(args) do
      paths
      |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
        case validate_upload_file_path(path, cwd) do
          {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        error -> error
      end
    end
  end

  defp validate_upload_file_path(path, cwd) do
    cwd = Path.expand(cwd)
    resolved = PathHelpers.resolve_path(path, cwd)

    cond do
      not project_relative_path?(resolved, cwd) ->
        {:error, "browser_upload_file path must be under the current project"}

      not File.regular?(resolved) ->
        {:error, "browser_upload_file path must be an existing file"}

      true ->
        {:ok, resolved}
    end
  end

  defp validate_download_output_args(args, cwd, runtime) do
    case Map.get(args, "path") do
      path when is_binary(path) ->
        if String.trim(path) == "" do
          validate_default_download_dir(args, cwd, runtime)
        else
          with {:ok, resolved} <- validate_download_output_path(path, cwd) do
            {:ok, Map.put(args, "path", resolved)}
          end
        end

      _ ->
        validate_default_download_dir(args, cwd, runtime)
    end
  end

  defp validate_default_download_dir(args, cwd, runtime) do
    dir = default_artifact_dir(cwd, runtime)

    if project_relative_path?(dir, cwd) do
      {:ok, Map.put(args, "dir", dir)}
    else
      {:error, "browser_download output path must be under the current project"}
    end
  end

  defp validate_download_output_path(path, cwd) do
    cwd = Path.expand(cwd)
    resolved = PathHelpers.resolve_path(path, cwd)

    cond do
      not project_relative_path?(resolved, cwd) ->
        {:error, "browser_download output path must be under the current project"}

      File.dir?(resolved) ->
        {:error, "browser_download output path must be a file path"}

      true ->
        {:ok, resolved}
    end
  end

  defp project_relative_path?(path, cwd) do
    resolved = Path.expand(path)
    cwd = Path.expand(cwd)
    resolved == cwd or String.starts_with?(resolved, cwd <> "/")
  end

  defp capture_analysis_screenshot(request, signal, cwd, runtime) do
    screenshot_request =
      request
      |> Map.put(:method, "browser.screenshot")
      |> Map.put(:send_to_channel, request.send_screenshot_to_channel)

    with :ok <- check_abort(signal),
         {:ok, result} <-
           runtime.browser_request.(
             screenshot_request.method,
             screenshot_request.args,
             screenshot_request.timeout_ms
           ),
         :ok <- check_abort(signal) do
      screenshot =
        result
        |> maybe_write_screenshot(screenshot_request, cwd, runtime)

      case screenshot do
        %{"path" => path} when is_binary(path) -> {:ok, screenshot}
        %{"artifactError" => reason} -> {:error, "browser screenshot artifact failed: #{reason}"}
        _ -> {:error, "browser screenshot did not produce an artifact"}
      end
    end
  end

  defp analyze_screenshot(screenshot, request, signal, cwd, runtime) do
    media_params =
      request.analysis
      |> Map.take([
        :provider,
        :prompt,
        :model,
        :detail,
        :filename,
        :response_format,
        :max_retries
      ])
      |> Enum.reduce(%{"imagePath" => screenshot["path"]}, fn
        {:provider, value}, acc -> Map.put(acc, "provider", value)
        {:prompt, value}, acc -> put_present(acc, "prompt", value)
        {:model, value}, acc -> put_present(acc, "model", value)
        {:detail, value}, acc -> put_present(acc, "detail", value)
        {:filename, value}, acc -> put_present(acc, "filename", value)
        {:response_format, value}, acc -> put_present(acc, "responseFormat", value)
        {:max_retries, value}, acc -> put_present(acc, "maxRetries", value)
      end)
      |> Map.put("sendToChannel", request.send_to_channel)
      |> Map.put_new("prompt", "Summarize the current browser screenshot.")

    tool = LemonSkills.Tools.MediaAnalyzeImage.tool(cwd, Map.get(runtime, :tool_opts, []))

    case tool.execute.("browser-analyze", media_params, signal, nil) do
      %AgentToolResult{} = result -> {:ok, result.details}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_present(acc, _key, nil), do: acc
  defp put_present(acc, _key, ""), do: acc
  defp put_present(acc, key, value), do: Map.put(acc, key, value)

  defp browser_analysis_result(screenshot, analysis, request) do
    result =
      %{
        "status" => "completed",
        "provider" => analysis["provider"],
        "model" => analysis["model"],
        "text" => analysis["text"],
        "screenshot" => screenshot_summary(screenshot),
        "analysis" => analysis,
        "trustMetadata" => browser_analysis_trust_metadata(:camel_case),
        "trust_metadata" => browser_analysis_trust_metadata(:snake_case)
      }

    case {request.include_image, Map.get(screenshot, "__image_content")} do
      {true, %ImageContent{} = image} -> Map.put(result, "__image_content", image)
      _ -> result
    end
  end

  defp screenshot_summary(screenshot) do
    screenshot
    |> Map.take([
      "path",
      "bytes",
      "contentType",
      "content_type",
      "imageIncluded",
      "auto_send_files"
    ])
    |> Map.put_new("imageIncluded", false)
  end

  defp browser_analysis_trust_metadata(key_style) do
    ExternalContent.trust_metadata(:web_fetch,
      key_style: key_style,
      warning_included: false,
      wrapped_fields: ["text", "analysis.text"]
    )
  end

  defp maybe_write_screenshot(
         %{"base64" => encoded} = result,
         %{
           path: path,
           extension: ext,
           include_image: include_image,
           send_to_channel: send_to_channel
         },
         cwd,
         runtime
       )
       when is_binary(encoded) do
    artifact_path = resolve_artifact_path(path, ext, cwd, runtime)

    with {:ok, bytes} <- Base.decode64(encoded),
         :ok <- File.mkdir_p(Path.dirname(artifact_path)),
         :ok <- File.write(artifact_path, bytes) do
      _ = cleanup_artifacts(cwd, runtime)

      result
      |> Map.drop(["base64"])
      |> Map.put("path", artifact_path)
      |> Map.put("bytes", byte_size(bytes))
      |> maybe_add_screenshot_image(encoded, include_image)
      |> maybe_add_screenshot_auto_send(artifact_path, send_to_channel)
    else
      {:error, reason} ->
        Map.drop(result, ["base64"])
        |> Map.put("artifactError", inspect(reason))
    end
  end

  defp maybe_write_screenshot(result, _request, _cwd, _runtime), do: result

  defp cleanup_artifacts(cwd, %{artifacts_dir: nil}) do
    Artifacts.cleanup(project_dir: cwd)
  catch
    _, _ -> :ok
  end

  defp cleanup_artifacts(_cwd, %{artifacts_dir: dir}) do
    Artifacts.cleanup(dir: dir)
  catch
    _, _ -> :ok
  end

  defp wrap_result(result, tool_name) when is_map(result) do
    payload =
      result
      |> Map.drop(["__image_content"])
      |> Map.put_new("tool", tool_name)
      |> Map.put_new("trustMetadata", browser_trust_metadata(:camel_case))
      |> Map.put_new("trust_metadata", browser_trust_metadata(:snake_case))

    case Map.get(result, "__image_content") do
      %ImageContent{} = image ->
        %AgentToolResult{
          content: [
            %TextContent{text: Jason.encode!(payload)},
            image
          ],
          details: payload,
          trust: :untrusted
        }

      _ ->
        ExternalContent.untrusted_json_result(payload)
    end
  end

  defp wrap_result(result, _tool_name) do
    %AgentToolResult{
      content: [%TextContent{text: Jason.encode!(%{"result" => result})}],
      details: result,
      trust: :untrusted
    }
  end

  defp browser_trust_metadata(key_style) do
    ExternalContent.trust_metadata(:web_fetch,
      key_style: key_style,
      warning_included: false,
      wrapped_fields: []
    )
  end

  defp emit_browser_update(on_update, tool_name, request, phase, result \\ %{})

  defp emit_browser_update(nil, _tool_name, _request, _phase, _result), do: :ok

  defp emit_browser_update(on_update, tool_name, request, phase, result)
       when is_function(on_update, 1) do
    details = browser_progress_details(tool_name, request, phase, result)

    _ =
      on_update.(%AgentToolResult{
        content: [%TextContent{text: Jason.encode!(details)}],
        details: details,
        trust: :trusted
      })

    :ok
  rescue
    _ -> :ok
  end

  defp emit_browser_update(_on_update, _tool_name, _request, _phase, _result), do: :ok

  defp browser_progress_details(tool_name, request, phase, result) do
    current_action = %{
      "title" => browser_progress_title(request.method, phase),
      "kind" => "browser",
      "phase" => phase
    }

    %{
      "tool" => tool_name,
      "method" => request.method,
      "phase" => phase,
      "timeoutMs" => request.timeout_ms,
      "current_action" => current_action,
      "browser" => browser_progress_request_summary(request),
      "result" => browser_progress_result_summary(result)
    }
  end

  defp browser_progress_title(method, "started"), do: "Browser #{browser_method_label(method)}"
  defp browser_progress_title(method, "completed"), do: "Browser #{browser_method_label(method)}"

  defp browser_progress_title(method, "failed"),
    do: "Browser #{browser_method_label(method)} failed"

  defp browser_progress_title(method, _phase), do: "Browser #{browser_method_label(method)}"

  defp browser_method_label(method) do
    method
    |> to_string()
    |> String.replace_prefix("browser.", "")
    |> Macro.underscore()
    |> String.replace("_", " ")
  end

  defp browser_progress_request_summary(%{
         method: "browser.navigate",
         args: %{"url" => url},
         network_policy: network_policy
       }) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(host) ->
        RoutePolicy.safe(network_policy)
        |> Map.put("scheme", scheme)
        |> Map.put("hostHash", hash_value(host))

      %URI{scheme: scheme} when is_binary(scheme) ->
        network_policy
        |> RoutePolicy.safe()
        |> Map.put("scheme", scheme)

      _ ->
        RoutePolicy.safe(network_policy)
    end
  end

  defp browser_progress_request_summary(%{method: "browser.navigate", args: %{"url" => url}}) do
    case RoutePolicy.validate_navigation(url) do
      {:ok, policy} -> RoutePolicy.safe(policy)
      _ -> %{}
    end
  end

  defp browser_progress_request_summary(%{method: method, args: args}) do
    %{
      "argumentKeys" =>
        args
        |> Map.keys()
        |> Enum.reject(
          &(&1 in [
              "text",
              "selector",
              "cookies",
              "url",
              "expression",
              "script",
              "path",
              "paths",
              "dir"
            ])
        )
        |> Enum.sort(),
      "sensitiveArgumentCount" => sensitive_browser_arg_count(method, args)
    }
  end

  defp browser_progress_result_summary(%{"screenshot" => screenshot, "analysis" => analysis}) do
    %{
      "bytes" => screenshot["bytes"],
      "artifactWritten" => Map.has_key?(screenshot, "path"),
      "imageIncluded" => screenshot["imageIncluded"] == true,
      "autoSendFileCount" => screenshot["auto_send_files"] |> List.wrap() |> length(),
      "analysisProvider" => analysis["provider"],
      "analysisArtifactWritten" => is_map(analysis["artifact"]),
      "analysisBytes" => get_in(analysis, ["artifact", "bytes"])
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, false, 0] end)
    |> Map.new()
  end

  defp browser_progress_result_summary(result) when is_map(result) do
    %{
      "contentType" => result["contentType"] || result["content_type"],
      "bytes" => result["bytes"] || result["byteSize"] || result["byte_size"],
      "artifactWritten" => Map.has_key?(result, "path"),
      "imageIncluded" => result["imageIncluded"] == true,
      "autoSendFileCount" => result["auto_send_files"] |> List.wrap() |> length(),
      "eventCount" => result["count"] || list_count(result["events"]),
      "cookieCount" => list_count(result["cookies"]),
      "errorKind" => result["errorKind"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, false, 0] end)
    |> Map.new()
  end

  defp browser_progress_result_summary(_result), do: %{}

  defp maybe_add_navigation_policy(result, %{
         method: "browser.navigate",
         network_policy: network_policy
       })
       when is_map(result) do
    Map.put(result, "networkPolicy", RoutePolicy.safe(network_policy))
  end

  defp maybe_add_navigation_policy(result, _request), do: result

  defp sensitive_browser_arg_count(_method, args) when is_map(args) do
    Enum.count(args, fn {key, value} ->
      key in [
        "text",
        "selector",
        "cookies",
        "url",
        "expression",
        "script",
        "value",
        "values",
        "path",
        "paths",
        "dir"
      ] and
        not blank_value?(value)
    end)
  end

  defp sensitive_browser_arg_count(_method, _args), do: 0

  defp safe_error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_error_kind(reason) when is_binary(reason) do
    lowered = String.downcase(reason)

    cond do
      String.contains?(lowered, "timeout") -> "timeout"
      String.contains?(lowered, "selector") -> "selector_error"
      String.contains?(lowered, "navigation") -> "navigation_error"
      String.contains?(lowered, "connection") -> "connection_error"
      true -> "browser_error"
    end
  end

  defp safe_error_kind(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp safe_error_kind(_reason), do: "browser_error"

  defp list_count(value) when is_list(value), do: length(value)
  defp list_count(_value), do: nil

  defp blank_value?(value), do: value in [nil, "", []]

  defp hash_value(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp required_string(params, keys, opts \\ []) do
    allow_empty = Keyword.get(opts, :allow_empty, false)

    case optional_string(params, keys) do
      nil when allow_empty -> {:ok, ""}
      nil -> {:error, "#{List.first(keys)} is required"}
      value -> {:ok, value}
    end
  end

  defp optional_string(params, keys) do
    keys
    |> Enum.find_value(fn key ->
      value = Map.get(params, key) || Map.get(params, Macro.underscore(key))

      case value do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: nil, else: trimmed

        value when is_integer(value) or is_float(value) or is_boolean(value) ->
          to_string(value)

        _ ->
          nil
      end
    end)
  end

  defp select_option_values(params) do
    cond do
      is_list(Map.get(params, "values")) ->
        values =
          params
          |> Map.get("values")
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if values == [], do: {:error, "value or values is required"}, else: {:ok, values}

      value = optional_string(params, ["value"]) ->
        {:ok, [value]}

      true ->
        {:error, "value or values is required"}
    end
  end

  defp select_option_args([value]), do: %{"value" => value}
  defp select_option_args(values), do: %{"values" => values}

  defp upload_file_paths(params) do
    cond do
      is_list(Map.get(params, "paths")) ->
        paths =
          params
          |> Map.get("paths")
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if paths == [], do: {:error, "path or paths is required"}, else: {:ok, paths}

      path = optional_string(params, ["path"]) ->
        {:ok, [path]}

      true ->
        {:error, "path or paths is required"}
    end
  end

  defp upload_file_args([path]), do: %{"path" => path}
  defp upload_file_args(paths), do: %{"paths" => paths}

  defp copy_optional(params, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      snake = Macro.underscore(key)

      cond do
        Map.has_key?(params, key) ->
          Map.put(acc, key, Map.get(params, key))

        Map.has_key?(params, snake) ->
          Map.put(acc, key, Map.get(params, snake))

        true ->
          acc
      end
    end)
  end

  defp timeout_ms(params) do
    params
    |> value_for(["timeoutMs", "timeout_ms"])
    |> normalize_timeout()
  end

  defp screenshot_type(params) do
    params
    |> optional_string(["type"])
    |> case do
      type when type in @screenshot_types -> type
      _ -> "png"
    end
  end

  defp value_for(params, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(params, key), do: Map.get(params, key)
    end)
  end

  defp boolean_value(params, keys) do
    case value_for(params, keys) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ["true", "1", "yes"]
      _ -> false
    end
  end

  defp normalize_timeout(value) do
    value
    |> normalize_int(@default_timeout_ms)
    |> max(1)
    |> min(@max_timeout_ms)
  end

  defp normalize_int(value, _fallback) when is_integer(value), do: value

  defp normalize_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> fallback
    end
  end

  defp normalize_int(_value, fallback), do: fallback

  defp resolve_artifact_path(nil, ext, cwd, runtime) do
    dir = default_artifact_dir(cwd, runtime)

    timestamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9A-Za-z]/, "")

    Path.join(dir, "#{timestamp}-screenshot#{ext}")
  end

  defp resolve_artifact_path(path, _ext, cwd, _runtime) do
    expanded =
      if Path.type(path) == :absolute do
        path
      else
        Path.expand(path, cwd)
      end

    expanded
  end

  defp default_artifact_dir(cwd, runtime) do
    runtime.artifacts_dir ||
      Path.join([cwd, ".lemon", "browser-artifacts"])
  end

  defp maybe_add_screenshot_image(result, _encoded, false) do
    Map.put(result, "imageIncluded", false)
  end

  defp maybe_add_screenshot_image(result, encoded, true) do
    content_type = screenshot_content_type(result)

    result
    |> Map.put("imageIncluded", true)
    |> Map.put("__image_content", %ImageContent{data: encoded, mime_type: content_type})
  end

  defp screenshot_content_type(%{"contentType" => content_type})
       when content_type in ["image/png", "image/jpeg"],
       do: content_type

  defp screenshot_content_type(%{"content_type" => content_type})
       when content_type in ["image/png", "image/jpeg"],
       do: content_type

  defp screenshot_content_type(_result), do: "image/png"

  defp maybe_add_screenshot_auto_send(result, _artifact_path, false), do: result

  defp maybe_add_screenshot_auto_send(result, artifact_path, true) do
    Map.put(result, "auto_send_files", [
      %{
        "path" => artifact_path,
        "filename" => Path.basename(artifact_path),
        "caption" => "browser screenshot",
        "source" => "explicit"
      }
    ])
  end

  defp timeout_schema do
    %{"type" => "integer", "description" => "Request timeout in milliseconds."}
  end
end

defmodule CodingAgent.Tools.BrowserNavigate do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:navigate))
end

defmodule CodingAgent.Tools.BrowserSnapshot do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:snapshot))
end

defmodule CodingAgent.Tools.BrowserGetContent do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:get_content))
end

defmodule CodingAgent.Tools.BrowserClick do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:click))
end

defmodule CodingAgent.Tools.BrowserType do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:type))
end

defmodule CodingAgent.Tools.BrowserHover do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:hover))
end

defmodule CodingAgent.Tools.BrowserSelectOption do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:select_option))
end

defmodule CodingAgent.Tools.BrowserUploadFile do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:upload_file))
end

defmodule CodingAgent.Tools.BrowserDownload do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:download))
end

defmodule CodingAgent.Tools.BrowserPress do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:press))
end

defmodule CodingAgent.Tools.BrowserScroll do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:scroll))
end

defmodule CodingAgent.Tools.BrowserBack do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:back))
end

defmodule CodingAgent.Tools.BrowserWaitForSelector do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do:
      CodingAgent.Tools.Browser.tool(
        cwd,
        opts,
        CodingAgent.Tools.Browser.spec(:wait_for_selector)
      )
end

defmodule CodingAgent.Tools.BrowserEvaluate do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:evaluate))
end

defmodule CodingAgent.Tools.BrowserEvents do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:events))
end

defmodule CodingAgent.Tools.BrowserGetCookies do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:get_cookies))
end

defmodule CodingAgent.Tools.BrowserSetCookies do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:set_cookies))
end

defmodule CodingAgent.Tools.BrowserClearState do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:clear_state))
end

defmodule CodingAgent.Tools.BrowserScreenshot do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:screenshot))
end

defmodule CodingAgent.Tools.BrowserAnalyze do
  @moduledoc false
  def tool(cwd, opts \\ []),
    do: CodingAgent.Tools.Browser.tool(cwd, opts, CodingAgent.Tools.Browser.spec(:analyze))
end
