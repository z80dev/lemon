defmodule CodingAgent.Search.Providers.KeyedHttp do
  @moduledoc false

  # Shared plumbing for API-key search providers (Tavily, Kagi, Jina): the
  # missing-key setup payload and bounded HTTP error reporting.

  alias CodingAgent.Search.Result

  @max_detail 400

  def available?(_provider, _env, %{api_key: key}) when is_binary(key) and key != "", do: :ok

  def available?(provider, env, _context) do
    {:error,
     %{
       "error" => "missing_#{provider}_api_key",
       "message" =>
         "websearch (#{provider}) needs an API key. Set #{env} or configure runtime.tools.web.search.providers.#{provider}.api_key.",
       "docs" => "docs/tools/web.md"
     }}
  end

  def request_opts(context, headers) do
    [
      headers: headers,
      connect_options: [timeout: context.timeout_ms],
      receive_timeout: context.timeout_ms
    ]
  end

  def handle(label, result, on_success) do
    case result do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        on_success.(Result.decode_json(body))

      {:ok, %Req.Response{status: status, body: body}} ->
        detail = body |> Result.to_string_safe() |> String.trim() |> String.slice(0, @max_detail)

        {:error,
         "#{label} API error (#{status}): #{if detail == "", do: "request failed", else: detail}"}

      {:error, reason} ->
        {:error, "#{label} request failed: #{Result.format_reason(reason)}"}

      other ->
        {:error, "Unexpected #{label} result: #{inspect(other)}"}
    end
  end

  def mapped(request, title, url, snippet, published \\ nil) do
    Result.mapped_result(title, url, snippet,
      title_max_chars: request.snippet_max_chars,
      description_max_chars: request.max_chars,
      published: published
    )
  end

  def list(value) when is_list(value), do: value
  def list(_), do: []
end
