defmodule CodingAgent.Search.ProvidersTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Search.Providers.{Brave, DuckDuckGo, Perplexity, Searxng}

  @request %{
    query: "lemon agents",
    count: 3,
    country: "US",
    search_lang: "en",
    ui_lang: "en",
    freshness: nil,
    max_chars: 2_000,
    snippet_max_chars: 200,
    max_citations: 5,
    citation_max_chars: 300
  }

  test "Brave normalizes results without leaking its key" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:brave_request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "web" => %{
             "results" => [
               %{"title" => "Lemon", "url" => "https://example.com", "description" => "Agent"}
             ]
           }
         }
       }}
    end

    assert {:ok, payload} =
             Brave.search(@request, %{api_key: "secret", timeout_ms: 100, http_get: http_get})

    assert payload["count"] == 1
    assert hd(payload["results"])["title"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    refute inspect(payload) =~ "secret"
    assert_received {:brave_request, url, _opts}
    assert url =~ "country=US"
  end

  test "Perplexity wraps answer content and bounds citations" do
    http_post = fn _url, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"content" => "answer"}}],
           "citations" => ["https://one.example", "https://two.example"]
         }
       }}
    end

    assert {:ok, payload} =
             Perplexity.search(@request, %{
               api_key: "pplx-secret",
               base_url: "https://api.perplexity.ai",
               model: "sonar",
               timeout_ms: 100,
               http_post: http_post
             })

    assert payload["content"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert payload["citations"] == ["https://one.example", "https://two.example"]
    refute inspect(payload) =~ "pplx-secret"
  end

  test "DuckDuckGo parses keyless HTML result links" do
    html = """
    <div class="result">
      <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Flemon">Lemon result</a>
      <a class="result__snippet">A useful citrus agent</a>
    </div>
    """

    http_get = fn _url, _opts -> {:ok, %Req.Response{status: 200, body: html}} end

    assert {:ok, payload} =
             DuckDuckGo.search(@request, %{timeout_ms: 100, http_get: http_get})

    assert payload["provider"] == "duckduckgo"
    assert hd(payload["results"])["url"] == "https://example.com/lemon"
  end

  test "SearXNG normalizes a configured JSON endpoint" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:searxng_url, url})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "results" => [
             %{"title" => "SearX", "url" => "https://search.example", "content" => "meta"}
           ]
         }
       }}
    end

    assert {:ok, payload} =
             Searxng.search(@request, %{
               base_url: "https://searx.example/",
               timeout_ms: 100,
               http_get: http_get
             })

    assert payload["count"] == 1
    assert_received {:searxng_url, url}
    assert url =~ "format=json"
  end
end
