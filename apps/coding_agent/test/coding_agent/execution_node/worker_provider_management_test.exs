defmodule CodingAgent.ExecutionNode.WorkerProviderManagementTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias CodingAgent.ExecutionNode.Worker

  # Explicit offline socket mock: all frames remain in the test process.
  defmodule OfflineSocketMock do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def request(pid, method, params, tag, _timeout),
      do: GenServer.call(pid, {:request, method, params, tag})

    def stop(pid), do: GenServer.stop(pid, :normal)

    def init(opts) do
      send(opts[:test], {:offline_socket, self()})
      {:ok, opts[:test]}
    end

    def handle_call({:request, method, params, tag}, _, test) do
      send(test, {:offline_request, method, params, tag})
      {:reply, "offline-request", test}
    end
  end

  test "worker advertises every destination provider method" do
    for operation <- LemonCore.ProviderManagement.operations() do
      assert Worker.capabilities()["node.providers.management." <> operation] == true
    end
  end

  @tag :tmp_dir
  test "worker resolves project credentials and defaults from its local cwd, not RPC paths",
       %{tmp_dir: root} do
    process_cwd = File.cwd!()
    worker_cwd = Path.join(root, "worker-project")
    home = Path.join(root, "home")
    File.mkdir_p!(Path.join(worker_cwd, ".lemon"))
    File.mkdir_p!(Path.join(home, ".lemon"))
    refute worker_cwd == process_cwd

    previous_paths = Application.fetch_env(:lemon_core, :paths)

    previous_defaults =
      Map.new(~w(LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL), &{&1, System.get_env(&1)})

    on_exit(fn ->
      case previous_paths do
        {:ok, value} -> Application.put_env(:lemon_core, :paths, value)
        :error -> Application.delete_env(:lemon_core, :paths)
      end

      Enum.each(previous_defaults, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Application.put_env(:lemon_core, :paths, home_dir: home)
    Enum.each(previous_defaults, fn {name, _} -> System.delete_env(name) end)

    File.write!(LemonCore.Config.global_path(), """
    [defaults]
    provider = "anthropic"
    model = "global-model"
    """)

    project_path = Path.join(worker_cwd, ".lemon/config.toml")

    File.write!(project_path, """
    [defaults]
    provider = "openai"
    model = "worker-project-model"
    [providers.openai]
    api_key = "PROJECT_FIXTURE_PRIVATE_DO_NOT_EXPOSE"
    """)

    worker =
      start_supervised!(
        {Worker,
         node_name: "cwd-provider-worker",
         controller: "ws://localhost:4040/ws",
         token: "offline-test-token",
         cwd: worker_cwd,
         socket_module: OfflineSocketMock,
         socket_opts: [test: self()],
         notify_pid: self()}
      )

    assert_receive {:offline_socket, socket}

    send(
      worker,
      {:execution_node_socket, socket,
       {:connected, %{"auth" => %{"clientId" => "cwd-provider-node"}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "cwd-provider-node"}}

    invoke_provider(worker, socket, "cwd-list", "list", %{})

    assert_receive {:offline_request, "node.invoke.result",
                    %{"invokeId" => "cwd-list", "result" => listing}, _},
                   5_000

    assert listing.target.nodeId == "cwd-provider-node"
    assert listing.default == %{providerId: "openai", modelId: "worker-project-model"}
    openai = Enum.find(listing.providers, &(&1.id == "openai"))
    assert "project_configuration" in openai.configurationOverrides
    assert openai.status == "configured"
    assert openai.lastValidation == nil
    encoded = Jason.encode!(listing)
    refute encoded =~ "PROJECT_FIXTURE_PRIVATE_DO_NOT_EXPOSE"
    refute encoded =~ worker_cwd
    refute encoded =~ process_cwd

    for operation <- LemonCore.ProviderManagement.operations(),
        field <- ~w(cwd config_path configPath home home_dir project_path) do
      params =
        case operation do
          "list" ->
            %{}

          "api_key.set" ->
            %{"targetId" => listing.target.id, "providerId" => "openai", "value" => "fixture"}

          "disconnect" ->
            %{"targetId" => listing.target.id, "providerId" => "openai"}

          "default.set" ->
            %{"targetId" => listing.target.id, "providerId" => "openai", "modelId" => "fixture"}
        end

      id = operation <> "-" <> field
      invoke_provider(worker, socket, id, operation, Map.put(params, field, process_cwd))

      assert_receive {:offline_request, "node.invoke.result",
                      %{"invokeId" => ^id, "error" => error}, _},
                     5_000

      assert inspect(error) =~ "invalid_request"
      refute inspect(error) =~ process_cwd
    end

    assert Toml.decode_file!(project_path)["defaults"]["model"] == "worker-project-model"

    assert Toml.decode_file!(LemonCore.Config.global_path())["defaults"]["model"] ==
             "global-model"

    assert File.cwd!() == process_cwd
  end

  defp invoke_provider(worker, socket, id, operation, args) do
    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{
          "invokeId" => id,
          "nodeId" => "cwd-provider-node",
          "method" => "node.providers.management." <> operation,
          "args" => args
        }}}
    )
  end

  @tag :tmp_dir
  test "worker rejects foreign target before optional service dispatch and never logs the value",
       %{tmp_dir: root} do
    worker =
      start_supervised!(
        {Worker,
         node_name: "offline-provider-worker",
         controller: "ws://localhost:4040/ws",
         token: "offline-test-token",
         cwd: root,
         socket_module: OfflineSocketMock,
         socket_opts: [test: self()],
         notify_pid: self()}
      )

    assert_receive {:offline_socket, socket}

    send(
      worker,
      {:execution_node_socket, socket,
       {:connected, %{"auth" => %{"clientId" => "provider-node-a"}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "provider-node-a"}}
    secret = "OFFLINE_WORKER_MOCK_SECRET_DO_NOT_LOG"

    logs =
      capture_log(fn ->
        send(
          worker,
          {:execution_node_socket, socket,
           {:event, "node.invoke.request",
            %{
              "invokeId" => "offline-provider-write",
              "nodeId" => "provider-node-a",
              "method" => "node.providers.management.api_key.set",
              "args" => %{
                "targetId" => "node:provider-node-b",
                "providerId" => "openai",
                "value" => secret
              }
            }}}
        )

        assert_receive {:offline_request, "node.invoke.result",
                        %{"invokeId" => "offline-provider-write", "error" => error}, _},
                       5_000

        assert inspect(error) =~ "target_mismatch"
        refute inspect(error) =~ secret
      end)

    refute logs =~ secret

    # Legacy name-only routing cannot substitute for a durable authenticated ID.
    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{
          "invokeId" => "offline-provider-name-only",
          "nodeName" => "offline-provider-worker",
          "method" => "node.providers.management.list",
          "args" => %{}
        }}}
    )

    assert_receive {:offline_request, "node.invoke.result",
                    %{"invokeId" => "offline-provider-name-only", "error" => error}, _}

    assert inspect(error) =~ "node_mismatch"
  end
end
