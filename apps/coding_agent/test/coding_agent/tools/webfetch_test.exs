defmodule CodingAgent.Tools.WebFetchTest do
  use ExUnit.Case, async: false

  alias AgentCore.AbortSignal
  alias CodingAgent.Tools.WebFetch

  setup do
    WebFetch.reset_cache()
    :ok
  end

  test "tool schema exposes url + extractMode + compatibility format" do
    tool = WebFetch.tool("/tmp")

    assert tool.name == "webfetch"
    assert tool.parameters["required"] == ["url"]
    assert Map.has_key?(tool.parameters["properties"], "extractMode")
    assert Map.has_key?(tool.parameters["properties"], "maxChars")
    assert Map.has_key?(tool.parameters["properties"], "format")
  end

  test "returns disabled error when configured off" do
    tool =
      WebFetch.tool("/tmp",
        settings_manager: %{tools: %{web: %{fetch: %{enabled: false}}}}
      )

    assert {:error, "webfetch is disabled by configuration"} =
             tool.execute.("id", %{"url" => "https://example.com"}, nil, nil)
  end

  test "rejects invalid URL scheme" do
    tool = WebFetch.tool("/tmp")

    assert {:error, "Invalid URL: must be http or https"} =
             tool.execute.("id", %{"url" => "file:///etc/passwd"}, nil, nil)
  end

  test "blocks localhost SSRF targets" do
    tool = WebFetch.tool("/tmp")

    assert {:error, message} = tool.execute.("id", %{"url" => "http://localhost/admin"}, nil, nil)
    assert message =~ "Blocked hostname"
  end

  test "blocks private network redirect targets" do
    parent = self()

    http_get = fn url, _opts ->
      send(parent, {:http_get, url})

      {:ok,
       %Req.Response{
         status: 302,
         headers: [{"location", "http://127.0.0.1/internal"}],
         body: ""
       }}
    end

    tool =
      WebFetch.tool("/tmp",
        http_get: http_get,
        settings_manager: %{
          tools: %{
            web: %{
              fetch: %{
                timeout_seconds: 5,
                max_redirects: 3
              }
            }
          }
        }
      )

    assert {:error, message} = tool.execute.("id", %{"url" => "https://8.8.8.8/start"}, nil, nil)
    assert message =~ "Blocked"
    assert_received {:http_get, "https://8.8.8.8/start"}
    refute_received {:http_get, "http://127.0.0.1/internal"}
  end

  test "extracts HTML and wraps untrusted content" do
    http_get = fn _url, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "text/html; charset=utf-8"}],
         body:
           "<html><head><title>Lemon Doc</title></head><body><main><h1>Hello</h1><p>World</p></main></body></html>"
       }}
    end

    tool =
      WebFetch.tool("/tmp",
        http_get: http_get,
        settings_manager: %{
          tools: %{
            web: %{
              fetch: %{
                timeout_seconds: 5,
                cache_ttl_minutes: 30,
                max_chars: 20_000,
                allow_private_network: true
              }
            }
          }
        }
      )

    result =
      tool.execute.("id", %{"url" => "https://8.8.8.8/doc", "extractMode" => "text"}, nil, nil)

    payload = decode_payload(result)

    assert payload["extractor"] == "readability"
    assert payload["status"] == 200
    assert payload["contentType"] == "text/html"
    assert payload["text"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert payload["text"] =~ "Hello"
  end

  test "uses firecrawl fallback on guarded fetch failure" do
    parent = self()

    http_get = fn _url, _opts ->
      send(parent, :http_get_called)
      {:error, :nxdomain}
    end

    http_post = fn _url, _opts ->
      send(parent, :http_post_called)

      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: %{
           "success" => true,
           "data" => %{
             "markdown" => "# Firecrawl Title\nSome content",
             "metadata" => %{
               "title" => "Firecrawl Title",
               "sourceURL" => "https://example.com/final",
               "statusCode" => 200
             }
           }
         }
       }}
    end

    tool =
      WebFetch.tool("/tmp",
        http_get: http_get,
        http_post: http_post,
        settings_manager: %{
          tools: %{
            web: %{
              fetch: %{
                timeout_seconds: 5,
                allow_private_network: true,
                firecrawl: %{
                  enabled: true,
                  api_key: "fc-key",
                  base_url: "https://api.firecrawl.dev"
                }
              }
            }
          }
        }
      )

    result = tool.execute.("id", %{"url" => "https://8.8.8.8/fail"}, nil, nil)
    payload = decode_payload(result)

    assert payload["extractor"] == "firecrawl"
    assert payload["finalUrl"] == "https://example.com/final"
    assert payload["text"] =~ "EXTERNAL_UNTRUSTED_CONTENT"
    assert_received :http_get_called
    assert_received :http_post_called
  end

  test "caches successful fetch results" do
    parent = self()

    http_get = fn _url, _opts ->
      send(parent, :http_get_called)

      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"hello":"world"})
       }}
    end

    tool =
      WebFetch.tool("/tmp",
        http_get: http_get,
        settings_manager: %{
          tools: %{
            web: %{
              fetch: %{
                allow_private_network: true,
                cache_ttl_minutes: 30
              }
            }
          }
        }
      )

    first = tool.execute.("id1", %{"url" => "https://8.8.8.8/cache"}, nil, nil)
    first_payload = decode_payload(first)
    assert first_payload["cached"] == nil

    second = tool.execute.("id2", %{"url" => "https://8.8.8.8/cache"}, nil, nil)
    second_payload = decode_payload(second)
    assert second_payload["cached"] == true

    assert_received :http_get_called
    refute_received :http_get_called
  end

  test "supports legacy format=html mode" do
    http_get = fn _url, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         headers: [{"content-type", "text/html"}],
         body: "<html><body><h1>Raw HTML</h1></body></html>"
       }}
    end

    tool =
      WebFetch.tool("/tmp",
        http_get: http_get,
        settings_manager: %{tools: %{web: %{fetch: %{allow_private_network: true}}}}
      )

    result = tool.execute.("id", %{"url" => "https://8.8.8.8/raw", "format" => "html"}, nil, nil)
    payload = decode_payload(result)

    assert payload["extractMode"] == "html"
    assert payload["extractor"] == "raw_html"
    assert payload["text"] =~ "<h1>Raw HTML</h1>"
  end

  test "handles already-aborted signal" do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)

    tool = WebFetch.tool("/tmp")

    assert {:error, "Operation aborted"} =
             tool.execute.("id", %{"url" => "https://example.com"}, signal, nil)
  end

  defp decode_payload(result) do
    [content] = result.content
    Jason.decode!(content.text)
  end
end
