defmodule LemonMCP.NotificationsTest.HTTPFixture do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    response =
      case request["method"] do
        "initialize" ->
          %{
            jsonrpc: "2.0",
            id: request["id"],
            result: %{
              protocolVersion: "2025-06-18",
              capabilities: %{},
              serverInfo: %{name: "notifications", version: "1"}
            }
          }

        "tools/list" ->
          %{jsonrpc: "2.0", id: request["id"], result: %{tools: []}}

        _ ->
          nil
      end

    if response do
      notification = %{jsonrpc: "2.0", method: "notifications/tools/list_changed"}
      # Include notifications before and after the response to preserve response selection.
      body =
        Enum.map_join([notification, response, notification], "", fn message ->
          "event: message\ndata: #{Jason.encode!(message)}\n\n"
        end)

      conn |> put_resp_content_type("text/event-stream") |> send_resp(200, body)
    else
      send_resp(conn, 202, "")
    end
  end
end

defmodule LemonMCP.NotificationsTest do
  use ExUnit.Case, async: false

  for transport <- [LemonMCP.Client, LemonMCP.Client.HTTP, LemonMCP.Client.SSE] do
    test "#{transport} validates notification handlers before connecting" do
      assert_raise ArgumentError, ~r/notification_handler/, fn ->
        unquote(transport).init(
          command: "unused",
          url: "http://localhost",
          notification_handler: fn -> :ok end
        )
      end
    end
  end

  test "legacy SSE dispatches fragmented notifications and ignores server requests" do
    owner = self()
    request_id = make_ref()

    state = %{
      stream_request_id: request_id,
      sse_buffer: "",
      sse_event: %{event: nil, data: []},
      config: %{notification_handler: fn notification -> send(owner, notification) end}
    }

    for method <- [
          "notifications/tools/list_changed",
          "notifications/resources/list_changed",
          "notifications/prompts/list_changed",
          "notifications/resources/updated"
        ] do
      params = %{"uri" => "fixture://status"}
      data = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})

      {:noreply, partial} =
        LemonMCP.Client.SSE.handle_info({:http, {request_id, :stream, "data: " <> data}}, state)

      {:noreply, _} =
        LemonMCP.Client.SSE.handle_info({:http, {request_id, :stream, "\n\n"}}, partial)

      assert_receive %{method: ^method, params: ^params}
    end

    request = Jason.encode!(%{jsonrpc: "2.0", id: 7, method: "server/request"})

    assert {:noreply, _} =
             LemonMCP.Client.SSE.handle_info(
               {:http, {request_id, :stream, "data: " <> request <> "\n\n"}},
               state
             )

    refute_receive %{method: "server/request"}
  end

  for kind <- [:stdio, :http], mode <- [:receive, :crash, :slow, :none] do
    test "#{kind} isolates #{mode} notification handlers" do
      owner = self()
      mode = unquote(mode)

      handler = notification_handler(mode, owner)

      {module, opts} = transport(unquote(kind))
      client = start_supervised!({module, Keyword.put(opts, :notification_handler, handler)})
      await_ready(module, client, 500)

      if mode != :none do
        assert_receive {:notification, %{method: "notifications/tools/list_changed", params: %{}},
                        worker},
                       5_000

        assert worker != client
      end

      assert module.state(client) == :ready
      assert {:ok, []} = module.list_tools(client)
      assert Process.alive?(client)
    end
  end

  defp notification_handler(:none, _owner), do: nil

  defp notification_handler(mode, owner) do
    fn notification ->
      send(owner, {:notification, notification, self()})
      handle_notification(mode)
    end
  end

  defp handle_notification(:crash), do: raise("handler failure")
  defp handle_notification(:slow), do: Process.sleep(1_000)
  defp handle_notification(_), do: :ok

  defp await_ready(module, client, attempts) do
    if module.state(client) != :ready and attempts > 0 do
      Process.sleep(10)
      await_ready(module, client, attempts - 1)
    end
  end

  defp transport(:http) do
    pid =
      start_supervised!(
        {Bandit,
         plug: LemonMCP.NotificationsTest.HTTPFixture, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    {LemonMCP.Client.HTTP, [url: "http://127.0.0.1:#{port}/mcp"]}
  end

  defp transport(:stdio) do
    script = """
    const rl = require('readline').createInterface({input: process.stdin});
    const send = m => process.stdout.write(JSON.stringify(m) + '\\n');
    rl.on('line', line => {
      const m = JSON.parse(line);
      if (m.method === 'initialize') send({jsonrpc:'2.0', id:m.id, result:{protocolVersion:'2025-06-18', capabilities:{}, serverInfo:{name:'notifications',version:'1'}}});
      else if (m.method === 'notifications/initialized') send({jsonrpc:'2.0',method:'notifications/tools/list_changed'});
      else if (m.method === 'tools/list') send({jsonrpc:'2.0',id:m.id,result:{tools:[]}});
    });
    """

    {LemonMCP.Client, [command: System.find_executable("node"), args: ["-e", script]]}
  end
end
