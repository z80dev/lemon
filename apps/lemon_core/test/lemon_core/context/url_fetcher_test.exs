defmodule LemonCore.Context.URLFetcherTest do
  use ExUnit.Case, async: true

  alias LemonCore.Context.URLFetcher

  test "blocks localhost, private DNS answers, URL credentials, and private redirects" do
    request = fn _url, _headers, _http, _max -> flunk("unsafe request was attempted") end

    assert {:error, :ssrf_blocked} = URLFetcher.fetch("http://localhost/a", request_fun: request)

    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("https://example.test/a",
               resolve_fun: fn _ -> {:ok, [{127, 0, 0, 1}]} end,
               request_fun: request
             )

    assert {:error, :url_credentials_forbidden} =
             URLFetcher.fetch("https://user:pass@example.test/a",
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: request
             )

    redirect = fn _url, _headers, _http, _max ->
      {:ok, {{~c"HTTP/1.1", 302, ~c"Found"}, [{~c"location", ~c"http://127.0.0.1/secret"}], ""}}
    end

    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("https://example.test/a",
               resolve_fun: fn host ->
                 if host == "example.test",
                   do: {:ok, [{93, 184, 216, 34}]},
                   else: {:ok, [{127, 0, 0, 1}]}
               end,
               request_fun: redirect
             )
  end

  test "pins the request IP, retains host header, and strips query metadata" do
    parent = self()

    request = fn url, headers, http, max ->
      send(parent, {:request, url, headers, http, max})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"text/plain"}], "hello"}}
    end

    assert {:ok, "hello", metadata} =
             URLFetcher.fetch("https://example.test/path?token=secret#frag",
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: request,
               max_input_bytes: 10
             )

    assert metadata.final_url == "https://example.test/path"
    assert_received {:request, "https://93.184.216.34/path?token=secret", headers, http, 10}
    assert {~c"host", ~c"example.test"} in headers
    assert get_in(http, [:ssl, :server_name_indication]) == ~c"example.test"
  end

  test "rejects a body over the limit even from an injected transport" do
    assert {:error, {:input_too_large, 6, 5}} =
             URLFetcher.fetch("https://example.test/",
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: fn _, _, _, _ ->
                 {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "123456"}}
               end,
               max_input_bytes: 5
             )
  end
end
