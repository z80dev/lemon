defmodule LemonMCP.ClientRequestWorkersTest.HTTPFixture do
  @moduledoc false
  # Streamable HTTP server whose `slow` tool and token endpoint can be held
  # open by the test. Bearer tokens are valid while listed in the store.
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    store = conn.assigns.store
    test = Agent.get(store, & &1.test)
    auth = Map.new(conn.req_headers)["authorization"]
    send(test, {:mcp, request["method"], get_in(request, ["params", "name"]), auth})

    cond do
      not authorized?(store, auth) ->
        conn
        |> put_resp_header(
          "www-authenticate",
          ~s|Bearer resource_metadata="http://127.0.0.1:#{conn.port}/.well-known/oauth-protected-resource/mcp"|
        )
        |> send_resp(401, "authorization required")

      request["method"] == "notifications/initialized" ->
        send_resp(conn, 202, "")

      true ->
        if get_in(request, ["params", "name"]) == "slow" do
          send(test, {:held, :slow, self()})

          receive do
            :release -> :ok
          end
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(response(request)))
    end
  end

  post "/oauth/token" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    store = conn.assigns.store
    %{test: test, hold_token: hold?} = Agent.get(store, & &1)
    send(test, {:token, URI.decode_query(body)["grant_type"]})

    if hold? do
      send(test, {:held, :token, self()})

      receive do
        :release -> :ok
      end
    end

    token =
      Agent.get_and_update(store, fn state ->
        token = "token-#{state.issued + 1}"
        {token, %{state | issued: state.issued + 1, valid: [token | state.valid]}}
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"access_token" => token, "token_type" => "Bearer"}))
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
        "token_endpoint" => "http://127.0.0.1:#{conn.port}/oauth/token"
      })
    )
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    conn
    |> Plug.Conn.assign(:store, Keyword.fetch!(opts, :store))
    |> super(opts)
  end

  defp authorized?(store, auth) do
    case Agent.get(store, & &1) do
      %{oauth: false} -> true
      %{valid: valid} -> Enum.any?(valid, &(auth == "Bearer " <> &1))
    end
  end

  defp response(%{"method" => "initialize", "id" => id}) do
    result(id, %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "workers", "version" => "1"}
    })
  end

  defp response(%{"method" => "tools/list", "id" => id}),
    do: result(id, %{"tools" => [%{"name" => "echo"}, %{"name" => "slow"}]})

  defp response(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name}}),
    do: result(id, %{"content" => [%{"type" => "text", "text" => name}], "isError" => false})

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end

defmodule LemonMCP.ClientRequestWorkersTest.SSEFixture do
  @moduledoc false
  # Legacy SSE server that withholds the `slow` tool's stream response until
  # the test pushes it.
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/sse" do
    stream = self()
    Agent.update(conn.assigns.store, &Map.put(&1, :stream, stream))

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    {:ok, conn} = chunk(conn, "event: endpoint\ndata: /messages\n\n")
    stream_loop(conn)
  end

  post "/messages" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)
    %{stream: stream, test: test} = Agent.get(conn.assigns.store, & &1)
    send(test, {:mcp, request["method"], get_in(request, ["params", "name"]), nil})

    case response(request) do
      nil ->
        :ok

      response ->
        if get_in(request, ["params", "name"]) == "slow",
          do: send(test, {:held, :slow, {stream, Jason.encode!(response)}}),
          else: send(stream, {:sse_message, Jason.encode!(response)})
    end

    send_resp(conn, 202, "")
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
    end
  end

  defp response(%{"method" => "initialize", "id" => id}) do
    result(id, %{
      "protocolVersion" => "2024-11-05",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "workers", "version" => "1"}
    })
  end

  defp response(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name}}),
    do: result(id, %{"content" => [%{"type" => "text", "text" => name}], "isError" => false})

  defp response(_notification), do: nil

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}
end

defmodule LemonMCP.ClientRequestWorkersTest do
  # Requests run outside the client process: a slow request never blocks
  # state reads or other requests, a deadline is an unknown outcome reached
  # only after the request worker is gone, and a 401 refreshes the grant once
  # without freezing the client.
  use ExUnit.Case, async: false

  alias LemonMCP.Client.{HTTP, SSE}
  alias LemonMCP.ClientRequestWorkersTest.{HTTPFixture, SSEFixture}

  describe "Streamable HTTP" do
    setup do
      start_http(oauth: false)
    end

    test "a long call_tool does not block state/1 or a second concurrent call", ctx do
      client = start_supervised!({HTTP, url: ctx.url, timeout_ms: 10_000})
      slow = Task.async(fn -> HTTP.call_tool(client, "slow", %{}, 10_000) end)
      assert_receive {:held, :slow, holder}, 5_000

      assert :ready = GenServer.call(client, :get_state, 200)
      assert {:ok, %{"tools" => %{}}} = GenServer.call(client, :server_capabilities, 200)
      assert {:ok, [%{"text" => "echo"}]} = HTTP.call_tool(client, "echo", %{}, 2_000)
      assert Task.yield(slow, 0) == nil

      send(holder, :release)
      assert {:ok, [%{"text" => "slow"}]} = Task.await(slow, 5_000)
    end

    test "a timed-out call is an unknown outcome and its worker is gone first", ctx do
      client = start_supervised!({HTTP, url: ctx.url, timeout_ms: 10_000})
      workers = :sys.get_state(client).request_supervisor

      call = Task.async(fn -> HTTP.call_tool(client, "slow", %{}, 1_000) end)
      assert_receive {:held, :slow, holder}, 5_000
      [worker] = Task.Supervisor.children(workers)
      ref = Process.monitor(worker)

      assert {:error, :outcome_unknown} = Task.await(call, 5_000)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
      assert :sys.get_state(client).requests == %{}

      send(holder, :release)
      assert :ready = HTTP.state(client)
      assert {:ok, [%{"text" => "echo"}]} = HTTP.call_tool(client, "echo", %{}, 2_000)
    end

    test "the request deadline caps a longer caller timeout", ctx do
      client = start_supervised!({HTTP, url: ctx.url, timeout_ms: 300})
      started = System.monotonic_time(:millisecond)
      assert {:error, :outcome_unknown} = HTTP.call_tool(client, "slow", %{}, 30_000)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert_received {:held, :slow, holder}
      send(holder, :release)
    end

    test "a caller that exits stops its request worker", ctx do
      client = start_supervised!({HTTP, url: ctx.url, timeout_ms: 10_000})
      workers = :sys.get_state(client).request_supervisor
      caller = spawn(fn -> HTTP.call_tool(client, "slow", %{}, 10_000) end)
      assert_receive {:held, :slow, holder}, 5_000
      [worker] = Task.Supervisor.children(workers)
      ref = Process.monitor(worker)

      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
      assert :sys.get_state(client).requests == %{}
      send(holder, :release)
    end
  end

  describe "Streamable HTTP OAuth" do
    setup do
      start_http(oauth: true)
    end

    test "a 401 during calls refreshes once without freezing the client", ctx do
      client = start_supervised!({HTTP, oauth_opts(ctx)})
      assert_received {:token, "client_credentials"}
      expire_tokens(ctx)
      Agent.update(ctx.store, &%{&1 | hold_token: true})

      calls =
        for _ <- 1..2,
            do: Task.async(fn -> HTTP.call_tool(client, "echo", %{}, 5_000) end)

      assert_receive {:held, :token, token_holder}, 5_000
      assert :ready = GenServer.call(client, :get_state, 200)
      assert Enum.map(calls, &Task.yield(&1, 0)) == [nil, nil]

      send(token_holder, :release)
      assert [{:ok, [%{"text" => "echo"}]}, {:ok, _}] = Enum.map(calls, &Task.await(&1, 5_000))
      assert_received {:token, "client_credentials"}
      refute_received {:token, _}
    end

    test "a refresh that outlives the caller never sends the retry", ctx do
      client = start_supervised!({HTTP, oauth_opts(ctx)})
      expire_tokens(ctx)
      Agent.update(ctx.store, &%{&1 | hold_token: true})

      assert {:error, {:auth_required, _metadata}} = HTTP.call_tool(client, "echo", %{}, 300)
      assert_received {:mcp, "tools/call", "echo", _expired}
      assert_receive {:held, :token, token_holder}, 5_000

      Agent.update(ctx.store, &%{&1 | hold_token: false})
      send(token_holder, :release)
      refute_receive {:mcp, "tools/call", _name, _auth}, 300

      # The refreshed grant serves later requests.
      assert {:ok, [%{"text" => "echo"}]} = HTTP.call_tool(client, "echo", %{}, 2_000)
      assert_received {:mcp, "tools/call", "echo", "Bearer token-2"}
    end

    test "interactive re-authorization runs in the background; calls fail fast", ctx do
      parent = self()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      provider = fn request ->
        if Agent.get_and_update(attempts, &{&1, &1 + 1}) > 0 do
          send(parent, {:held, :provider, self()})

          receive do
            :release -> :ok
          end
        end

        {:ok, %{code: "code", state: request.state}}
      end

      opts =
        Keyword.put(oauth_opts(ctx), :oauth,
          client_id: "public",
          redirect_uri: "http://127.0.0.1/callback",
          authorization_code_provider: provider
        )

      client = start_supervised!({HTTP, opts})
      assert_received {:token, "authorization_code"}
      expire_tokens(ctx)

      started = System.monotonic_time(:millisecond)
      assert {:error, {:auth_required, _}} = HTTP.call_tool(client, "echo", %{}, 5_000)
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert_receive {:held, :provider, provider_pid}, 5_000

      # Another 401 while authorization is pending fails fast too.
      assert {:error, {:auth_required, _}} = HTTP.call_tool(client, "echo", %{}, 5_000)
      assert :ready = GenServer.call(client, :get_state, 200)

      send(provider_pid, :release)
      assert_receive {:token, "authorization_code"}, 5_000
      wait_until(fn -> :sys.get_state(client).auth == nil end)
      assert {:ok, [%{"text" => "echo"}]} = HTTP.call_tool(client, "echo", %{}, 2_000)
    end
  end

  describe "legacy SSE" do
    setup do
      test = self()
      store = start_supervised!({Agent, fn -> %{test: test, stream: nil} end})

      listener =
        start_supervised!(
          {Bandit, plug: {SSEFixture, store: store}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
      %{url: "http://127.0.0.1:#{port}/sse"}
    end

    test "a long call_tool does not block state/1 or a second concurrent call", ctx do
      client = start_supervised!({SSE, url: ctx.url, timeout_ms: 10_000})
      slow = Task.async(fn -> SSE.call_tool(client, "slow", %{}, 10_000) end)
      assert_receive {:held, :slow, {stream, response}}, 5_000

      assert :ready = GenServer.call(client, :get_state, 200)
      assert {:ok, [%{"text" => "echo"}]} = SSE.call_tool(client, "echo", %{}, 2_000)
      assert Task.yield(slow, 0) == nil

      send(stream, {:sse_message, response})
      assert {:ok, [%{"text" => "slow"}]} = Task.await(slow, 5_000)
    end

    test "a timed-out call is an unknown outcome and a late response is dropped", ctx do
      client = start_supervised!({SSE, url: ctx.url, timeout_ms: 10_000})
      assert {:error, :outcome_unknown} = SSE.call_tool(client, "slow", %{}, 300)
      assert_received {:held, :slow, {stream, response}}
      assert :sys.get_state(client).pending == %{}

      send(stream, {:sse_message, response})
      assert {:ok, [%{"text" => "echo"}]} = SSE.call_tool(client, "echo", %{}, 2_000)
      assert :ready = SSE.state(client)
    end
  end

  defp start_http(oauth: oauth?) do
    test = self()

    store =
      start_supervised!(
        {Agent, fn -> %{test: test, oauth: oauth?, valid: [], issued: 0, hold_token: false} end}
      )

    listener =
      start_supervised!(
        {Bandit, plug: {HTTPFixture, store: store}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
    %{store: store, url: "http://127.0.0.1:#{port}/mcp"}
  end

  defp oauth_opts(ctx) do
    [
      url: ctx.url,
      timeout_ms: 10_000,
      oauth: [client_id: "lemon", client_secret: "secret"]
    ]
  end

  defp expire_tokens(ctx), do: Agent.update(ctx.store, &%{&1 | valid: []})

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end
