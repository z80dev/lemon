Application.ensure_all_started(:lemon_mcp)
Application.ensure_all_started(:lemon_skills)
Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveMcpSseSmoke.Fixture do
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

defmodule LemonScripts.LiveMcpSseSmoke do
  alias CodingAgent.ToolRegistry
  alias LemonMCP.Client.SSE
  alias LemonMCP.Protocol
  alias LemonSkills.McpSource

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])
    project_dir = File.cwd!()
    proof_path = opts[:out] || Path.join([project_dir, ".lemon", "proofs", "mcp-sse-latest.json"])
    archive_path = archive_path(proof_path)

    checks = run_checks(project_dir)
    completed_count = Enum.count(checks, &(&1.status == "completed"))
    failed_count = Enum.count(checks, &(&1.status == "failed"))
    skipped_count = Enum.count(checks, &(&1.status == "skipped"))

    proof = %{
      status: proof_status(completed_count, skipped_count, failed_count),
      proof: "mcp_sse_smoke",
      proof_scope: "mcp_sse_smoke",
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
    direct_port = free_port()
    direct_url = "http://127.0.0.1:#{direct_port}/sse"
    {:ok, direct_server, direct_store, direct_transport} = start_sse_transport(direct_port)

    source_port = free_port()
    source_url = "http://127.0.0.1:#{source_port}/sse"
    {:ok, source_server, source_store, source_transport} = start_sse_transport(source_port)

    Process.put(:mcp_sse_servers, [direct_server, source_server])
    Process.put(:mcp_sse_stores, [direct_store, source_store])
    Process.put(:mcp_sse_transports, [direct_transport, source_transport])

    configure_mcp_source(source_url)
    {client_result, client} = start_client(direct_url)

    [
      check("mcp_sse_client_initializes", fn ->
        unless match?({:ok, pid} when is_pid(pid), client_result),
          do: raise("client did not start")

        assert_until(fn -> SSE.state(client) == :ready end)
        {:ok, %{name: "SSE Fixture", version: "1.0.0"}} = SSE.server_info(client)
      end),
      check("mcp_sse_lists_tools", fn ->
        {:ok, tools} = SSE.list_tools(client, 5_000)
        true = Enum.any?(tools, &(&1["name"] == "echo"))
        true = Enum.any?(tools, &(&1["name"] == "fail"))
      end),
      check("mcp_sse_calls_tool_success", fn ->
        {:ok, [%{"type" => "text", "text" => "echo:ok"}]} =
          SSE.call_tool(client, "echo", %{"message" => "ok"}, 5_000)
      end),
      check("mcp_sse_calls_tool_error", fn ->
        {:error, {:tool_error, [%{"type" => "text", "text" => "planned failure"}]}} =
          SSE.call_tool(client, "fail", %{}, 5_000)
      end),
      check("mcp_sse_lists_resources", fn ->
        {:ok, resources} = SSE.list_resources(client, 5_000)
        true = Enum.any?(resources, &(&1["uri"] == "fixture://status"))
      end),
      check("mcp_sse_reads_resource", fn ->
        {:ok, [%{"uri" => "fixture://status", "text" => "status:ok"}]} =
          SSE.read_resource(client, "fixture://status", 5_000)
      end),
      check("mcp_sse_lists_prompts", fn ->
        {:ok, prompts} = SSE.list_prompts(client, 5_000)
        true = Enum.any?(prompts, &(&1["name"] == "brief"))
      end),
      check("mcp_sse_gets_prompt", fn ->
        {:ok, %{messages: [%{"role" => "user"}]}} =
          SSE.get_prompt(client, "brief", %{"topic" => "beam"}, 5_000)

        :ok = SSE.close(client)
      end),
      check("mcp_source_discovers_prefixed_sse_tools", fn ->
        tools = McpSource.discover_tools(force_refresh: true)
        true = Enum.any?(tools, &(&1.name == "mcp_sse_echo"))
        true = Enum.any?(tools, &(&1.name == "mcp_sse_fail"))
        true = Enum.any?(tools, &(&1.name == "mcp_sse_resources_list"))
        true = Enum.any?(tools, &(&1.name == "mcp_sse_resource_read"))
        true = Enum.any?(tools, &(&1.name == "mcp_sse_prompts_list"))
        true = Enum.any?(tools, &(&1.name == "mcp_sse_prompt_get"))
      end),
      check("mcp_source_invokes_sse_tool", fn ->
        {:ok, result} = McpSource.call_tool("mcp_sse_echo", %{"message" => "ok"})
        true = result.content |> hd() |> Map.fetch!(:text) == "echo:ok"
      end),
      check("mcp_source_invokes_sse_resource_and_prompt_utilities", fn ->
        {:ok, resource} =
          McpSource.call_tool("mcp_sse_resource_read", %{"uri" => "fixture://status"})

        true =
          resource.content
          |> hd()
          |> Map.fetch!(:text)
          |> Jason.decode!()
          |> Enum.any?(&(&1["text"] == "status:ok"))

        {:ok, prompt} =
          McpSource.call_tool("mcp_sse_prompt_get", %{
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
      check("mcp_registry_exposes_prefixed_sse_tools", fn ->
        tools = ToolRegistry.get_tools(project_dir)
        true = Enum.any?(tools, &(&1.name == "mcp_sse_echo"))
        report = ToolRegistry.tool_conflict_report(project_dir)
        true = report.mcp_count >= 6
      end),
      check("mcp_source_status_reports_sse_capabilities", fn ->
        status = McpSource.status()

        true =
          Enum.any?(status.servers, fn {_name, server} ->
            server.connected and server.tool_count == 6 and server.resource_count == 1 and
              server.prompt_count == 1 and server.capabilities.tools and
              server.capabilities.resources and server.capabilities.prompts
          end)
      end),
      check("mcp_source_applies_sse_filters", fn ->
        filter_port = free_port()
        filter_url = "http://127.0.0.1:#{filter_port}/sse"
        {:ok, filter_server, filter_store, filter_transport} = start_sse_transport(filter_port)
        Process.put(:mcp_sse_servers, [filter_server | Process.get(:mcp_sse_servers, [])])
        Process.put(:mcp_sse_stores, [filter_store | Process.get(:mcp_sse_stores, [])])

        Process.put(:mcp_sse_transports, [filter_transport | Process.get(:mcp_sse_transports, [])])

        configure_mcp_source(filter_url, allow_tools: ["echo"])
        tools = McpSource.discover_tools(force_refresh: true)
        names = Enum.map(tools, & &1.name)
        true = "mcp_sse_echo" in names
        false = "mcp_sse_fail" in names
      end)
    ]
  after
    case Process.get(:mcp_sse_client) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: SSE.close(pid)

      _ ->
        :ok
    end

    Process.get(:mcp_sse_stores, []) |> Enum.each(&stop_sse_streams/1)
    Process.get(:mcp_sse_transports, []) |> Enum.each(&stop_pid/1)
    Process.get(:mcp_sse_servers, []) |> Enum.each(&stop_pid/1)
    Process.get(:mcp_sse_stores, []) |> Enum.each(&stop_pid/1)
  end

  def handle_tool("echo", args) do
    {:ok,
     %Protocol.ToolCallResult{
       content: [%{type: "text", text: "echo:" <> Map.get(args, "message", "")}],
       isError: false
     }}
  end

  def handle_tool("fail", _args) do
    {:ok,
     %Protocol.ToolCallResult{
       content: [%{type: "text", text: "planned failure"}],
       isError: true
     }}
  end

  def handle_tool(_name, _args), do: {:error, :unknown_tool}

  defp start_client(url) do
    result = SSE.start_link(url: url, timeout_ms: 5_000)

    case result do
      {:ok, pid} ->
        Process.put(:mcp_sse_client, {:ok, pid})
        {result, pid}

      _ ->
        {result, nil}
    end
  end

  defp configure_mcp_source(url, opts \\ []) do
    Application.put_env(:lemon_skills, :mcp_servers, [
      if opts == [] do
        {:sse, url}
      else
        {:sse, url, opts}
      end
    ])

    McpSource.refresh()
  end

  defp start_sse_transport(port) do
    {:ok, store} = Agent.start_link(fn -> %{} end)

    {:ok, server} =
      LemonMCP.Server.start_link(
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
        tool_handler: &__MODULE__.handle_tool/2,
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

    {:ok, transport} =
      Bandit.start_link(
        plug: {LemonScripts.LiveMcpSseSmoke.Fixture, store: store, mcp_server: server},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    {:ok, server, store, transport}
  end

  defp stop_sse_streams(store) when is_pid(store) do
    store
    |> Agent.get(&Map.values/1)
    |> Enum.each(&send(&1, :stop))
  end

  defp stop_sse_streams(_store), do: :ok

  defp stop_pid(pid) when is_pid(pid), do: Process.exit(pid, :normal)
  defp stop_pid(_pid), do: :ok

  defp check(name, fun) do
    fun.()
    %{name: name, proof_scope: "mcp_sse_smoke", status: "completed"}
  rescue
    error ->
      %{
        name: name,
        proof_scope: "mcp_sse_smoke",
        status: "failed",
        reason_kind: "mcp_sse_smoke_failure",
        failure_hint: error.__struct__ |> Atom.to_string()
      }
  catch
    kind, reason ->
      %{
        name: name,
        proof_scope: "mcp_sse_smoke",
        status: "failed",
        reason_kind: "mcp_sse_smoke_failure",
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

    Path.join(Path.dirname(proof_path), "mcp-sse-smoke-#{stamp}.json")
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

LemonScripts.LiveMcpSseSmoke.main(System.argv())
