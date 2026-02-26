defmodule CodingAgent.Tools.WebDownload do
  @moduledoc """
  WebDownload tool for the coding agent.

  Downloads a URL to a local file with SSRF protections similar to `webfetch`.

  This is intended for binary content (images, PDFs, etc.) where `webfetch` is
  not appropriate.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Security.ExternalContent
  alias CodingAgent.Tools.WebGuard
  alias CodingAgent.Utils.Http

  @default_timeout_seconds 60
  @default_max_redirects 3
  @default_max_bytes 25 * 1024 * 1024
  @default_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
  @max_error_detail_chars 400

  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    runtime = build_runtime(opts)

    %AgentTool{
      name: "webdownload",
      description:
        "Download a URL to a local file with SSRF protections. Returns JSON metadata (path, bytes, sha256, content-type).",
      label: "Web Download",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "HTTP or HTTPS URL to download."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Optional output file path (relative to cwd or absolute). If omitted, a filename is generated under ./downloads/."
          },
          "maxBytes" => %{
            "type" => "integer",
            "description" =>
              "Maximum bytes to write to disk (default from config; hard stop after download)."
          },
          "overwrite" => %{
            "type" => "boolean",
            "description" => "Overwrite the output path if it exists (default: false)."
          }
        },
        "required" => ["url"]
      },
      execute: fn tool_call_id, params, signal, on_update ->
        execute(tool_call_id, params, signal, on_update, cwd, runtime)
      end
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          runtime :: map()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, runtime) do
    if runtime.enabled do
      with :ok <- check_abort(signal),
           {:ok, url} <- read_required_string(params, "url"),
           :ok <- check_abort(signal) do
        max_bytes =
          read_integer(params, ["maxBytes", "max_bytes"], runtime.max_bytes)
          |> normalize_max_bytes(runtime.max_bytes)

        overwrite = truthy?(Map.get(params, "overwrite", false))

        output_path =
          case normalize_optional_string(Map.get(params, "path")) do
            nil -> default_output_path(url, cwd, runtime)
            path -> resolve_path(path, cwd)
          end

        run_download(url, output_path, max_bytes, overwrite, signal, runtime)
      end
    else
      {:error, "webdownload is disabled by configuration"}
    end
  end

  defp run_download(url, output_path, max_bytes, overwrite, signal, runtime) do
    started_ms = System.monotonic_time(:millisecond)

    with :ok <- check_abort(signal),
         :ok <- ensure_parent_dir(output_path),
         :ok <- maybe_reject_existing_file(output_path, overwrite),
         {:ok, response, final_url} <- guarded_get(url, runtime),
         :ok <- check_abort(signal) do
      if response.status in 200..299 do
        content_type = normalize_content_type(header_value(response.headers, "content-type"))

        with {:ok, binary} <- normalize_binary_body(response.body, content_type),
             :ok <- enforce_max_bytes(binary, max_bytes),
             :ok <- File.write(output_path, binary) do
          final_path = maybe_add_extension(output_path, content_type, overwrite)
          sha256 = sha256_hex(binary)

          payload = %{
            "url" => url,
            "finalUrl" => final_url,
            "status" => response.status,
            "contentType" => content_type || "application/octet-stream",
            "path" => final_path,
            "bytes" => byte_size(binary),
            "sha256" => sha256,
            "downloadedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "tookMs" => elapsed_ms(started_ms),
            "trustMetadata" => web_download_trust_metadata(:camel_case),
            "trust_metadata" => web_download_trust_metadata(:snake_case)
          }

          json_result(payload)
        else
          {:error, reason} ->
            {:error, to_string(reason)}
        end
      else
        detail = sanitize_error_detail(response.body)

        {:error,
         "Web download failed: HTTP #{response.status}: #{if(detail == "", do: "request failed", else: detail)}"}
      end
    else
      {:error, reason} ->
        {:error, format_guard_error(reason)}
    end
  end

  defp guarded_get(url, runtime) do
    guard_opts = [
      headers: [
        {"accept", "*/*"},
        {"user-agent", runtime.user_agent},
        {"accept-language", "en-US,en;q=0.9"}
      ],
      timeout_ms: runtime.timeout_ms,
      max_redirects: runtime.max_redirects,
      allow_private_network: runtime.allow_private_network,
      allowed_hostnames: runtime.allowed_hostnames,
      http_get: runtime.http_get
    ]

    WebGuard.guarded_get(url, guard_opts)
  end

  defp normalize_binary_body(body, _content_type) when is_binary(body), do: {:ok, body}

  defp normalize_binary_body(body, _content_type) when is_list(body) do
    try do
      {:ok, IO.iodata_to_binary(body)}
    rescue
      _ -> {:error, "Unexpected response body type (list)"}
    end
  end

  defp normalize_binary_body(body, content_type) when is_map(body) or is_list(body) do
    if is_binary(content_type) and String.contains?(content_type, "application/json") do
      {:ok, Jason.encode!(body, pretty: true)}
    else
      {:ok, inspect(body)}
    end
  end

  defp normalize_binary_body(body, _content_type), do: {:ok, to_string_safe(body)}

  defp enforce_max_bytes(binary, max_bytes) when is_binary(binary) do
    if byte_size(binary) <= max_bytes do
      :ok
    else
      {:error, "Downloaded file exceeds maxBytes (#{byte_size(binary)} > #{max_bytes})"}
    end
  end

  defp maybe_reject_existing_file(path, overwrite) do
    if File.exists?(path) and not overwrite do
      {:error, "File already exists: #{path} (set overwrite=true to replace)"}
    else
      :ok
    end
  end

  defp ensure_parent_dir(path) do
    path |> Path.dirname() |> File.mkdir_p()
  end

  defp default_output_path(url, cwd, runtime) do
    base_dir = Path.join(cwd, runtime.default_dir)
    _ = File.mkdir_p(base_dir)

    uri = URI.parse(url)
    raw_name = uri.path |> to_string() |> Path.basename()
    name = sanitize_filename(raw_name)

    name =
      case name do
        "" -> "download"
        "." -> "download"
        "/" -> "download"
        other -> other
      end

    suffix = short_hash(url)
    {root, ext} = {Path.rootname(name), Path.extname(name)}
    filename = if ext == "", do: "#{root}-#{suffix}", else: "#{root}-#{suffix}#{ext}"
    Path.join(base_dir, filename)
  end

  defp maybe_add_extension(path, content_type, overwrite) do
    ext = Path.extname(path)

    if ext != "" do
      path
    else
      case extension_for_content_type(content_type) do
        nil ->
          path

        add_ext ->
          new_path = path <> add_ext

          cond do
            new_path == path ->
              path

            File.exists?(new_path) and not overwrite ->
              path

            true ->
              case File.rename(path, new_path) do
                :ok -> new_path
                {:error, _} -> path
              end
          end
      end
    end
  end

  defp extension_for_content_type(nil), do: nil
  defp extension_for_content_type("image/png"), do: ".png"
  defp extension_for_content_type("image/jpeg"), do: ".jpg"
  defp extension_for_content_type("image/webp"), do: ".webp"
  defp extension_for_content_type("image/gif"), do: ".gif"
  defp extension_for_content_type("application/pdf"), do: ".pdf"
  defp extension_for_content_type("application/json"), do: ".json"
  defp extension_for_content_type("text/plain"), do: ".txt"
  defp extension_for_content_type(_), do: nil

  defp sanitize_filename(nil), do: ""

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.trim("_")
  end

  defp sanitize_filename(_), do: ""

  defp resolve_path(path, cwd) do
    path
    |> expand_home()
    |> make_absolute(cwd)
    |> Path.expand()
  end

  defp expand_home("~" <> rest), do: Path.expand("~") <> rest
  defp expand_home(path), do: path

  defp make_absolute(path, cwd) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(cwd, path)
    end
  end

  defp sha256_hex(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  defp short_hash(str) when is_binary(str) do
    h = :erlang.phash2(str, 0xFFFFFFFF)
    h |> Integer.to_string(16) |> String.pad_leading(8, "0") |> String.slice(0, 8)
  end

  defp elapsed_ms(started_ms), do: System.monotonic_time(:millisecond) - started_ms

  defp check_abort(nil), do: :ok

  defp check_abort(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end

  defp json_result(payload) do
    ExternalContent.untrusted_json_result(payload)
  end

  defp web_download_trust_metadata(:camel_case) do
    ExternalContent.web_trust_metadata(:web_fetch, [],
      key_style: :camel_case,
      warning_included: false
    )
  end

  defp web_download_trust_metadata(:snake_case) do
    ExternalContent.web_trust_metadata(:web_fetch, [], warning_included: false)
  end

  defp format_guard_error({:ssrf_blocked, message}), do: message
  defp format_guard_error({:invalid_url, message}), do: message
  defp format_guard_error({:redirect_error, message}), do: message
  defp format_guard_error({:network_error, message}), do: message
  defp format_guard_error(reason), do: format_reason(reason)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp read_required_string(params, key) do
    case normalize_optional_string(Map.get(params, key)) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp read_integer(params, keys, fallback) do
    keys
    |> Enum.find_value(fn key ->
      case Map.get(params, key) do
        nil -> nil
        value -> normalize_integer(value)
      end
    end)
    |> case do
      nil -> fallback
      value -> value
    end
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp normalize_max_bytes(nil, default), do: max(default, 1024)
  defp normalize_max_bytes(value, _default) when is_integer(value), do: max(value, 1024)
  defp normalize_max_bytes(_value, default), do: max(default, 1024)

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_content_type(nil), do: nil

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> normalize_optional_string()
  end

  defp normalize_content_type(_), do: nil

  defp header_value(headers, key) do
    Enum.find_value(headers, fn {header_key, header_value} ->
      if Http.header_key_match?(header_key, key),
        do: to_string(header_value)
    end)
  end

  defp to_string_safe(body) when is_binary(body), do: body
  defp to_string_safe(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp to_string_safe(body), do: inspect(body)

  defp sanitize_error_detail(body) do
    text = to_string_safe(body)

    if is_binary(text) and String.valid?(text) do
      text
      |> strip_tags()
      |> normalize_whitespace()
      |> truncate_error_detail()
    else
      ""
    end
  end

  defp strip_tags(value) do
    value
    |> String.replace(~r/<[^>]+>/, "")
    |> decode_html_entities()
  end

  defp decode_html_entities(value) do
    value
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp normalize_whitespace(value) do
    value
    |> String.replace("\r", "")
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.trim()
  end

  defp truncate_error_detail(detail) when byte_size(detail) <= @max_error_detail_chars, do: detail

  defp truncate_error_detail(detail),
    do: String.slice(detail, 0, @max_error_detail_chars) <> "..."

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp build_runtime(opts) do
    settings_manager = Keyword.get(opts, :settings_manager)
    tools_cfg = settings_manager |> get_struct_field(:tools, %{}) |> ensure_map()
    web_cfg = tools_cfg |> get_map_value(:web, %{}) |> ensure_map()
    download_cfg = web_cfg |> get_map_value(:download, %{}) |> ensure_map()

    timeout_seconds =
      get_map_value(download_cfg, :timeout_seconds, @default_timeout_seconds)
      |> normalize_integer()
      |> case do
        nil -> @default_timeout_seconds
        value -> max(value, 1)
      end

    max_redirects =
      get_map_value(download_cfg, :max_redirects, @default_max_redirects)
      |> normalize_integer()
      |> case do
        nil -> @default_max_redirects
        value -> max(value, 0)
      end

    max_bytes =
      get_map_value(download_cfg, :max_bytes, @default_max_bytes)
      |> normalize_integer()
      |> case do
        nil -> @default_max_bytes
        value -> max(value, 1024)
      end

    default_dir =
      normalize_optional_string(get_map_value(download_cfg, :default_dir, "downloads")) ||
        "downloads"

    %{
      enabled: truthy?(get_map_value(download_cfg, :enabled, true)),
      timeout_ms: timeout_seconds * 1_000,
      max_redirects: max_redirects,
      max_bytes: max_bytes,
      default_dir: default_dir,
      user_agent:
        normalize_optional_string(get_map_value(download_cfg, :user_agent, nil)) ||
          @default_user_agent,
      allow_private_network: truthy?(get_map_value(download_cfg, :allow_private_network, false)),
      allowed_hostnames:
        get_map_value(download_cfg, :allowed_hostnames, [])
        |> ensure_list()
        |> Enum.map(&to_string/1),
      http_get: Keyword.get(opts, :http_get, &Req.get/2)
    }
  end

  defp get_struct_field(nil, _field, default), do: default

  defp get_struct_field(struct, field, default) when is_map(struct) do
    Map.get(struct, field, default)
  end

  defp get_struct_field(_struct, _field, default), do: default

  defp get_map_value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp get_map_value(_map, _key, default), do: default

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_), do: []
end
