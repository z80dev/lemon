defmodule CodingAgent.Tools.WebFetch do
  @moduledoc """
  WebFetch tool for the coding agent.

  Fetches content from a URL and returns it as text, markdown, or HTML.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @max_response_size 5 * 1024 * 1024
  @default_timeout_ms 30_000
  @max_timeout_ms 120_000

  @doc """
  Returns the WebFetch tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, _opts \\ []) do
    %AgentTool{
      name: "webfetch",
      description: "Fetch content from a URL and return it as text, markdown, or html.",
      label: "Web Fetch",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "The URL to fetch (http or https)"
          },
          "format" => %{
            "type" => "string",
            "description" => "Format to return: text, markdown, or html",
            "enum" => ["text", "markdown", "html"]
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Optional timeout in seconds (max 120)"
          }
        },
        "required" => ["url", "format"]
      },
      execute: &execute/4
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal)
    end
  end

  defp do_execute(params, signal) do
    url = Map.get(params, "url", "")
    format = Map.get(params, "format", "text")
    timeout_seconds = Map.get(params, "timeout")
    timeout_ms = normalize_timeout(timeout_seconds)

    with :ok <- validate_url(url),
         {:ok, response} <- fetch_with_retry(url, timeout_ms, signal),
         :ok <- check_abort(signal) do
      case response do
        %{status: status} when status >= 200 and status < 300 ->
          process_success_response(response, url, format)

        %{status: status} ->
          {:error, format_http_error(status, url)}
      end
    end
  end

  defp process_success_response(%{body: body, headers: headers}, url, format) do
    content_type = header_value(headers, "content-type") || ""
    body = ensure_binary(body)

    if byte_size(body) > @max_response_size do
      {:error, "Response too large (exceeds #{div(@max_response_size, 1024 * 1024)}MB limit)"}
    else
      formatted = format_body(body, content_type, format)
      content_type_display = content_type |> String.split(";") |> List.first() |> String.trim()

      %AgentToolResult{
        content: [%TextContent{text: formatted}],
        details: %{title: "#{url} (#{content_type_display})"}
      }
    end
  end

  defp validate_url(url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      :ok
    else
      {:error, "URL must start with http:// or https://"}
    end
  end

  defp normalize_timeout(nil), do: @default_timeout_ms

  defp normalize_timeout(timeout_seconds) when is_integer(timeout_seconds) do
    timeout_seconds
    |> max(0)
    |> Kernel.*(1000)
    |> min(@max_timeout_ms)
  end

  defp normalize_timeout(_), do: @default_timeout_ms

  @max_retries 3
  @retry_base_delay_ms 1000

  defp fetch_with_retry(url, timeout_ms, signal, retries_left \\ @max_retries) do
    case fetch(url, timeout_ms, signal) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        if retries_left > 0 and retryable_error?(reason) do
          delay = @retry_base_delay_ms * (@max_retries - retries_left + 1)
          Process.sleep(delay)
          fetch_with_retry(url, timeout_ms, signal, retries_left - 1)
        else
          {:error, reason}
        end
    end
  end

  defp retryable_error?(reason) when is_atom(reason) do
    reason in [:timeout, :connect_timeout, :closed, :econnrefused, :econnreset]
  end

  defp retryable_error?({:error, %{status: status}}) when is_integer(status) do
    status in [429, 502, 503, 504]
  end

  defp retryable_error?(_), do: false

  defp format_http_error(404, url), do: "Page not found (404): #{url}"
  defp format_http_error(403, url), do: "Access forbidden (403): #{url}"
  defp format_http_error(401, url), do: "Authentication required (401): #{url}"
  defp format_http_error(429, url), do: "Rate limited (429): #{url}"
  defp format_http_error(500, url), do: "Server error (500): #{url}"
  defp format_http_error(502, url), do: "Bad gateway (502): #{url}"
  defp format_http_error(503, url), do: "Service unavailable (503): #{url}"
  defp format_http_error(status, url), do: "Request failed with status #{status}: #{url}"

  defp fetch(url, timeout_ms, _signal) do
    headers = [
      {"user-agent",
       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
      {"accept",
       "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.9"}
    ]

    Req.get(url,
      headers: headers,
      decode_body: false,
      connect_timeout: timeout_ms,
      receive_timeout: timeout_ms
    )
  end

  defp check_abort(nil), do: :ok

  defp check_abort(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end

  defp header_value(headers, key) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == String.downcase(key), do: v
    end)
  end

  defp ensure_binary(body) when is_binary(body), do: body
  defp ensure_binary(body), do: IO.iodata_to_binary(body)

  defp format_body(body, content_type, format) do
    case format do
      "html" ->
        body

      "markdown" ->
        if String.contains?(content_type, "text/html") do
          html_to_markdown(body)
        else
          "```\n" <> body <> "\n```"
        end

      _ ->
        if String.contains?(content_type, "text/html") do
          html_to_text(body)
        else
          body
        end
    end
  end

  defp html_to_text(html) do
    html
    |> strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp html_to_markdown(html) do
    html
    |> strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp strip_tags(html) do
    html
    |> String.replace(~r/<\s*script[^>]*>.*?<\s*\/\s*script\s*>/is, " ")
    |> String.replace(~r/<\s*style[^>]*>.*?<\s*\/\s*style\s*>/is, " ")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n")
    |> String.replace(~r/<\/li>/i, "\n")
    |> String.replace(~r/<[^>]+>/, " ")
  end
end
