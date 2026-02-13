defmodule CodingAgent.Tools.WebSearchTest do
  use ExUnit.Case, async: false

  alias AgentCore.AbortSignal
  alias CodingAgent.Tools.WebSearch

  setup do
    WebSearch.reset_rate_limit()
    WebSearch.reset_cache()
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
        settings_manager: %{tools: %{web: %{search: %{provider: "brave", api_key: nil}}}}
      )

    result = tool.execute.("id", %{"query" => "hello"}, nil, nil)
    payload = decode_payload(result)

    assert payload["error"] == "missing_brave_api_key"
    assert payload["docs"] =~ "/tools/web"
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
    first_payload = decode_payload(first)

    assert first_payload["provider"] == "brave"
    assert first_payload["count"] == 1
    assert first_payload["cached"] == nil
    [first_result] = first_payload["results"]
    assert first_result["url"] == "https://example.com/lemon"
    assert first_result["title"] =~ "EXTERNAL_UNTRUSTED_CONTENT"

    second = tool.execute.("id2", %{"query" => "lemon"}, nil, nil)
    second_payload = decode_payload(second)

    assert second_payload["cached"] == true
    assert_received {:http_get, _, _}
    refute_received {:http_get, _, _}
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
    payload = decode_payload(result)

    assert payload["provider"] == "perplexity"
    assert payload["model"] == "perplexity/sonar"
    assert payload["content"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert payload["citations"] == ["https://example.com/source"]
    assert_received {:http_post, _, _}
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
