defmodule CodingAgent.Tools.Browser do
  @moduledoc """
  Browser tool for the coding agent (local browser mode).

  Uses LemonCore.Browser.LocalServer which spawns a local Node + Playwright driver.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Security.ExternalContent

  @default_timeout_ms 30_000
  @default_max_chars 20_000
  @default_snapshot_max_chars 12_000
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
              "Browser method: navigate, snapshot, screenshot, click, type, evaluate, waitForSelector, getContent, getCookies, setCookies. " <>
                "Prefer snapshot for page understanding (compact text). Use getContent only when raw HTML is required. " <>
                "Examples: navigate args={url}, snapshot args={maxChars?,maxNodes?,interactiveOnly?}, click args={selector}, type args={selector,text,clear?,useFill?}, screenshot args={fullPage?}."
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
      {:ok, out} ->
        json_result(
          %{"ok" => true, "result" => out.result},
          details: out.details,
          wrapped_fields: ["result"]
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_ok_result(_cwd, "browser.getContent", args, %{"html" => html} = result)
       when is_binary(html) do
    max_chars = read_positive_int(args, ["maxChars", :maxChars], @default_max_chars)

    text_max_chars =
      read_positive_int(
        args,
        ["textMaxChars", :textMaxChars],
        min(max_chars, @default_snapshot_max_chars)
      )

    {final_result, wrapped_fields} =
      normalize_get_content_result(result, max_chars, text_max_chars)

    json_result(
      %{
        "ok" => true,
        "result" => final_result
      },
      wrapped_fields: wrapped_fields
    )
  end

  defp handle_ok_result(_cwd, "browser.getContent", args, %{} = result) do
    max_chars = read_positive_int(args, ["maxChars", :maxChars], @default_max_chars)

    text_max_chars =
      read_positive_int(
        args,
        ["textMaxChars", :textMaxChars],
        min(max_chars, @default_snapshot_max_chars)
      )

    {final_result, wrapped_fields} =
      normalize_get_content_result(result, max_chars, text_max_chars)

    json_result(
      %{
        "ok" => true,
        "result" => final_result
      },
      wrapped_fields: wrapped_fields
    )
  end

  defp handle_ok_result(_cwd, "browser.snapshot", args, %{"snapshot" => snapshot} = result)
       when is_binary(snapshot) do
    max_chars = read_positive_int(args, ["maxChars", :maxChars], @default_snapshot_max_chars)
    original_chars = read_result_original_chars(result, snapshot, "originalChars")
    existing_truncated = Map.get(result, "truncated") == true
    {final_snapshot, truncated_now?} = maybe_truncate(snapshot, max_chars)

    final_result =
      result
      |> Map.put("snapshot", final_snapshot)
      |> Map.put("originalChars", original_chars)
      |> maybe_put("truncated", existing_truncated or truncated_now?)

    json_result(
      %{
        "ok" => true,
        "result" => final_result
      },
      wrapped_fields: ["result.snapshot"]
    )
  end

  defp handle_ok_result(_cwd, _method, _args, result) do
    json_result(%{"ok" => true, "result" => result}, wrapped_fields: ["result"])
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

  defp json_result(payload, opts) when is_map(payload) do
    payload = put_trust_metadata(payload, Keyword.get(opts, :wrapped_fields, ["result"]))
    result = ExternalContent.untrusted_json_result(payload)

    case Keyword.fetch(opts, :details) do
      {:ok, details} -> %{result | details: details}
      :error -> result
    end
  end

  defp put_trust_metadata(payload, wrapped_fields) when is_map(payload) do
    trust_metadata_camel =
      ExternalContent.trust_metadata(:browser,
        key_style: :camel_case,
        warning_included: false,
        wrapped_fields: wrapped_fields
      )

    trust_metadata_snake =
      ExternalContent.trust_metadata(:browser,
        warning_included: false,
        wrapped_fields: wrapped_fields
      )

    payload
    |> Map.put_new("trustMetadata", trust_metadata_camel)
    |> Map.put_new("trust_metadata", trust_metadata_snake)
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

  defp normalize_get_content_result(result, max_chars, text_max_chars) do
    {result, wrapped_fields} = normalize_get_content_html(result, max_chars, [])
    {result, wrapped_fields} = normalize_get_content_text(result, text_max_chars, wrapped_fields)

    wrapped_fields =
      case wrapped_fields do
        [] -> ["result"]
        fields -> Enum.reverse(fields) |> Enum.map(&"result.#{&1}")
      end

    {result, wrapped_fields}
  end

  defp normalize_get_content_html(result, max_chars, wrapped_fields) do
    case Map.get(result, "html") do
      html when is_binary(html) ->
        existing_truncated = Map.get(result, "truncated") == true
        original_chars = read_result_original_chars(result, html, "originalChars")
        {final_html, truncated_now?} = maybe_truncate(html, max_chars)

        result =
          result
          |> Map.put("html", final_html)
          |> Map.put("originalChars", original_chars)
          |> maybe_put("truncated", existing_truncated or truncated_now?)

        {result, ["html" | wrapped_fields]}

      _ ->
        {result, wrapped_fields}
    end
  end

  defp normalize_get_content_text(result, text_max_chars, wrapped_fields) do
    case Map.get(result, "text") do
      text when is_binary(text) ->
        existing_truncated = Map.get(result, "textTruncated") == true
        original_chars = read_result_original_chars(result, text, "originalTextChars")
        {final_text, truncated_now?} = maybe_truncate(text, text_max_chars)

        result =
          result
          |> Map.put("text", final_text)
          |> Map.put("originalTextChars", original_chars)
          |> maybe_put("textTruncated", existing_truncated or truncated_now?)

        {result, ["text" | wrapped_fields]}

      _ ->
        {result, wrapped_fields}
    end
  end

  defp read_result_original_chars(result, text, key) do
    case Map.get(result, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> String.length(text)
    end
  end

  defp read_positive_int(args, keys, default)
       when is_map(args) and is_list(keys) and is_integer(default) and default > 0 do
    Enum.find_value(keys, default, fn key ->
      case Map.get(args, key) do
        n when is_integer(n) and n > 0 ->
          n

        n when is_binary(n) ->
          case Integer.parse(String.trim(n)) do
            {value, _rest} when value > 0 -> value
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

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
