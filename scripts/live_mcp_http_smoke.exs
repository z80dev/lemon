Application.ensure_all_started(:lemon_mcp)
Application.ensure_all_started(:lemon_skills)
Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveMcpHttpSmoke.StreamableFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    record_request(conn.assigns.store, conn, request)

    case response_for(request) do
      nil ->
        send_resp(conn, 202, "")

      {response, :json} ->
        conn
        |> put_resp_header("mcp-session-id", "stream-session-1")
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))

      {response, :sse} ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, "event: message\ndata: #{Jason.encode!(response)}\n\n")
    end
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

  defp record_request(store, conn, request) do
    headers = Map.new(conn.req_headers)
    Agent.update(store, &[{request["method"], headers} | &1])
  end

  defp response_for(%{"method" => "initialize", "id" => id}) do
    {%{
       "jsonrpc" => "2.0",
       "id" => id,
       "result" => %{
         "protocolVersion" => "2025-06-18",
         "capabilities" => %{"tools" => %{}},
         "serverInfo" => %{"name" => "Streamable Fixture", "version" => "1.0.0"}
       }
     }, :json}
  end

  defp response_for(%{"method" => "notifications/initialized"}), do: nil

  defp response_for(%{"method" => "tools/list", "id" => id}) do
    {%{
       "jsonrpc" => "2.0",
       "id" => id,
       "result" => %{
         "tools" => [
           %{
             "name" => "stream_echo",
             "description" => "Echo through streamable HTTP",
             "inputSchema" => %{"type" => "object", "properties" => %{}}
           }
         ]
       }
     }, :sse}
  end

  defp response_for(%{"id" => id}) do
    {%{
       "jsonrpc" => "2.0",
       "id" => id,
       "error" => %{"code" => -32601, "message" => "Method not found"}
     }, :json}
  end
end

defmodule LemonScripts.LiveMcpHttpSmoke.OAuthMetadataFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    conn
    |> put_resp_header(
      "www-authenticate",
      ~s|Bearer resource_metadata="http://127.0.0.1:#{conn.port}/.well-known/oauth-protected-resource/mcp"|
    )
    |> send_resp(401, "authorization required")
  end

  get "/.well-known/oauth-protected-resource/mcp" do
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
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "issuer" => "http://127.0.0.1:#{conn.port}/oauth",
        "authorization_endpoint" => "http://127.0.0.1:#{conn.port}/oauth/authorize",
        "token_endpoint" => "http://127.0.0.1:#{conn.port}/oauth/token",
        "registration_endpoint" => "http://127.0.0.1:#{conn.port}/oauth/register"
      })
    )
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end

defmodule LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    headers = Map.new(conn.req_headers)
    record(conn.assigns.store, {:mcp, request["method"], headers})

    if authorized_mcp_request?(request, headers["authorization"]) do
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

    if valid_oauth_token_request?(form, conn.req_headers) do
      token = issue_token(conn.assigns.store, form)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(token)
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
        "serverInfo" => %{"name" => "OAuth Token Fixture", "version" => "1.0.0"}
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
            "description" => "Echo through OAuth-protected HTTP",
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

  defp authorized_mcp_request?(_request, "Bearer fixture-token"), do: true
  defp authorized_mcp_request?(_request, "Bearer refreshed-token"), do: true
  defp authorized_mcp_request?(_request, "Bearer refresh-access-token"), do: true
  defp authorized_mcp_request?(_request, "Bearer auth-code-token"), do: true

  defp authorized_mcp_request?(%{"method" => method}, "Bearer expiring-token")
       when method in ["initialize", "notifications/initialized"],
       do: true

  defp authorized_mcp_request?(%{"method" => method}, "Bearer refresh-expiring-token")
       when method in ["initialize", "notifications/initialized"],
       do: true

  defp authorized_mcp_request?(_request, _authorization), do: false

  defp issue_token(store, %{"grant_type" => "client_credentials", "scope" => "expire"}) do
    Agent.get_and_update(store, fn events ->
      issued = Enum.count(events, &match?({:issued_token, _token}, &1))
      token = if issued == 0, do: "expiring-token", else: "refreshed-token"
      {%{"access_token" => token, "token_type" => "Bearer"}, [{:issued_token, token} | events]}
    end)
  end

  defp issue_token(store, %{
         "grant_type" => "client_credentials",
         "scope" => "refresh-lifecycle"
       }) do
    Agent.get_and_update(store, fn events ->
      token = %{
        "access_token" => "refresh-expiring-token",
        "refresh_token" => "refresh-one",
        "token_type" => "Bearer"
      }

      {token, [{:issued_token, "refresh-expiring-token"} | events]}
    end)
  end

  defp issue_token(store, %{"grant_type" => "refresh_token", "refresh_token" => "refresh-one"}) do
    Agent.get_and_update(store, fn events ->
      token = %{
        "access_token" => "refresh-access-token",
        "refresh_token" => "refresh-two",
        "token_type" => "Bearer"
      }

      {token, [{:issued_token, "refresh-access-token"} | events]}
    end)
  end

  defp issue_token(_store, %{"grant_type" => "authorization_code", "code" => code})
       when code in ["operator-code", "loopback-code"] do
    %{
      "access_token" => "auth-code-token",
      "refresh_token" => "auth-refresh",
      "token_type" => "Bearer"
    }
  end

  defp issue_token(_store, _form),
    do: %{"access_token" => "fixture-token", "token_type" => "Bearer"}

  defp valid_oauth_token_request?(%{"grant_type" => "client_credentials"} = form, headers) do
    post_secret? = form["client_id"] == "lemon" and form["client_secret"] == "secret"
    basic_secret? = Map.new(headers)["authorization"] == "Basic " <> Base.encode64("lemon:secret")

    post_secret? or basic_secret?
  end

  defp valid_oauth_token_request?(%{"grant_type" => "refresh_token"} = form, headers) do
    post_secret? =
      form["client_id"] == "lemon" and form["client_secret"] == "secret" and
        form["refresh_token"] == "refresh-one"

    basic_secret? =
      Map.new(headers)["authorization"] == "Basic " <> Base.encode64("lemon:secret") and
        form["refresh_token"] == "refresh-one"

    post_secret? or basic_secret?
  end

  defp valid_oauth_token_request?(%{"grant_type" => "authorization_code"} = form, _headers) do
    form["client_id"] == "lemon-public" and
      form["code"] in ["operator-code", "loopback-code"] and
      is_binary(form["code_verifier"]) and form["code_verifier"] != "" and
      valid_authorization_redirect_uri?(form["redirect_uri"])
  end

  defp valid_oauth_token_request?(_form, _headers), do: false

  defp valid_authorization_redirect_uri?("http://127.0.0.1/callback"), do: true

  defp valid_authorization_redirect_uri?(redirect_uri) when is_binary(redirect_uri) do
    case URI.parse(redirect_uri) do
      %URI{scheme: "http", host: "127.0.0.1", port: port, path: "/callback"}
      when is_integer(port) and port > 0 ->
        true

      _ ->
        false
    end
  end

  defp valid_authorization_redirect_uri?(_redirect_uri), do: false

  defp record(store, event), do: Agent.update(store, &[event | &1])
end

defmodule LemonScripts.LiveMcpHttpSmoke do
  alias CodingAgent.ToolRegistry
  alias LemonMCP.Client.HTTP
  alias LemonMCP.Protocol
  alias LemonMCP.Transport
  alias LemonSkills.McpSource

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    project_dir = File.cwd!()

    proof_path =
      opts[:out] || Path.join([project_dir, ".lemon", "proofs", "mcp-http-latest.json"])

    archive_path = archive_path(proof_path)

    checks = run_checks(project_dir)
    completed_count = Enum.count(checks, &(&1.status == "completed"))
    failed_count = Enum.count(checks, &(&1.status == "failed"))
    skipped_count = Enum.count(checks, &(&1.status == "skipped"))

    proof = %{
      status: proof_status(completed_count, skipped_count, failed_count),
      proof: "mcp_http_smoke",
      proof_scope: "mcp_http_smoke",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      completed_count: completed_count,
      failed_count: failed_count,
      skipped_count: skipped_count,
      checks: checks,
      cleanup: %{
        includes_raw_paths: false,
        includes_raw_filenames: false,
        includes_raw_prompts: false,
        includes_raw_provider_responses: false,
        includes_raw_tool_arguments: false,
        includes_raw_tool_results: false,
        includes_server_io: false
      }
    }

    write_json!(proof_path, proof)
    write_json!(archive_path, proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if failed_count > 0 do
      System.halt(1)
    end
  end

  defp run_checks(project_dir) do
    port = free_port()
    url = "http://127.0.0.1:#{port}/mcp"
    {:ok, transport} = start_http_transport(port)
    Process.put(:mcp_http_transport, transport)
    configure_mcp_source(url)

    {client_result, client} = start_client(url)

    {streamable_result, streamable_client, streamable_store, _streamable_transport} =
      start_streamable_client()

    {oauth_result, oauth_port, _oauth_transport} = start_oauth_metadata_probe()

    {oauth_token_result, oauth_token_client, oauth_token_store, oauth_token_port,
     _oauth_token_transport} =
      start_oauth_token_client()

    {oauth_refresh_result, oauth_refresh_client, oauth_refresh_store, _oauth_refresh_port,
     _oauth_refresh_transport} =
      start_oauth_refresh_client()

    {oauth_refresh_token_result, oauth_refresh_token_client, oauth_refresh_token_store,
     oauth_refresh_token_port, _oauth_refresh_token_transport} =
      start_oauth_refresh_token_client()

    {oauth_basic_result, oauth_basic_client, oauth_basic_store, _oauth_basic_port,
     _oauth_basic_transport} =
      start_oauth_basic_client()

    {oauth_pkce_result, oauth_pkce_client, oauth_pkce_store, oauth_pkce_port, oauth_pkce_request,
     _oauth_pkce_transport} =
      start_oauth_pkce_client()

    {oauth_cached_pkce_result, oauth_cached_pkce_client, oauth_cached_pkce_store,
     oauth_cached_pkce_port, oauth_cached_pkce_request, oauth_cached_pkce_cache,
     _oauth_cached_pkce_transport} =
      start_oauth_cached_pkce_client()

    [
      check("mcp_http_client_initializes", fn ->
        unless match?({:ok, pid} when is_pid(pid), client_result),
          do: raise("client did not start")

        assert_until(fn -> HTTP.state(client) == :ready end)
        {:ok, %{name: "HTTP Fixture", version: "1.0.0"}} = HTTP.server_info(client)
      end),
      check("mcp_http_lists_tools", fn ->
        assert_until(fn -> HTTP.state(client) == :ready end)
        {:ok, tools} = HTTP.list_tools(client, 5_000)
        true = Enum.any?(tools, &(&1["name"] == "echo"))
        true = Enum.any?(tools, &(&1["name"] == "fail"))
      end),
      check("mcp_http_calls_tool_success", fn ->
        {:ok, [%{"type" => "text", "text" => "echo:ok"}]} =
          HTTP.call_tool(client, "echo", %{"message" => "ok"}, 5_000)
      end),
      check("mcp_http_calls_tool_error", fn ->
        {:error, {:tool_error, [%{"type" => "text", "text" => "planned failure"}]}} =
          HTTP.call_tool(client, "fail", %{}, 5_000)
      end),
      check("mcp_http_lists_resources", fn ->
        {:ok, resources} = HTTP.list_resources(client, 5_000)
        true = Enum.any?(resources, &(&1["uri"] == "fixture://status"))
      end),
      check("mcp_http_reads_resource", fn ->
        {:ok, [%{"uri" => "fixture://status", "text" => "status:ok"}]} =
          HTTP.read_resource(client, "fixture://status", 5_000)
      end),
      check("mcp_http_lists_prompts", fn ->
        {:ok, prompts} = HTTP.list_prompts(client, 5_000)
        true = Enum.any?(prompts, &(&1["name"] == "brief"))
      end),
      check("mcp_http_gets_prompt", fn ->
        {:ok, %{messages: [%{"role" => "user"}]}} =
          HTTP.get_prompt(client, "brief", %{"topic" => "beam"}, 5_000)
      end),
      check("mcp_http_streamable_sse_response_and_session_headers", fn ->
        unless match?({:ok, pid} when is_pid(pid), streamable_result),
          do: raise("streamable client did not start")

        assert_until(fn -> HTTP.state(streamable_client) == :ready end)
        {:ok, [%{"name" => "stream_echo"}]} = HTTP.list_tools(streamable_client, 5_000)

        observed =
          streamable_store
          |> Agent.get(& &1)
          |> Enum.reverse()

        {"initialize", initialize_headers} = Enum.at(observed, 0)
        true = String.contains?(initialize_headers["accept"], "application/json")
        true = String.contains?(initialize_headers["accept"], "text/event-stream")

        {"notifications/initialized", initialized_headers} = Enum.at(observed, 1)
        "stream-session-1" = initialized_headers["mcp-session-id"]
        "2025-06-18" = initialized_headers["mcp-protocol-version"]

        {"tools/list", list_headers} = Enum.at(observed, 2)
        "stream-session-1" = list_headers["mcp-session-id"]
        "2025-06-18" = list_headers["mcp-protocol-version"]
      end),
      check("mcp_http_oauth_protected_resource_metadata", fn ->
        {:error, {:auth_required, metadata}} = oauth_result
        true = metadata["resource"] == "http://127.0.0.1:#{oauth_port}/mcp"
        true = metadata["authorization_servers"] == ["http://127.0.0.1:#{oauth_port}/oauth"]
        true = String.contains?(metadata["resource_metadata_url"], "oauth-protected-resource")
        true = String.contains?(metadata["www_authenticate"], "Bearer")
      end),
      check("mcp_http_oauth_authorization_server_metadata", fn ->
        {:error, {:auth_required, metadata}} = oauth_result

        [authorization_metadata] = metadata["authorization_server_metadata"]
        true = authorization_metadata["issuer"] == "http://127.0.0.1:#{oauth_port}/oauth"

        true =
          authorization_metadata["authorization_endpoint"] ==
            "http://127.0.0.1:#{oauth_port}/oauth/authorize"

        true =
          authorization_metadata["token_endpoint"] ==
            "http://127.0.0.1:#{oauth_port}/oauth/token"

        true =
          authorization_metadata["registration_endpoint"] ==
            "http://127.0.0.1:#{oauth_port}/oauth/register"

        true =
          authorization_metadata["metadata_url"] ==
            "http://127.0.0.1:#{oauth_port}/.well-known/oauth-authorization-server/oauth"
      end),
      check("mcp_http_oauth_client_credentials_token_acquisition", fn ->
        unless match?({:ok, pid} when is_pid(pid), oauth_token_result),
          do: raise("OAuth token client did not start")

        assert_until(fn -> HTTP.state(oauth_token_client) == :ready end)
        {:ok, [%{"name" => "secured_echo"}]} = HTTP.list_tools(oauth_token_client, 5_000)

        observed = Agent.get(oauth_token_store, &Enum.reverse/1)
        {:metadata, metadata_headers} = Enum.find(observed, &match?({:metadata, _}, &1))
        false = Map.has_key?(metadata_headers, "authorization")

        {:authorization_metadata, authorization_metadata_headers} =
          Enum.find(observed, &match?({:authorization_metadata, _}, &1))

        false = Map.has_key?(authorization_metadata_headers, "authorization")

        {:token, token_form, _token_headers} = Enum.find(observed, &match?({:token, _, _}, &1))
        "client_credentials" = token_form["grant_type"]
        "lemon" = token_form["client_id"]
        "secret" = token_form["client_secret"]
        true = token_form["resource"] == "http://127.0.0.1:#{oauth_token_port}/mcp"
        "tools prompts" = token_form["scope"]

        true =
          Enum.any?(observed, fn
            {:mcp, "tools/list", %{"authorization" => "Bearer fixture-token"}} -> true
            _ -> false
          end)
      end),
      check("mcp_http_oauth_client_credentials_token_refresh", fn ->
        unless match?({:ok, pid} when is_pid(pid), oauth_refresh_result),
          do: raise("OAuth refresh client did not start")

        assert_until(fn -> HTTP.state(oauth_refresh_client) == :ready end)
        {:ok, [%{"name" => "secured_echo"}]} = HTTP.list_tools(oauth_refresh_client, 5_000)

        observed = Agent.get(oauth_refresh_store, &Enum.reverse/1)
        true = Enum.count(observed, &match?({:token, _, _}, &1)) == 2
        true = {:issued_token, "expiring-token"} in observed
        true = {:issued_token, "refreshed-token"} in observed

        true =
          Enum.any?(observed, fn
            {:mcp, "tools/list", %{"authorization" => "Bearer expiring-token"}} -> true
            _ -> false
          end)

        true =
          Enum.any?(observed, fn
            {:mcp, "tools/list", %{"authorization" => "Bearer refreshed-token"}} -> true
            _ -> false
          end)
      end),
      check("mcp_http_oauth_refresh_token_grant", fn ->
        unless match?({:ok, pid} when is_pid(pid), oauth_refresh_token_result),
          do: raise("OAuth refresh-token client did not start")

        assert_until(fn -> HTTP.state(oauth_refresh_token_client) == :ready end)

        {:ok, [%{"name" => "secured_echo"}]} =
          HTTP.list_tools(oauth_refresh_token_client, 5_000)

        observed = Agent.get(oauth_refresh_token_store, &Enum.reverse/1)

        token_requests = Enum.filter(observed, &match?({:token, _, _}, &1))
        true = length(token_requests) == 2

        [{:token, client_credentials_form, _}, {:token, refresh_form, _}] = token_requests

        "client_credentials" = client_credentials_form["grant_type"]
        "refresh-lifecycle" = client_credentials_form["scope"]
        "refresh_token" = refresh_form["grant_type"]
        "refresh-one" = refresh_form["refresh_token"]
        true = refresh_form["resource"] == "http://127.0.0.1:#{oauth_refresh_token_port}/mcp"
        true = {:issued_token, "refresh-expiring-token"} in observed
        true = {:issued_token, "refresh-access-token"} in observed

        true =
          Enum.any?(observed, fn
            {:mcp, "tools/list", %{"authorization" => "Bearer refresh-expiring-token"}} ->
              true

            _ ->
              false
          end)

        true =
          Enum.any?(observed, fn
            {:mcp, "tools/list", %{"authorization" => "Bearer refresh-access-token"}} ->
              true

            _ ->
              false
          end)
      end),
      check("mcp_http_oauth_client_secret_basic_token_auth", fn ->
        unless match?({:ok, pid} when is_pid(pid), oauth_basic_result),
          do: raise("OAuth basic-auth client did not start")

        assert_until(fn -> HTTP.state(oauth_basic_client) == :ready end)
        {:ok, [%{"name" => "secured_echo"}]} = HTTP.list_tools(oauth_basic_client, 5_000)

        observed = Agent.get(oauth_basic_store, &Enum.reverse/1)
        {:token, token_form, token_headers} = Enum.find(observed, &match?({:token, _, _}, &1))
        "client_credentials" = token_form["grant_type"]
        false = Map.has_key?(token_form, "client_id")
        false = Map.has_key?(token_form, "client_secret")
        "tools" = token_form["scope"]
        true = token_headers["authorization"] == "Basic " <> Base.encode64("lemon:secret")
      end),
      check("mcp_http_oauth_pkce_authorization_code", fn ->
        unless match?({:ok, pid} when is_pid(pid), oauth_pkce_result),
          do: raise("OAuth PKCE client did not start")

        assert_until(fn -> HTTP.state(oauth_pkce_client) == :ready end)
        {:ok, [%{"name" => "secured_echo"}]} = HTTP.list_tools(oauth_pkce_client, 5_000)

        request = Agent.get(oauth_pkce_request, & &1)
        true = is_map(request)

        true =
          request.authorization_endpoint == "http://127.0.0.1:#{oauth_pkce_port}/oauth/authorize"

        "lemon-public" = request.client_id
        "http://127.0.0.1/callback" = request.redirect_uri
        "tools" = request.scope
        true = request.resource == "http://127.0.0.1:#{oauth_pkce_port}/mcp"
        "S256" = request.code_challenge_method

        expected_challenge =
          :crypto.hash(:sha256, request.code_verifier)
          |> Base.url_encode64(padding: false)

        true = request.code_challenge == expected_challenge

        query =
          request.authorization_url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()

        "code" = query["response_type"]
        "lemon-public" = query["client_id"]
        "http://127.0.0.1/callback" = query["redirect_uri"]
        "tools" = query["scope"]
        true = query["resource"] == "http://127.0.0.1:#{oauth_pkce_port}/mcp"
        true = query["state"] == request.state
        true = query["code_challenge"] == request.code_challenge
        "S256" = query["code_challenge_method"]

        observed = Agent.get(oauth_pkce_store, &Enum.reverse/1)
        {:token, token_form, _token_headers} = Enum.find(observed, &match?({:token, _, _}, &1))
        "authorization_code" = token_form["grant_type"]
        "lemon-public" = token_form["client_id"]
        "operator-code" = token_form["code"]
        true = token_form["code_verifier"] == request.code_verifier
        "http://127.0.0.1/callback" = token_form["redirect_uri"]
        true = token_form["resource"] == "http://127.0.0.1:#{oauth_pkce_port}/mcp"
        "tools" = token_form["scope"]

        true =
          Enum.any?(observed, fn
            {:mcp, "tools/list", %{"authorization" => "Bearer auth-code-token"}} -> true
            _ -> false
          end)
      end),
      check("mcp_http_oauth_token_cache_resume", fn ->
        unless match?({:ok, pid} when is_pid(pid), oauth_cached_pkce_result),
          do: raise("OAuth cached PKCE client did not start")

        assert_until(fn -> HTTP.state(oauth_cached_pkce_client) == :ready end)
        {:ok, [%{"name" => "secured_echo"}]} = HTTP.list_tools(oauth_cached_pkce_client, 5_000)

        cached_token = Agent.get(oauth_cached_pkce_cache, & &1)
        "auth-code-token" = cached_token.access_token
        "auth-refresh" = cached_token.refresh_token
        true = is_map(cached_token.metadata)

        first_request = Agent.get(oauth_cached_pkce_request, & &1)
        true = is_map(first_request)

        true =
          first_request.authorization_endpoint ==
            "http://127.0.0.1:#{oauth_cached_pkce_port}/oauth/authorize"

        observed = Agent.get(oauth_cached_pkce_store, &Enum.reverse/1)

        false = Enum.any?(observed, &match?({:token, _, _}, &1))
        false = Enum.any?(observed, &match?({:metadata, _}, &1))
        false = Enum.any?(observed, &match?({:authorization_metadata, _}, &1))

        true =
          Enum.any?(observed, fn
            {:mcp, "initialize", %{"authorization" => "Bearer auth-code-token"}} -> true
            _ -> false
          end)

        true =
          Enum.any?(observed, fn
            {:mcp, "tools/list", %{"authorization" => "Bearer auth-code-token"}} -> true
            _ -> false
          end)
      end),
      check("mcp_source_discovers_prefixed_http_tools", fn ->
        tools = McpSource.discover_tools(force_refresh: true)
        true = Enum.any?(tools, &(&1.name == "mcp_mcp_echo"))
        true = Enum.any?(tools, &(&1.name == "mcp_mcp_fail"))
        true = Enum.any?(tools, &(&1.name == "mcp_mcp_resources_list"))
        true = Enum.any?(tools, &(&1.name == "mcp_mcp_resource_read"))
        true = Enum.any?(tools, &(&1.name == "mcp_mcp_prompts_list"))
        true = Enum.any?(tools, &(&1.name == "mcp_mcp_prompt_get"))
      end),
      check("mcp_source_invokes_http_tool", fn ->
        {:ok, result} = McpSource.call_tool("mcp_mcp_echo", %{"message" => "ok"})
        true = result.content |> hd() |> Map.fetch!(:text) == "echo:ok"
      end),
      check("mcp_source_invokes_http_resource_and_prompt_utilities", fn ->
        {:ok, resource} =
          McpSource.call_tool("mcp_mcp_resource_read", %{"uri" => "fixture://status"})

        true =
          resource.content
          |> hd()
          |> Map.fetch!(:text)
          |> Jason.decode!()
          |> Enum.any?(&(&1["text"] == "status:ok"))

        {:ok, prompt} =
          McpSource.call_tool("mcp_mcp_prompt_get", %{
            "name" => "brief",
            "arguments" => %{"topic" => "beam"}
          })

        true =
          prompt.content
          |> hd()
          |> Map.fetch!(:text)
          |> Jason.decode!()
          |> Map.fetch!("messages")
          |> Enum.any?(&(&1["role"] == "user"))
      end),
      check("mcp_registry_exposes_prefixed_http_tools", fn ->
        tools = ToolRegistry.get_tools(project_dir)
        true = Enum.any?(tools, &(&1.name == "mcp_mcp_echo"))
        report = ToolRegistry.tool_conflict_report(project_dir)
        true = report.mcp_count >= 6
      end),
      check("mcp_source_status_reports_http_capabilities", fn ->
        status = McpSource.status()

        true =
          Enum.any?(status.servers, fn {_name, server} ->
            server.connected and server.tool_count == 6 and server.resource_count == 1 and
              server.prompt_count == 1 and server.capabilities.tools and
              server.capabilities.resources and
              server.capabilities.prompts
          end)
      end),
      check("mcp_source_applies_http_filters", fn ->
        configure_mcp_source(url, allow_tools: ["echo"])
        tools = McpSource.discover_tools(force_refresh: true)
        names = Enum.map(tools, & &1.name)
        true = "mcp_mcp_echo" in names
        false = "mcp_mcp_fail" in names
      end),
      check("mcp_source_http_oauth_loopback_callback", fn ->
        {tools, observed, request, pending, oauth_source_port, callback_port, transport} =
          run_oauth_loopback_source()

        try do
          true = Enum.any?(tools, &(&1.name == "mcp_mcp_secured_echo"))
          "lemon-public" = request.client_id
          true = request.redirect_uri == "http://127.0.0.1:#{callback_port}/callback"
          "tools" = request.scope
          true = request.resource == "http://127.0.0.1:#{oauth_source_port}/mcp"
          "mcp_mcp_oauth" = pending.tool
          "mcp_oauth_authorization" = pending.action.type
          true = pending.action.authorization_url == request.authorization_url
          true = pending.action.resource == "http://127.0.0.1:#{oauth_source_port}/mcp"

          {:token, token_form, _token_headers} =
            Enum.find(observed, &match?({:token, _, _}, &1))

          "authorization_code" = token_form["grant_type"]
          "lemon-public" = token_form["client_id"]
          "loopback-code" = token_form["code"]
          true = is_binary(token_form["code_verifier"]) and token_form["code_verifier"] != ""
          true = token_form["redirect_uri"] == "http://127.0.0.1:#{callback_port}/callback"
          true = token_form["resource"] == "http://127.0.0.1:#{oauth_source_port}/mcp"
          "tools" = token_form["scope"]

          true =
            Enum.any?(observed, fn
              {:mcp, "tools/list", %{"authorization" => "Bearer auth-code-token"}} -> true
              _ -> false
            end)
        after
          if is_pid(transport), do: Process.exit(transport, :normal)
        end
      end)
    ]
  after
    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_streamable_http_client)) do
      {:ok, pid} = Process.get(:mcp_streamable_http_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_streamable_http_transport)) do
      Process.exit(Process.get(:mcp_streamable_http_transport), :normal)
    end

    if is_pid(Process.get(:mcp_oauth_metadata_transport)) do
      Process.exit(Process.get(:mcp_oauth_metadata_transport), :normal)
    end

    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_oauth_token_client)) do
      {:ok, pid} = Process.get(:mcp_oauth_token_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_oauth_token_transport)) do
      Process.exit(Process.get(:mcp_oauth_token_transport), :normal)
    end

    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_oauth_refresh_client)) do
      {:ok, pid} = Process.get(:mcp_oauth_refresh_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_oauth_refresh_transport)) do
      Process.exit(Process.get(:mcp_oauth_refresh_transport), :normal)
    end

    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_oauth_refresh_token_client)) do
      {:ok, pid} = Process.get(:mcp_oauth_refresh_token_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_oauth_refresh_token_transport)) do
      Process.exit(Process.get(:mcp_oauth_refresh_token_transport), :normal)
    end

    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_oauth_basic_client)) do
      {:ok, pid} = Process.get(:mcp_oauth_basic_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_oauth_basic_transport)) do
      Process.exit(Process.get(:mcp_oauth_basic_transport), :normal)
    end

    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_oauth_pkce_client)) do
      {:ok, pid} = Process.get(:mcp_oauth_pkce_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_oauth_pkce_transport)) do
      Process.exit(Process.get(:mcp_oauth_pkce_transport), :normal)
    end

    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_oauth_cached_pkce_client)) do
      {:ok, pid} = Process.get(:mcp_oauth_cached_pkce_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_oauth_cached_pkce_transport)) do
      Process.exit(Process.get(:mcp_oauth_cached_pkce_transport), :normal)
    end

    if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_http_client)) do
      {:ok, pid} = Process.get(:mcp_http_client)
      _ = HTTP.close(pid)
    end

    if is_pid(Process.get(:mcp_http_transport)) do
      Process.exit(Process.get(:mcp_http_transport), :normal)
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

  defp start_client(url) do
    result = HTTP.start_link(url: url, timeout_ms: 5_000)

    case result do
      {:ok, pid} ->
        Process.put(:mcp_http_client, {:ok, pid})
        {result, pid}

      _ ->
        {result, nil}
    end
  end

  defp start_streamable_client do
    port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.StreamableFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_streamable_http_transport, transport)

    result = HTTP.start_link(url: "http://127.0.0.1:#{port}/mcp", timeout_ms: 5_000)

    case result do
      {:ok, pid} ->
        Process.put(:mcp_streamable_http_client, {:ok, pid})
        {result, pid, store, transport}

      _ ->
        {result, nil, store, transport}
    end
  end

  defp start_oauth_metadata_probe do
    port = free_port()

    {:ok, transport} =
      Bandit.start_link(
        plug: LemonScripts.LiveMcpHttpSmoke.OAuthMetadataFixture,
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_oauth_metadata_transport, transport)

    previous_trap_exit = Process.flag(:trap_exit, true)
    result = HTTP.start_link(url: "http://127.0.0.1:#{port}/mcp", timeout_ms: 5_000)
    Process.flag(:trap_exit, previous_trap_exit)

    {result, port, transport}
  end

  defp start_oauth_token_client do
    port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_oauth_token_transport, transport)

    result =
      HTTP.start_link(
        url: "http://127.0.0.1:#{port}/mcp",
        oauth: [client_id: "lemon", client_secret: "secret", scopes: ["tools", "prompts"]],
        timeout_ms: 5_000
      )

    case result do
      {:ok, pid} ->
        Process.put(:mcp_oauth_token_client, {:ok, pid})
        {result, pid, store, port, transport}

      _ ->
        {result, nil, store, port, transport}
    end
  end

  defp start_oauth_refresh_client do
    port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_oauth_refresh_transport, transport)

    result =
      HTTP.start_link(
        url: "http://127.0.0.1:#{port}/mcp",
        oauth: [client_id: "lemon", client_secret: "secret", scope: "expire"],
        timeout_ms: 5_000
      )

    case result do
      {:ok, pid} ->
        Process.put(:mcp_oauth_refresh_client, {:ok, pid})
        {result, pid, store, port, transport}

      _ ->
        {result, nil, store, port, transport}
    end
  end

  defp start_oauth_refresh_token_client do
    port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_oauth_refresh_token_transport, transport)

    result =
      HTTP.start_link(
        url: "http://127.0.0.1:#{port}/mcp",
        oauth: [client_id: "lemon", client_secret: "secret", scope: "refresh-lifecycle"],
        timeout_ms: 5_000
      )

    case result do
      {:ok, pid} ->
        Process.put(:mcp_oauth_refresh_token_client, {:ok, pid})
        {result, pid, store, port, transport}

      _ ->
        {result, nil, store, port, transport}
    end
  end

  defp start_oauth_basic_client do
    port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_oauth_basic_transport, transport)

    result =
      HTTP.start_link(
        url: "http://127.0.0.1:#{port}/mcp",
        oauth: [
          client_id: "lemon",
          client_secret: "secret",
          scopes: ["tools"],
          token_auth_method: :client_secret_basic
        ],
        timeout_ms: 5_000
      )

    case result do
      {:ok, pid} ->
        Process.put(:mcp_oauth_basic_client, {:ok, pid})
        {result, pid, store, port, transport}

      _ ->
        {result, nil, store, port, transport}
    end
  end

  defp start_oauth_pkce_client do
    port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)
    {:ok, authorization_request} = Agent.start_link(fn -> nil end)

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_oauth_pkce_transport, transport)

    result =
      HTTP.start_link(
        url: "http://127.0.0.1:#{port}/mcp",
        oauth: [
          flow: :authorization_code_pkce,
          client_id: "lemon-public",
          redirect_uri: "http://127.0.0.1/callback",
          scopes: ["tools"],
          authorization_code_provider: fn request ->
            Agent.update(authorization_request, fn _ -> request end)
            {:ok, %{code: "operator-code", state: request.state}}
          end
        ],
        timeout_ms: 5_000
      )

    case result do
      {:ok, pid} ->
        Process.put(:mcp_oauth_pkce_client, {:ok, pid})
        {result, pid, store, port, authorization_request, transport}

      _ ->
        {result, nil, store, port, authorization_request, transport}
    end
  end

  defp start_oauth_cached_pkce_client do
    port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)
    {:ok, authorization_request} = Agent.start_link(fn -> nil end)
    {:ok, token_cache} = Agent.start_link(fn -> nil end)

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    Process.put(:mcp_oauth_cached_pkce_transport, transport)

    cache = [
      load: fn -> Agent.get(token_cache, & &1) end,
      save: fn token ->
        Agent.update(token_cache, fn _ -> token end)
        :ok
      end
    ]

    oauth = [
      flow: :authorization_code_pkce,
      client_id: "lemon-public",
      redirect_uri: "http://127.0.0.1/callback",
      scopes: ["tools"],
      authorization_code_provider: fn request ->
        Agent.update(authorization_request, fn _ -> request end)
        {:ok, %{code: "operator-code", state: request.state}}
      end
    ]

    first_result =
      HTTP.start_link(
        url: "http://127.0.0.1:#{port}/mcp",
        oauth: oauth,
        oauth_token_cache: cache,
        timeout_ms: 5_000
      )

    with {:ok, first_client} <- first_result do
      assert_until(fn -> HTTP.state(first_client) == :ready end)
      {:ok, [%{"name" => "secured_echo"}]} = HTTP.list_tools(first_client, 5_000)
      _ = HTTP.close(first_client)
      Agent.update(store, fn _ -> [] end)

      resume_oauth =
        Keyword.put(oauth, :authorization_code_provider, fn _request ->
          raise "authorization_code_provider called despite cached OAuth token"
        end)

      result =
        HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: resume_oauth,
          oauth_token_cache: cache,
          timeout_ms: 5_000
        )

      case result do
        {:ok, pid} ->
          Process.put(:mcp_oauth_cached_pkce_client, {:ok, pid})
          {result, pid, store, port, authorization_request, token_cache, transport}

        _ ->
          {result, nil, store, port, authorization_request, token_cache, transport}
      end
    else
      _ ->
        {first_result, nil, store, port, authorization_request, token_cache, transport}
    end
  end

  defp configure_mcp_source(url, opts \\ []) do
    Application.put_env(:lemon_skills, :mcp_servers, [
      if opts == [] do
        {:http, url}
      else
        {:http, url, opts}
      end
    ])

    McpSource.refresh()
  end

  defp run_oauth_loopback_source do
    port = free_port()
    callback_port = free_port()
    {:ok, store} = Agent.start_link(fn -> [] end)
    parent = self()

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpHttpSmoke.OAuthTokenFixture, store: store},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    url = "http://127.0.0.1:#{port}/mcp"
    run_id = "mcp-oauth-smoke-#{System.unique_integer([:positive, :monotonic])}"
    session_key = "agent:mcp-oauth-smoke:main"

    Application.put_env(:lemon_skills, :mcp_servers, [
      {:http, url,
       oauth: [
         flow: :authorization_code_pkce,
         client_id: "lemon-public",
         redirect_uri: "http://127.0.0.1:#{callback_port}/callback",
         scopes: ["tools"],
         authorization_timeout_ms: 5_000,
         authorization_request_observer: parent,
         authorization_approval_context: [
           run_id: run_id,
           session_key: session_key,
           agent_id: "mcp-oauth-smoke"
         ]
       ]}
    ])

    task = Task.async(fn -> McpSource.discover_tools(force_refresh: true) end)

    request =
      receive do
        {:mcp_oauth_authorization_request, request} -> request
      after
        2_000 -> raise "loopback authorization request was not observed"
      end

    pending = wait_for_pending_approval(run_id)

    callback_url =
      "http://127.0.0.1:#{callback_port}/callback?" <>
        URI.encode_query(%{"code" => "loopback-code", "state" => request.state})

    {:ok, {{_, 200, _}, _headers, _body}} =
      :httpc.request(
        :get,
        {String.to_charlist(callback_url), []},
        [timeout: 1_000, connect_timeout: 1_000],
        body_format: :binary
      )

    :ok = LemonCore.ExecApprovals.resolve(pending.id, :approve_once)

    tools = Task.await(task, 10_000)
    observed = Agent.get(store, &Enum.reverse/1)
    {tools, observed, request, pending, port, callback_port, transport}
  end

  defp wait_for_pending_approval(run_id, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    case find_pending_approval(run_id) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "timed out waiting for pending approval #{run_id}"
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
    |> Enum.find(&(Map.get(&1, :run_id) == run_id))
  end

  defp start_http_transport(port) do
    Transport.HTTP.start_link(
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
    )
  end

  defp check(name, fun) do
    fun.()
    %{name: name, proof_scope: "mcp_http_smoke", status: "completed"}
  rescue
    error ->
      %{
        name: name,
        proof_scope: "mcp_http_smoke",
        status: "failed",
        reason_kind: "mcp_http_smoke_failure",
        failure_hint: error.__struct__ |> Atom.to_string()
      }
  catch
    kind, reason ->
      %{
        name: name,
        proof_scope: "mcp_http_smoke",
        status: "failed",
        reason_kind: "mcp_http_smoke_failure",
        failure_hint: "#{kind}:#{inspect(reason)}"
      }
  end

  defp assert_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "condition timeout"

      true ->
        Process.sleep(50)
        assert_until(fun, deadline)
    end
  end

  defp proof_status(_completed_count, _skipped_count, failed_count) when failed_count > 0,
    do: "failed"

  defp proof_status(0, skipped_count, 0) when skipped_count > 0, do: "skipped"
  defp proof_status(completed_count, _skipped_count, 0) when completed_count > 0, do: "completed"
  defp proof_status(_completed_count, _skipped_count, _failed_count), do: "unknown"

  defp archive_path(proof_path) do
    stamp =
      DateTime.utc_now()
      |> DateTime.to_iso8601(:basic)
      |> String.replace(~r/[^0-9A-Za-z]/, "")

    Path.join(Path.dirname(proof_path), "mcp-http-smoke-#{stamp}.json")
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value, pretty: true))
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

LemonScripts.LiveMcpHttpSmoke.main(System.argv())
