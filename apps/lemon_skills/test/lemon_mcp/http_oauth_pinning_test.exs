defmodule LemonMCP.HTTPOAuthPinningTest.Fixture do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    record(conn, request["method"])

    if get_req_header(conn, "authorization") == ["Bearer " <> config(conn).accepted_token] do
      case LemonMCP.TestSupport.FixtureServer.response_for(request, "OAuth Fixture") do
        nil -> send_resp(conn, 202, "")
        response -> json(conn, response)
      end
    else
      case config(conn).metadata_url do
        nil ->
          send_resp(conn, 401, "authorization required")

        metadata_url ->
          conn
          |> put_resp_header("www-authenticate", ~s|Bearer resource_metadata="#{metadata_url}"|)
          |> send_resp(401, "authorization required")
      end
    end
  end

  get "/metadata" do
    record(conn, :metadata)
    json(conn, config(conn).resource_metadata)
  end

  get "/.well-known/oauth-authorization-server/oauth" do
    record(conn, :authorization_metadata)
    config = config(conn)

    if config.self_issuer do
      self = "http://127.0.0.1:#{conn.port}/oauth"
      json(conn, %{"issuer" => self, "token_endpoint" => self <> "/token"})
    else
      json(conn, config.authorization_metadata)
    end
  end

  post "/oauth/token" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    record(conn, {:token, URI.decode_query(body)})

    json(conn, %{
      "access_token" => config(conn).issued_token,
      "refresh_token" => "fixture-refresh",
      "token_type" => "Bearer"
    })
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
    |> Plug.Conn.assign(:name, Keyword.fetch!(opts, :name))
    |> super(opts)
  end

  defp config(conn), do: Agent.get(conn.assigns.store, & &1)

  defp record(conn, event) do
    entry = {conn.assigns.name, event, Map.new(conn.req_headers)}
    Agent.update(conn.assigns.store, &%{&1 | events: [entry | &1.events]})
  end

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end
end

defmodule LemonMCP.HTTPOAuthPinningTest do
  # Discovery is server-supplied data: the client must bind it to the MCP URL
  # it was configured with, the issuer it requested and a validated token
  # endpoint before any client credential leaves the process.
  use ExUnit.Case, async: false

  alias LemonMCP.Client.HTTP

  @secret "client-secret-must-not-leak"

  setup do
    store = start_supervised!({Agent, fn -> %{events: []} end})
    port = listen(store, :primary, :primary)
    other_port = listen(store, :other, :other)
    origin = "http://127.0.0.1:#{port}"
    other = "http://127.0.0.1:#{other_port}"

    Agent.update(store, fn state ->
      Map.merge(state, %{
        metadata_url: origin <> "/metadata",
        accepted_token: "fixture-token",
        issued_token: "fixture-token",
        self_issuer: false,
        resource_metadata: %{
          "resource" => origin <> "/mcp",
          "authorization_servers" => [origin <> "/oauth"]
        },
        authorization_metadata: %{
          "issuer" => origin <> "/oauth",
          "token_endpoint" => origin <> "/oauth/token",
          "authorization_endpoint" => origin <> "/oauth/authorize"
        }
      })
    end)

    %{store: store, origin: origin, other: other}
  end

  describe "default (no allowedOrigins) client" do
    test "a loopback authorization server still authenticates and calls tools", ctx do
      client = start_supervised!({HTTP, client_opts(ctx)})

      assert {:ok, [%{"text" => "echo:ok"}]} =
               HTTP.call_tool(client, "echo", %{"message" => "ok"})

      assert [{:primary, {:token, form}}] = token_posts(ctx)
      assert form["resource"] == ctx.origin <> "/mcp"
      assert form["client_secret"] == @secret
    end

    test "authorization metadata naming a different issuer is rejected", ctx do
      put_as(ctx, "issuer", "https://attacker.example/oauth")

      assert {:error, :invalid_oauth_metadata} = start(ctx)
      assert token_posts(ctx) == []
    end

    test "authorization metadata without an issuer is rejected", ctx do
      Agent.update(
        ctx.store,
        &%{&1 | authorization_metadata: Map.delete(&1.authorization_metadata, "issuer")}
      )

      assert {:error, :invalid_oauth_metadata} = start(ctx)
      assert token_posts(ctx) == []
    end

    test "a protected-resource audience other than the configured URL is rejected", ctx do
      for resource <- [
            ctx.origin <> "/other",
            ctx.other <> "/mcp",
            "https://attacker.example/mcp"
          ] do
        reset(ctx)
        put_prm(ctx, "resource", resource)

        assert {:error, :invalid_oauth_metadata} = start(ctx)
        assert names(ctx) == [{:primary, "initialize"}, {:primary, :metadata}]
      end
    end

    test "protected-resource metadata without a resource is rejected", ctx do
      Agent.update(
        ctx.store,
        &%{&1 | resource_metadata: Map.delete(&1.resource_metadata, "resource")}
      )

      assert {:error, :invalid_oauth_metadata} = start(ctx)
      assert token_posts(ctx) == []
    end

    test "a token endpoint on another origin never receives the client secret", ctx do
      put_as(ctx, "token_endpoint", ctx.other <> "/oauth/token")

      assert {:error, :origin_not_allowed} = start(ctx)
      assert token_posts(ctx) == []
      refute Enum.any?(events(ctx), &(elem(&1, 0) == :other))
    end

    test "a cleartext non-loopback token endpoint is rejected before connecting", ctx do
      put_as(ctx, "issuer", "http://auth.lemon-test.invalid/oauth")
      put_prm(ctx, "authorization_servers", ["http://auth.lemon-test.invalid/oauth"])

      assert {:error, :insecure_oauth_endpoint} = start(ctx)
      assert names(ctx) == [{:primary, "initialize"}, {:primary, :metadata}]
    end

    test "a cleartext non-loopback metadata URL is never fetched", ctx do
      Agent.update(
        ctx.store,
        &%{&1 | metadata_url: "http://metadata.lemon-test.invalid/metadata"}
      )

      assert {:error, :insecure_oauth_endpoint} = start(ctx)
      assert names(ctx) == [{:primary, "initialize"}]
    end

    test "discovery cannot steer the client to a private address", ctx do
      # The MCP origin is the operator's loopback server; an issuer on a
      # private network address is neither that origin nor public.
      put_prm(ctx, "authorization_servers", ["https://10.0.0.1/oauth"])

      assert {:error, :destination_not_public} = start(ctx)
      assert token_posts(ctx) == []
    end

    test "a token endpoint from protected-resource metadata alone is never used", ctx do
      Agent.update(ctx.store, fn state ->
        %{
          state
          | resource_metadata: %{
              "resource" => ctx.origin <> "/mcp",
              "token_endpoint" => ctx.other <> "/oauth/token"
            }
        }
      end)

      assert {:error, {:auth_required, _metadata}} = start(ctx)
      assert token_posts(ctx) == []
    end

    test "a cached token endpoint is revalidated before refreshing", ctx do
      cached = %{
        refresh_token: "cached-refresh",
        issuer: ctx.origin <> "/oauth",
        client_id: "client",
        metadata: %{
          "resource" => ctx.origin <> "/mcp",
          "authorization_server_metadata" => [
            %{"issuer" => ctx.origin <> "/oauth", "token_endpoint" => ctx.other <> "/oauth/token"}
          ]
        }
      }

      # A bare challenge makes the client fall back to its cached metadata.
      Agent.update(ctx.store, &%{&1 | metadata_url: nil})

      assert {:error, :origin_not_allowed} =
               GenServer.start(
                 HTTP,
                 Keyword.put(client_opts(ctx), :oauth_token_loader, fn -> {:ok, cached} end)
               )

      assert token_posts(ctx) == []
    end

    test "forged authorization-server records in protected-resource JSON are ignored", ctx do
      forged = [
        %{"issuer" => ctx.other <> "/oauth", "token_endpoint" => ctx.other <> "/oauth/token"}
      ]

      Agent.update(ctx.store, fn state ->
        %{
          state
          | resource_metadata: %{
              "resource" => ctx.origin <> "/mcp",
              "authorization_server_metadata" => forged
            }
        }
      end)

      assert {:error, {:auth_required, metadata}} = start(ctx)
      refute Map.has_key?(metadata, "authorization_server_metadata")
      assert token_posts(ctx) == []

      # Alongside a real issuer, only validated discovery supplies records.
      reset(ctx)
      put_prm(ctx, "authorization_servers", [ctx.origin <> "/oauth"])
      client = start_supervised!({HTTP, client_opts(ctx)})
      assert {:ok, _tools} = HTTP.list_tools(client)
      assert [{:primary, {:token, _form}}] = token_posts(ctx)
    end

    test "a cached grant from another issuer is never refreshed or replaced", ctx do
      cached = %{
        refresh_token: "cached-refresh",
        issuer: ctx.other <> "/oauth",
        client_id: "client"
      }

      assert {:error, :oauth_issuer_changed} =
               GenServer.start(
                 HTTP,
                 Keyword.put(client_opts(ctx), :oauth_token_loader, fn -> {:ok, cached} end)
               )

      assert token_posts(ctx) == []
    end

    test "unbound or foreign-client cached refresh tokens are never sent", ctx do
      for cached <- [
            %{refresh_token: "cached-refresh"},
            %{refresh_token: "cached-refresh", issuer: ctx.origin <> "/oauth"},
            %{refresh_token: "cached-refresh", issuer: ctx.origin <> "/oauth", client_id: "x"}
          ] do
        reset(ctx)
        opts = Keyword.put(client_opts(ctx), :oauth_token_loader, fn -> {:ok, cached} end)
        assert {:ok, pid} = GenServer.start(HTTP, opts)
        GenServer.stop(pid)

        assert [{:primary, {:token, form}}] = token_posts(ctx)
        assert form["grant_type"] == "client_credentials"
        refute Map.has_key?(form, "refresh_token")
      end
    end

    test "a live session never moves its credentials to a new issuer", ctx do
      client = start_supervised!({HTTP, client_opts(ctx)})
      assert {:ok, _tools} = HTTP.list_tools(client)
      reset(ctx)
      switch_issuer(ctx)

      assert {:error, :oauth_issuer_changed} = HTTP.list_tools(client)
      assert token_posts(ctx) == []
    end

    test "a persisted grant never moves to a new issuer", ctx do
      parent = self()

      persist = fn payload ->
        send(parent, {:saved, payload})
        :ok
      end

      {:ok, pid} =
        GenServer.start(HTTP, Keyword.put(client_opts(ctx), :oauth_token_persister, persist))

      GenServer.stop(pid)
      assert_received {:saved, saved}
      assert saved.issuer == ctx.origin <> "/oauth"
      assert saved.client_id == "client"
      assert saved.refresh_token == "fixture-refresh"

      reset(ctx)
      switch_issuer(ctx)

      assert {:error, :oauth_issuer_changed} =
               GenServer.start(
                 HTTP,
                 Keyword.put(client_opts(ctx), :oauth_token_loader, fn -> {:ok, saved} end)
               )

      assert token_posts(ctx) == []
    end
  end

  describe "operator issuer binding" do
    test "a configured refresh token without oauth.issuer is a configuration error", ctx do
      oauth = [client_id: "client", client_secret: @secret, refresh_token: "configured-refresh"]

      assert {:error, :oauth_issuer_required} = start(ctx, oauth: oauth)
      assert events(ctx) == []
    end

    test "configured credentials never follow attacker-selected discovery", ctx do
      switch_issuer(ctx)

      oauth = [
        client_id: "client",
        client_secret: @secret,
        refresh_token: "configured-refresh",
        issuer: ctx.origin <> "/oauth"
      ]

      assert {:error, :oauth_issuer_mismatch} = start(ctx, oauth: oauth)
      assert token_posts(ctx) == []

      # Without a configured issuer, a client secret never goes off-origin.
      reset(ctx)
      oauth = [client_id: "client", client_secret: @secret]
      assert {:error, :oauth_issuer_required} = start(ctx, oauth: oauth)
      assert token_posts(ctx) == []
    end

    test "a configured issuer authenticates with the configured refresh token", ctx do
      oauth = [
        client_id: "client",
        client_secret: @secret,
        refresh_token: "configured-refresh",
        issuer: ctx.origin <> "/oauth"
      ]

      client = start_supervised!({HTTP, client_opts(ctx, oauth: oauth)})
      assert {:ok, _tools} = HTTP.list_tools(client)
      assert [{:primary, {:token, form}}] = token_posts(ctx)
      assert form["grant_type"] == "refresh_token"
      assert form["refresh_token"] == "configured-refresh"
    end

    test "a configured off-origin issuer may receive the client secret", ctx do
      switch_issuer(ctx)
      Agent.update(ctx.store, &%{&1 | issued_token: "rotated-token"})
      oauth = [client_id: "client", client_secret: @secret, issuer: ctx.other <> "/oauth"]

      client = start_supervised!({HTTP, client_opts(ctx, oauth: oauth)})
      assert {:ok, _tools} = HTTP.list_tools(client)
      assert [{:other, {:token, _form}}] = token_posts(ctx)
    end
  end

  describe "explicit allowedOrigins policy" do
    test "a token endpoint on another origin works only when allowlisted", ctx do
      put_as(ctx, "token_endpoint", ctx.other <> "/oauth/token")

      assert {:error, :origin_not_allowed} =
               start(ctx, origin_policy: private_policy([ctx.origin]))

      assert token_posts(ctx) == []
      reset(ctx)

      client =
        start_supervised!(
          {HTTP, client_opts(ctx, origin_policy: private_policy([ctx.origin, ctx.other]))}
        )

      assert {:ok, _tools} = HTTP.list_tools(client)
      assert [{:other, {:token, _form}}] = token_posts(ctx)
    end

    test "an allowlisted cleartext DNS origin is still not used for OAuth", ctx do
      port = URI.parse(ctx.origin).port
      named = "http://localhost:#{port}"
      Agent.update(ctx.store, &%{&1 | metadata_url: named <> "/metadata"})

      assert {:error, :insecure_oauth_endpoint} =
               start(ctx, origin_policy: private_policy([ctx.origin, named]))

      assert names(ctx) == [{:primary, "initialize"}]
    end

    test "issuer and resource are still bound under a policy", ctx do
      put_as(ctx, "issuer", ctx.other <> "/oauth")

      assert {:error, :invalid_oauth_metadata} =
               start(ctx, origin_policy: private_policy([ctx.origin]))

      reset(ctx)
      put_as(ctx, "issuer", ctx.origin <> "/oauth")
      put_prm(ctx, "resource", ctx.origin <> "/elsewhere")

      assert {:error, :invalid_oauth_metadata} =
               start(ctx, origin_policy: private_policy([ctx.origin]))

      assert token_posts(ctx) == []
    end

    test "an unallowlisted authorization endpoint never reaches the provider", ctx do
      port = URI.parse(ctx.origin).port
      put_as(ctx, "authorization_endpoint", "http://127.0.0.3:#{port}/oauth/authorize")
      parent = self()

      opts =
        client_opts(ctx,
          origin_policy: private_policy([ctx.origin]),
          oauth: [
            client_id: "public",
            authorization_code_provider: fn request -> send(parent, {:provider, request}) end
          ]
        )

      assert {:error, :origin_not_allowed} = GenServer.start(HTTP, opts)
      refute_received {:provider, _}
      assert token_posts(ctx) == []
    end

    test "lemon_skills never exposes an unallowlisted authorization URL", ctx do
      port = URI.parse(ctx.origin).port
      put_as(ctx, "authorization_endpoint", "http://127.0.0.3:#{port}/oauth/authorize")
      run_id = "mcp_oauth_policy_#{System.unique_integer([:positive])}"
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, callback_port} = :inet.port(socket)
      :gen_tcp.close(socket)
      previous = Application.get_env(:lemon_skills, :mcp_servers)
      previous_disabled = Application.get_env(:lemon_skills, :mcp_disabled)

      on_exit(fn ->
        restore_env(:mcp_servers, previous)
        restore_env(:mcp_disabled, previous_disabled)
        if Process.whereis(LemonSkills.McpSource), do: LemonSkills.McpSource.refresh()
      end)

      Application.put_env(:lemon_skills, :mcp_disabled, false)

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:http, ctx.origin <> "/mcp",
         origin_policy: private_policy([ctx.origin]),
         oauth: [
           flow: :authorization_code_pkce,
           client_id: "lemon-public",
           redirect_uri: "http://127.0.0.1:#{callback_port}/callback",
           authorization_timeout_ms: 2_000,
           authorization_request_observer: self(),
           authorization_approval_context: [
             run_id: run_id,
             session_key: "agent:mcp-oauth-policy:main",
             agent_id: "mcp-oauth-policy"
           ]
         ]}
      ])

      ExUnit.CaptureLog.capture_log(fn ->
        LemonSkills.McpSource.discover_tools(force_refresh: true)
      end)

      assert {:primary, :authorization_metadata} in names(ctx)
      refute_received {:mcp_oauth_authorization_request, _}

      refute Enum.any?(LemonCore.ExecApprovalStore.list_pending(), fn {_id, pending} ->
               pending.run_id == run_id
             end)

      assert token_posts(ctx) == []
    end
  end

  defp listen(store, name, id) do
    listener =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {LemonMCP.HTTPOAuthPinningTest.Fixture, store: store, name: name},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0},
          id: id
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    port
  end

  defp client_opts(ctx, extra \\ []) do
    [
      url: ctx.origin <> "/mcp",
      timeout_ms: 2_000,
      oauth: [client_id: "client", client_secret: @secret]
    ]
    |> Keyword.merge(extra)
  end

  defp start(ctx, extra \\ []), do: GenServer.start(HTTP, client_opts(ctx, extra))

  defp private_policy(origins), do: %{allowed_origins: origins, approved_private_origins: origins}

  defp put_as(ctx, key, value),
    do:
      Agent.update(
        ctx.store,
        &%{&1 | authorization_metadata: Map.put(&1.authorization_metadata, key, value)}
      )

  defp put_prm(ctx, key, value),
    do:
      Agent.update(
        ctx.store,
        &%{&1 | resource_metadata: Map.put(&1.resource_metadata, key, value)}
      )

  defp switch_issuer(ctx) do
    Agent.update(ctx.store, fn state ->
      %{
        state
        | accepted_token: "rotated-token",
          self_issuer: true,
          resource_metadata: %{
            "resource" => ctx.origin <> "/mcp",
            "authorization_servers" => [ctx.other <> "/oauth"]
          }
      }
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_skills, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_skills, key, value)

  defp reset(ctx), do: Agent.update(ctx.store, &%{&1 | events: []})

  defp events(ctx), do: Agent.get(ctx.store, &Enum.reverse(&1.events))

  defp names(ctx), do: Enum.map(events(ctx), fn {name, event, _} -> {name, event} end)

  defp token_posts(ctx) do
    for {name, {:token, _} = event, _headers} <- events(ctx), do: {name, event}
  end
end
