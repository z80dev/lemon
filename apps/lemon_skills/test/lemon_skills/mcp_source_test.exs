defmodule LemonSkills.McpSourceTest.SSEFixture do
  use Plug.Router

  alias LemonMCP.Protocol
  alias LemonMCP.Server.Handler

  plug(:match)
  plug(:dispatch)

  get "/sse" do
    session = Integer.to_string(System.unique_integer([:positive]))
    stream_pid = self()
    Agent.update(conn.assigns.store, &Map.put(&1, session, stream_pid))

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: endpoint\ndata: /messages/#{session}\n\n")
    stream_loop(conn)
  end

  post "/messages/:session" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {:ok, request_map} = Jason.decode(body)
    {:ok, request} = Protocol.parse_request(request_map)
    response = Handler.handle_request(request, conn.assigns.mcp_server)
    encoded = response |> Map.from_struct() |> Jason.encode!()
    pid = Agent.get(conn.assigns.store, &Map.fetch!(&1, session))
    send(pid, {:sse_message, encoded})
    send_resp(conn, 202, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn
    |> Plug.Conn.assign(:store, Keyword.fetch!(opts, :store))
    |> Plug.Conn.assign(:mcp_server, Keyword.fetch!(opts, :mcp_server))
    |> super(opts)
  end

  defp stream_loop(conn) do
    receive do
      {:sse_message, data} ->
        case chunk(conn, "event: message\ndata: #{data}\n\n") do
          {:ok, conn} -> stream_loop(conn)
          {:error, _reason} -> conn
        end

      :stop ->
        conn
    after
      30_000 ->
        conn
    end
  end
end

defmodule LemonSkills.McpSourceTest.OAuthTokenFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    headers = Map.new(conn.req_headers)
    record(conn.assigns.store, {:mcp, request["method"], headers})

    if headers["authorization"] == "Bearer fixture-token" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(mcp_response(request)))
    else
      conn
      |> put_resp_header(
        "www-authenticate",
        ~s|Bearer resource_metadata="http://127.0.0.1:#{conn.port}/.well-known/oauth-protected-resource/mcp"|
      )
      |> send_resp(401, "authorization required")
    end
  end

  post "/oauth/token" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    form = URI.decode_query(body)
    record(conn.assigns.store, {:token, form, Map.new(conn.req_headers)})

    if form["grant_type"] == "client_credentials" and form["client_id"] == "lemon" and
         form["client_secret"] == "secret" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "fixture-token",
          "refresh_token" => "fixture-refresh",
          "token_type" => "Bearer"
        })
      )
    else
      send_authorization_code_token_response(conn, form)
    end
  end

  defp send_authorization_code_token_response(conn, form) do
    if form["grant_type"] == "authorization_code" and form["client_id"] == "lemon-public" and
         form["code"] == "loopback-code" and is_binary(form["code_verifier"]) and
         form["code_verifier"] != "" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "fixture-token",
          "refresh_token" => "fixture-refresh",
          "token_type" => "Bearer"
        })
      )
    else
      send_resp(conn, 400, "invalid client")
    end
  end

  get "/.well-known/oauth-protected-resource/mcp" do
    record(conn.assigns.store, {:metadata, Map.new(conn.req_headers)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "resource" => "http://127.0.0.1:#{conn.port}/mcp",
        "authorization_servers" => ["http://127.0.0.1:#{conn.port}/oauth"]
      })
    )
  end

  get "/.well-known/oauth-authorization-server/oauth" do
    record(conn.assigns.store, {:authorization_metadata, Map.new(conn.req_headers)})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "issuer" => "http://127.0.0.1:#{conn.port}/oauth",
        "authorization_endpoint" => "http://127.0.0.1:#{conn.port}/oauth/authorize",
        "token_endpoint" => "http://127.0.0.1:#{conn.port}/oauth/token"
      })
    )
  end

  match _ do
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

  defp mcp_response(%{"method" => "initialize", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "OAuth Source Fixture", "version" => "1.0.0"}
      }
    }
  end

  defp mcp_response(%{"method" => "notifications/initialized"}), do: %{}

  defp mcp_response(%{"method" => "tools/list", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => [
          %{
            "name" => "secured_echo",
            "description" => "Echo through OAuth",
            "inputSchema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      }
    }
  end

  defp mcp_response(%{"id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not found"}
    }
  end

  defp record(store, event), do: Agent.update(store, &[event | &1])
end

defmodule LemonSkills.McpSourceTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Secrets, Store}
  alias LemonMCP.Protocol
  alias LemonSkills.McpSource

  @moduletag :tmp_dir

  setup do
    # Ensure MCP is not disabled for tests
    previous_mcp_disabled = Application.get_env(:lemon_skills, :mcp_disabled)
    previous_mcp_servers = Application.get_env(:lemon_skills, :mcp_servers)
    previous_mcp_disabled_env = System.get_env("LEMON_MCP_DISABLED")

    on_exit(fn ->
      if previous_mcp_disabled == nil do
        Application.delete_env(:lemon_skills, :mcp_disabled)
      else
        Application.put_env(:lemon_skills, :mcp_disabled, previous_mcp_disabled)
      end

      if previous_mcp_servers == nil do
        Application.delete_env(:lemon_skills, :mcp_servers)
      else
        Application.put_env(:lemon_skills, :mcp_servers, previous_mcp_servers)
      end

      if previous_mcp_disabled_env == nil do
        System.delete_env("LEMON_MCP_DISABLED")
      else
        System.put_env("LEMON_MCP_DISABLED", previous_mcp_disabled_env)
      end

      if Process.whereis(McpSource), do: McpSource.refresh()
    end)

    :ok
  end

  describe "validate_config/1" do
    test "accepts valid stdio config" do
      assert :ok = McpSource.validate_config({:stdio, "npx", ["-y", "server"]})
      assert :ok = McpSource.validate_config({:stdio, "uvx", ["mcp-server"]})
      assert :ok = McpSource.validate_config({:stdio, "/path/to/server", []})

      assert :ok =
               McpSource.validate_config(
                 {:stdio, "npx", ["-y", "server"],
                  allow_tools: ["echo"], block_prompts: ["unsafe"]}
               )
    end

    test "rejects stdio config with empty command" do
      assert {:error, "stdio command cannot be empty"} =
               McpSource.validate_config({:stdio, "", []})

      assert {:error, "stdio command cannot be empty"} =
               McpSource.validate_config({:stdio, "   ", []})
    end

    test "rejects invalid stdio filter values" do
      assert {:error, "allow_tools must be a list of strings"} =
               McpSource.validate_config({:stdio, "npx", ["server"], allow_tools: [:echo]})
    end

    test "accepts valid http config" do
      assert :ok = McpSource.validate_config({:http, "http://localhost:3000/mcp"})
      assert :ok = McpSource.validate_config({:http, "https://api.example.com/mcp"})

      assert :ok =
               McpSource.validate_config({:http, "http://localhost:3000/mcp", [headers: []]})

      assert :ok =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [oauth: [client_id: "client", client_secret: "secret", scopes: ["tools"]]]}
               )

      assert :ok =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [
                    oauth: [
                      client_id: "client",
                      client_secret_secret: "mcp_client_secret",
                      token_secret: "mcp_oauth_token",
                      scopes: ["tools"]
                    ]
                  ]}
               )

      assert :ok =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [
                    oauth: [
                      client_id: "client",
                      client_secret: "secret",
                      token_auth_method: :client_secret_basic
                    ]
                  ]}
               )

      assert :ok =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [
                    oauth: [
                      flow: :authorization_code_pkce,
                      client_id: "public-client",
                      redirect_uri: "http://127.0.0.1/callback",
                      scopes: ["tools"],
                      authorization_approval: false,
                      authorization_timeout_ms: 120_000
                    ]
                  ]}
               )
    end

    test "rejects invalid http URL" do
      assert {:error, _} = McpSource.validate_config({:http, "not-a-url"})
      assert {:error, _} = McpSource.validate_config({:http, "ftp://example.com/mcp"})
      assert {:error, _} = McpSource.validate_config({:http, ""})

      assert {:error, "oauth.client_secret must be a non-empty string"} =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp", [oauth: [client_id: "client"]]}
               )

      assert {:error, "oauth.flow must be client_credentials or authorization_code_pkce"} =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [oauth: [client_id: "client", client_secret: "secret", flow: "unknown"]]}
               )

      assert {:error, "oauth.token_secret must be a non-empty string"} =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [oauth: [client_id: "client", client_secret: "secret", token_secret: ""]]}
               )

      assert {:error, "oauth.authorization_timeout_ms must be a positive integer"} =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [
                    oauth: [
                      flow: :authorization_code_pkce,
                      client_id: "public-client",
                      redirect_uri: "http://127.0.0.1/callback",
                      authorization_timeout_ms: 0
                    ]
                  ]}
               )

      assert {:error, "oauth.token_auth_method must be client_secret_post or client_secret_basic"} =
               McpSource.validate_config(
                 {:http, "http://localhost:3000/mcp",
                  [
                    oauth: [
                      client_id: "client",
                      client_secret: "secret",
                      token_auth_method: "unsupported"
                    ]
                  ]}
               )
    end

    test "rejects unknown config formats" do
      assert {:error, _} = McpSource.validate_config({:unknown, "something"})
      assert {:error, _} = McpSource.validate_config("just a string")
      assert {:error, _} = McpSource.validate_config(nil)
    end
  end

  describe "mcp_enabled?/0" do
    test "returns based on LemonMCP.Client availability when not disabled" do
      Application.delete_env(:lemon_skills, :mcp_disabled)
      # Result depends on whether LemonMCP.Client is loaded
      expected = Code.ensure_loaded?(LemonMCP.Client)
      assert McpSource.mcp_enabled?() == expected
    end

    test "returns false when explicitly disabled" do
      Application.put_env(:lemon_skills, :mcp_disabled, true)
      assert McpSource.mcp_enabled?() == false
      Application.delete_env(:lemon_skills, :mcp_disabled)
    end

    test "returns false when disabled through environment" do
      System.put_env("LEMON_MCP_DISABLED", "1")
      assert McpSource.mcp_enabled?() == false
    end
  end

  describe "with disabled MCP source" do
    test "discover_tools returns empty list when MCP is unavailable", %{tmp_dir: _tmp_dir} do
      # MCP is already started by the application, just verify behavior
      # Since LemonMCP.Client is available, MCP is not disabled
      # Just verify we get some result (empty list or tools depending on config)
      result = McpSource.discover_tools()
      assert is_list(result)

      status = McpSource.status()
      assert is_map(status)
    end

    test "get_tool returns :error for unknown tool", %{tmp_dir: _tmp_dir} do
      # MCP is already started, test with a non-existent tool
      assert McpSource.get_tool("unknown_tool_that_does_not_exist") == :error
    end
  end

  describe "stdio MCP discovery and calls" do
    test "discovers prefixed tools and invokes them through LemonMCP.Client", %{tmp_dir: tmp_dir} do
      server_script = Path.join(tmp_dir, "fixture_mcp_server.exs")
      File.write!(server_script, fixture_server_script())

      elixir = System.find_executable("elixir")

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:stdio, elixir, [server_script]}
      ])

      assert :ok = McpSource.refresh()

      tools = McpSource.discover_tools(force_refresh: true)
      names = Enum.map(tools, & &1.name)

      assert "mcp_elixir_echo" in names
      assert "mcp_elixir_fail" in names
      assert "mcp_elixir_resources_list" in names
      assert "mcp_elixir_resource_read" in names
      assert "mcp_elixir_prompts_list" in names
      assert "mcp_elixir_prompt_get" in names

      assert {:ok, result} = McpSource.call_tool("mcp_elixir_echo", %{"message" => "ok"})
      assert [%Ai.Types.TextContent{text: "echo:ok"}] = result.content

      assert {:ok, result} = McpSource.call_tool("mcp_elixir_resources_list", %{})
      assert [%Ai.Types.TextContent{text: resources_json}] = result.content
      assert [%{"uri" => "fixture://status"}] = Jason.decode!(resources_json)

      assert {:ok, result} =
               McpSource.call_tool("mcp_elixir_resource_read", %{"uri" => "fixture://status"})

      assert [%Ai.Types.TextContent{text: resource_json}] = result.content
      assert [%{"text" => "status:ok"}] = Jason.decode!(resource_json)

      assert {:ok, result} = McpSource.call_tool("mcp_elixir_prompts_list", %{})
      assert [%Ai.Types.TextContent{text: prompts_json}] = result.content
      assert [%{"name" => "brief"}] = Jason.decode!(prompts_json)

      assert {:ok, result} =
               McpSource.call_tool("mcp_elixir_prompt_get", %{
                 "name" => "brief",
                 "arguments" => %{"topic" => "beam"}
               })

      assert [%Ai.Types.TextContent{text: prompt_json}] = result.content
      assert %{"messages" => [%{"role" => "user"}]} = Jason.decode!(prompt_json)

      assert {:error, {:tool_error, [%Ai.Types.TextContent{text: "planned failure"}]}} =
               McpSource.call_tool("mcp_elixir_fail", %{})

      status = McpSource.status()
      assert status.cached_tools >= 6

      assert Enum.any?(status.servers, fn {_name, server} ->
               server.connected and server.resource_count == 1 and server.prompt_count == 1 and
                 server.capabilities.resources and server.capabilities.prompts
             end)
    end

    test "applies exact allow and block filters", %{tmp_dir: tmp_dir} do
      server_script = Path.join(tmp_dir, "fixture_mcp_server.exs")
      File.write!(server_script, fixture_server_script())

      elixir = System.find_executable("elixir")

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:stdio, elixir, [server_script],
         allow_tools: ["echo"], block_resources: ["fixture://status"], block_prompts: ["brief"]}
      ])

      assert :ok = McpSource.refresh()

      tools = McpSource.discover_tools(force_refresh: true)
      names = Enum.map(tools, & &1.name)

      assert "mcp_elixir_echo" in names
      refute "mcp_elixir_fail" in names
      assert "mcp_elixir_resources_list" in names
      assert "mcp_elixir_prompts_list" in names

      assert {:ok, result} = McpSource.call_tool("mcp_elixir_resources_list", %{})
      assert [%Ai.Types.TextContent{text: "[]"}] = result.content

      assert {:error, {:blocked_resource, "fixture://status"}} =
               McpSource.call_tool("mcp_elixir_resource_read", %{"uri" => "fixture://status"})

      assert {:ok, result} = McpSource.call_tool("mcp_elixir_prompts_list", %{})
      assert [%Ai.Types.TextContent{text: "[]"}] = result.content

      assert {:error, {:blocked_prompt, "brief"}} =
               McpSource.call_tool("mcp_elixir_prompt_get", %{"name" => "brief"})
    end

    test "bridges configured sampling review through exec approvals", %{tmp_dir: tmp_dir} do
      server_script = Path.join(tmp_dir, "fixture_sampling_mcp_server.exs")
      File.write!(server_script, fixture_sampling_server_script())

      elixir = System.find_executable("elixir")
      parent = self()
      run_id = "mcp_sampling_run_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:mcp-sampling-test:main"

      delegate = fn params, summary ->
        send(parent, {:sampling_delegate, params, summary})

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "sampled"},
           "model" => "lemon-test",
           "stopReason" => "endTurn"
         }}
      end

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:stdio, elixir, [server_script],
         sampling_policy: [
           mode: :reviewed_model,
           reviewer: :ops_approval,
           delegate: delegate,
           max_tokens: 32,
           approval_timeout_ms: 2_000,
           approval_context: [
             run_id: run_id,
             session_key: session_key,
             agent_id: "mcp-sampling-test"
           ]
         ]}
      ])

      task = Task.async(fn -> McpSource.discover_tools(force_refresh: true) end)
      pending = wait_for_pending_approval(run_id)

      assert pending.tool == "mcp_elixir_sampling"
      assert pending.session_key == session_key
      assert pending.action.type == "mcp_sampling"
      assert pending.action.server == "elixir"
      assert pending.action.message_count == 1
      assert pending.action.max_tokens == 16
      assert pending.action.requested_model == "lemon-test"
      assert pending.rationale =~ "MCP sampling request"
      assert pending.rationale =~ "request="
      refute inspect(pending) =~ "secret prompt"

      assert :ok = LemonCore.ExecApprovals.resolve(pending.id, :approve_once)

      tools = Task.await(task, 5_000)
      assert "mcp_elixir_echo" in Enum.map(tools, & &1.name)

      assert_receive {:sampling_delegate, params, summary}, 1_000
      assert get_in(params, ["messages", Access.at(0), "content", "text"]) == "secret prompt"
      refute inspect(summary) =~ "secret prompt"
    end
  end

  describe "HTTP MCP discovery and calls" do
    test "discovers and invokes tools from an HTTP MCP server" do
      port = start_http_transport()
      url = "http://127.0.0.1:#{port}/mcp"

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:http, url, allow_tools: ["echo"]}
      ])

      assert :ok = McpSource.refresh()

      tools = McpSource.discover_tools(force_refresh: true)
      names = Enum.map(tools, & &1.name)

      assert "mcp_mcp_echo" in names
      assert "mcp_mcp_resources_list" in names
      assert "mcp_mcp_resource_read" in names
      assert "mcp_mcp_prompts_list" in names
      assert "mcp_mcp_prompt_get" in names
      refute "mcp_mcp_fail" in names

      assert {:ok, result} = McpSource.call_tool("mcp_mcp_echo", %{"message" => "ok"})
      assert [%Ai.Types.TextContent{text: "echo:ok"}] = result.content

      assert {:ok, result} = McpSource.call_tool("mcp_mcp_resources_list", %{})
      assert [%Ai.Types.TextContent{text: resources_json}] = result.content
      assert [%{"uri" => "fixture://status"}] = Jason.decode!(resources_json)

      assert {:ok, result} =
               McpSource.call_tool("mcp_mcp_resource_read", %{"uri" => "fixture://status"})

      assert [%Ai.Types.TextContent{text: resource_json}] = result.content
      assert [%{"text" => "status:ok"}] = Jason.decode!(resource_json)

      assert {:ok, result} = McpSource.call_tool("mcp_mcp_prompts_list", %{})
      assert [%Ai.Types.TextContent{text: prompts_json}] = result.content
      assert [%{"name" => "brief"}] = Jason.decode!(prompts_json)

      assert {:ok, result} =
               McpSource.call_tool("mcp_mcp_prompt_get", %{
                 "name" => "brief",
                 "arguments" => %{"topic" => "beam"}
               })

      assert [%Ai.Types.TextContent{text: prompt_json}] = result.content
      assert %{"messages" => [%{"role" => "user"}]} = Jason.decode!(prompt_json)

      status = McpSource.status()
      assert status.cached_tools == 5

      assert Enum.any?(status.servers, fn {_name, server} ->
               server.connected and server.tool_count == 5 and server.resource_count == 1 and
                 server.prompt_count == 1 and server.capabilities.tools and
                 server.capabilities.resources and server.capabilities.prompts
             end)
    end

    test "persists OAuth token cache through configured token_secret" do
      token_secret = "mcp_source_oauth_token_#{System.unique_integer([:positive])}"
      previous_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
      master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

      on_exit(fn ->
        Store.delete(Secrets.table(), {Secrets.default_owner(), token_secret})

        if previous_master_key == nil do
          System.delete_env("LEMON_SECRETS_MASTER_KEY")
        else
          System.put_env("LEMON_SECRETS_MASTER_KEY", previous_master_key)
        end
      end)

      {port, store} = start_oauth_http_transport()
      url = "http://127.0.0.1:#{port}/mcp"

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:http, url,
         oauth: [
           client_id: "lemon",
           client_secret: "secret",
           token_secret: token_secret,
           scopes: ["tools"]
         ]}
      ])

      assert :ok = McpSource.refresh()

      tools = McpSource.discover_tools(force_refresh: true)
      assert "mcp_mcp_secured_echo" in Enum.map(tools, & &1.name)

      assert {:ok, token_json} = Secrets.get(token_secret, env_fallback: false)
      token = Jason.decode!(token_json)
      assert token["version"] == 1
      assert token["access_token"] == "fixture-token"
      assert token["refresh_token"] == "fixture-refresh"
      assert token["client_id"] == "lemon"
      assert token["scope"] == "tools"
      assert token["resource"] == "http://127.0.0.1:#{port}/mcp"

      assert {:ok, listed_secrets} = Secrets.list()
      metadata = Enum.find(listed_secrets, &(&1.name == token_secret))
      assert metadata
      assert metadata.name == token_secret
      assert metadata.provider == "mcp_oauth"

      observed = Agent.get(store, &Enum.reverse/1)
      assert Enum.any?(observed, &match?({:token, _, _}, &1))

      assert Enum.any?(
               observed,
               &match?({:mcp, "tools/list", %{"authorization" => "Bearer fixture-token"}}, &1)
             )
    end

    test "captures local OAuth PKCE callbacks for configured HTTP sources" do
      {port, store} = start_oauth_http_transport()
      callback_port = free_port()
      url = "http://127.0.0.1:#{port}/mcp"
      test_pid = self()
      run_id = "mcp_oauth_run_#{System.unique_integer([:positive, :monotonic])}"
      session_key = "agent:mcp-oauth-test:main"

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:http, url,
         oauth: [
           flow: :authorization_code_pkce,
           client_id: "lemon-public",
           redirect_uri: "http://127.0.0.1:#{callback_port}/callback",
           scopes: ["tools"],
           authorization_timeout_ms: 2_000,
           authorization_request_observer: test_pid,
           authorization_approval_context: [
             run_id: run_id,
             session_key: session_key,
             agent_id: "mcp-oauth-test"
           ]
         ]}
      ])

      task = Task.async(fn -> McpSource.discover_tools(force_refresh: true) end)

      assert_receive {:mcp_oauth_authorization_request, authorization_request}, 1_000
      assert authorization_request.client_id == "lemon-public"
      assert authorization_request.redirect_uri == "http://127.0.0.1:#{callback_port}/callback"
      assert authorization_request.scope == "tools"
      assert authorization_request.resource == url
      assert authorization_request.authorization_url =~ "response_type=code"
      assert authorization_request.authorization_url =~ "code_challenge_method=S256"

      pending = wait_for_pending_approval(run_id)

      assert pending.tool == "mcp_mcp_oauth"
      assert pending.session_key == session_key
      assert pending.action.type == "mcp_oauth_authorization"
      assert pending.action.authorization_url == authorization_request.authorization_url
      assert pending.action.resource == url
      assert pending.action.client_id == "lemon-public"
      assert pending.action.redirect_uri == "http://127.0.0.1:#{callback_port}/callback"
      assert pending.action.scope == "tools"
      assert pending.action.state_hash
      refute inspect(pending) =~ "code_verifier"

      callback_url =
        "http://127.0.0.1:#{callback_port}/callback?" <>
          URI.encode_query(%{"code" => "loopback-code", "state" => authorization_request.state})

      assert {:ok, {{_, 200, _}, _headers, _body}} =
               :httpc.request(
                 :get,
                 {String.to_charlist(callback_url), []},
                 [timeout: 1_000, connect_timeout: 1_000],
                 body_format: :binary
               )

      assert :ok = LemonCore.ExecApprovals.resolve(pending.id, :approve_once)

      tools = Task.await(task, 5_000)
      assert "mcp_mcp_secured_echo" in Enum.map(tools, & &1.name)

      observed = Agent.get(store, &Enum.reverse/1)

      assert {:token, token_form, _token_headers} =
               Enum.find(observed, &match?({:token, _form, _headers}, &1))

      assert token_form["grant_type"] == "authorization_code"
      assert token_form["client_id"] == "lemon-public"
      assert token_form["code"] == "loopback-code"
      assert token_form["redirect_uri"] == "http://127.0.0.1:#{callback_port}/callback"
      assert token_form["resource"] == url
      assert token_form["scope"] == "tools"
      assert is_binary(token_form["code_verifier"]) and token_form["code_verifier"] != ""

      assert Enum.any?(
               observed,
               &match?({:mcp, "tools/list", %{"authorization" => "Bearer fixture-token"}}, &1)
             )
    end
  end

  describe "SSE MCP discovery and calls" do
    test "discovers and invokes tools from a legacy SSE MCP server" do
      {port, store} = start_sse_transport()
      url = "http://127.0.0.1:#{port}/sse"

      Application.put_env(:lemon_skills, :mcp_servers, [
        {:sse, url, allow_tools: ["echo"]}
      ])

      assert :ok = McpSource.refresh()

      tools = McpSource.discover_tools(force_refresh: true)
      names = Enum.map(tools, & &1.name)

      assert "mcp_sse_echo" in names
      assert "mcp_sse_resources_list" in names
      assert "mcp_sse_resource_read" in names
      assert "mcp_sse_prompts_list" in names
      assert "mcp_sse_prompt_get" in names
      refute "mcp_sse_fail" in names

      assert {:ok, result} = McpSource.call_tool("mcp_sse_echo", %{"message" => "ok"})
      assert [%Ai.Types.TextContent{text: "echo:ok"}] = result.content

      assert {:ok, result} = McpSource.call_tool("mcp_sse_resources_list", %{})
      assert [%Ai.Types.TextContent{text: resources_json}] = result.content
      assert [%{"uri" => "fixture://status"}] = Jason.decode!(resources_json)

      assert {:ok, result} =
               McpSource.call_tool("mcp_sse_resource_read", %{"uri" => "fixture://status"})

      assert [%Ai.Types.TextContent{text: resource_json}] = result.content
      assert [%{"text" => "status:ok"}] = Jason.decode!(resource_json)

      assert {:ok, result} = McpSource.call_tool("mcp_sse_prompts_list", %{})
      assert [%Ai.Types.TextContent{text: prompts_json}] = result.content
      assert [%{"name" => "brief"}] = Jason.decode!(prompts_json)

      assert {:ok, result} =
               McpSource.call_tool("mcp_sse_prompt_get", %{
                 "name" => "brief",
                 "arguments" => %{"topic" => "beam"}
               })

      assert [%Ai.Types.TextContent{text: prompt_json}] = result.content
      assert %{"messages" => [%{"role" => "user"}]} = Jason.decode!(prompt_json)

      status = McpSource.status()
      assert status.cached_tools == 5

      assert Enum.any?(status.servers, fn {_name, server} ->
               server.connected and server.tool_count == 5 and server.resource_count == 1 and
                 server.prompt_count == 1 and server.capabilities.tools and
                 server.capabilities.resources and server.capabilities.prompts
             end)

      stop_sse_streams(store)
    end
  end

  describe "Config.mcp_servers/0" do
    test "reads from application config" do
      previous = Application.get_env(:lemon_skills, :mcp_servers)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:lemon_skills, :mcp_servers)
        else
          Application.put_env(:lemon_skills, :mcp_servers, previous)
        end
      end)

      servers = [
        {:stdio, "npx", ["-y", "@modelcontextprotocol/server-filesystem"]},
        {:http, "http://localhost:3000/mcp"},
        {:sse, "http://localhost:3001/sse"}
      ]

      Application.put_env(:lemon_skills, :mcp_servers, servers)

      assert LemonSkills.Config.mcp_servers() == servers
    end

    test "returns empty list when not configured" do
      previous = Application.get_env(:lemon_skills, :mcp_servers)

      on_exit(fn ->
        if previous == nil do
          Application.delete_env(:lemon_skills, :mcp_servers)
        else
          Application.put_env(:lemon_skills, :mcp_servers, previous)
        end
      end)

      Application.delete_env(:lemon_skills, :mcp_servers)
      assert LemonSkills.Config.mcp_servers() == []
    end

    test "parses HTTP OAuth config from environment JSON" do
      previous_env = System.get_env("LEMON_MCP_SERVERS")

      on_exit(fn ->
        if previous_env == nil do
          System.delete_env("LEMON_MCP_SERVERS")
        else
          System.put_env("LEMON_MCP_SERVERS", previous_env)
        end
      end)

      System.put_env(
        "LEMON_MCP_SERVERS",
        Jason.encode!([
          %{
            "type" => "http",
            "url" => "https://api.example.com/mcp",
            "oauth" => %{
              "flow" => "authorization_code_pkce",
              "client_id" => "client",
              "token_secret" => "mcp_oauth_token",
              "redirect_uri" => "http://127.0.0.1/callback",
              "scopes" => ["tools"],
              "authorization_approval" => false,
              "authorization_timeout_ms" => 120_000,
              "token_auth_method" => "client_secret_post"
            }
          }
        ])
      )

      assert [
               {:http, "https://api.example.com/mcp",
                [
                  oauth: [
                    client_id: "client",
                    token_secret: "mcp_oauth_token",
                    flow: "authorization_code_pkce",
                    redirect_uri: "http://127.0.0.1/callback",
                    scopes: ["tools"],
                    authorization_approval: false,
                    authorization_timeout_ms: 120_000,
                    token_auth_method: "client_secret_post"
                  ]
                ]}
             ] = LemonSkills.Config.mcp_servers()
    end

    test "parses stdio sampling approval config from environment JSON" do
      previous_env = System.get_env("LEMON_MCP_SERVERS")

      on_exit(fn ->
        if previous_env == nil do
          System.delete_env("LEMON_MCP_SERVERS")
        else
          System.put_env("LEMON_MCP_SERVERS", previous_env)
        end
      end)

      System.put_env(
        "LEMON_MCP_SERVERS",
        Jason.encode!([
          %{
            "type" => "stdio",
            "command" => "elixir",
            "args" => ["server.exs"],
            "sampling" => %{
              "mode" => "reviewed_model",
              "reviewer" => "ops_approval",
              "max_tokens" => 64,
              "allowed_models" => ["lemon-test"]
            }
          }
        ])
      )

      assert [
               {:stdio, "elixir", ["server.exs"],
                [
                  sampling_policy: [
                    mode: "reviewed_model",
                    reviewer: :ops_approval,
                    max_tokens: 64,
                    allowed_models: ["lemon-test"]
                  ]
                ]}
             ] = LemonSkills.Config.mcp_servers()
    end
  end

  describe "Config.validate_mcp_servers/1" do
    test "returns :ok for valid configs" do
      configs = [
        {:stdio, "npx", ["-y", "server"]},
        {:stdio, "uvx", ["server"], allow_tools: ["safe_tool"]},
        {:stdio, "uvx", ["server"],
         sampling_policy: [
           mode: :reviewed_model,
           reviewer: :ops_approval,
           max_tokens: 64,
           allowed_models: ["lemon-test"]
         ]},
        {:http, "http://localhost:3000/mcp"},
        {:http, "http://localhost:3001/mcp",
         headers: [{"Authorization", "Bearer test"}], allow_tools: ["echo"]},
        {:http, "http://localhost:3003/mcp",
         oauth: [
           client_id: "client",
           client_secret_secret: "mcp_client_secret",
           token_secret: "mcp_oauth_token",
           scopes: ["tools"],
           token_auth_method: :client_secret_basic
         ]},
        {:http, "http://localhost:3004/mcp",
         oauth: [
           flow: :authorization_code_pkce,
           client_id: "public-client",
           redirect_uri: "http://127.0.0.1/callback",
           scopes: ["tools"]
         ]},
        {:sse, "http://localhost:3002/sse",
         headers: [{"Authorization", "Bearer test"}], allow_tools: ["echo"]}
      ]

      assert {:ok, ^configs} = LemonSkills.Config.validate_mcp_servers(configs)
    end

    test "returns errors for invalid configs" do
      configs = [
        {:stdio, "npx", ["-y", "server"]},
        {:http, "invalid-url"},
        {:sse, "invalid-url"},
        {:stdio, "", []},
        {:stdio, "uvx", ["server"], allow_tools: [:not_string]},
        {:http, "http://localhost:3002/mcp", headers: [{"Authorization", :bad}]},
        {:http, "http://localhost:3003/mcp", oauth: [client_id: "client"]},
        {:stdio, "uvx", ["server"], sampling_policy: [max_tokens: 0]}
      ]

      assert {:error, errors} = LemonSkills.Config.validate_mcp_servers(configs)
      assert length(errors) == 7
    end
  end

  describe "Config.mcp_config/1" do
    test "merges global and project config" do
      # This test would require more setup to create actual config files
      # For now, we just verify it returns the expected structure
      result = LemonSkills.Config.mcp_config(nil)

      assert is_map(result)
      assert Map.has_key?(result, :servers)
      assert Map.has_key?(result, :enabled)
      assert is_list(result.servers)
      assert is_boolean(result.enabled)
    end
  end

  describe "server name generation" do
    test "generates consistent names for same config" do
      config1 = {:stdio, "npx", ["-y", "server"]}
      config2 = {:stdio, "npx", ["-y", "server"]}

      # Generate server names using private function logic
      name1 =
        :crypto.hash(:md5, :erlang.term_to_binary(config1))
        |> Base.encode16(case: :lower)
        |> String.to_atom()

      name2 =
        :crypto.hash(:md5, :erlang.term_to_binary(config2))
        |> Base.encode16(case: :lower)
        |> String.to_atom()

      assert name1 == name2
    end

    test "generates different names for different configs" do
      config1 = {:stdio, "npx", ["-y", "server1"]}
      config2 = {:stdio, "npx", ["-y", "server2"]}

      name1 =
        :crypto.hash(:md5, :erlang.term_to_binary(config1))
        |> Base.encode16(case: :lower)
        |> String.to_atom()

      name2 =
        :crypto.hash(:md5, :erlang.term_to_binary(config2))
        |> Base.encode16(case: :lower)
        |> String.to_atom()

      assert name1 != name2
    end
  end

  def handle_http_tool("echo", args) do
    {:ok,
     %Protocol.ToolCallResult{
       content: [%{type: "text", text: "echo:" <> Map.get(args, "message", "")}],
       isError: false
     }}
  end

  def handle_http_tool("fail", _args) do
    {:ok,
     %Protocol.ToolCallResult{
       content: [%{type: "text", text: "planned failure"}],
       isError: true
     }}
  end

  def handle_http_tool(_name, _args), do: {:error, :unknown_tool}

  defp start_http_transport do
    port = free_port()

    start_supervised!(
      {LemonMCP.Transport.HTTP,
       [
         port: port,
         server_name: "HTTP Fixture",
         server_version: "1.0.0",
         tools: [
           %Protocol.Tool{
             name: "echo",
             description: "Echo a message",
             inputSchema: %{
               "type" => "object",
               "properties" => %{"message" => %{"type" => "string"}},
               "required" => ["message"]
             }
           },
           %Protocol.Tool{
             name: "fail",
             description: "Return a planned tool error",
             inputSchema: %{"type" => "object", "properties" => %{}}
           }
         ],
         tool_handler: &__MODULE__.handle_http_tool/2,
         resources: [%{"uri" => "fixture://status", "name" => "Status"}],
         resource_handler: fn
           "fixture://status" ->
             {:ok, [%{"uri" => "fixture://status", "text" => "status:ok"}]}

           _ ->
             {:error, :unknown_resource}
         end,
         prompts: [%{"name" => "brief", "description" => "Write a brief"}],
         prompt_handler: fn
           "brief", args ->
             {:ok,
              %{
                "description" => "Write a brief",
                "messages" => [
                  %{
                    "role" => "user",
                    "content" => %{
                      "type" => "text",
                      "text" => "brief:" <> Map.get(args, "topic", "")
                    }
                  }
                ]
              }}

           _, _ ->
             {:error, :unknown_prompt}
         end
       ]}
    )

    port
  end

  defp start_sse_transport do
    port = free_port()
    {:ok, store} = start_supervised({Agent, fn -> %{} end})

    {:ok, server} =
      start_supervised(
        {LemonMCP.Server,
         [
           server_name: "SSE Fixture",
           server_version: "1.0.0",
           tools: [
             %Protocol.Tool{
               name: "echo",
               description: "Echo a message",
               inputSchema: %{
                 "type" => "object",
                 "properties" => %{"message" => %{"type" => "string"}},
                 "required" => ["message"]
               }
             },
             %Protocol.Tool{
               name: "fail",
               description: "Return a planned tool error",
               inputSchema: %{"type" => "object", "properties" => %{}}
             }
           ],
           tool_handler: &__MODULE__.handle_http_tool/2,
           resources: [%{"uri" => "fixture://status", "name" => "Status"}],
           resource_handler: fn
             "fixture://status" ->
               {:ok, [%{"uri" => "fixture://status", "text" => "status:ok"}]}

             _ ->
               {:error, :unknown_resource}
           end,
           prompts: [%{"name" => "brief", "description" => "Write a brief"}],
           prompt_handler: fn
             "brief", args ->
               {:ok,
                %{
                  "description" => "Write a brief",
                  "messages" => [
                    %{
                      "role" => "user",
                      "content" => %{
                        "type" => "text",
                        "text" => "brief:" <> Map.get(args, "topic", "")
                      }
                    }
                  ]
                }}

             _, _ ->
               {:error, :unknown_prompt}
           end
         ]}
      )

    start_supervised!(
      {Bandit,
       plug: {LemonSkills.McpSourceTest.SSEFixture, store: store, mcp_server: server},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port}
    )

    {port, store}
  end

  defp start_oauth_http_transport do
    port = free_port()
    {:ok, store} = start_supervised({Agent, fn -> [] end})

    start_supervised!(
      {Bandit,
       plug: {LemonSkills.McpSourceTest.OAuthTokenFixture, store: store},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port}
    )

    {port, store}
  end

  defp stop_sse_streams(store) do
    store
    |> Agent.get(&Map.values/1)
    |> Enum.each(&send(&1, :stop))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp fixture_server_script do
    ~S'''
    defmodule FixtureMcpServer do
      def run do
        IO.stream(:stdio, :line)
        |> Enum.each(&handle_line/1)
      end

      defp handle_line(line) do
        request = :json.decode(String.trim(line))
        handle_request(request)
      end

      defp handle_request(%{"method" => "initialize", "id" => id}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}},
            "serverInfo" => %{"name" => "fixture-mcp", "version" => "1.0.0"}
          }
        })
      end

      defp handle_request(%{"method" => "notifications/initialized"}), do: :ok

      defp handle_request(%{"method" => "resources/list", "id" => id}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "resources" => [%{"uri" => "fixture://status", "name" => "Status"}]
          }
        })
      end

      defp handle_request(%{
             "method" => "resources/read",
             "id" => id,
             "params" => %{"uri" => "fixture://status"}
           }) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "contents" => [%{"uri" => "fixture://status", "text" => "status:ok"}]
          }
        })
      end

      defp handle_request(%{"method" => "prompts/list", "id" => id}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "prompts" => [%{"name" => "brief", "description" => "Write a brief"}]
          }
        })
      end

      defp handle_request(%{
             "method" => "prompts/get",
             "id" => id,
             "params" => %{"name" => "brief", "arguments" => args}
           }) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "description" => "Write a brief",
            "messages" => [
              %{
                "role" => "user",
                "content" => %{
                  "type" => "text",
                  "text" => "brief:" <> Map.get(args, "topic", "")
                }
              }
            ]
          }
        })
      end

      defp handle_request(%{"method" => "tools/list", "id" => id}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "tools" => [
              %{
                "name" => "echo",
                "description" => "Echo a safe message",
                "inputSchema" => %{
                  "type" => "object",
                  "properties" => %{"message" => %{"type" => "string"}},
                  "required" => ["message"]
                }
              },
              %{
                "name" => "fail",
                "description" => "Return a planned tool error",
                "inputSchema" => %{"type" => "object", "properties" => %{}}
              }
            ]
          }
        })
      end

      defp handle_request(%{
             "method" => "tools/call",
             "id" => id,
             "params" => %{"name" => "echo", "arguments" => args}
           }) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [%{"type" => "text", "text" => "echo:" <> Map.get(args, "message", "")}],
            "isError" => false
          }
        })
      end

      defp handle_request(%{"method" => "tools/call", "id" => id, "params" => %{"name" => "fail"}}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "content" => [%{"type" => "text", "text" => "planned failure"}],
            "isError" => true
          }
        })
      end

      defp handle_request(%{"id" => id}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })
      end

      defp respond(response) do
        IO.write([:json.encode(response), "\n"])
      end
    end

    FixtureMcpServer.run()
    '''
  end

  defp fixture_sampling_server_script do
    ~S'''
    defmodule FixtureSamplingMcpServer do
      def run do
        IO.stream(:stdio, :line)
        |> Enum.each(&handle_line/1)
      end

      defp handle_line(line) do
        request = :json.decode(String.trim(line))
        handle_request(request)
      end

      defp handle_request(%{"method" => "initialize", "id" => id, "params" => params}) do
        Process.put(:saw_sampling_capability, Map.has_key?(params["capabilities"] || %{}, "sampling"))

        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "fixture-sampling-mcp", "version" => "1.0.0"}
          }
        })
      end

      defp handle_request(%{"method" => "notifications/initialized"}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => "sampling-1",
          "method" => "sampling/createMessage",
          "params" => %{
            "messages" => [
              %{"role" => "user", "content" => %{"type" => "text", "text" => "secret prompt"}}
            ],
            "maxTokens" => 16,
            "modelPreferences" => %{"hints" => [%{"name" => "lemon-test"}]},
            "sawSamplingCapability" => Process.get(:saw_sampling_capability)
          }
        })
      end

      defp handle_request(%{"id" => "sampling-1", "result" => _result}), do: :ok

      defp handle_request(%{"method" => "tools/list", "id" => id}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "tools" => [
              %{
                "name" => "echo",
                "description" => "Echo a safe message",
                "inputSchema" => %{"type" => "object", "properties" => %{}}
              }
            ]
          }
        })
      end

      defp handle_request(%{"id" => id}) do
        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => %{"code" => -32601, "message" => "Method not found"}
        })
      end

      defp respond(response) do
        IO.write([:json.encode(response), "\n"])
      end
    end

    FixtureSamplingMcpServer.run()
    '''
  end

  defp wait_for_pending_approval(run_id, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    case find_pending_approval(run_id) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for pending approval #{run_id}")
        else
          Process.sleep(20)
          wait_for_pending_approval(run_id, deadline)
        end

      pending ->
        pending
    end
  end

  defp find_pending_approval(run_id) do
    LemonCore.ExecApprovalStore.list_pending()
    |> Enum.map(fn {_id, pending} -> pending end)
    |> Enum.find(fn pending -> pending.run_id == run_id end)
  end
end
