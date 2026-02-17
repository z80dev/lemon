defmodule CodingAgent.Tools.WebSearchTest do
  use ExUnit.Case, async: false

  alias AgentCore.AbortSignal
  alias CodingAgent.Tools.WebSearch

  setup do
    original_cache_path = System.get_env("LEMON_WEB_CACHE_PATH")

    cache_dir =
      Path.join(System.tmp_dir!(), "websearch_cache_#{System.unique_integer([:positive])}")

    File.mkdir_p!(cache_dir)
    System.put_env("LEMON_WEB_CACHE_PATH", cache_dir)

    on_exit(fn ->
      if original_cache_path,
        do: System.put_env("LEMON_WEB_CACHE_PATH", original_cache_path),
        else: System.delete_env("LEMON_WEB_CACHE_PATH")

      File.rm_rf!(cache_dir)
    end)

    WebSearch.reset_rate_limit()
    WebSearch.reset_cache(%{"path" => cache_dir})
    :ok
  end

  test "tool schema exposes modern and compatibility parameters" do
    tool = WebSearch.tool("/tmp")

    assert tool.name == "websearch"
    assert tool.parameters["required"] == ["query"]
    assert Map.has_key?(tool.parameters["properties"], "count")
    assert Map.has_key?(tool.parameters["properties"], "max_results")
    assert Map.has_key?(tool.parameters["properties"], "region")
    assert Map.has_key?(tool.parameters["properties"], "freshness")
    assert Map.has_key?(tool.parameters["properties"], "maxChars")
    assert Map.has_key?(tool.parameters["properties"], "snippetMaxChars")
    assert Map.has_key?(tool.parameters["properties"], "maxCitations")
  end

  test "returns error when query is missing" do
    tool = WebSearch.tool("/tmp")
    assert {:error, "Query is required"} = tool.execute.("id", %{}, nil, nil)
  end

  test "returns disabled error when configured off" do
    tool =
      WebSearch.tool("/tmp",
        settings_manager: %{tools: %{web: %{search: %{enabled: false}}}}
      )

    assert {:error, "websearch is disabled by configuration"} =
             tool.execute.("id", %{"query" => "hello"}, nil, nil)
  end

  test "returns setup payload when Brave key is missing" do
    original = System.get_env("BRAVE_API_KEY")
    System.delete_env("BRAVE_API_KEY")

    on_exit(fn ->
      if original,
        do: System.put_env("BRAVE_API_KEY", original),
        else: System.delete_env("BRAVE_API_KEY")
    end)

    tool =
      WebSearch.tool("/tmp",
        settings_manager: %{
          tools: %{
            web: %{search: %{provider: "brave", api_key: nil, failover: %{enabled: false}}}
          }
        }
      )

    result = tool.execute.("id", %{"query" => "hello"}, nil, nil)
    payload = decode_payload(result)

    assert payload["error"] == "missing_brave_api_key"
    assert payload["docs"] =~ "/tools/web"
  end

  test "fails over when primary provider is missing key" do
    original_brave = System.get_env("BRAVE_API_KEY")
    System.delete_env("BRAVE_API_KEY")

    on_exit(fn ->
      if original_brave,
        do: System.put_env("BRAVE_API_KEY", original_brave),
        else: System.delete_env("BRAVE_API_KEY")
    end)

    parent = self()

    http_post = fn _url, _opts ->
      send(parent, :fallback_http_post)

      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
           "choices" => [%{"message" => %{"content" => "Fallback response"}}],
           "citations" => ["https://example.com/fallback"]
         }
       }}
    end

    tool =
      WebSearch.tool("/tmp",
        http_post: http_post,
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "brave",
                api_key: nil,
                failover: %{enabled: true, provider: "perplexity"},
                perplexity: %{api_key: "pplx-key"}
              }
            }
          }
        }
      )

    payload = tool.execute.("id", %{"query" => "lemon failover"}, nil, nil) |> decode_payload()

    assert payload["provider"] == "perplexity"
    assert payload["provider_requested"] == "brave"
    assert payload["provider_used"] == "perplexity"
    assert payload["failover"]["attempted"] == true
    assert payload["failover"]["used"] == true
    assert payload["failover"]["from"] == "brave"
    assert payload["failover"]["to"] == "perplexity"
    assert payload["failover"]["reason"] =~ "missing_brave_api_key"
    assert_received :fallback_http_post
  end

  test "runs Brave search and caches results" do
    parent = self()

    http_get = fn url, opts ->
      send(parent, {:http_get, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
           "web" => %{
             "results" => [
               %{
                 "title" => "Lemon",
                 "url" => "https://example.com/lemon",
                 "description" => "A citrus fruit",
                 "age" => "2d"
               }
             ]
           }
         }
       }}
    end

    tool =
      WebSearch.tool("/tmp",
        http_get: http_get,
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "brave",
                api_key: "brave-key",
                cache_ttl_minutes: 60
              }
            }
          }
        }
      )

    first = tool.execute.("id1", %{"query" => "lemon"}, nil, nil)
    assert first.trust == :untrusted
    first_payload = decode_payload(first)

    assert first_payload["provider"] == "brave"
    assert first_payload["count"] == 1
    assert first_payload["cached"] == nil
    [first_result] = first_payload["results"]
    assert first_result["url"] == "https://example.com/lemon"
    assert first_result["title"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert first_payload["trust_metadata"]["untrusted"] == true
    assert first_payload["trust_metadata"]["source"] == "web_search"
    assert first_payload["trust_metadata"]["source_label"] == "Web Search"
    assert first_payload["trust_metadata"]["wrapping_applied"] == true
    assert first_payload["trust_metadata"]["warning_included"] == false

    assert first_payload["trust_metadata"]["wrapped_fields"] == [
             "results[].title",
             "results[].description"
           ]

    second = tool.execute.("id2", %{"query" => "lemon"}, nil, nil)
    assert second.trust == :untrusted
    second_payload = decode_payload(second)

    assert second_payload["cached"] == true
    assert_received {:http_get, _, _}
    refute_received {:http_get, _, _}
  end

  test "fails over when primary provider request errors" do
    parent = self()

    http_get = fn _url, _opts ->
      send(parent, :primary_http_get)
      {:error, :timeout}
    end

    http_post = fn _url, _opts ->
      send(parent, :fallback_http_post)

      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
           "choices" => [%{"message" => %{"content" => "Fallback answer"}}],
           "citations" => []
         }
       }}
    end

    tool =
      WebSearch.tool("/tmp",
        http_get: http_get,
        http_post: http_post,
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "brave",
                api_key: "brave-key",
                failover: %{enabled: true, provider: "perplexity"},
                perplexity: %{api_key: "pplx-key"}
              }
            }
          }
        }
      )

    payload = tool.execute.("id", %{"query" => "lemon timeout"}, nil, nil) |> decode_payload()

    assert payload["provider"] == "perplexity"
    assert payload["provider_requested"] == "brave"
    assert payload["provider_used"] == "perplexity"
    assert payload["failover"]["attempted"] == true
    assert payload["failover"]["used"] == true
    assert payload["failover"]["reason"] =~ "Brave Search request failed"
    assert_received :primary_http_get
    assert_received :fallback_http_post
  end

  test "returns primary provider error when failover disabled" do
    parent = self()

    http_get = fn _url, _opts ->
      send(parent, :primary_http_get)
      {:error, :econnrefused}
    end

    http_post = fn _url, _opts ->
      send(parent, :fallback_http_post)
      {:error, :should_not_be_called}
    end

    tool =
      WebSearch.tool("/tmp",
        http_get: http_get,
        http_post: http_post,
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "brave",
                api_key: "brave-key",
                failover: %{enabled: false},
                perplexity: %{api_key: "pplx-key"}
              }
            }
          }
        }
      )

    assert {:error, message} = tool.execute.("id", %{"query" => "no fallback"}, nil, nil)
    assert message =~ "Brave Search request failed"
    assert_received :primary_http_get
    refute_received :fallback_http_post
  end

  test "does not degrade freshness requests to non-brave failover provider" do
    original_brave = System.get_env("BRAVE_API_KEY")
    System.delete_env("BRAVE_API_KEY")

    on_exit(fn ->
      if original_brave,
        do: System.put_env("BRAVE_API_KEY", original_brave),
        else: System.delete_env("BRAVE_API_KEY")
    end)

    tool =
      WebSearch.tool("/tmp",
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "brave",
                api_key: nil,
                failover: %{enabled: true, provider: "perplexity"},
                perplexity: %{api_key: "pplx-key"}
              }
            }
          }
        }
      )

    payload =
      tool.execute.("id", %{"query" => "fresh lemons", "freshness" => "pw"}, nil, nil)
      |> decode_payload()

    assert payload["error"] == "missing_brave_api_key"
    assert payload["provider_requested"] == "brave"
    assert payload["provider_used"] == "brave"
    assert payload["failover"]["attempted"] == false
    assert payload["failover"]["used"] == false
    assert payload["failover"]["reason"] =~ "freshness is only supported by Brave"
  end

  test "rejects freshness for non-brave providers" do
    tool =
      WebSearch.tool("/tmp",
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "perplexity",
                perplexity: %{api_key: "pplx-key"}
              }
            }
          }
        }
      )

    assert {:error, "freshness is only supported by the Brave websearch provider"} =
             tool.execute.("id", %{"query" => "lemon", "freshness" => "pw"}, nil, nil)
  end

  test "runs perplexity search with citations" do
    parent = self()

    http_post = fn url, opts ->
      send(parent, {:http_post, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
           "choices" => [%{"message" => %{"content" => "Synthesized answer"}}],
           "citations" => ["https://example.com/source"]
         }
       }}
    end

    tool =
      WebSearch.tool("/tmp",
        http_post: http_post,
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "perplexity",
                perplexity: %{
                  api_key: "pplx-key",
                  model: "perplexity/sonar"
                }
              }
            }
          }
        }
      )

    result = tool.execute.("id", %{"query" => "latest lemon news"}, nil, nil)
    assert result.trust == :untrusted
    payload = decode_payload(result)

    assert payload["provider"] == "perplexity"
    assert payload["model"] == "perplexity/sonar"
    assert payload["content"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert payload["citations"] == ["https://example.com/source"]
    assert payload["trust_metadata"]["untrusted"] == true
    assert payload["trust_metadata"]["source"] == "web_search"
    assert payload["trust_metadata"]["wrapped_fields"] == ["content"]
    assert_received {:http_post, _, _}
  end

  test "applies compact limits to perplexity content and citations" do
    long_content = String.duplicate("Lemon ", 300)
    long_citation = "https://example.com/" <> String.duplicate("a", 200)

    http_post = fn _url, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
           "choices" => [%{"message" => %{"content" => long_content}}],
           "citations" => [long_citation, long_citation, long_citation]
         }
       }}
    end

    tool =
      WebSearch.tool("/tmp",
        http_post: http_post,
        settings_manager: %{
          tools: %{
            web: %{
              search: %{
                provider: "perplexity",
                perplexity: %{api_key: "pplx-key"}
              }
            }
          }
        }
      )

    payload =
      tool.execute.(
        "id",
        %{
          "query" => "compact output",
          "maxChars" => 120,
          "maxCitations" => 2,
          "citationMaxChars" => 50
        },
        nil,
        nil
      )
      |> decode_payload()

    assert length(payload["citations"]) == 2
    assert Enum.all?(payload["citations"], &(String.length(&1) <= 53))
    assert String.length(payload["content"]) < 1000
    assert payload["content"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
  end

  test "handles already-aborted signal" do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)

    tool = WebSearch.tool("/tmp")
    assert {:error, "Operation aborted"} = tool.execute.("id", %{"query" => "hello"}, signal, nil)
  end

  defp decode_payload(result) do
    [content] = result.content
    Jason.decode!(content.text)
  end
end
