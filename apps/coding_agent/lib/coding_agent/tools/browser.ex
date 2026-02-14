defmodule CodingAgent.Tools.Browser do
  @moduledoc """
  Browser tool for the coding agent (local browser mode).

  Uses LemonCore.Browser.LocalServer which spawns a local Node + Playwright driver.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @default_timeout_ms 30_000
  @default_max_chars 50_000
  @default_screenshot_dir ".lemon/browser/screenshots"

  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) when is_binary(cwd) do
    server = Keyword.get(opts, :browser_server, LemonCore.Browser.LocalServer)

    %AgentTool{
      name: "browser",
      description:
        "Control a local Chrome/Chromium browser (persistent profile) for navigation, screenshots, and DOM actions.",
      label: "Browser",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "method" => %{
            "type" => "string",
            "description" =>
              "Browser method: navigate, screenshot, click, type, evaluate, waitForSelector, getContent, getCookies, setCookies. " <>
                "Examples: navigate args={url}, click args={selector}, type args={selector,text,clear?,useFill?}, screenshot args={fullPage?}."
          },
          "args" => %{
            "type" => "object",
            "description" => "Method arguments (shape depends on method)."
          },
          "timeoutMs" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default: 30000)."
          }
        },
        "required" => ["method"]
      },
      execute: fn tool_call_id, params, signal, on_update ->
        execute(tool_call_id, params, signal, on_update, cwd, server)
      end
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t(),
          module()
        ) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update, cwd, server) do
    with {:ok, method} <- read_required_string(params, "method"),
         {:ok, args} <- read_optional_map(params, "args"),
         timeout_ms <- read_timeout_ms(params) do
      full = if String.starts_with?(method, "browser."), do: method, else: "browser.#{method}"

      case server.request(full, args, timeout_ms) do
        {:ok, result} ->
          handle_ok_result(cwd, full, args, result)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_ok_result(cwd, "browser.screenshot", args, %{} = result) do
    case materialize_screenshot(cwd, args, result) do
      {:ok, out} -> json_result(%{"ok" => true, "result" => out.result}, details: out.details)
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_ok_result(_cwd, "browser.getContent", args, %{"html" => html} = result)
       when is_binary(html) do
    max_chars =
      case Map.get(args, "maxChars") || Map.get(args, :maxChars) do
        n when is_integer(n) and n > 0 -> n
        _ -> @default_max_chars
      end

    {final_html, truncated?} = maybe_truncate(html, max_chars)

    json_result(%{
      "ok" => true,
      "result" =>
        result
        |> Map.put("html", final_html)
        |> maybe_put("truncated", truncated?)
        |> maybe_put("originalChars", String.length(html))
    })
  end

  defp handle_ok_result(_cwd, _method, _args, result) do
    json_result(%{"ok" => true, "result" => result})
  end

  defp read_timeout_ms(params) do
    case Map.get(params, "timeoutMs") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_timeout_ms
    end
  end

  defp read_required_string(params, key) do
    value = Map.get(params, key)

    if is_binary(value) do
      trimmed = String.trim(value)

      if byte_size(trimmed) > 0 do
        {:ok, trimmed}
      else
        {:error, "#{key} is required"}
      end
    else
      {:error, "#{key} is required"}
    end
  end

  defp read_optional_map(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "#{key} must be an object"}
    end
  end

  defp json_result(payload, opts \\ []) do
    text = Jason.encode!(payload, pretty: true)
    details = Keyword.get(opts, :details)

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: details || payload
    }
  end

  defp materialize_screenshot(cwd, args, %{} = result) do
    b64 = Map.get(result, "base64")

    content_type =
      Map.get(result, "contentType") || Map.get(result, "content_type") || "image/png"

    with b64 when is_binary(b64) and b64 != "" <- b64,
         {:ok, bin} <- Base.decode64(b64),
         {:ok, rel_path} <- write_screenshot_file(cwd, content_type, bin),
         caption <- screenshot_caption(args) do
      out_result = %{
        "contentType" => content_type,
        "path" => rel_path,
        "bytes" => byte_size(bin)
      }

      details = %{
        auto_send_files: [
          %{
            path: rel_path,
            filename: Path.basename(rel_path),
            caption: caption
          }
        ],
        screenshot: out_result
      }

      {:ok, %{result: out_result, details: details}}
    else
      nil -> {:error, "screenshot returned no base64 data"}
      "" -> {:error, "screenshot returned no base64 data"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
      _ -> {:error, "screenshot returned invalid base64 data"}
    end
  end

  defp write_screenshot_file(cwd, content_type, bin) when is_binary(cwd) and is_binary(bin) do
    ext = screenshot_ext(content_type)
    dir = Path.join(cwd, @default_screenshot_dir)
    _ = File.mkdir_p!(dir)

    filename = "screenshot-#{System.system_time(:millisecond)}-#{LemonCore.Id.uuid()}#{ext}"
    abs_path = Path.join(dir, filename)

    case File.write(abs_path, bin) do
      :ok -> {:ok, Path.relative_to(abs_path, cwd)}
      {:error, reason} -> {:error, "Failed to write screenshot: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Failed to write screenshot: #{Exception.message(e)}"}
  end

  defp screenshot_ext(content_type) when is_binary(content_type) do
    ct = content_type |> String.downcase() |> String.trim()
    if ct == "image/jpeg" or ct == "image/jpg", do: ".jpg", else: ".png"
  end

  defp screenshot_caption(args) when is_map(args) do
    url =
      case Map.get(args, "url") || Map.get(args, :url) do
        u when is_binary(u) and u != "" -> u
        _ -> nil
      end

    if url, do: "Browser screenshot (#{url})", else: "Browser screenshot"
  end

  defp screenshot_caption(_), do: "Browser screenshot"

  defp maybe_truncate(text, max_chars) when is_binary(text) and is_integer(max_chars) do
    if max_chars > 0 and String.length(text) > max_chars do
      {String.slice(text, 0, max_chars) <> "...", true}
    else
      {text, false}
    end
  end

  defp maybe_put(map, _key, false) when is_map(map), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
end
