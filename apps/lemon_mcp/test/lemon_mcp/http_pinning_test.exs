defmodule LemonMCP.HTTPPinningTest.Fixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    record(conn, request["method"])
    config = Agent.get(conn.assigns.store, & &1)

    if config.oauth and get_req_header(conn, "authorization") != ["Bearer fixture-token"] do
      conn
      |> put_resp_header("www-authenticate", ~s|Bearer resource_metadata="#{config.metadata_url}"|)
      |> send_resp(401, "authorization required")
    else
      case LemonMCP.TestSupport.FixtureServer.response_for(request, "Pinned Fixture") do
        nil -> send_resp(conn, 202, "")
        response -> json(conn, response)
      end
    end
  end

  post "/redirect/:status" do
    record(conn, :redirect)
    conn
    |> put_resp_header("location", "http://127.0.0.1:#{conn.port}/target")
    |> send_resp(String.to_integer(status), "redirect body must not escape")
  end

  get "/metadata" do
    record(conn, :metadata)
    config = Agent.get(conn.assigns.store, & &1)

    if config.metadata_redirect do
      conn
      |> put_resp_header("location", "http://127.0.0.1:#{conn.port}/target")
      |> send_resp(302, "redirect")
    else
      json(conn, %{"resource" => "http://127.0.0.1:#{conn.port}/mcp",
        "authorization_servers" => [config.issuer]})
    end
  end

  get "/.well-known/oauth-authorization-server/oauth" do
    record(conn, :authorization_metadata)
    config = Agent.get(conn.assigns.store, & &1)
    json(conn, %{"token_endpoint" => config.token_endpoint})
  end

  post "/oauth/token" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    record(conn, {:token, URI.decode_query(body)})
    config = Agent.get(conn.assigns.store, & &1)

    if config.token_redirect do
      conn
      |> put_resp_header("location", "http://127.0.0.1:#{conn.port}/target")
      |> send_resp(307, "redirect")
    else
      json(conn, %{"access_token" => "fixture-token", "token_type" => "Bearer"})
    end
  end

  match "/target" do
    record(conn, :target)
    send_resp(conn, 200, "redirect target was fetched")
  end

  match _ do
    record(conn, :unexpected)
    send_resp(conn, 404, "not found")
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn
    |> Plug.Conn.assign(:store, Keyword.fetch!(opts, :store))
    |> super(opts)
  end

  defp record(conn, event) do
    Agent.update(conn.assigns.store, fn config ->
      %{config | events: [{event, Map.new(conn.req_headers)} | config.events]}
    end)
  end

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end
end

defmodule LemonMCP.HTTPPinningTest do
  use ExUnit.Case, async: false

  alias LemonMCP.Client.HTTP
  alias LemonMCP.HTTP.OriginPolicy

  setup do
    store = start_supervised!({Agent, fn ->
      %{events: [], oauth: false, metadata_url: nil, issuer: nil, token_endpoint: nil,
        metadata_redirect: false, token_redirect: false}
    end})
    listener = start_supervised!({Bandit,
      plug: {LemonMCP.HTTPPinningTest.Fixture, store: store},
      scheme: :http, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    origin = "http://127.0.0.1:#{port}"
    Agent.update(store, &%{&1 | metadata_url: origin <> "/metadata",
      issuer: origin <> "/oauth", token_endpoint: origin <> "/oauth/token"})
    %{store: store, port: port, origin: origin}
  end

  test "all MCP requests use an internal DNS pin and preserve original Host", ctx do
    origin = "http://no-dns.pinned.invalid:#{ctx.port}"
    url = origin <> "/mcp"
    policy = private_policy(origin)
    parent = self()
    resolver = fn host ->
      send(parent, {:resolved, host})
      {:ok, [{127, 0, 0, 1}]}
    end
    assert {:ok, pin} = OriginPolicy.pin(url, policy, resolver: resolver)
    assert_receive {:resolved, "no-dns.pinned.invalid"}

    client = start_supervised!({HTTP, url: url, origin_policy: policy, destination_pin: pin,
      headers: [{"authorization", "Bearer original"}, {"Host", "attacker.invalid"}],
      timeout_ms: 2_000})
    assert {:ok, tools} = HTTP.list_tools(client)
    assert Enum.map(tools, & &1["name"]) == ["echo", "fail"]
    assert {:ok, [%{"text" => "echo:pinned"}]} =
      HTTP.call_tool(client, "echo", %{"message" => "pinned"})

    events = events(ctx)
    assert Enum.map(events, &elem(&1, 0)) ==
      ["initialize", "notifications/initialized", "tools/list", "tools/call"]
    for {_event, headers} <- events do
      assert headers["host"] == "no-dns.pinned.invalid:#{ctx.port}"
      assert headers["authorization"] == "Bearer original"
    end
    refute_receive {:resolved, _host}
  end

  test "no internal pin independently authorizes and pins a loopback opt-in", ctx do
    client = start_supervised!({HTTP, url: ctx.origin <> "/mcp",
      origin_policy: private_policy(ctx.origin), timeout_ms: 2_000})
    assert HTTP.state(client) == :ready
    assert {:ok, _tools} = HTTP.list_tools(client)
    assert length(events(ctx)) == 3
  end

  test "IDNA original URL routes to its pin using the canonical ASCII Host", ctx do
    url = "http://BÜCHER.Example.:#{ctx.port}/mcp"
    policy = private_policy("http://xn--bcher-kva.example:#{ctx.port}")
    assert {:ok, pin} = OriginPolicy.pin(url, policy,
      resolver: fn "xn--bcher-kva.example" -> {:ok, [{127, 0, 0, 1}]} end)
    client = start_supervised!({HTTP, url: url, origin_policy: policy,
      destination_pin: pin, timeout_ms: 2_000})
    assert HTTP.state(client) == :ready
    assert Enum.all?(events(ctx), fn {_event, headers} ->
      headers["host"] == "xn--bcher-kva.example:#{ctx.port}"
    end)
  end

  test "IPv6 literal pins connect to an actual IPv6 socket", ctx do
    listener = start_supervised!(Supervisor.child_spec(
      {Bandit, plug: {LemonMCP.HTTPPinningTest.Fixture, store: ctx.store},
       scheme: :http, ip: {0, 0, 0, 0, 0, 0, 0, 1}, port: 0}, id: :ipv6_fixture))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    origin = "http://[::1]:#{port}"
    client = start_supervised!({HTTP, url: origin <> "/mcp",
      origin_policy: private_policy(origin), timeout_ms: 2_000})
    assert {:ok, _tools} = HTTP.list_tools(client)
    assert length(events(ctx)) == 3
    assert Enum.all?(events(ctx), fn {_event, headers} -> headers["host"] == "[::1]:#{port}" end)
  end

  test "a real DNS-resolved localhost origin requires explicit private approval", ctx do
    origin = "http://localhost:#{ctx.port}"
    assert {:error, :destination_not_public} = GenServer.start(HTTP,
      url: origin <> "/mcp", origin_policy: %{allowed_origins: [origin]}, timeout_ms: 2_000)
    assert events(ctx) == []

    client = start_supervised!({HTTP, url: origin <> "/mcp",
      origin_policy: private_policy(origin), timeout_ms: 2_000})
    assert HTTP.state(client) == :ready
    assert Enum.all?(events(ctx), fn {_event, headers} ->
      headers["host"] == "localhost:#{ctx.port}"
    end)
  end

  test "MCP redirects never fetch their target or forward credentials", ctx do
    for status <- [301, 302, 303, 307, 308] do
      url = ctx.origin <> "/redirect/#{status}"
      assert {:error, :redirect_forbidden} = GenServer.start(HTTP,
        url: url, origin_policy: private_policy(ctx.origin),
        headers: [{"authorization", "Bearer secret"}], timeout_ms: 2_000)
    end
    assert length(events(ctx)) == 5
    assert Enum.all?(events(ctx), fn {event, _headers} -> event == :redirect end)
  end

  test "legacy clients also reject redirects without fetching target", ctx do
    assert {:error, :redirect_forbidden} = GenServer.start(HTTP,
      url: ctx.origin <> "/redirect/302", timeout_ms: 2_000)
    assert [{:redirect, _headers}] = events(ctx)
  end

  test "an internal pin for another URL fails before credentials or networking", ctx do
    policy = private_policy(ctx.origin)
    assert {:ok, pin} = OriginPolicy.pin(ctx.origin <> "/mcp", policy)
    parent = self()
    assert {:error, :invalid_destination_pin} = GenServer.start(HTTP,
      url: ctx.origin <> "/other", origin_policy: policy, destination_pin: pin,
      oauth_token_loader: fn -> send(parent, :loaded_credentials); :error end)
    refute_receive :loaded_credentials
    assert events(ctx) == []
  end

  test "denied policy fails before invoking credential callbacks", ctx do
    parent = self()
    assert {:error, :origin_not_allowed} = GenServer.start(HTTP,
      url: ctx.origin <> "/mcp", origin_policy: %{allowed_origins: []},
      oauth_token_loader: fn -> send(parent, :loaded_credentials); :error end)
    refute_receive :loaded_credentials
    assert events(ctx) == []
  end

  test "OAuth discovery and token exchange independently pin without MCP credentials", ctx do
    Agent.update(ctx.store, &%{&1 | oauth: true})
    # Explicit Authorization headers take precedence over acquired OAuth tokens.
    # Use a stale cached bearer so the retry can use the newly exchanged token.
    opts =
      ctx
      |> oauth_opts()
      |> Keyword.put(:headers, [{"x-private", "private-secret"}])
      |> Keyword.put(:oauth_token_loader, fn -> {:ok, %{access_token: "original"}} end)

    client = start_supervised!({HTTP, opts})
    assert HTTP.state(client) == :ready
    assert {:ok, _tools} = HTTP.list_tools(client)
    observed = events(ctx)
    assert {:metadata, metadata_headers} = Enum.find(observed, &(elem(&1, 0) == :metadata))
    assert {:authorization_metadata, issuer_headers} =
      Enum.find(observed, &(elem(&1, 0) == :authorization_metadata))
    assert {{:token, form}, token_headers} =
      Enum.find(observed, &match?({{:token, _}, _}, &1))
    assert form == %{"grant_type" => "client_credentials", "resource" => ctx.origin <> "/mcp"}
    assert token_headers["authorization"] == "Basic " <> Base.encode64("client:client-secret")
    mcp_events = Enum.filter(observed, fn {event, _headers} -> is_binary(event) end)
    assert Enum.map(mcp_events, fn {event, headers} -> {event, headers["authorization"]} end) ==
      [{"initialize", "Bearer original"}, {"initialize", "Bearer fixture-token"},
       {"notifications/initialized", "Bearer fixture-token"}, {"tools/list", "Bearer fixture-token"}]
    assert Enum.all?(mcp_events, fn {_event, headers} ->
      headers["x-private"] == "private-secret"
    end)
    for headers <- [metadata_headers, issuer_headers, token_headers] do
      refute Map.has_key?(headers, "x-private")
    end
    refute Map.has_key?(metadata_headers, "authorization")
    refute Map.has_key?(issuer_headers, "authorization")
  end

  test "a challenge cannot cause a forbidden metadata request", ctx do
    Agent.update(ctx.store, &%{&1 | oauth: true,
      metadata_url: "http://localhost:#{ctx.port}/target"})
    assert {:error, :origin_not_allowed} = GenServer.start(HTTP, oauth_opts(ctx))
    assert [{"initialize", _headers}] = events(ctx)
  end

  test "authorization issuer discovery enforces its own origin", ctx do
    Agent.update(ctx.store, &%{&1 | oauth: true, issuer: "http://localhost:#{ctx.port}/oauth"})
    assert {:error, :origin_not_allowed} = GenServer.start(HTTP, oauth_opts(ctx))
    assert Enum.map(events(ctx), &elem(&1, 0)) == ["initialize", :metadata]
  end

  test "token endpoint origin is checked before posting client secrets", ctx do
    Agent.update(ctx.store, &%{&1 | oauth: true,
      token_endpoint: "http://localhost:#{ctx.port}/target"})
    assert {:error, :origin_not_allowed} = GenServer.start(HTTP, oauth_opts(ctx))
    assert Enum.map(events(ctx), &elem(&1, 0)) ==
      ["initialize", :metadata, :authorization_metadata]
  end

  test "metadata redirects are classified without fetching target", ctx do
    Agent.update(ctx.store, &%{&1 | oauth: true, metadata_redirect: true})
    assert {:error, :redirect_forbidden} = GenServer.start(HTTP, oauth_opts(ctx))
    assert Enum.map(events(ctx), &elem(&1, 0)) == ["initialize", :metadata]
  end

  test "token redirects never forward OAuth client credentials", ctx do
    Agent.update(ctx.store, &%{&1 | oauth: true, token_redirect: true})
    assert {:error, :redirect_forbidden} = GenServer.start(HTTP, oauth_opts(ctx))
    observed = events(ctx)
    assert Enum.map(observed, &elem(&1, 0)) ==
      ["initialize", :metadata, :authorization_metadata,
       {:token, %{"grant_type" => "client_credentials", "resource" => ctx.origin <> "/mcp"}}]
    assert {{:token, _form}, token_headers} = List.last(observed)
    assert token_headers["authorization"] == "Basic " <> Base.encode64("client:client-secret")
    refute Map.has_key?(token_headers, "x-private")
  end

  test "policy HTTP status failures do not expose response bodies or URLs", ctx do
    assert {:error, :http_error} = GenServer.start(HTTP,
      url: ctx.origin <> "/unexpected", origin_policy: private_policy(ctx.origin),
      headers: [{"authorization", "Bearer secret"}], timeout_ms: 2_000)
    assert [{:unexpected, _headers}] = events(ctx)
  end

  test "policy auth-required errors do not expose challenge metadata", ctx do
    Agent.update(ctx.store, &%{&1 | oauth: true})
    assert {:error, :auth_required} = GenServer.start(HTTP,
      url: ctx.origin <> "/mcp", origin_policy: private_policy(ctx.origin),
      timeout_ms: 2_000)
    assert Enum.map(events(ctx), &elem(&1, 0)) ==
      ["initialize", :metadata, :authorization_metadata]
  end


  defp private_policy(origin) do
    %{allowed_origins: [origin], approved_private_origins: [origin]}
  end

  defp oauth_opts(ctx) do
    [url: ctx.origin <> "/mcp", origin_policy: private_policy(ctx.origin), timeout_ms: 2_000,
      headers: [{"authorization", "Bearer original"}, {"x-private", "private-secret"}],
      oauth: [client_id: "client", client_secret: "client-secret", token_auth_method: :client_secret_basic]]
  end

  defp events(ctx), do: Agent.get(ctx.store, &Enum.reverse(&1.events))
end
