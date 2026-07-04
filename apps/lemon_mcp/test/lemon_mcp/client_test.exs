defmodule LemonMCP.ClientTest.SSEFixture do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/sse" do
    session = Integer.to_string(System.unique_integer([:positive]))
    store = conn.assigns.store
    stream_pid = self()

    Agent.update(store, &Map.put(&1, session, stream_pid))

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: endpoint\ndata: /messages/#{session}\n\n")
    stream_loop(conn)
  end

  post "/messages/:session" do
    store = conn.assigns.store
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    if response = response_for(request) do
      pid = Agent.get(store, &Map.fetch!(&1, session))
      send(pid, {:sse_message, Jason.encode!(response)})
    end

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

  defp response_for(%{"method" => "initialize", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => LemonMCP.protocol_version(),
        "capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}},
        "serverInfo" => %{"name" => "SSE Fixture", "version" => "1.0.0"}
      }
    }
  end

  defp response_for(%{"method" => "notifications/initialized"}), do: nil

  defp response_for(%{"method" => "tools/list", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "tools" => [
          %{
            "name" => "echo",
            "description" => "Echo a message",
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
    }
  end

  defp response_for(%{
         "method" => "tools/call",
         "id" => id,
         "params" => %{"name" => "echo", "arguments" => args}
       }) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => "echo:" <> Map.get(args, "message", "")}],
        "isError" => false
      }
    }
  end

  defp response_for(%{"method" => "tools/call", "id" => id, "params" => %{"name" => "fail"}}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "content" => [%{"type" => "text", "text" => "planned failure"}],
        "isError" => true
      }
    }
  end

  defp response_for(%{"method" => "resources/list", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"resources" => [%{"uri" => "fixture://status", "name" => "Status"}]}
    }
  end

  defp response_for(%{
         "method" => "resources/read",
         "id" => id,
         "params" => %{"uri" => "fixture://status"}
       }) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "contents" => [%{"uri" => "fixture://status", "text" => "status:ok"}]
      }
    }
  end

  defp response_for(%{"method" => "prompts/list", "id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"prompts" => [%{"name" => "brief", "description" => "Write a brief"}]}
    }
  end

  defp response_for(%{
         "method" => "prompts/get",
         "id" => id,
         "params" => %{"name" => "brief", "arguments" => args}
       }) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "description" => "Write a brief",
        "messages" => [
          %{
            "role" => "user",
            "content" => %{"type" => "text", "text" => "brief:" <> Map.get(args, "topic", "")}
          }
        ]
      }
    }
  end

  defp response_for(%{"id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    }
  end
end

defmodule LemonMCP.ClientTest.StreamableHTTPFixture do
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

      {response, :sse} ->
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_resp(200, "event: message\ndata: #{Jason.encode!(response)}\n\n")

      {response, :json} ->
        conn
        |> put_resp_header("mcp-session-id", "stream-session-1")
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response))
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
       "error" => %{"code" => -32_601, "message" => "Method not found"}
     }, :json}
  end
end

defmodule LemonMCP.ClientTest.OAuthMetadataFixture do
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

defmodule LemonMCP.ClientTest.OAuthTokenFixture do
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

  defp mcp_response(%{"method" => "notifications/initialized"}), do: %{}

  defp mcp_response(%{"id" => id}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
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

  defp issue_token(_store, %{"grant_type" => "authorization_code", "code" => "operator-code"}),
    do: %{
      "access_token" => "auth-code-token",
      "refresh_token" => "auth-refresh",
      "token_type" => "Bearer"
    }

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
    form["client_id"] == "lemon-public" and form["code"] == "operator-code" and
      is_binary(form["code_verifier"]) and form["code_verifier"] != "" and
      form["redirect_uri"] == "http://127.0.0.1/callback"
  end

  defp valid_oauth_token_request?(_form, _headers), do: false

  defp record(store, event), do: Agent.update(store, &[event | &1])
end

defmodule LemonMCP.ClientTest do
  use ExUnit.Case, async: false

  alias LemonMCP.Protocol

  describe "protocol operations" do
    test "initialize_request creates valid request" do
      request =
        Protocol.initialize_request(
          id: "test-init",
          client_name: "test-client",
          client_version: "1.0.0"
        )

      assert request.method == "initialize"
      assert request.params.protocolVersion == "2024-11-05"
      assert request.params.clientInfo.name == "test-client"
    end

    test "tool_list_request creates valid request" do
      request = Protocol.tool_list_request(id: "test-list")

      assert request.method == "tools/list"
      assert request.id == "test-list"
    end

    test "tool_call_request creates valid request" do
      request =
        Protocol.tool_call_request(
          id: "test-call",
          name: "echo",
          arguments: %{"message" => "hello"}
        )

      assert request.method == "tools/call"
      assert request.params.name == "echo"
      assert request.params.arguments == %{"message" => "hello"}
    end

    test "resource and prompt requests create valid requests" do
      resource = Protocol.resource_read_request(id: "test-resource", uri: "file://safe")
      prompt = Protocol.prompt_get_request(id: "test-prompt", name: "brief", arguments: %{})

      assert resource.method == "resources/read"
      assert resource.params.uri == "file://safe"
      assert prompt.method == "prompts/get"
      assert prompt.params.name == "brief"
    end
  end

  describe "message encoding/decoding" do
    test "encode and decode initialize request" do
      request = Protocol.initialize_request(id: "enc-test")
      {:ok, json} = Protocol.encode(request)
      assert is_binary(json)

      # Decode as map since it's a request (not a response)
      {:ok, decoded} = Jason.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == "enc-test"
      assert decoded["method"] == "initialize"
    end

    test "encode and decode tool call response" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "resp-1",
        "result": {
          "content": [{"type": "text", "text": "result"}],
          "isError": false
        }
      }|

      {:ok, response} = Protocol.decode(json)
      assert %Protocol.ToolCallResponse{} = response
      assert response.id == "resp-1"
      assert response.result.isError == false
    end

    test "decode resource and prompt responses" do
      {:ok, resource_response} =
        Protocol.decode(~s|{
          "jsonrpc": "2.0",
          "id": "resource-1",
          "result": {"contents": [{"uri": "file://safe", "text": "ok"}]}
        }|)

      {:ok, prompt_response} =
        Protocol.decode(~s|{
          "jsonrpc": "2.0",
          "id": "prompt-1",
          "result": {"description": "Brief", "messages": [{"role": "user"}]}
        }|)

      assert %Protocol.ResourceReadResponse{} = resource_response
      assert [%{"text" => "ok"}] = resource_response.result.contents
      assert %Protocol.PromptGetResponse{} = prompt_response
      assert [%{"role" => "user"}] = prompt_response.result.messages
    end
  end

  describe "error handling" do
    test "handles JSON parse error" do
      result = Protocol.decode(~s|{invalid json}|)
      assert {:error, _} = result
    end

    test "handles missing jsonrpc field" do
      result = Protocol.decode(~s|{"id": "1", "result": {}}|)
      assert {:error, :invalid_jsonrpc} = result
    end

    test "decodes error response correctly" do
      json = ~s|{
        "jsonrpc": "2.0",
        "id": "err-1",
        "error": {
          "code": -32601,
          "message": "Method not found",
          "data": "extra info"
        }
      }|

      {:ok, response} = Protocol.decode(json)
      assert response.error != nil
      assert response.error.code == -32_601
      assert response.error.message == "Method not found"
      assert response.error.data == "extra info"
    end
  end

  describe "client state management" do
    test "client tracks server info after initialization" do
      # Simulate the flow: when client receives initialize response,
      # it should store server info

      init_response = %Protocol.InitializeResponse{
        id: "init-1",
        result: %{
          protocolVersion: "2024-11-05",
          capabilities: %{tools: true},
          serverInfo: %{name: "test-server", version: "1.0.0"}
        },
        error: nil
      }

      assert init_response.result.serverInfo.name == "test-server"
      assert init_response.result.serverInfo.version == "1.0.0"
    end

    test "client handles tool errors" do
      error_response = %Protocol.ToolCallResponse{
        id: "call-1",
        result: %{
          content: [%{type: "text", text: "Error occurred"}],
          isError: true
        },
        error: nil
      }

      assert error_response.result.isError == true
    end
  end

  describe "stdio client sampling" do
    test "advertises sampling and routes server sampling requests through callback" do
      parent = self()

      handler = fn params ->
        send(parent, {:sampling_params, params})

        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "sampled"},
           "model" => "lemon-test",
           "stopReason" => "endTurn"
         }}
      end

      {:ok, client} =
        LemonMCP.Client.start_link(
          command: "node",
          args: ["-e", sampling_fixture_node()],
          sampling_handler: handler,
          timeout_ms: 2_000
        )

      assert_receive {:sampling_params,
                      %{
                        "sawSamplingCapability" => true,
                        "messages" => [
                          %{"role" => "user", "content" => %{"type" => "text", "text" => "ping"}}
                        ],
                        "maxTokens" => 16
                      }},
                     2_000

      assert LemonMCP.Client.state(client) in [:ready, :disconnected]
    end

    test "sampling policy advertises sampling and routes requests through review" do
      parent = self()

      reviewer = fn summary ->
        send(parent, {:sampling_review, summary})
        :approve
      end

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

      {:ok, client} =
        LemonMCP.Client.start_link(
          command: "node",
          args: ["-e", sampling_fixture_node()],
          sampling_policy: [
            mode: :reviewed_model,
            reviewer: reviewer,
            delegate: delegate,
            max_tokens: 32,
            allowed_models: []
          ],
          timeout_ms: 2_000
        )

      assert_receive {:sampling_review,
                      %{
                        message_count: 1,
                        max_tokens: 16,
                        text_char_count: 4,
                        request_hash: request_hash
                      } = review_summary},
                     2_000

      assert is_binary(request_hash)
      refute inspect(review_summary) =~ "ping"

      assert_receive {:sampling_delegate,
                      %{
                        "sawSamplingCapability" => true,
                        "messages" => [
                          %{"role" => "user", "content" => %{"type" => "text", "text" => "ping"}}
                        ],
                        "maxTokens" => 16
                      }, ^review_summary},
                     2_000

      assert LemonMCP.Client.state(client) in [:ready, :disconnected]
    end
  end

  describe "HTTP client" do
    test "initializes, lists tools, and calls tools through HTTP transport" do
      port = start_http_transport()

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(client) == :ready

      assert {:ok, %{name: "HTTP Fixture", version: "1.0.0"}} =
               LemonMCP.Client.HTTP.server_info(client)

      assert {:ok, capabilities} = LemonMCP.Client.HTTP.server_capabilities(client)
      assert capabilities["tools"] == %{}
      assert capabilities["resources"] == %{}
      assert capabilities["prompts"] == %{}

      assert {:ok, tools} = LemonMCP.Client.HTTP.list_tools(client)
      assert Enum.map(tools, & &1["name"]) == ["echo", "fail"]

      assert {:ok, [%{"type" => "text", "text" => "echo:ok"}]} =
               LemonMCP.Client.HTTP.call_tool(client, "echo", %{"message" => "ok"})

      assert {:error, {:tool_error, [%{"type" => "text", "text" => "planned failure"}]}} =
               LemonMCP.Client.HTTP.call_tool(client, "fail", %{})

      assert {:ok, [%{"uri" => "fixture://status"}]} =
               LemonMCP.Client.HTTP.list_resources(client)

      assert {:ok, [%{"uri" => "fixture://status", "text" => "status:ok"}]} =
               LemonMCP.Client.HTTP.read_resource(client, "fixture://status")

      assert {:ok, [%{"name" => "brief"}]} = LemonMCP.Client.HTTP.list_prompts(client)

      assert {:ok, %{messages: [%{"role" => "user"}]}} =
               LemonMCP.Client.HTTP.get_prompt(client, "brief", %{"topic" => "beam"})
    end

    test "supports streamable HTTP SSE responses and session headers" do
      {port, store} = start_streamable_http_transport()

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(client) == :ready

      assert {:ok, %{name: "Streamable Fixture", version: "1.0.0"}} =
               LemonMCP.Client.HTTP.server_info(client)

      assert {:ok, [%{"name" => "stream_echo"}]} = LemonMCP.Client.HTTP.list_tools(client)

      observed =
        store
        |> Agent.get(& &1)
        |> Enum.reverse()

      assert {"initialize", initialize_headers} = Enum.at(observed, 0)
      assert String.contains?(initialize_headers["accept"], "application/json")
      assert String.contains?(initialize_headers["accept"], "text/event-stream")

      assert {"notifications/initialized", initialized_headers} = Enum.at(observed, 1)
      assert initialized_headers["mcp-session-id"] == "stream-session-1"
      assert initialized_headers["mcp-protocol-version"] == "2025-06-18"

      assert {"tools/list", list_headers} = Enum.at(observed, 2)
      assert list_headers["mcp-session-id"] == "stream-session-1"
      assert list_headers["mcp-protocol-version"] == "2025-06-18"
    end

    test "returns OAuth protected-resource metadata for auth challenges" do
      port = start_oauth_metadata_transport()
      previous_trap_exit = Process.flag(:trap_exit, true)

      assert {:error, {:auth_required, metadata}} =
               LemonMCP.Client.HTTP.start_link(
                 url: "http://127.0.0.1:#{port}/mcp",
                 timeout_ms: 2_000
               )

      Process.flag(:trap_exit, previous_trap_exit)

      assert metadata["resource"] == "http://127.0.0.1:#{port}/mcp"
      assert metadata["authorization_servers"] == ["http://127.0.0.1:#{port}/oauth"]
      assert metadata["resource_metadata_url"] =~ "/.well-known/oauth-protected-resource/mcp"
      assert metadata["www_authenticate"] =~ "Bearer"

      assert [authorization_metadata] = metadata["authorization_server_metadata"]
      assert authorization_metadata["issuer"] == "http://127.0.0.1:#{port}/oauth"

      assert authorization_metadata["authorization_endpoint"] ==
               "http://127.0.0.1:#{port}/oauth/authorize"

      assert authorization_metadata["token_endpoint"] == "http://127.0.0.1:#{port}/oauth/token"

      assert authorization_metadata["registration_endpoint"] ==
               "http://127.0.0.1:#{port}/oauth/register"

      assert authorization_metadata["metadata_url"] ==
               "http://127.0.0.1:#{port}/.well-known/oauth-authorization-server/oauth"
    end

    test "uses configured OAuth client credentials to acquire a token and retry" do
      {port, store} = start_oauth_token_transport()

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: [client_id: "lemon", client_secret: "secret", scopes: ["tools", "prompts"]],
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(client) == :ready

      assert {:ok, %{name: "OAuth Token Fixture", version: "1.0.0"}} =
               LemonMCP.Client.HTTP.server_info(client)

      assert {:ok, [%{"name" => "secured_echo"}]} = LemonMCP.Client.HTTP.list_tools(client)

      observed = Agent.get(store, &Enum.reverse/1)

      assert {:metadata, metadata_headers} =
               Enum.find(observed, &match?({:metadata, _headers}, &1))

      refute Map.has_key?(metadata_headers, "authorization")

      assert {:authorization_metadata, authorization_metadata_headers} =
               Enum.find(observed, &match?({:authorization_metadata, _headers}, &1))

      refute Map.has_key?(authorization_metadata_headers, "authorization")

      assert {:token, token_form, _token_headers} =
               Enum.find(observed, &match?({:token, _form, _headers}, &1))

      assert token_form["grant_type"] == "client_credentials"
      assert token_form["client_id"] == "lemon"
      assert token_form["client_secret"] == "secret"
      assert token_form["resource"] == "http://127.0.0.1:#{port}/mcp"
      assert token_form["scope"] == "tools prompts"

      authorized_requests =
        Enum.filter(observed, fn
          {:mcp, _method, %{"authorization" => "Bearer fixture-token"}} -> true
          _ -> false
        end)

      assert length(authorized_requests) >= 2
    end

    test "reacquires configured OAuth client credentials after a bearer token expires" do
      {port, store} = start_oauth_token_transport()

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: [client_id: "lemon", client_secret: "secret", scope: "expire"],
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(client) == :ready
      assert {:ok, [%{"name" => "secured_echo"}]} = LemonMCP.Client.HTTP.list_tools(client)

      observed = Agent.get(store, &Enum.reverse/1)

      assert Enum.count(observed, &match?({:token, _form, _headers}, &1)) == 2
      assert {:issued_token, "expiring-token"} in observed
      assert {:issued_token, "refreshed-token"} in observed

      assert Enum.any?(observed, fn
               {:mcp, "tools/list", %{"authorization" => "Bearer expiring-token"}} -> true
               _ -> false
             end)

      assert Enum.any?(observed, fn
               {:mcp, "tools/list", %{"authorization" => "Bearer refreshed-token"}} -> true
               _ -> false
             end)
    end

    test "uses OAuth refresh-token grant after a refresh-capable bearer token expires" do
      {port, store} = start_oauth_token_transport()

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: [client_id: "lemon", client_secret: "secret", scope: "refresh-lifecycle"],
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(client) == :ready
      assert {:ok, [%{"name" => "secured_echo"}]} = LemonMCP.Client.HTTP.list_tools(client)

      observed = Agent.get(store, &Enum.reverse/1)

      token_requests =
        Enum.filter(observed, &match?({:token, _form, _headers}, &1))

      assert length(token_requests) == 2

      assert [{:token, client_credentials_form, _}, {:token, refresh_form, _}] = token_requests

      assert client_credentials_form["grant_type"] == "client_credentials"
      assert client_credentials_form["scope"] == "refresh-lifecycle"

      assert refresh_form["grant_type"] == "refresh_token"
      assert refresh_form["refresh_token"] == "refresh-one"
      assert refresh_form["resource"] == "http://127.0.0.1:#{port}/mcp"

      assert {:issued_token, "refresh-expiring-token"} in observed
      assert {:issued_token, "refresh-access-token"} in observed

      assert Enum.any?(observed, fn
               {:mcp, "tools/list", %{"authorization" => "Bearer refresh-expiring-token"}} ->
                 true

               _ ->
                 false
             end)

      assert Enum.any?(observed, fn
               {:mcp, "tools/list", %{"authorization" => "Bearer refresh-access-token"}} ->
                 true

               _ ->
                 false
             end)
    end

    test "supports OAuth client_secret_basic token endpoint authentication" do
      {port, store} = start_oauth_token_transport()

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: [
            client_id: "lemon",
            client_secret: "secret",
            scopes: ["tools"],
            token_auth_method: :client_secret_basic
          ],
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(client) == :ready
      assert {:ok, [%{"name" => "secured_echo"}]} = LemonMCP.Client.HTTP.list_tools(client)

      observed = Agent.get(store, &Enum.reverse/1)

      assert {:token, token_form, token_headers} =
               Enum.find(observed, &match?({:token, _form, _headers}, &1))

      assert token_form["grant_type"] == "client_credentials"
      refute Map.has_key?(token_form, "client_id")
      refute Map.has_key?(token_form, "client_secret")
      assert token_form["scope"] == "tools"
      assert token_headers["authorization"] == "Basic " <> Base.encode64("lemon:secret")
    end

    test "uses OAuth authorization-code PKCE callback to acquire a token and retry" do
      {port, store} = start_oauth_token_transport()
      test_pid = self()

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: [
            client_id: "lemon-public",
            redirect_uri: "http://127.0.0.1/callback",
            scopes: ["tools"],
            authorization_code_provider: fn request ->
              send(test_pid, {:authorization_request, request})
              {:ok, %{code: "operator-code", state: request.state}}
            end
          ],
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(client) == :ready
      assert {:ok, [%{"name" => "secured_echo"}]} = LemonMCP.Client.HTTP.list_tools(client)

      assert_receive {:authorization_request, authorization_request}

      assert authorization_request.authorization_endpoint ==
               "http://127.0.0.1:#{port}/oauth/authorize"

      assert authorization_request.client_id == "lemon-public"
      assert authorization_request.redirect_uri == "http://127.0.0.1/callback"
      assert authorization_request.scope == "tools"
      assert authorization_request.resource == "http://127.0.0.1:#{port}/mcp"
      assert authorization_request.code_challenge_method == "S256"
      assert is_binary(authorization_request.state) and authorization_request.state != ""
      assert is_binary(authorization_request.code_verifier)
      assert is_binary(authorization_request.code_challenge)

      expected_challenge =
        :crypto.hash(:sha256, authorization_request.code_verifier)
        |> Base.url_encode64(padding: false)

      assert authorization_request.code_challenge == expected_challenge

      query =
        authorization_request.authorization_url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query["response_type"] == "code"
      assert query["client_id"] == "lemon-public"
      assert query["redirect_uri"] == "http://127.0.0.1/callback"
      assert query["scope"] == "tools"
      assert query["resource"] == "http://127.0.0.1:#{port}/mcp"
      assert query["state"] == authorization_request.state
      assert query["code_challenge"] == authorization_request.code_challenge
      assert query["code_challenge_method"] == "S256"

      observed = Agent.get(store, &Enum.reverse/1)

      assert {:token, token_form, _token_headers} =
               Enum.find(observed, &match?({:token, _form, _headers}, &1))

      assert token_form["grant_type"] == "authorization_code"
      assert token_form["client_id"] == "lemon-public"
      assert token_form["code"] == "operator-code"
      assert token_form["code_verifier"] == authorization_request.code_verifier
      assert token_form["redirect_uri"] == "http://127.0.0.1/callback"
      assert token_form["resource"] == "http://127.0.0.1:#{port}/mcp"
      assert token_form["scope"] == "tools"

      assert Enum.any?(observed, fn
               {:mcp, "tools/list", %{"authorization" => "Bearer auth-code-token"}} -> true
               _ -> false
             end)
    end

    test "loads and saves OAuth tokens through configured cache callbacks" do
      {port, store} = start_oauth_token_transport()
      test_pid = self()
      {:ok, cache} = Agent.start_link(fn -> nil end)

      token_cache = [
        load: fn -> Agent.get(cache, & &1) end,
        save: fn token ->
          Agent.update(cache, fn _ -> token end)
          :ok
        end
      ]

      {:ok, client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: [
            client_id: "lemon-public",
            redirect_uri: "http://127.0.0.1/callback",
            scopes: ["tools"],
            authorization_code_provider: fn request ->
              send(test_pid, {:authorization_request, request.state})
              {:ok, %{code: "operator-code", state: request.state}}
            end
          ],
          oauth_token_cache: token_cache,
          timeout_ms: 2_000
        )

      assert_receive {:authorization_request, _state}
      assert LemonMCP.Client.HTTP.state(client) == :ready
      assert {:ok, [%{"name" => "secured_echo"}]} = LemonMCP.Client.HTTP.list_tools(client)

      cached_token = Agent.get(cache, & &1)
      assert cached_token.access_token == "auth-code-token"
      assert cached_token.refresh_token == "auth-refresh"
      assert cached_token.metadata["resource"] == "http://127.0.0.1:#{port}/mcp"

      :ok = LemonMCP.Client.HTTP.close(client)
      Agent.update(store, fn _ -> [] end)

      {:ok, resumed_client} =
        LemonMCP.Client.HTTP.start_link(
          url: "http://127.0.0.1:#{port}/mcp",
          oauth: [
            client_id: "lemon-public",
            redirect_uri: "http://127.0.0.1/callback",
            scopes: ["tools"],
            authorization_code_provider: fn _request ->
              flunk("authorization callback should not run when cached token is accepted")
            end
          ],
          oauth_token_cache: token_cache,
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.HTTP.state(resumed_client) == :ready

      assert {:ok, [%{"name" => "secured_echo"}]} =
               LemonMCP.Client.HTTP.list_tools(resumed_client)

      observed = Agent.get(store, &Enum.reverse/1)
      refute Enum.any?(observed, &match?({:token, _form, _headers}, &1))

      assert Enum.any?(observed, fn
               {:mcp, "initialize", %{"authorization" => "Bearer auth-code-token"}} -> true
               _ -> false
             end)

      assert Enum.any?(observed, fn
               {:mcp, "tools/list", %{"authorization" => "Bearer auth-code-token"}} -> true
               _ -> false
             end)
    end

    test "rejects OAuth authorization-code callback responses with mismatched state" do
      {port, _store} = start_oauth_token_transport()
      previous_trap_exit = Process.flag(:trap_exit, true)

      assert {:error, {:auth_required, metadata}} =
               LemonMCP.Client.HTTP.start_link(
                 url: "http://127.0.0.1:#{port}/mcp",
                 oauth: [
                   client_id: "lemon-public",
                   redirect_uri: "http://127.0.0.1/callback",
                   authorization_code_provider: fn _request ->
                     {:ok, %{code: "operator-code", state: "wrong-state"}}
                   end
                 ],
                 timeout_ms: 2_000
               )

      Process.flag(:trap_exit, previous_trap_exit)
      assert metadata["resource"] == "http://127.0.0.1:#{port}/mcp"
    end
  end

  describe "SSE client" do
    test "initializes, lists tools, and calls tools through legacy HTTP+SSE transport" do
      {port, store} = start_sse_transport()

      {:ok, client} =
        LemonMCP.Client.SSE.start_link(
          url: "http://127.0.0.1:#{port}/sse",
          timeout_ms: 2_000
        )

      assert LemonMCP.Client.SSE.state(client) == :ready

      assert {:ok, %{name: "SSE Fixture", version: "1.0.0"}} =
               LemonMCP.Client.SSE.server_info(client)

      assert {:ok, capabilities} = LemonMCP.Client.SSE.server_capabilities(client)
      assert capabilities["tools"] == %{}
      assert capabilities["resources"] == %{}
      assert capabilities["prompts"] == %{}

      assert {:ok, tools} = LemonMCP.Client.SSE.list_tools(client)
      assert Enum.map(tools, & &1["name"]) == ["echo", "fail"]

      assert {:ok, [%{"type" => "text", "text" => "echo:ok"}]} =
               LemonMCP.Client.SSE.call_tool(client, "echo", %{"message" => "ok"})

      assert {:error, {:tool_error, [%{"type" => "text", "text" => "planned failure"}]}} =
               LemonMCP.Client.SSE.call_tool(client, "fail", %{})

      assert {:ok, [%{"uri" => "fixture://status"}]} =
               LemonMCP.Client.SSE.list_resources(client)

      assert {:ok, [%{"uri" => "fixture://status", "text" => "status:ok"}]} =
               LemonMCP.Client.SSE.read_resource(client, "fixture://status")

      assert {:ok, [%{"name" => "brief"}]} = LemonMCP.Client.SSE.list_prompts(client)

      assert {:ok, %{messages: [%{"role" => "user"}]}} =
               LemonMCP.Client.SSE.get_prompt(client, "brief", %{"topic" => "beam"})

      assert :ok = LemonMCP.Client.SSE.close(client)
      stop_sse_streams(store)
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

  defp sampling_fixture_node do
    """
    const readline = require('readline');
    const rl = readline.createInterface({ input: process.stdin });
    let sawSamplingCapability = false;
    const send = (message) => process.stdout.write(JSON.stringify(message) + '\\n');

    rl.on('line', (line) => {
      const message = JSON.parse(line);

      if (message.method === 'initialize') {
        sawSamplingCapability = !!(message.params.capabilities && message.params.capabilities.sampling);
        send({
          jsonrpc: '2.0',
          id: message.id,
          result: {
            protocolVersion: message.params.protocolVersion,
            capabilities: { tools: {} },
            serverInfo: { name: 'Sampling Fixture', version: '1.0.0' }
          }
        });
      } else if (message.method === 'notifications/initialized') {
        send({
          jsonrpc: '2.0',
          id: 'sampling-1',
          method: 'sampling/createMessage',
          params: {
            messages: [{ role: 'user', content: { type: 'text', text: 'ping' } }],
            maxTokens: 16,
            sawSamplingCapability
          }
        });
      } else if (message.id === 'sampling-1' && message.result) {
        setTimeout(() => process.exit(0), 20);
      }
    });

    setTimeout(() => process.exit(1), 2000);
    """
  end

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
    {:ok, store} = start_supervised({Agent, fn -> %{} end})
    port = start_bandit({LemonMCP.ClientTest.SSEFixture, store: store})

    {port, store}
  end

  defp start_streamable_http_transport do
    {:ok, store} = start_supervised({Agent, fn -> [] end})
    port = start_bandit({LemonMCP.ClientTest.StreamableHTTPFixture, store: store})

    {port, store}
  end

  defp start_oauth_metadata_transport do
    start_bandit(LemonMCP.ClientTest.OAuthMetadataFixture)
  end

  defp start_oauth_token_transport do
    {:ok, store} = start_supervised({Agent, fn -> [] end})
    port = start_bandit({LemonMCP.ClientTest.OAuthTokenFixture, store: store})

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

  defp start_bandit(plug) do
    pid =
      start_supervised!({Bandit, plug: plug, scheme: :http, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end
end
