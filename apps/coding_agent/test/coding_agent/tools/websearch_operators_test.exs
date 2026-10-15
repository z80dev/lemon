defmodule CodingAgent.Tools.WebSearchOperatorsTest do
  use ExUnit.Case, async: false
  alias CodingAgent.Search.Operators
  alias CodingAgent.Tools.WebSearch

  setup do
    WebSearch.reset_rate_limit()
    WebSearch.reset_cache(%{"persistent" => false})

    on_exit(fn ->
      WebSearch.reset_rate_limit()
      WebSearch.reset_cache(%{"persistent" => false})
    end)

    :ok
  end

  test "parses all recognized operators and leaves invalid dates as text" do
    tokens =
      Operators.parse(
        ~s(lemon site:example.org -site:bad.org inurl:docs intitle:OTP filetype:pdf after:2026-01-01 before:2026-02-01 "exact phrase" -ads OR after:2026-02-30)
      )

    assert Enum.map(tokens, & &1.kind) == [
             :term,
             :site,
             :exclude_site,
             :inurl,
             :intitle,
             :filetype,
             :after,
             :before,
             :phrase,
             :exclude,
             :or,
             :term
           ]
  end

  test "URL postfilters enforce domain boundaries, exclusions, paths and extensions" do
    prepared =
      Operators.prepare(
        "lemon site:example.org -site:bad.example.org inurl:docs filetype:pdf intitle:OTP -ads",
        %{}
      )

    assert prepared.query == "lemon"
    assert prepared.dropped == ["intitle:OTP", "-ads"]

    urls = [
      "https://example.org/docs/a.pdf",
      "https://bad.example.org/docs/a.pdf",
      "https://notexample.org/docs/a.pdf",
      "https://example.org/docs/a.html"
    ]

    payload =
      Operators.finish(%{"results" => Enum.map(urls, &%{"url" => &1})}, "original", prepared)

    assert payload["results"] == [%{"url" => hd(urls)}]
  end

  test "native syntax passes through including phrases, exclusions and disjunction" do
    query = ~s(lemon site:example.org OR "exact phrase" -ads)
    prepared = Operators.prepare(query, %{operators: Operators.syntax()})
    assert prepared.query == query
    assert prepared.dropped == []
    assert prepared.filters == []
  end

  test "unsupported disjunction is reported, not approximated as conjunction" do
    prepared = Operators.prepare("lemon site:a.org OR site:b.org", %{})
    assert prepared.dropped == ["site:a.org", "OR", "site:b.org"]
    assert prepared.filters == []
  end

  test "maps date operators to Exa and reports unsupported query syntax" do
    parent = self()

    post = fn _, opts ->
      send(parent, {:body, Keyword.fetch!(opts, :json)})
      {:ok, Req.Response.new(body: %{"results" => []})}
    end

    tool = tool(http_post: post)

    payload =
      tool.execute.(
        "id",
        %{
          "query" => ~s(lemon after:2026-01-01 before:2026-02-01 intitle:OTP "exact"),
          "provider" => "exa",
          "fallbackProviders" => []
        },
        nil,
        nil
      )
      |> decode()

    assert_received {:body,
                     %{
                       "query" => "lemon",
                       "startPublishedDate" => "2026-01-01T00:00:00Z",
                       "endPublishedDate" => "2026-02-01T00:00:00Z"
                     }}

    assert payload["dropped_operators"] == ["intitle:OTP", ~s("exact")]
  end

  test "freshness skips incapable primary and falls back between capable providers" do
    parent = self()

    post = fn url, opts ->
      send(parent, {:request, url, Keyword.fetch!(opts, :json)})

      if String.contains?(url, "exa"),
        do: {:error, :timeout},
        else: {:ok, Req.Response.new(body: %{"results" => []})}
    end

    payload =
      tool(http_post: post).execute.(
        "id",
        %{
          "query" => "recency operator test",
          "provider" => "perplexity",
          "fallbackProviders" => ["exa", "tavily"],
          "recency" => "week"
        },
        nil,
        nil
      )
      |> decode()

    assert payload["provider_used"] == "tavily"
    assert payload["failover"]["used"]
    assert_received {:request, "https://api.exa.ai/search", %{"startPublishedDate" => _}}
    assert_received {:request, "https://api.tavily.com/search", %{"start_date" => _}}
    refute_received {:request, "https://openrouter.ai/api/v1/chat/completions", _}
  end

  defp tool(opts) do
    WebSearch.tool(
      "/tmp",
      Keyword.merge(
        [
          settings_manager: %{
            tools: %{
              web: %{
                cache: %{persistent: false},
                search: %{
                  provider: "exa",
                  providers: %{exa: %{api_key: "test"}, tavily: %{api_key: "test"}}
                }
              }
            }
          }
        ],
        opts
      )
    )
  end

  defp decode(result), do: result.content |> hd() |> Map.fetch!(:text) |> Jason.decode!()
end
