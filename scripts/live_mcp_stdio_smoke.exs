Application.ensure_all_started(:lemon_mcp)
Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveMcpStdioSmoke do
  alias CodingAgent.ToolRegistry
  alias LemonMCP.Client
  alias LemonMCP.Server
  alias LemonMCP.Server.Handler
  alias LemonMCP.Protocol
  alias LemonMCP.Transport.Stdio
  alias LemonSkills.McpSource

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    project_dir = File.cwd!()

    proof_path =
      opts[:out] || Path.join([project_dir, ".lemon", "proofs", "mcp-stdio-latest.json"])

    archive_path = archive_path(proof_path)

    checks = run_checks(project_dir)
    completed_count = Enum.count(checks, &(&1.status == "completed"))
    failed_count = Enum.count(checks, &(&1.status == "failed"))
    skipped_count = Enum.count(checks, &(&1.status == "skipped"))

    proof = %{
      status: proof_status(completed_count, skipped_count, failed_count),
      proof: "mcp_stdio_smoke",
      proof_scope: "mcp_stdio_smoke",
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
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_mcp_stdio_smoke_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    server_script = Path.join(tmp_dir, "fixture_mcp_server.exs")
    sampling_script = Path.join(tmp_dir, "fixture_sampling_mcp_server.exs")
    File.write!(server_script, fixture_server_script())
    File.write!(sampling_script, fixture_sampling_server_script())
    configure_mcp_source(server_script)

    try do
      {client_result, client} = start_client(server_script)
      {:ok, sampling_store} = Agent.start_link(fn -> [] end)

      {sampling_client_result, sampling_client} =
        start_sampling_client(sampling_script, sampling_store)

      [
        check("mcp_stdio_degraded_startup_missing_command", fn ->
          unless match?(
                   {:error, {:invalid_command, _message}},
                   GenServer.start(Stdio, command: "definitely-not-a-real-mcp-server")
                 ) do
            raise("missing command did not degrade cleanly")
          end
        end),
        check("mcp_stdio_client_initializes", fn ->
          unless match?({:ok, pid} when is_pid(pid), client_result),
            do: raise("client did not start")

          assert_until(fn -> Client.state(client) == :ready end)
        end),
        check("mcp_stdio_lists_tools", fn ->
          assert_until(fn -> Client.state(client) == :ready end)
          {:ok, tools} = Client.list_tools(client, 5_000)
          true = Enum.any?(tools, &(&1["name"] == "echo"))
          true = Enum.any?(tools, &(&1["name"] == "fail"))
        end),
        check("mcp_stdio_lists_resources", fn ->
          assert_until(fn -> Client.state(client) == :ready end)
          {:ok, resources} = Client.list_resources(client, 5_000)
          true = Enum.any?(resources, &(&1["uri"] == "fixture://status"))
        end),
        check("mcp_stdio_reads_resource", fn ->
          {:ok, [%{"uri" => "fixture://status", "text" => "status:ok"}]} =
            Client.read_resource(client, "fixture://status", 5_000)
        end),
        check("mcp_stdio_lists_prompts", fn ->
          assert_until(fn -> Client.state(client) == :ready end)
          {:ok, prompts} = Client.list_prompts(client, 5_000)
          true = Enum.any?(prompts, &(&1["name"] == "brief"))
        end),
        check("mcp_stdio_gets_prompt", fn ->
          {:ok, %{description: "Write a brief", messages: [%{"role" => "user"}]}} =
            Client.get_prompt(client, "brief", %{"topic" => "beam"}, 5_000)
        end),
        check("mcp_stdio_calls_tool_success", fn ->
          {:ok, [%{"type" => "text", "text" => "echo:ok"}]} =
            Client.call_tool(client, "echo", %{"message" => "ok"}, 5_000)
        end),
        check("mcp_stdio_calls_tool_error", fn ->
          {:error, {:tool_error, [%{"type" => "text", "text" => "planned failure"}]}} =
            Client.call_tool(client, "fail", %{}, 5_000)
        end),
        check("mcp_source_discovers_prefixed_stdio_tools", fn ->
          tools = McpSource.discover_tools(force_refresh: true)
          true = Enum.any?(tools, &(&1.name == "mcp_elixir_echo"))
          true = Enum.any?(tools, &(&1.name == "mcp_elixir_fail"))
          true = Enum.any?(tools, &(&1.name == "mcp_elixir_resources_list"))
          true = Enum.any?(tools, &(&1.name == "mcp_elixir_resource_read"))
          true = Enum.any?(tools, &(&1.name == "mcp_elixir_prompts_list"))
          true = Enum.any?(tools, &(&1.name == "mcp_elixir_prompt_get"))
        end),
        check("mcp_source_invokes_resource_and_prompt_utilities", fn ->
          {:ok, resources} = McpSource.call_tool("mcp_elixir_resources_list", %{})

          true =
            resources.content |> hd() |> Map.fetch!(:text) |> Jason.decode!() |> length() == 1

          {:ok, resource} =
            McpSource.call_tool("mcp_elixir_resource_read", %{"uri" => "fixture://status"})

          true =
            resource.content
            |> hd()
            |> Map.fetch!(:text)
            |> Jason.decode!()
            |> Enum.any?(&(&1["text"] == "status:ok"))

          {:ok, prompts} = McpSource.call_tool("mcp_elixir_prompts_list", %{})
          true = prompts.content |> hd() |> Map.fetch!(:text) |> Jason.decode!() |> length() == 1

          {:ok, prompt} =
            McpSource.call_tool("mcp_elixir_prompt_get", %{
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
        check("mcp_registry_exposes_prefixed_stdio_tools", fn ->
          tools = ToolRegistry.get_tools(project_dir)
          true = Enum.any?(tools, &(&1.name == "mcp_elixir_echo"))
          report = ToolRegistry.tool_conflict_report(project_dir)
          true = report.mcp_count >= 6
        end),
        check("mcp_source_applies_stdio_filters", fn ->
          configure_mcp_source(server_script,
            allow_tools: ["echo"],
            block_resources: ["fixture://status"],
            block_prompts: ["brief"]
          )

          tools = McpSource.discover_tools(force_refresh: true)
          names = Enum.map(tools, & &1.name)

          true = "mcp_elixir_echo" in names
          false = "mcp_elixir_fail" in names

          {:ok, resources} = McpSource.call_tool("mcp_elixir_resources_list", %{})
          [] = resources.content |> hd() |> Map.fetch!(:text) |> Jason.decode!()

          {:error, {:blocked_resource, "fixture://status"}} =
            McpSource.call_tool("mcp_elixir_resource_read", %{"uri" => "fixture://status"})

          {:ok, prompts} = McpSource.call_tool("mcp_elixir_prompts_list", %{})
          [] = prompts.content |> hd() |> Map.fetch!(:text) |> Jason.decode!()

          {:error, {:blocked_prompt, "brief"}} =
            McpSource.call_tool("mcp_elixir_prompt_get", %{"name" => "brief"})
        end),
        check("mcp_server_accepts_spec_initialized_notification", fn ->
          {:ok, server} = Server.start_link(tools: [])

          request = %Protocol.JSONRPCRequest{
            jsonrpc: "2.0",
            id: nil,
            method: "notifications/initialized",
            params: nil
          }

          response = Handler.handle_request(request, server)
          true = is_nil(response.id)
          true = Server.initialized?(server)
        end),
        check("mcp_stdio_sampling_callback_wrapper", fn ->
          unless match?({:ok, pid} when is_pid(pid), sampling_client_result),
            do: raise("sampling client did not start")

          assert_until(fn -> Client.state(sampling_client) == :ready end)
          assert_until(fn -> Agent.get(sampling_store, & &1) != [] end)

          entries = Agent.get(sampling_store, &Enum.reverse/1)
          {:delegate, params, _summary} = Enum.find(entries, &match?({:delegate, _, _}, &1))

          true = params["sawSamplingCapability"]
          16 = params["maxTokens"]

          [%{"role" => "user", "content" => %{"type" => "text", "text" => "ping"}}] =
            params["messages"]
        end),
        check("mcp_stdio_sampling_reviewed_model_policy", fn ->
          unless match?({:ok, pid} when is_pid(pid), sampling_client_result),
            do: raise("sampling client did not start")

          assert_until(fn -> Client.state(sampling_client) == :ready end)
          assert_until(fn -> Agent.get(sampling_store, & &1) != [] end)

          entries = Agent.get(sampling_store, &Enum.reverse/1)
          {:review, review_summary} = Enum.find(entries, &match?({:review, _}, &1))

          {:delegate, _params, delegate_summary} =
            Enum.find(entries, &match?({:delegate, _, _}, &1))

          1 = review_summary.message_count
          16 = review_summary.max_tokens
          4 = review_summary.text_char_count
          true = is_binary(review_summary.request_hash)
          false = String.contains?(inspect(review_summary), "ping")
          ^review_summary = delegate_summary
        end),
        check("mcp_stdio_sampling_ops_approval_bridge", fn ->
          run_sampling_source_approval_bridge(sampling_script, sampling_store)
        end)
      ]
    after
      if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_smoke_client)) do
        {:ok, pid} = Process.get(:mcp_smoke_client)
        _ = Client.close(pid)
      end

      if match?({:ok, pid} when is_pid(pid), Process.get(:mcp_sampling_smoke_client)) do
        {:ok, pid} = Process.get(:mcp_sampling_smoke_client)
        _ = Client.close(pid)
      end

      File.rm_rf!(tmp_dir)
      _ = project_dir
    end
  end

  defp start_client(server_script) do
    elixir = System.find_executable("elixir")

    result =
      Client.start_link(
        command: elixir,
        args: [server_script],
        timeout_ms: 5_000
      )

    case result do
      {:ok, pid} ->
        Process.put(:mcp_smoke_client, {:ok, pid})
        {result, pid}

      _ ->
        {result, nil}
    end
  end

  defp start_sampling_client(server_script, store) do
    elixir = System.find_executable("elixir")

    reviewer = fn summary ->
      Agent.update(store, &[{:review, summary} | &1])
      :approve
    end

    delegate = fn params, summary ->
      Agent.update(store, &[{:delegate, params, summary} | &1])

      {:ok,
       %{
         "role" => "assistant",
         "content" => %{"type" => "text", "text" => "sampled"},
         "model" => "lemon-test",
         "stopReason" => "endTurn"
       }}
    end

    result =
      Client.start_link(
        command: elixir,
        args: [server_script],
        sampling_policy: [
          mode: :reviewed_model,
          reviewer: reviewer,
          delegate: delegate,
          max_tokens: 32
        ],
        timeout_ms: 5_000
      )

    case result do
      {:ok, pid} ->
        Process.put(:mcp_sampling_smoke_client, {:ok, pid})
        {result, pid}

      _ ->
        {result, nil}
    end
  end

  defp configure_mcp_source(server_script, opts \\ []) do
    elixir = System.find_executable("elixir")

    Application.put_env(:lemon_skills, :mcp_servers, [
      if opts == [] do
        {:stdio, elixir, [server_script]}
      else
        {:stdio, elixir, [server_script], opts}
      end
    ])

    McpSource.refresh()
  end

  defp run_sampling_source_approval_bridge(server_script, store) do
    run_id = "mcp_sampling_smoke_#{System.unique_integer([:positive, :monotonic])}"

    delegate = fn params, summary ->
      Agent.update(store, &[{:source_delegate, params, summary} | &1])

      {:ok,
       %{
         "role" => "assistant",
         "content" => %{"type" => "text", "text" => "sampled"},
         "model" => "lemon-test",
         "stopReason" => "endTurn"
       }}
    end

    elixir = System.find_executable("elixir")

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
           session_key: "agent:mcp-sampling-smoke:main",
           agent_id: "mcp-sampling-smoke"
         ]
       ]}
    ])

    task = Task.async(fn -> McpSource.discover_tools(force_refresh: true) end)
    pending = wait_for_pending_approval(run_id)

    "mcp_elixir_sampling" = pending.tool
    "mcp_sampling" = pending.action.type
    "elixir" = pending.action.server
    1 = pending.action.message_count
    16 = pending.action.max_tokens
    true = is_binary(pending.action.request_hash)
    false = String.contains?(inspect(pending), "ping")

    :ok = LemonCore.ExecApprovals.resolve(pending.id, :approve_once)

    tools = Task.await(task, 5_000)
    true = Enum.any?(tools, &(&1.name == "mcp_elixir_echo"))

    assert_until(fn ->
      Agent.get(store, fn entries ->
        Enum.any?(entries, &match?({:source_delegate, _params, _summary}, &1))
      end)
    end)

    entries = Agent.get(store, &Enum.reverse/1)

    {:source_delegate, params, summary} =
      Enum.find(entries, &match?({:source_delegate, _, _}, &1))

    true = params["sawSamplingCapability"]
    false = String.contains?(inspect(summary), "ping")
  end

  defp check(name, fun) do
    fun.()
    %{name: name, proof_scope: "mcp_stdio_smoke", status: "completed"}
  rescue
    error ->
      %{
        name: name,
        proof_scope: "mcp_stdio_smoke",
        status: "failed",
        reason_kind: "mcp_stdio_smoke_failure",
        failure_hint: error.__struct__ |> Atom.to_string()
      }
  catch
    kind, reason ->
      %{
        name: name,
        proof_scope: "mcp_stdio_smoke",
        status: "failed",
        reason_kind: "mcp_stdio_smoke_failure",
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

  defp wait_for_pending_approval(run_id, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    case find_pending_approval(run_id) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise("timed out waiting for pending approval #{run_id}")
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

    Path.join(Path.dirname(proof_path), "mcp-stdio-smoke-#{stamp}.json")
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value, pretty: true))
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
        capabilities = Map.get(params, "capabilities", %{})
        Process.put(:saw_sampling_capability, Map.has_key?(capabilities, "sampling"))

        respond(%{
          "jsonrpc" => "2.0",
          "id" => id,
          "result" => %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "sampling-fixture-mcp", "version" => "1.0.0"}
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
              %{"role" => "user", "content" => %{"type" => "text", "text" => "ping"}}
            ],
            "maxTokens" => 16,
            "sawSamplingCapability" => Process.get(:saw_sampling_capability)
          }
        })
      end

      defp handle_request(%{
             "id" => "sampling-1",
             "result" => %{"content" => %{"text" => "sampled"}}
           }), do: :ok

      defp handle_request(%{"id" => "sampling-1"}), do: :ok

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

      defp handle_request(%{"method" => "resources/list", "id" => id}) do
        respond(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"resources" => []}})
      end

      defp handle_request(%{"method" => "prompts/list", "id" => id}) do
        respond(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"prompts" => []}})
      end

      defp handle_request(_request), do: :ok

      defp respond(response) do
        IO.write([:json.encode(response), "\n"])
      end
    end

    FixtureSamplingMcpServer.run()
    '''
  end
end

LemonScripts.LiveMcpStdioSmoke.main(System.argv())
