defmodule LemonMCP.Transport.HTTP do
  @moduledoc """
  HTTP transport for the MCP Server.

  Provides an HTTP endpoint that accepts MCP protocol messages via POST requests.
  Supports both single requests and batch requests (JSON-RPC spec).

  ## Configuration

      config :lemon_mcp, :http_transport,
        enabled: true,
        port: 4048,
        ip: {127, 0, 0, 1},
        server_name: "Lemon MCP Server",
        server_version: "0.1.0"

  ## Usage

  Start the HTTP transport:

      {:ok, pid} = LemonMCP.Transport.HTTP.start_link(
        port: 4048,
        server_name: "My Server",
        server_version: "1.0.0",
        tool_provider: MyToolProvider
      )

  Send MCP requests:

      POST /mcp
      Content-Type: application/json

      {
        "jsonrpc": "2.0",
        "id": "1",
        "method": "initialize",
        "params": {
          "protocolVersion": "2024-11-05",
          "capabilities": {},
          "clientInfo": {"name": "test-client", "version": "1.0.0"}
        }
      }

  """

  use Plug.Router

  require Logger

  alias LemonMCP.Protocol
  alias LemonMCP.Server
  alias LemonMCP.Server.Handler

  @default_port if(Code.ensure_loaded?(Mix) and Mix.env() == :test, do: 0, else: 4048)
  @default_ip {127, 0, 0, 1}

  plug(Plug.Logger, log: :debug)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # ============================================================================
  # Plug Router Routes
  # ============================================================================

  post "/mcp" do
    with {:ok, body} <- get_request_body(conn),
         {:ok, responses} <- handle_mcp_request(body, conn.assigns[:mcp_server]) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(responses))
    else
      {:error, :invalid_json} ->
        error =
          Protocol.create_error_response(
            nil,
            Protocol.error_code(:parse_error),
            "Parse error: invalid JSON"
          )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(error))

      {:error, reason} ->
        Logger.error("MCP request failed: #{inspect(reason)}")

        error =
          Protocol.create_error_response(
            nil,
            Protocol.error_code(:internal_error),
            "Internal error"
          )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(error))
    end
  end

  get "/health" do
    initialized =
      if conn.assigns[:mcp_server] do
        Server.initialized?(conn.assigns[:mcp_server])
      else
        false
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok", initialized: initialized}))
  end

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{error: "Not found"}))
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the HTTP transport server.

  ## Options

    * `:port` - Port to listen on (default: 4048, test: 0 for random port)
    * `:ip` - IP address to bind to (default: {127, 0, 0, 1})
    * `:server_name` - Server name for initialize response
    * `:server_version` - Server version for initialize response
    * `:tool_provider` - Module implementing tool provider behaviour
    * `:tools` - List of tools (alternative to tool_provider)
    * `:tool_handler` - Function to handle tool calls

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    if enabled?(opts) do
      port = Keyword.get(opts, :port, @default_port)
      ip = Keyword.get(opts, :ip, @default_ip)

      # Start the MCP server first
      server_opts = build_server_opts(opts)
      {:ok, server_pid} = Server.start_link(server_opts)

      Logger.info("Starting MCP HTTP transport on #{format_ip(ip)}:#{port}")

      # Use Bandit to serve the Plug with the MCP server in assigns
      bandit_opts = [
        plug: {__MODULE__, mcp_server: server_pid},
        ip: ip,
        port: port,
        scheme: :http
      ]

      # Store server pid for later retrieval
      :persistent_term.put({__MODULE__, :mcp_server}, server_pid)

      Bandit.start_link(bandit_opts)
    else
      Logger.info("MCP HTTP transport disabled")
      :ignore
    end
  end

  @doc """
  Returns the MCP server PID if the transport is running.
  """
  @spec get_server_pid() :: pid() | nil
  def get_server_pid do
    case :persistent_term.get({__MODULE__, :mcp_server}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: nil

      _ ->
        nil
    end
  end

  @doc """
  Returns whether the HTTP transport is enabled.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get(opts, :enabled, true)
  end

  @doc """
  Child spec for use in supervisors.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # ============================================================================
  # Plug Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    # Store the MCP server in the options for the call/2 callback
    opts
  end

  @impl true
  def call(conn, opts) do
    # Inject the MCP server into conn.assigns before routing
    server_pid = Keyword.get(opts, :mcp_server)
    conn = Plug.Conn.assign(conn, :mcp_server, server_pid)
    super(conn, opts)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_server_opts(opts) do
    [
      server_name: Keyword.get(opts, :server_name, "Lemon MCP Server"),
      server_version: Keyword.get(opts, :server_version, "0.1.0"),
      tool_provider: Keyword.get(opts, :tool_provider),
      tools: Keyword.get(opts, :tools),
      tool_handler: Keyword.get(opts, :tool_handler)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp get_request_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        # Body not yet fetched, try to read it
        case Plug.Conn.read_body(conn) do
          {:ok, body, _conn} -> parse_json(body)
          {:error, _reason} -> {:error, :invalid_body}
        end

      params when is_map(params) ->
        {:ok, params}

      _ ->
        {:error, :invalid_body}
    end
  end

  defp parse_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp handle_mcp_request(body, server_pid) when is_map(body) do
    # Check if it's a batch request (array) or single request
    if is_list(body) do
      # Batch request
      responses =
        body
        |> Enum.map(&process_single_request(&1, server_pid))
        |> Enum.reject(&is_nil/1)

      {:ok, responses}
    else
      # Single request
      case process_single_request(body, server_pid) do
        nil -> {:ok, nil}
        response -> {:ok, response}
      end
    end
  end

  defp handle_mcp_request(_body, _server_pid) do
    {:error, :invalid_request}
  end

  defp process_single_request(json_request, server_pid) do
    case Handler.handle_json_request(json_request, server_pid) do
      {:ok, %Protocol.JSONRPCResponse{id: nil} = _response} ->
        # Don't return responses for notifications (id is nil)
        nil

      {:ok, %Protocol.JSONRPCResponse{} = response} ->
        %{
          "jsonrpc" => response.jsonrpc,
          "id" => response.id,
          "result" => response.result
        }

      {:ok, error_response} when is_map(error_response) ->
        error_response

      {:error, reason} ->
        Logger.warning("Failed to process MCP request: #{inspect(reason)}")
        nil
    end
  end

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip(ip) when is_list(ip) do
    ip |> :inet.ntoa() |> to_string()
  end

  defp format_ip(ip), do: inspect(ip)
end
