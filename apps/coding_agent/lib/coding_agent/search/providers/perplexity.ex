defmodule CodingAgent.Search.Providers.Perplexity do
  @moduledoc "Perplexity Sonar search-answer provider, direct or through OpenRouter."

  @behaviour CodingAgent.Search.Provider

  alias CodingAgent.Search.Result
  alias CodingAgent.Security.ExternalContent

  @impl true
  def id, do: "perplexity"

  @impl true
  def capabilities, do: [:search]

  @impl true
  def available?(:search, %{api_key: key}) when is_binary(key) and key != "", do: :ok

  def available?(:search, _context) do
    {:error,
     %{
       "error" => "missing_perplexity_api_key",
       "message" =>
         "websearch (perplexity) needs an API key. Set PERPLEXITY_API_KEY or OPENROUTER_API_KEY, or configure agent.tools.web.search.perplexity.api_key.",
       "docs" => "docs/tools/web.md"
     }}
  end

  @impl true
  def search(request, context) do
    started_ms = System.monotonic_time(:millisecond)
    endpoint = String.trim_trailing(context.base_url, "/") <> "/chat/completions"

    opts = [
      headers: [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{context.api_key}"},
        {"http-referer", "https://lemon.agent"},
        {"x-title", "Lemon Web Search"}
      ],
      json: %{
        "model" => context.model,
        "messages" => [%{"role" => "user", "content" => request.query}]
      },
      connect_options: [timeout: context.timeout_ms],
      receive_timeout: context.timeout_ms
    ]

    case context.http_post.(endpoint, opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        body = Result.decode_json(response.body)

        raw_content =
          get_in(body, ["choices", Access.at(0), "message", "content"]) || "No response"

        content = raw_content |> to_string() |> Result.truncate(request.max_chars)

        citations =
          body
          |> Map.get("citations", [])
          |> normalize_citations(request)

        {:ok,
         %{
           "query" => request.query,
           "provider" => id(),
           "model" => context.model,
           "took_ms" => Result.elapsed_ms(started_ms),
           "content" => ExternalContent.wrap_web_content(content, :web_search),
           "citations" => citations,
           "trust_metadata" =>
             ExternalContent.web_trust_metadata(:web_search, ["content"], warning_included: false)
         }}

      {:ok, %Req.Response{status: status} = response} ->
        detail = response.body |> Result.to_string_safe() |> String.trim()
        {:error, "Perplexity API error (#{status}): #{empty_default(detail)}"}

      {:error, reason} ->
        {:error, "Perplexity request failed: #{Result.format_reason(reason)}"}

      other ->
        {:error, "Unexpected Perplexity result: #{inspect(other)}"}
    end
  end

  defp normalize_citations(citations, request) when is_list(citations) do
    citations
    |> Enum.map(fn value -> value |> to_string() |> Result.optional_string() end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Result.truncate(&1, request.citation_max_chars))
    |> Enum.take(request.max_citations)
  end

  defp normalize_citations(_, _request), do: []
  defp empty_default(""), do: "request failed"
  defp empty_default(value), do: value
end
