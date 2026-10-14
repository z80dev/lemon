defmodule CodingAgent.Search.ProvidersTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Search.Providers.{
    Brave,
    DuckDuckGo,
    Exa,
    Jina,
    Kagi,
    Perplexity,
    Searxng,
    Tavily
  }

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

  test "Exa uses highlights for search and never exposes its key" do
    parent = self()

    http_post = fn url, opts ->
      send(parent, {:exa_request, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "results" => [
             %{
               "title" => "Semantic citrus",
               "url" => "https://example.com/exa",
               "highlights" => ["Dense answer", "Second excerpt"],
               "publishedDate" => "2026-08-30T00:00:00Z"
             }
           ]
         }
       }}
    end

    assert {:ok, payload} =
             Exa.search(@request, %{
               api_key: "exa-secret",
               base_url: "https://exa.test/",
               timeout_ms: 100,
               http_post: http_post
             })

    assert payload["provider"] == "exa"
    assert hd(payload["results"])["description"] =~ "Dense answer"
    refute inspect(payload) =~ "exa-secret"

    assert_received {:exa_request, "https://exa.test/search", opts}
    assert opts[:json]["type"] == "auto"
    assert opts[:json]["contents"]["highlights"]["maxCharacters"] == 2_000
    assert {"x-api-key", "exa-secret"} in opts[:headers]
  end

  test "Exa extracts bounded, wrapped content from known URLs" do
    http_post = fn url, opts ->
      assert url == "https://api.exa.ai/contents"
      assert opts[:json]["urls"] == ["https://example.com/article"]

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "results" => [
             %{
               "title" => "Article",
               "url" => "https://example.com/article",
               "text" => "untrusted page text"
             }
           ]
         }
       }}
    end

    request = %{
      url: "https://example.com/article",
      extract_mode: :markdown,
      max_chars: 1_000
    }

    assert {:ok, payload} =
             Exa.extract(request, %{
               api_key: "exa-secret",
               base_url: "https://api.exa.ai",
               timeout_ms: 100,
               http_post: http_post
             })

    assert payload["extractor"] == "exa"
    assert payload["text"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert payload["trustMetadata"]["untrusted"] == true
    refute inspect(payload) =~ "exa-secret"
  end

  test "Exa reports missing credentials for both capabilities" do
    assert {:error, %{"error" => "missing_exa_api_key"}} = Exa.available?(:search, %{})
    assert {:error, %{"error" => "missing_exa_api_key"}} = Exa.available?(:extract, %{})
  end

  describe "keyed providers" do
    test "Tavily posts a bearer-authenticated query and maps results" do
      parent = self()

      http_post = fn url, opts ->
        send(parent, {:tavily, url, opts})

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "results" => [
               %{
                 "title" => "Lemon",
                 "url" => "https://lemon.example",
                 "content" => "Agent harness",
                 "published_date" => "2026-01-02"
               },
               %{"title" => "no url"}
             ]
           }
         }}
      end

      context = %{api_key: "tvly-secret", timeout_ms: 100, http_post: http_post}
      assert {:ok, payload} = Tavily.search(@request, context)

      assert_received {:tavily, "https://api.tavily.com/search", opts}
      assert {"authorization", "Bearer tvly-secret"} in opts[:headers]
      assert opts[:json]["max_results"] == 3

      assert [%{"url" => "https://lemon.example", "published" => "2026-01-02"} | _] =
               payload["results"]

      assert hd(payload["results"])["description"] =~ "Agent harness"
      refute inspect(payload) =~ "tvly-secret"
    end

    test "Kagi reads V1 result buckets in order and caps the count" do
      http_post = fn "https://kagi.com/api/v1/search", opts ->
        assert {"authorization", "Bearer kagi-secret"} in opts[:headers]
        assert opts[:json] == %{"query" => "lemon agents", "limit" => 3}

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "data" => %{
               "news" => [%{"url" => "https://news.example", "title" => "Headline"}],
               "search" => [
                 %{"url" => "https://a.example", "title" => "A", "snippet" => "first"},
                 %{"url" => "https://b.example", "title" => "B"},
                 %{"title" => "missing url"}
               ],
               "video" => [%{"url" => "https://v.example", "title" => "Clip"}]
             }
           }
         }}
      end

      assert {:ok, payload} =
               Kagi.search(@request, %{
                 api_key: "kagi-secret",
                 timeout_ms: 100,
                 http_post: http_post
               })

      assert Enum.map(payload["results"], & &1["url"]) ==
               ["https://a.example", "https://b.example", "https://v.example"]

      assert Enum.at(payload["results"], 2)["title"] =~ "[Video] Clip"
    end

    test "Jina encodes the query in the path and accepts data envelopes" do
      parent = self()

      http_get = fn url, opts ->
        send(parent, {:jina, url, opts})

        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "code" => 200,
             "data" => [
               %{
                 "url" => "https://j.example",
                 "title" => "J",
                 "description" => " ",
                 "content" => "body text"
               }
             ]
           }
         }}
      end

      assert {:ok, payload} =
               Jina.search(@request, %{
                 api_key: "jina-secret",
                 timeout_ms: 100,
                 http_get: http_get
               })

      assert_received {:jina, "https://s.jina.ai/lemon%20agents?count=3", opts}
      assert {"x-respond-with", "no-content"} in opts[:headers]
      assert [%{"url" => "https://j.example"} = result] = payload["results"]
      assert result["description"] =~ "body text"
    end

    test "missing keys and HTTP errors are reported without the key" do
      assert {:error, %{"error" => "missing_tavily_api_key", "message" => message}} =
               Tavily.available?(:search, %{})

      assert message =~ "TAVILY_API_KEY"

      assert {:error, %{"error" => "missing_kagi_api_key"}} =
               Kagi.available?(:search, %{api_key: ""})

      http_get = fn _url, _opts -> {:ok, %Req.Response{status: 401, body: "bad key"}} end

      assert {:error, "Jina API error (401): bad key"} =
               Jina.search(@request, %{
                 api_key: "jina-secret",
                 timeout_ms: 100,
                 http_get: http_get
               })
    end
  end
end
