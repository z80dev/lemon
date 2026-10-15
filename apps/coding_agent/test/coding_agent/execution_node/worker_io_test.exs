defmodule CodingAgent.ExecutionNode.WorkerIOTest do
  use ExUnit.Case, async: false
  alias CodingAgent.ExecutionNode.Worker

  defmodule Socket do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def request(pid, method, params, tag, _timeout),
      do: GenServer.call(pid, {:request, method, params, tag})

    def stop(pid), do: GenServer.stop(pid, :normal)

    def init(opts) do
      test = opts[:test]
      send(test, {:socket, self()})
      {:ok, test}
    end

    def handle_call({:request, method, params, tag}, _from, test) do
      send(test, {:request, method, params, tag})
      {:reply, "request", test}
    end
  end

  @tag :tmp_dir
  test "local worker dispatch roundtrips multiple file chunks including the full 1 MiB limit", %{
    tmp_dir: root
  } do
    worker =
      start_supervised!(
        {Worker,
         node_name: "io-worker",
         controller: "ws://localhost:4040/ws",
         token: "test-token",
         cwd: root,
         allowed_roots: [root],
         socket_module: Socket,
         socket_opts: [test: self()],
         notify_pid: self()}
      )

    assert_receive {:socket, socket}

    send(
      worker,
      {:execution_node_socket, socket,
       {:connected,
        %{"auth" => %{"clientId" => "io-node"}, "policy" => %{"maxPayload" => 16_777_216}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "io-node"}}

    first = :binary.copy(<<0, 1, 2, 255>>, 262_144)
    tail = "last chunk"

    assert {:ok, written} =
             invoke(worker, socket, "write-1", "node.fs.write", %{
               "path" => "upload.bin",
               "dataBase64" => Base.encode64(first),
               "offset" => 0,
               "truncate" => false
             })

    assert {:ok, _} =
             invoke(worker, socket, "write-2", "node.fs.write", %{
               "path" => "upload.bin",
               "dataBase64" => Base.encode64(tail),
               "offset" => byte_size(first),
               "truncate" => true,
               "expectedModifiedAtMs" => written["mtimeMs"]
             })

    assert {:ok, chunk} =
             invoke(worker, socket, "read-1", "node.fs.read", %{"path" => "upload.bin"})

    assert Base.decode64!(chunk["dataBase64"]) == first
    assert chunk["size"] == byte_size(first) + byte_size(tail)
    assert chunk["eof"] == false

    assert {:ok, chunk} =
             invoke(worker, socket, "read-2", "node.fs.read", %{
               "path" => "upload.bin",
               "offset" => byte_size(first)
             })

    assert Base.decode64!(chunk["dataBase64"]) == tail
    assert chunk["eof"] == true
    assert File.read!(Path.join(root, "upload.bin")) == first <> tail

    assert {:error, _} =
             invoke(worker, socket, "escape", "node.fs.read", %{"path" => "../outside"})

    assert {:ok, preview} =
             invoke(worker, socket, "preview", "node.fs.delete.preview", %{"path" => "upload.bin"})

    assert {:ok, %{"deleted" => true}} =
             invoke(worker, socket, "delete", "node.fs.delete", %{
               "path" => "upload.bin",
               "confirm" => "upload.bin",
               "confirmationToken" => preview["confirmationToken"]
             })

    refute File.exists?(Path.join(root, "upload.bin"))
  end

  defp invoke(worker, socket, id, method, args) do
    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{"invokeId" => id, "nodeId" => "io-node", "method" => method, "args" => args}}}
    )

    assert_receive {:request, "node.invoke.result", %{"invokeId" => ^id} = params,
                    {:invoke_result, ^id}},
                   5_000

    if Map.has_key?(params, "result"),
      do: {:ok, params["result"]},
      else: {:error, params["error"]}
  end
end
