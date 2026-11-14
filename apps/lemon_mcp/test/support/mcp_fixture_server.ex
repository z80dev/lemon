defmodule LemonMCP.TestSupport.FixtureServer do
  @moduledoc false
  # Scripted MCP server shared by the HTTP and SSE client fixtures: `echo` and
  # `fail` tools, one `fixture://status` resource, and one `brief` prompt.

  @spec response_for(map(), String.t()) :: map() | nil
  def response_for(%{"method" => "initialize", "id" => id}, server_name) do
    result(id, %{
      "protocolVersion" => LemonMCP.Protocol.protocol_version(),
      "capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}},
      "serverInfo" => %{"name" => server_name, "version" => "1.0.0"}
    })
  end

  def response_for(%{"method" => "notifications/initialized"}, _server_name), do: nil

  def response_for(%{"method" => "tools/list", "id" => id}, _server_name) do
    result(id, %{
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
    })
  end

  def response_for(
        %{"method" => "tools/call", "id" => id, "params" => %{"name" => "echo"} = params},
        _server_name
      ) do
    message = get_in(params, ["arguments", "message"]) || ""

    result(id, %{
      "content" => [%{"type" => "text", "text" => "echo:" <> message}],
      "isError" => false
    })
  end

  def response_for(
        %{"method" => "tools/call", "id" => id, "params" => %{"name" => "fail"}},
        _server_name
      ) do
    result(id, %{
      "content" => [%{"type" => "text", "text" => "planned failure"}],
      "isError" => true
    })
  end

  def response_for(%{"method" => "resources/list", "id" => id}, _server_name) do
    result(id, %{"resources" => [%{"uri" => "fixture://status", "name" => "Status"}]})
  end

  def response_for(
        %{"method" => "resources/read", "id" => id, "params" => %{"uri" => "fixture://status"}},
        _server_name
      ) do
    result(id, %{"contents" => [%{"uri" => "fixture://status", "text" => "status:ok"}]})
  end

  def response_for(%{"method" => "prompts/list", "id" => id}, _server_name) do
    result(id, %{"prompts" => [%{"name" => "brief", "description" => "Write a brief"}]})
  end

  def response_for(
        %{"method" => "prompts/get", "id" => id, "params" => %{"name" => "brief"} = params},
        _server_name
      ) do
    topic = get_in(params, ["arguments", "topic"]) || ""

    result(id, %{
      "description" => "Write a brief",
      "messages" => [
        %{"role" => "user", "content" => %{"type" => "text", "text" => "brief:" <> topic}}
      ]
    })
  end

  def response_for(%{"id" => id}, _server_name) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    }
  end

  def response_for(_notification, _server_name), do: nil

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end

defmodule LemonMCP.TestSupport.HTTPFixture do
  @moduledoc false
  # Streamable HTTP endpoint (`POST /mcp`) backed by `FixtureServer`.
  # Options: `:server_name`.
  use Plug.Router

  alias LemonMCP.TestSupport.FixtureServer

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    case FixtureServer.response_for(request, conn.assigns.server_name) do
      nil ->
        send_resp(conn, 202, "")

      response ->
        conn
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
    |> Plug.Conn.assign(:server_name, Keyword.fetch!(opts, :server_name))
    |> super(opts)
  end
end

defmodule LemonMCP.TestSupport.SSEFixture do
  @moduledoc false
  # Legacy HTTP+SSE endpoint (`GET /sse` + `POST /messages/:session`) backed by
  # `FixtureServer`. Options: `:store` (an Agent holding session => stream pid)
  # and `:server_name`. Send `:stop` to a stored stream pid to close it.
  use Plug.Router

  alias LemonMCP.TestSupport.FixtureServer

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
    request = Jason.decode!(body)

    if response = FixtureServer.response_for(request, conn.assigns.server_name) do
      pid = Agent.get(conn.assigns.store, &Map.fetch!(&1, session))
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
    |> Plug.Conn.assign(:server_name, Keyword.fetch!(opts, :server_name))
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
