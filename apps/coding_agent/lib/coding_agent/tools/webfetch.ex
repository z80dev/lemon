defmodule CodingAgent.Tools.WebFetch do
  @moduledoc """
  WebFetch tool for the coding agent.

  Fetches content from a URL with SSRF protections, readability extraction,
  optional Firecrawl fallback, and structured JSON output.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Security.ExternalContent
  alias CodingAgent.Tools.WebCache
  alias CodingAgent.Tools.WebGuard

  @default_fetch_max_chars 20_000
  @default_fetch_max_redirects 3
  @default_timeout_seconds 30
  @default_cache_ttl_minutes 15
  @default_cache_max_entries 100
  @default_firecrawl_base_url "https://api.firecrawl.dev"
  @default_firecrawl_max_age_ms 172_800_000
  @default_fetch_user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
  @max_error_detail_chars 400
  @fetch_cache_table :coding_agent_webfetch_cache

  @doc """
  Returns the WebFetch tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    runtime = build_runtime(opts)

    %AgentTool{
      name: "webfetch",
      description:
        "Fetch and extract readable content from a URL (HTML -> markdown/text). Returns structured JSON.",
      label: "Web Fetch",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "HTTP or HTTPS URL to fetch."
          },
          "extractMode" => %{
            "type" => "string",
            "description" => "Extraction mode: markdown (default) or text.",
            "enum" => ["markdown", "text"]
          },
          "maxChars" => %{
            "type" => "integer",
            "description" => "Maximum characters to return."
          },
          "format" => %{
            "type" => "string",
            "description" => "Backward-compatible alias: text, markdown, html.",
            "enum" => ["text", "markdown", "html"]
          }
        },
        "required" => ["url"]
      },
      execute: fn tool_call_id, params, signal, on_update ->
        execute(tool_call_id, params, signal, on_update, runtime)
      end
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, on_update) do
    execute(tool_call_id, params, signal, on_update, build_runtime([]))
  end

  @doc false
  def reset_cache(opts \\ []), do: WebCache.clear_cache(@fetch_cache_table, opts)

  defp execute(_tool_call_id, params, signal, _on_update, runtime) do
    if runtime.enabled do
      with :ok <- check_abort(signal),
           {:ok, url} <- read_required_string(params, "url"),
           {:ok, extract_mode} <- resolve_extract_mode(params),
           :ok <- check_abort(signal) do
        max_chars =
          read_integer(params, ["maxChars", "max_chars"], nil)
          |> normalize_max_chars(runtime.max_chars)

        run_fetch(url, extract_mode, max_chars, runtime)
      end
    else
      {:error, "webfetch is disabled by configuration"}
    end
  end

  defp run_fetch(url, extract_mode, max_chars, runtime) do
    cache_key =
      WebCache.normalize_cache_key("fetch:#{url}:#{Atom.to_string(extract_mode)}:#{max_chars}")

    case WebCache.read_cache(@fetch_cache_table, cache_key, runtime.cache_opts) do
      {:hit, payload} ->
        json_result(Map.put(payload, "cached", true))

      :miss ->
        with {:ok, payload} <- perform_fetch(url, extract_mode, max_chars, runtime) do
          WebCache.write_cache(
            @fetch_cache_table,
            cache_key,
            payload,
            runtime.cache_ttl_ms,
            runtime.cache_max_entries,
            runtime.cache_opts
          )

          json_result(payload)
        end
    end
  end

  defp perform_fetch(url, extract_mode, max_chars, runtime) do
    started_ms = System.monotonic_time(:millisecond)

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

    case WebGuard.guarded_get(url, guard_opts) do
      {:ok, response, final_url} ->
        handle_guarded_response(
          response,
          url,
          final_url,
          extract_mode,
          max_chars,
          runtime,
          started_ms
        )

      {:error, reason} ->
        if WebGuard.ssrf_blocked?(reason) or direct_guard_error?(reason) do
          {:error, format_guard_error(reason)}
        else
          maybe_fallback_to_firecrawl(url, extract_mode, max_chars, runtime, started_ms, reason)
        end
    end
  end

  defp handle_guarded_response(
         response,
         original_url,
         final_url,
         extract_mode,
         max_chars,
         runtime,
         started_ms
       ) do
    status = response.status

    if status in 200..299 do
      parse_success_response(
        response,
        original_url,
        final_url,
        extract_mode,
        max_chars,
        runtime,
        started_ms
      )
    else
      maybe_fallback_to_firecrawl(
        original_url,
        extract_mode,
        max_chars,
        runtime,
        started_ms,
        {:http_error, status, response}
      )
    end
  end

  defp parse_success_response(
         response,
         original_url,
         final_url,
         extract_mode,
         max_chars,
         runtime,
         started_ms
       ) do
    content_type = normalize_content_type(header_value(response.headers, "content-type"))
    body = to_string_safe(response.body)

    case extract_content(body, content_type, extract_mode, final_url, runtime) do
      {:ok, %{text: text, title: title, extractor: extractor}} ->
        wrapped = wrap_web_fetch_content(text, max_chars)
        wrapped_title = wrap_web_fetch_field(title)
        trust_metadata = web_fetch_trust_metadata(wrapped, wrapped_title)

        {:ok,
         %{
           "url" => original_url,
           "finalUrl" => final_url,
           "status" => response.status,
           "contentType" => content_type || "application/octet-stream",
           "title" => wrapped_title,
           "extractMode" => Atom.to_string(extract_mode),
           "extractor" => extractor,
           "truncated" => wrapped.truncated,
           "length" => wrapped.wrapped_length,
           "rawLength" => wrapped.raw_length,
           "wrappedLength" => wrapped.wrapped_length,
           "fetchedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
           "tookMs" => elapsed_ms(started_ms),
           "text" => wrapped.text,
           "trustMetadata" => trust_metadata
         }}

      {:error, reason} ->
        maybe_fallback_to_firecrawl(
          final_url,
          extract_mode,
          max_chars,
          runtime,
          started_ms,
          {:extract_error, reason}
        )
    end
  end

  defp maybe_fallback_to_firecrawl(
         url,
         extract_mode,
         max_chars,
         runtime,
         started_ms,
         primary_error
       ) do
    if firecrawl_enabled?(runtime.firecrawl) do
      case fetch_firecrawl_content(url, extract_mode, runtime) do
        {:ok, firecrawl} ->
          wrapped = wrap_web_fetch_content(firecrawl.text, max_chars)
          wrapped_title = wrap_web_fetch_field(firecrawl.title)
          wrapped_warning = wrap_web_fetch_field(firecrawl.warning)
          trust_metadata = web_fetch_trust_metadata(wrapped, wrapped_title, wrapped_warning)

          {:ok,
           %{
             "url" => url,
             "finalUrl" => firecrawl.final_url || url,
             "status" => firecrawl.status || 200,
             "contentType" => "text/markdown",
             "title" => wrapped_title,
             "extractMode" => Atom.to_string(extract_mode),
             "extractor" => "firecrawl",
             "truncated" => wrapped.truncated,
             "length" => wrapped.wrapped_length,
             "rawLength" => wrapped.raw_length,
             "wrappedLength" => wrapped.wrapped_length,
             "fetchedAt" => DateTime.utc_now() |> DateTime.to_iso8601(),
             "tookMs" => elapsed_ms(started_ms),
             "text" => wrapped.text,
             "warning" => wrapped_warning,
             "trustMetadata" => trust_metadata
           }}

        {:error, firecrawl_reason} ->
          {:error,
           "Web fetch failed: #{format_primary_error(primary_error)} (Firecrawl fallback failed: #{firecrawl_reason})"}
      end
    else
      {:error, "Web fetch failed: #{format_primary_error(primary_error)}"}
    end
  end

  defp extract_content(body, _content_type, :html, _url, _runtime) do
    {:ok, %{text: body, title: nil, extractor: "raw_html"}}
  end

  defp extract_content(body, content_type, extract_mode, url, runtime) do
    cond do
      is_binary(content_type) and String.contains?(content_type, "text/html") ->
        extract_html_content(body, extract_mode, url, runtime)

      is_binary(content_type) and String.contains?(content_type, "application/json") ->
        text =
          case Jason.decode(body) do
            {:ok, decoded} -> Jason.encode!(decoded)
            _ -> body
          end

        {:ok, %{text: text, title: nil, extractor: "json"}}

      true ->
        {:ok, %{text: body, title: nil, extractor: "raw"}}
    end
  end

  defp extract_html_content(html, extract_mode, url, runtime) do
    if runtime.readability_enabled do
      case safe_readability_extract(runtime, html, extract_mode, url) do
        {:ok, %{text: text} = payload} when is_binary(text) ->
          title = Map.get(payload, :title) || Map.get(payload, "title")

          if String.trim(text) == "" do
            extract_html_content_fallback(html, extract_mode)
          else
            {:ok, %{text: text, title: title, extractor: "readability"}}
          end

        {:ok, _other} ->
          extract_html_content_fallback(html, extract_mode)

        {:error, _reason} ->
          extract_html_content_fallback(html, extract_mode)
      end
    else
      extract_html_content_fallback(html, extract_mode)
    end
  end

  defp safe_readability_extract(runtime, html, extract_mode, url) do
    try do
      runtime.readability_extract.(html, extract_mode, url)
    rescue
      error ->
        {:error, "Readability extraction failed: #{Exception.message(error)}"}
    catch
      :exit, reason ->
        {:error, "Readability extraction failed: #{format_reason(reason)}"}

      kind, reason ->
        {:error, "Readability extraction failed (#{kind}): #{format_reason(reason)}"}
    end
  end

  defp extract_with_readability(html, extract_mode, url) do
    article = Readability.article(html, page_url: url)
    readable_html = Readability.readable_html(article)
    rendered = html_to_markdown(readable_html)

    text =
      case extract_mode do
        :text ->
          article
          |> Readability.readable_text()
          |> normalize_whitespace()

        :markdown ->
          rendered.text
      end

    title = readability_title(html) || rendered.title

    {:ok, %{text: text, title: title}}
  end

  defp readability_title(html) do
    case Readability.title(html) do
      value when is_binary(value) -> normalize_optional_string(value)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_html_content_fallback(html, extract_mode) do
    rendered = html_to_markdown(html)
    text = if extract_mode == :text, do: markdown_to_text(rendered.text), else: rendered.text

    if String.trim(text) == "" do
      {:error, "Readability extraction returned no content"}
    else
      {:ok, %{text: text, title: rendered.title, extractor: "readability_fallback"}}
    end
  end

  defp fetch_firecrawl_content(url, extract_mode, runtime) do
    endpoint = resolve_firecrawl_endpoint(runtime.firecrawl.base_url)

    request_body = %{
      "url" => url,
      "formats" => ["markdown"],
      "onlyMainContent" => runtime.firecrawl.only_main_content,
      "timeout" => runtime.firecrawl.timeout_seconds * 1_000,
      "maxAge" => runtime.firecrawl.max_age_ms,
      "proxy" => "auto",
      "storeInCache" => true
    }

    request_opts = [
      headers: [
        {"authorization", "Bearer #{runtime.firecrawl.api_key}"},
        {"content-type", "application/json"}
      ],
      json: request_body,
      connect_options: [timeout: runtime.firecrawl.timeout_seconds * 1_000],
      receive_timeout: runtime.firecrawl.timeout_seconds * 1_000
    ]

    case runtime.http_post.(endpoint, request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        payload = decode_json_body(response.body)
        success = Map.get(payload, "success")
        data = Map.get(payload, "data", %{}) |> ensure_map()

        if success == false do
          {:error,
           "Firecrawl fetch failed: #{normalize_optional_string(Map.get(payload, "error")) || "request failed"}"}
        else
          raw_text =
            normalize_optional_string(Map.get(data, "markdown")) ||
              normalize_optional_string(Map.get(data, "content")) || ""

          text = if extract_mode == :text, do: markdown_to_text(raw_text), else: raw_text
          metadata = Map.get(data, "metadata", %{}) |> ensure_map()

          {:ok,
           %{
             text: text,
             title: normalize_optional_string(Map.get(metadata, "title")),
             final_url: normalize_optional_string(Map.get(metadata, "sourceURL")),
             status: Map.get(metadata, "statusCode"),
             warning: normalize_optional_string(Map.get(payload, "warning"))
           }}
        end

      {:ok, %Req.Response{status: status} = response} ->
        detail = sanitize_error_detail(response.body)

        {:error,
         "Firecrawl fetch failed (#{status}): #{if(detail == "", do: "request failed", else: detail)}"}

      {:error, reason} ->
        {:error, "Firecrawl request failed: #{format_reason(reason)}"}

      other ->
        {:error, "Unexpected Firecrawl result: #{inspect(other)}"}
    end
  end

  defp resolve_firecrawl_endpoint(base_url) do
    trimmed = normalize_optional_string(base_url) || @default_firecrawl_base_url

    case URI.parse(trimmed) do
      %URI{host: host} = uri when is_binary(host) and host != "" ->
        path = normalize_optional_string(uri.path)

        cond do
          is_nil(path) or path == "/" ->
            uri
            |> Map.put(:path, "/v2/scrape")
            |> Map.put(:query, nil)
            |> URI.to_string()

          true ->
            URI.to_string(uri)
        end

      _ ->
        @default_firecrawl_base_url <> "/v2/scrape"
    end
  end

  defp firecrawl_enabled?(firecrawl) do
    configured_enabled = firecrawl.enabled
    has_api_key = present?(firecrawl.api_key)

    cond do
      configured_enabled in [true, false] -> configured_enabled and has_api_key
      true -> has_api_key
    end
  end

  defp resolve_extract_mode(params) do
    explicit_mode =
      read_string(params, ["extractMode", "extract_mode"])
      |> normalize_optional_string()

    format_alias = read_string(params, ["format"]) |> normalize_optional_string()

    cond do
      not is_nil(format_alias) and format_alias not in ["text", "markdown", "html"] ->
        {:error, "format must be one of: text, markdown, html"}

      explicit_mode == "text" ->
        {:ok, :text}

      explicit_mode == "markdown" ->
        {:ok, :markdown}

      not is_nil(explicit_mode) ->
        {:error, "extractMode must be one of: text, markdown"}

      format_alias == "text" ->
        {:ok, :text}

      format_alias == "html" ->
        {:ok, :html}

      true ->
        {:ok, :markdown}
    end
  end

  defp html_to_markdown(html) when is_binary(html) do
    title =
      case Regex.run(~r/<title[^>]*>([\s\S]*?)<\/title>/i, html, capture: :all_but_first) do
        [value] -> value |> strip_tags() |> normalize_whitespace() |> normalize_optional_string()
        _ -> nil
      end

    body =
      html
      |> remove_tag_with_contents("script")
      |> remove_tag_with_contents("style")
      |> remove_tag_with_contents("noscript")
      |> maybe_keep_main_section()
      |> convert_links_to_markdown()
      |> convert_headings_to_markdown()
      |> convert_list_items_to_markdown()
      |> String.replace(~r/<(br|hr)\s*\/?>/i, "\n")
      |> String.replace(~r/<\/(p|div|section|article|header|footer|table|tr|ul|ol)>/i, "\n")
      |> strip_tags()
      |> normalize_whitespace()

    %{text: body, title: title}
  end

  defp markdown_to_text(markdown) when is_binary(markdown) do
    markdown
    |> String.replace(~r/!\[[^\]]*]\([^)]+\)/, "")
    |> String.replace(~r/\[([^\]]+)]\([^)]+\)/, "\\1")
    |> String.replace(~r/```[\s\S]*?```/, fn block ->
      block
      |> String.replace(~r/```[^\n]*\n?/, "")
      |> String.replace("```", "")
    end)
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/^\#{1,6}\s+/m, "")
    |> String.replace(~r/^\s*[-*+]\s+/m, "")
    |> String.replace(~r/^\s*\d+\.\s+/m, "")
    |> normalize_whitespace()
  end

  defp remove_tag_with_contents(html, tag) do
    Regex.replace(~r/<#{tag}[\s\S]*?<\/#{tag}>/i, html, "")
  end

  defp maybe_keep_main_section(html) do
    case Regex.run(~r/<(main|article)[^>]*>([\s\S]*?)<\/\1>/i, html, capture: :all_but_first) do
      [_tag, section] -> section
      _ -> html
    end
  end

  defp convert_links_to_markdown(html) do
    Regex.replace(~r/<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/i, html, fn _,
                                                                                      href,
                                                                                      body ->
      label = body |> strip_tags() |> normalize_whitespace()
      if label == "", do: href, else: "[#{label}](#{href})"
    end)
  end

  defp convert_headings_to_markdown(html) do
    Regex.replace(~r/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/i, html, fn _, level, body ->
      prefix = String.duplicate("#", max(min(String.to_integer(level), 6), 1))
      label = body |> strip_tags() |> normalize_whitespace()
      "\n#{prefix} #{label}\n"
    end)
  end

  defp convert_list_items_to_markdown(html) do
    Regex.replace(~r/<li[^>]*>([\s\S]*?)<\/li>/i, html, fn _, body ->
      label = body |> strip_tags() |> normalize_whitespace()
      if label == "", do: "", else: "\n- #{label}"
    end)
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

  defp wrap_web_fetch_content(value, max_chars) do
    wrapper_with_warning = ExternalContent.wrap_web_content("", :web_fetch)

    wrapper_without_warning =
      ExternalContent.wrap_external_content("", source: :web_fetch, include_warning: false)

    include_warning = String.length(wrapper_with_warning) <= max_chars

    wrapper_overhead =
      if include_warning,
        do: String.length(wrapper_with_warning),
        else: String.length(wrapper_without_warning)

    max_inner = max(max_chars - wrapper_overhead, 0)

    {truncated, truncated?} = truncate_text(value, max_inner)
    wrapped = wrap_text(truncated, include_warning)

    {final_wrapped, final_truncated, final_raw} =
      if String.length(wrapped) > max_chars do
        excess = String.length(wrapped) - max_chars
        adjusted_max_inner = max(max_inner - excess, 0)
        {adjusted, adjusted_truncated?} = truncate_text(value, adjusted_max_inner)
        {wrap_text(adjusted, include_warning), adjusted_truncated?, adjusted}
      else
        {wrapped, truncated?, truncated}
      end

    %{
      text: final_wrapped,
      truncated: final_truncated,
      raw_length: String.length(final_raw),
      wrapped_length: String.length(final_wrapped),
      warning_included: include_warning
    }
  end

  defp wrap_text(content, true), do: ExternalContent.wrap_web_content(content, :web_fetch)

  defp wrap_text(content, false) do
    ExternalContent.wrap_external_content(content, source: :web_fetch, include_warning: false)
  end

  defp wrap_web_fetch_field(nil), do: nil
  defp wrap_web_fetch_field(""), do: nil

  defp wrap_web_fetch_field(value) do
    ExternalContent.wrap_external_content(value, source: :web_fetch, include_warning: false)
  end

  defp web_fetch_trust_metadata(wrapped, wrapped_title, wrapped_warning \\ nil) do
    wrapped_fields =
      ["text"]
      |> maybe_add_wrapped_field(wrapped_title, "title")
      |> maybe_add_wrapped_field(wrapped_warning, "warning")

    ExternalContent.web_trust_metadata(:web_fetch, wrapped_fields,
      key_style: :camel_case,
      warning_included: wrapped.warning_included
    )
  end

  defp maybe_add_wrapped_field(fields, nil, _field), do: fields
  defp maybe_add_wrapped_field(fields, "", _field), do: fields
  defp maybe_add_wrapped_field(fields, _value, field), do: fields ++ [field]

  defp truncate_text(_value, max_chars) when max_chars <= 0, do: {"", true}

  defp truncate_text(value, max_chars) do
    if String.length(value) <= max_chars do
      {value, false}
    else
      {String.slice(value, 0, max_chars), true}
    end
  end

  defp normalize_content_type(nil), do: nil

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> normalize_optional_string()
  end

  defp normalize_content_type(_), do: nil

  defp format_guard_error({:ssrf_blocked, message}), do: message
  defp format_guard_error({:invalid_url, message}), do: message
  defp format_guard_error({:redirect_error, message}), do: message
  defp format_guard_error({:network_error, message}), do: message
  defp format_guard_error(reason), do: format_reason(reason)

  defp direct_guard_error?({:invalid_url, _}), do: true
  defp direct_guard_error?(_), do: false

  defp format_primary_error({:http_error, status, response}) do
    detail = sanitize_error_detail(response.body)
    "HTTP #{status}: #{if(detail == "", do: "request failed", else: detail)}"
  end

  defp format_primary_error({:extract_error, reason}), do: to_string(reason)
  defp format_primary_error(reason), do: format_guard_error(reason)

  defp header_value(headers, key) do
    Enum.find_value(headers, fn {header_key, header_value} ->
      if String.downcase(to_string(header_key)) == String.downcase(key),
        do: to_string(header_value)
    end)
  end

  defp decode_json_body(body) when is_map(body), do: body

  defp decode_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode_json_body(body) when is_list(body), do: decode_json_body(IO.iodata_to_binary(body))
  defp decode_json_body(_), do: %{}

  defp to_string_safe(body) when is_binary(body), do: body
  defp to_string_safe(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp to_string_safe(body), do: inspect(body)

  defp sanitize_error_detail(body) do
    body
    |> to_string_safe()
    |> strip_tags()
    |> normalize_whitespace()
    |> truncate_error_detail()
  end

  defp truncate_error_detail(detail) when byte_size(detail) <= @max_error_detail_chars, do: detail

  defp truncate_error_detail(detail),
    do: String.slice(detail, 0, @max_error_detail_chars) <> "..."

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

  defp read_string(params, keys) do
    keys
    |> Enum.find_value(fn key -> normalize_optional_string(Map.get(params, key)) end)
  end

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_), do: nil

  defp normalize_max_chars(nil, default), do: max(default, 100)
  defp normalize_max_chars(value, _default) when is_integer(value), do: max(value, 100)
  defp normalize_max_chars(_value, default), do: max(default, 100)

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp present?(value), do: not is_nil(normalize_optional_string(value))

  defp elapsed_ms(started_ms), do: System.monotonic_time(:millisecond) - started_ms

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

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

  defp build_runtime(opts) do
    settings_manager = Keyword.get(opts, :settings_manager)
    tools_cfg = settings_manager |> get_struct_field(:tools, %{}) |> ensure_map()
    web_cfg = tools_cfg |> get_map_value(:web, %{}) |> ensure_map()
    fetch_cfg = web_cfg |> get_map_value(:fetch, %{}) |> ensure_map()
    firecrawl_cfg = fetch_cfg |> get_map_value(:firecrawl, %{}) |> ensure_map()
    cache_cfg = web_cfg |> get_map_value(:cache, %{}) |> ensure_map()

    cache_max_entries =
      WebCache.resolve_cache_max_entries(
        get_map_value(cache_cfg, :max_entries, @default_cache_max_entries),
        @default_cache_max_entries
      )

    default_cache_opts = %{
      "persistent" => truthy?(get_map_value(cache_cfg, :persistent, true)),
      "path" => normalize_optional_string(get_map_value(cache_cfg, :path, nil)),
      "max_entries" => cache_max_entries
    }

    cache_opts =
      case Keyword.get(opts, :cache_opts) do
        override when is_map(override) or is_list(override) -> override
        _ -> default_cache_opts
      end

    timeout_seconds =
      WebCache.resolve_timeout_seconds(
        get_map_value(fetch_cfg, :timeout_seconds, @default_timeout_seconds),
        @default_timeout_seconds
      )

    cache_ttl_ms =
      WebCache.resolve_cache_ttl_ms(
        get_map_value(fetch_cfg, :cache_ttl_minutes, @default_cache_ttl_minutes),
        @default_cache_ttl_minutes
      )

    max_redirects =
      get_map_value(fetch_cfg, :max_redirects, @default_fetch_max_redirects)
      |> normalize_integer()
      |> case do
        nil -> @default_fetch_max_redirects
        value -> max(value, 0)
      end

    firecrawl_enabled =
      case get_map_value(firecrawl_cfg, :enabled, nil) do
        true -> true
        false -> false
        _ -> nil
      end

    firecrawl_api_key =
      normalize_optional_string(get_map_value(firecrawl_cfg, :api_key, nil)) ||
        normalize_optional_string(System.get_env("FIRECRAWL_API_KEY"))

    firecrawl_timeout =
      WebCache.resolve_timeout_seconds(
        get_map_value(firecrawl_cfg, :timeout_seconds, timeout_seconds),
        timeout_seconds
      )

    readability_extract =
      case Keyword.get(opts, :readability_extract) do
        fun when is_function(fun, 3) -> fun
        _ -> &extract_with_readability/3
      end

    %{
      enabled: truthy?(get_map_value(fetch_cfg, :enabled, true)),
      max_chars:
        get_map_value(fetch_cfg, :max_chars, @default_fetch_max_chars)
        |> normalize_integer()
        |> normalize_max_chars(@default_fetch_max_chars),
      timeout_ms: timeout_seconds * 1_000,
      cache_ttl_ms: cache_ttl_ms,
      cache_max_entries: cache_max_entries,
      cache_opts: cache_opts,
      max_redirects: max_redirects,
      user_agent:
        normalize_optional_string(get_map_value(fetch_cfg, :user_agent, nil)) ||
          @default_fetch_user_agent,
      readability_enabled: truthy?(get_map_value(fetch_cfg, :readability, true)),
      readability_extract: readability_extract,
      allow_private_network: truthy?(get_map_value(fetch_cfg, :allow_private_network, false)),
      allowed_hostnames:
        get_map_value(fetch_cfg, :allowed_hostnames, [])
        |> ensure_list()
        |> Enum.map(&to_string/1),
      firecrawl: %{
        enabled: firecrawl_enabled,
        api_key: firecrawl_api_key,
        base_url:
          normalize_optional_string(get_map_value(firecrawl_cfg, :base_url, nil)) ||
            @default_firecrawl_base_url,
        only_main_content: truthy?(get_map_value(firecrawl_cfg, :only_main_content, true)),
        max_age_ms:
          get_map_value(firecrawl_cfg, :max_age_ms, @default_firecrawl_max_age_ms)
          |> normalize_integer()
          |> case do
            nil -> @default_firecrawl_max_age_ms
            value -> max(value, 0)
          end,
        timeout_seconds: firecrawl_timeout
      },
      http_get: Keyword.get(opts, :http_get, &Req.get/2),
      http_post: Keyword.get(opts, :http_post, &Req.post/2)
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

  defp truthy?(value) when value in [false, "false", "0", 0], do: false
  defp truthy?(_), do: true
end
