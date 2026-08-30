defmodule LemonBrowser.SessionProvidersTest do
  use ExUnit.Case, async: true

  alias LemonBrowser.SessionProviders.{Browserbase, BrowserUse, Firecrawl}

  test "Browser Use creates and releases a CDP session" do
    parent = self()

    post = fn url, opts ->
      send(parent, {:post, url, opts})

      {:ok,
       %Req.Response{
         status: 201,
         body: %{
           "id" => "bu-session",
           "cdpUrl" => "wss://secret@browser-use.test/cdp",
           "timeoutAt" => "2026-08-30T03:00:00Z"
         }
       }}
    end

    patch = fn url, opts ->
      send(parent, {:patch, url, opts})
      {:ok, %Req.Response{status: 204, body: ""}}
    end

    opts = [
      provider_config: %{api_key: "bu-secret", base_url: "https://bu.test/api/v3"},
      http_post: post,
      http_patch: patch
    ]

    assert BrowserUse.available?(opts)

    assert {:ok, session} = BrowserUse.create_session("scope", opts)
    assert session.id == "bu-session"
    assert session.cdp_endpoint == "wss://secret@browser-use.test/cdp"
    assert session.expires_at == "2026-08-30T03:00:00Z"
    assert_received {:post, "https://bu.test/api/v3/browsers", create_opts}
    assert {"x-browser-use-api-key", "bu-secret"} in create_opts[:headers]

    assert :ok = BrowserUse.close_session(session.id, opts)
    assert_received {:patch, "https://bu.test/api/v3/browsers/bu-session", close_opts}
    assert close_opts[:json] == %{"action" => "stop"}
    refute inspect(BrowserUse.status()) =~ "bu-secret"
  end

  test "Firecrawl creates a bounded-TTL browser and deletes it" do
    parent = self()

    post = fn url, opts ->
      send(parent, {:post, url, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"id" => "fc-session", "cdpUrl" => "wss://firecrawl.test/cdp"}
       }}
    end

    delete = fn url, opts ->
      send(parent, {:delete, url, opts})
      {:ok, %Req.Response{status: 204, body: ""}}
    end

    opts = [
      provider_config: %{
        api_key: "fc-secret",
        base_url: "https://firecrawl.test",
        ttl_seconds: 99_999
      },
      http_post: post,
      http_delete: delete
    ]

    assert {:ok, session} = Firecrawl.create_session("scope", opts)
    assert session.features.ttl_seconds == 3_600
    assert_received {:post, "https://firecrawl.test/v2/browser", create_opts}
    assert create_opts[:json] == %{"ttl" => 3_600}
    assert {"authorization", "Bearer fc-secret"} in create_opts[:headers]

    assert :ok = Firecrawl.close_session(session.id, opts)
    assert_received {:delete, "https://firecrawl.test/v2/browser/fc-session", _opts}
  end

  test "Browserbase retries without paid proxy and keep-alive features on 402" do
    parent = self()
    calls = :counters.new(1, [:atomics])

    post = fn url, opts ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)
      send(parent, {:post, call, url, opts})

      case call do
        1 ->
          {:ok, %Req.Response{status: 402, body: %{}}}

        2 ->
          {:ok,
           %Req.Response{
             status: 201,
             body: %{"id" => "bb-session", "connectUrl" => "wss://browserbase.test/cdp"}
           }}

        3 ->
          {:ok, %Req.Response{status: 200, body: %{}}}
      end
    end

    opts = [
      provider_config: %{
        api_key: "bb-secret",
        project_id: "project-1",
        base_url: "https://bb.test",
        keep_alive: true,
        proxies: true,
        advanced_stealth: true,
        timeout_seconds: 600
      },
      http_post: post
    ]

    assert {:ok, session} = Browserbase.create_session("scope", opts)
    assert session.id == "bb-session"
    assert session.features.keep_alive == false
    assert session.features.proxies == false
    assert session.features.advanced_stealth == true

    assert_received {:post, 1, "https://bb.test/v1/sessions", first}
    assert first[:json]["keepAlive"] == true
    assert first[:json]["proxies"] == true

    assert_received {:post, 2, "https://bb.test/v1/sessions", second}
    refute Map.has_key?(second[:json], "keepAlive")
    refute Map.has_key?(second[:json], "proxies")

    assert :ok = Browserbase.close_session(session.id, opts)
    assert_received {:post, 3, "https://bb.test/v1/sessions/bb-session", close_opts}
    assert close_opts[:json]["status"] == "REQUEST_RELEASE"
  end

  test "providers fail closed on missing credentials without leaking configuration" do
    refute BrowserUse.available?(provider_config: %{})
    refute Browserbase.available?(provider_config: %{})
    refute Firecrawl.available?(provider_config: %{})

    assert {:error, :missing_browser_use_api_key} =
             BrowserUse.create_session("scope", provider_config: %{})

    assert {:error, :missing_browserbase_credentials} =
             Browserbase.create_session("scope", provider_config: %{})

    assert {:error, :missing_firecrawl_api_key} =
             Firecrawl.create_session("scope", provider_config: %{})
  end
end
