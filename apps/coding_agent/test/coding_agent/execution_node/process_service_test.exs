defmodule CodingAgent.ExecutionNode.ProcessServiceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.ProcessService
  alias LemonCore.Store

  @moduletag :tmp_dir
  @store :node_process_test_store
  @server :node_process_test_service

  setup %{tmp_dir: root} do
    start_supervised!(
      Supervisor.child_spec(
        {Store,
         name: @store,
         backend: LemonCore.Store.SqliteBackend,
         backend_opts: [path: Path.join(root, "receipts.sqlite3"), ephemeral_tables: []]},
        id: @store
      )
    )

    start_service()
    python = System.find_executable("python3")
    assert is_binary(python), "python3 is required for destination process execution"
    fixture = Path.expand("../../support/node_process_fixture.py", __DIR__)

    opts = [
      server: @server,
      node_id: "process-node",
      session_generation: 11,
      invoke_id: "original-invocation",
      owner: self(),
      default_cwd: root,
      allowed_roots: [root]
    ]

    %{root: root, python: python, fixture: fixture, opts: opts}
  end

  test "literal Unicode, quoted 21kB argv, raw stdin EOF, non-TTY pipes, independent streams and real exit",
       ctx do
    literal = ["雪 λ 'quoted' \"double\"", "", String.duplicate("x '雪' ", 3_000)]
    stdin = <<0, 1, 255>> <> "exact stdin\n"

    args =
      args(ctx, "literal", ["report" | literal]) |> Map.put("stdinBase64", Base.encode64(stdin))

    assert {:ok, receipt} = run(args, ctx.opts)
    assert receipt["state"] == "completed"
    assert receipt["exitCode"] == 17
    assert receipt["outputTruncated"] == false
    report = receipt["stdoutBase64"] |> Base.decode64!() |> Jason.decode!()
    assert report["argv"] == literal
    assert report["stdin"] == Base.encode64(stdin)
    assert report["isatty"] == [false, false, false]
    assert File.stat!(report["cwd"]).inode == File.stat!(ctx.root).inode
    assert Base.decode64!(receipt["stderrBase64"]) == <<"independent-stderr", 0, 255>>
    assert {:ok, ^receipt} = get("literal", ctx.opts)
    assert {:ok, ^receipt} = run(args, Keyword.put(ctx.opts, :session_generation, 12))

    assert {:error, :process_intent_conflict} =
             run(Map.put(args, "stdinBase64", Base.encode64("different")), ctx.opts)

    assert {:ok, metadata} =
             Store.fetch(@store, :node_process_receipts, {"process-node", "literal"})

    refute Map.has_key?(metadata, :argv)
    refute Map.has_key?(metadata, :stdin)
    refute Map.has_key?(metadata, :stdout)
    refute Map.has_key?(metadata, :stderr)
  end

  test "get absence is strict and cancel-before-run is a durable non-executing tombstone", ctx do
    assert {:ok, missing} = get("missing", ctx.opts)
    assert missing == unavailable("missing", "not_found")
    assert {:ok, tombstone} = cancel("missing", ctx.opts)
    assert tombstone == unavailable("missing", "cancelled")
    marker = Path.join(ctx.root, "must-not-run")
    assert {:ok, ^tombstone} = run(args(ctx, "missing", ["touch", marker]), ctx.opts)
    refute File.exists?(marker)
    stop_supervised!(ProcessService)
    start_service()
    assert {:ok, ^tombstone} = run(args(ctx, "missing", ["touch", marker]), ctx.opts)
    refute File.exists?(marker)
  end

  test "run reserves once while get and cancel remain concurrent and invocation-bound", ctx do
    ready = Path.join(ctx.root, "ready")
    args = args(ctx, "active", ["hold", ready])
    task = Task.async(fn -> run(args, ctx.opts) end)
    await_file(ready)
    assert {:ok, running} = get("active", ctx.opts)
    assert running == unavailable("active", "running")
    assert {:ok, ^running} = run(args, ctx.opts)
    assert {:error, :process_intent_conflict} = run(Map.put(args, "cwd", "/"), ctx.opts)
    foreign = spawn(fn -> Process.sleep(:infinity) end)

    try do
      assert {:error, :process_owner_mismatch} =
               cancel("active", Keyword.put(ctx.opts, :owner, foreign))

      assert {:error, :process_owner_mismatch} =
               cancel("active", Keyword.put(ctx.opts, :session_generation, 12))
    after
      Process.exit(foreign, :kill)
    end

    assert {:ok, cancelled} =
             cancel("active", Keyword.put(ctx.opts, :invoke_id, "cancel-invocation"))

    assert cancelled["state"] == "cancelled"
    assert is_integer(cancelled["exitCode"])
    assert {:ok, ^cancelled} = Task.await(task, 5_000)
  end

  test "timeout, explicit and original-invocation cancellation kill descendants", ctx do
    for {id, action} <- [
          {"timeout-tree", :timeout},
          {"cancel-tree", :cancel},
          {"invocation-tree", :invocation}
        ] do
      ready = Path.join(ctx.root, id <> "-ready")
      survived = Path.join(ctx.root, id <> "-survived")
      timeout = if action == :timeout, do: 1_000, else: 10_000
      args = args(ctx, id, ["tree", ready, survived]) |> Map.put("timeoutMs", timeout)
      task = Task.async(fn -> run(args, ctx.opts) end)
      await_file(ready)

      case action do
        :timeout ->
          :ok

        :cancel ->
          assert {:ok, %{"state" => "cancelled"}} = cancel(id, ctx.opts)

        :invocation ->
          assert :ok = ProcessService.cancel_invocation(self(), "original-invocation", @server)
      end

      assert {:ok, result} = Task.await(task, 5_000)
      assert result["state"] == "cancelled"
      assert is_integer(result["exitCode"])
      Process.sleep(2_100)
      refute File.exists?(survived)
    end
  end

  test "combined overflow is bounded and terminalizes instead of draining unbounded output",
       ctx do
    args = args(ctx, "overflow", ["overflow"]) |> Map.put("maxOutputBytes", 257)
    assert {:ok, result} = run(args, ctx.opts)
    assert result["state"] == "cancelled"
    assert result["outputTruncated"] == true
    assert is_integer(result["exitCode"])

    assert byte_size(Base.decode64!(result["stdoutBase64"])) +
             byte_size(Base.decode64!(result["stderrBase64"])) == 257
  end

  test "caller and authenticated owner death cancel actual work", ctx do
    for which <- [:caller, :owner] do
      id = Atom.to_string(which)
      ready = Path.join(ctx.root, id <> "-ready")
      survived = Path.join(ctx.root, id <> "-survived")
      owner = spawn(fn -> Process.sleep(:infinity) end)
      opts = Keyword.put(ctx.opts, :owner, owner)
      caller = spawn(fn -> run(args(ctx, id, ["tree", ready, survived]), opts) end)
      await_file(ready)
      Process.exit(if(which == :owner, do: owner, else: caller), :kill)
      result = await_state(id, "cancelled", ctx.opts)
      assert is_integer(result["exitCode"])
      Process.exit(owner, :kill)
      Process.exit(caller, :kill)
      Process.sleep(2_100)
      refute File.exists?(survived)
    end
  end

  test "service restart reports unknown without fake bytes, exit or replay; durable final exit survives",
       ctx do
    completed = args(ctx, "completed", ["report", "before restart"])
    assert {:ok, %{"exitCode" => 17}} = run(completed, ctx.opts)
    ready = Path.join(ctx.root, "restart-ready")
    marker = Path.join(ctx.root, "restart-survived")
    active = args(ctx, "restart", ["tree", ready, marker])
    task = Task.async(fn -> run(active, ctx.opts) end)
    await_file(ready)
    stop_supervised!(ProcessService)
    assert {:error, :process_outcome_unknown} = Task.await(task, 5_000)
    start_service()
    assert {:ok, unknown} = get("restart", ctx.opts)
    assert unknown == unavailable("restart", "outcome_unknown")
    assert {:ok, ^unknown} = run(active, ctx.opts)
    assert {:ok, restored} = get("completed", ctx.opts)
    assert restored == Map.put(unavailable("completed", "completed"), "exitCode", 17)
    Process.sleep(2_100)
    refute File.exists?(marker)
  end

  test "independent validation rejects missing generation, unsafe cwd and literal launch failures",
       ctx do
    args = args(ctx, "validate", ["report"])
    assert {:error, :invalid_request} = run(args, Keyword.delete(ctx.opts, :session_generation))
    assert {:error, :invalid_request} = run(Map.put(args, "argv", ["python3", <<0>>]), ctx.opts)

    assert {:error, :invalid_request} =
             run(Map.put(args, "argv", [String.duplicate("x", 131_073)]), ctx.opts)

    assert {:error, :invalid_request} = run(Map.put(args, "stdinBase64", "not base64"), ctx.opts)
    assert {:error, :path_not_allowed} = run(Map.put(args, "cwd", "../outside"), ctx.opts)

    assert {:error, :executable_not_found} =
             run(
               Map.put(args(ctx, "no-exe", []), "argv", [
                 "lemon-process-executable-that-does-not-exist"
               ]),
               ctx.opts
             )

    assert {:ok, %{"state" => "outcome_unknown", "exitCode" => nil}} = get("no-exe", ctx.opts)

    assert {:error, :store_unavailable} =
             ProcessService.handle(
               "node.process.get",
               %{"nodeId" => "process-node", "processId" => "missing"},
               Keyword.put(ctx.opts, :server, start_unavailable_service())
             )
  end

  test "receipts and active execution caps fail closed, without evicting uncertain IDs", ctx do
    stop_supervised!(ProcessService)

    for index <- 1..1_000 do
      receipt = %{
        node_id: "process-node",
        process_id: "reserved-#{index}",
        generation: 11,
        invoke_id: "original-invocation",
        state: "outcome_unknown",
        exit_code: nil,
        intent: Base.encode64(:crypto.hash(:sha256, "reserved-#{index}")),
        created_at: 0
      }

      assert :ok =
               Store.put(
                 @store,
                 :node_process_receipts,
                 {"process-node", receipt.process_id},
                 receipt
               )
    end

    start_service()
    assert {:error, :process_receipt_limit} = run(args(ctx, "over-limit", ["report"]), ctx.opts)
    assert {:error, :process_receipt_limit} = cancel("over-limit", ctx.opts)
    assert {:ok, %{"state" => "outcome_unknown"}} = get("reserved-1", ctx.opts)
  end

  test "sixteen live processes bound admission; superseded generation cannot mutate", ctx do
    tasks =
      for index <- 1..16 do
        ready = Path.join(ctx.root, "cap-#{index}")
        task = Task.async(fn -> run(args(ctx, "cap-#{index}", ["hold", ready]), ctx.opts) end)
        await_file(ready)
        task
      end

    assert {:error, :process_limit} = run(args(ctx, "seventeenth", ["report"]), ctx.opts)
    assert :ok = ProcessService.cancel_owner(self(), @server)
    for task <- tasks, do: assert({:ok, %{"state" => "cancelled"}} = Task.await(task, 5_000))
    newer = Keyword.put(ctx.opts, :session_generation, 12)
    assert {:ok, _} = cancel("new-generation", newer)
    assert {:error, :stale_generation} = run(args(ctx, "old-generation", ["report"]), ctx.opts)
    assert {:error, :stale_generation} = cancel("old-generation", ctx.opts)
    assert {:ok, _} = get("cap-1", newer)
  end

  test "spent receipts never expire or redispatch; only the output cache expires", ctx do
    for index <- 1..17 do
      assert {:ok, %{"state" => "completed", "exitCode" => 17}} =
               run(args(ctx, "cached-#{index}", ["report"]), ctx.opts)
    end

    assert map_size(:sys.get_state(@server).cache) == 16

    assert {:ok,
            %{
              "state" => "completed",
              "exitCode" => 17,
              "stdoutBase64" => nil,
              "stderrBase64" => nil,
              "outputTruncated" => true
            }} = get("cached-1", ctx.opts)

    assert {:ok, newest} = get("cached-17", ctx.opts)
    assert is_binary(newest["stdoutBase64"])
    key = {"process-node", "cached-17"}
    assert {:ok, receipt} = Store.fetch(@store, :node_process_receipts, key)
    old = System.system_time(:millisecond) - 86_400_001
    assert :ok = Store.put(@store, :node_process_receipts, key, %{receipt | created_at: old})
    stop_supervised!(ProcessService)
    start_service()
    assert {:ok, %{"state" => "completed", "exitCode" => 17}} = get("cached-17", ctx.opts)

    assert :ok =
             Store.put(@store, :node_process_receipts, key, %{
               receipt
               | created_at: old,
                 finished_at: old
             })

    stop_supervised!(ProcessService)
    start_service()
    assert {:ok, restored} = get("cached-17", ctx.opts)
    assert restored == Map.put(unavailable("cached-17", "completed"), "exitCode", 17)
    assert {:ok, ^restored} = run(args(ctx, "cached-17", ["report"]), ctx.opts)
    assert {:ok, tombstone} = cancel("old-tombstone", ctx.opts)

    assert {:ok, cancelled} =
             Store.fetch(@store, :node_process_receipts, {"process-node", "old-tombstone"})

    assert :ok =
             Store.put(@store, :node_process_receipts, {"process-node", "old-tombstone"}, %{
               cancelled
               | created_at: 0
             })

    stop_supervised!(ProcessService)
    start_service()
    marker = Path.join(ctx.root, "must-not-run-old-id")
    assert {:ok, ^tombstone} = run(args(ctx, "old-tombstone", ["touch", marker]), ctx.opts)
    assert {:ok, _} = run(args(ctx, "cache-expiry", ["report"]), ctx.opts)
    refute File.exists?(marker)

    :sys.replace_state(@server, fn state ->
      cache =
        Map.new(state.cache, fn {key, {time, output}} -> {key, {time - 86_400_001, output}} end)

      %{state | cache: cache}
    end)

    send(Process.whereis(@server), :sweep)
    assert map_size(:sys.get_state(@server).cache) == 0
  end

  test "real JSONL backend reload preserves intent, terminal exit and missing-cancel fences",
       ctx do
    store = :node_process_jsonl_test_store
    service = :node_process_jsonl_test_service

    store_spec =
      Supervisor.child_spec(
        {Store,
         name: store,
         backend: LemonCore.Store.JsonlBackend,
         backend_opts: [path: Path.join(ctx.root, "jsonl-receipts")]},
        id: store
      )

    service_spec =
      Supervisor.child_spec({ProcessService, name: service, store: store}, id: service)

    start_supervised!(store_spec)
    start_supervised!(service_spec)
    opts = Keyword.put(ctx.opts, :server, service)
    literal = args(ctx, "jsonl-run", ["report", "雪 literal"])
    assert {:ok, %{"exitCode" => 17}} = run(literal, opts)
    assert {:ok, tombstone} = cancel("jsonl-tombstone", opts)
    stop_supervised!(service)
    stop_supervised!(store)
    start_supervised!(store_spec)
    start_supervised!(service_spec)
    assert {:ok, restored} = run(literal, opts)
    assert restored == Map.put(unavailable("jsonl-run", "completed"), "exitCode", 17)

    assert {:error, :process_intent_conflict} =
             run(Map.put(literal, "stdinBase64", Base.encode64("different")), opts)

    marker = Path.join(ctx.root, "jsonl-must-not-run")
    assert {:ok, ^tombstone} = run(args(ctx, "jsonl-tombstone", ["touch", marker]), opts)
    refute File.exists?(marker)
  end

  test "string-key receipts normalize, while malformed or contradictory proof fails closed",
       ctx do
    assert {:ok, tombstone} = cancel("string-map", ctx.opts)
    key = {"process-node", "string-map"}
    assert {:ok, receipt} = Store.fetch(@store, :node_process_receipts, key)
    strings = Map.new(receipt, fn {key, value} -> {Atom.to_string(key), value} end)
    assert :ok = Store.put(@store, :node_process_receipts, key, strings)
    stop_supervised!(ProcessService)
    start_service()
    assert {:ok, ^tombstone} = get("string-map", ctx.opts)
    assert {:ok, ^tombstone} = run(args(ctx, "string-map", ["report"]), ctx.opts)
    invalid = Map.put(strings, "state", "completed")
    assert :ok = Store.put(@store, :node_process_receipts, key, invalid)
    assert {:error, :store_unavailable} = get("string-map", ctx.opts)
    assert {:error, :store_unavailable} = run(args(ctx, "string-map", ["report"]), ctx.opts)
    assert Process.alive?(Process.whereis(@server))
    stop_supervised!(ProcessService)
    start_service()

    assert {:error, :store_unavailable} =
             run(args(ctx, "new-untrusted-store", ["report"]), ctx.opts)

    assert {:ok, ^invalid} = Store.fetch(@store, :node_process_receipts, key)
  end

  test "completed helper packets without an observed OS exit are never accepted", ctx do
    ready = Path.join(ctx.root, "invalid-packet-ready")
    task = Task.async(fn -> run(args(ctx, "invalid-packet", ["hold", ready]), ctx.opts) end)
    await_file(ready)
    job = :sys.get_state(@server).jobs[{"process-node", "invalid-packet"}]

    packet =
      unavailable("invalid-packet", "completed")
      |> Map.merge(%{"stdoutBase64" => "", "stderrBase64" => "", "outputTruncated" => false})

    send(Process.whereis(@server), {job.port, {:data, Jason.encode!(%{"ok" => packet})}})
    assert {:error, :process_outcome_unknown} = Task.await(task, 5_000)
    assert {:ok, unknown} = get("invalid-packet", ctx.opts)
    assert unknown == unavailable("invalid-packet", "outcome_unknown")
  end

  defp start_service do
    start_supervised!({ProcessService, name: @server, store: @store})
  end

  defp start_unavailable_service do
    name = :unavailable_process_test_service

    start_supervised!(
      Supervisor.child_spec({ProcessService, name: name, store: :missing_process_test_store},
        id: name
      )
    )

    name
  end

  defp args(ctx, id, extra),
    do: %{
      "nodeId" => "process-node",
      "processId" => id,
      "cwd" => ctx.root,
      "argv" => [ctx.python, ctx.fixture | extra],
      "stdinBase64" => "",
      "timeoutMs" => 10_000,
      "maxOutputBytes" => 1_048_576
    }

  defp run(args, opts), do: ProcessService.handle("node.process.run", args, opts)

  defp get(id, opts),
    do:
      ProcessService.handle(
        "node.process.get",
        %{"nodeId" => "process-node", "processId" => id},
        opts
      )

  defp cancel(id, opts),
    do:
      ProcessService.handle(
        "node.process.cancel",
        %{"nodeId" => "process-node", "processId" => id},
        opts
      )

  defp unavailable(id, state),
    do: %{
      "nodeId" => "process-node",
      "processId" => id,
      "state" => state,
      "exitCode" => nil,
      "stdoutBase64" => nil,
      "stderrBase64" => nil,
      "outputTruncated" => true
    }

  defp await_file(path, attempts \\ 200)
  defp await_file(path, 0), do: flunk("fixture did not become ready: #{path}")

  defp await_file(path, attempts) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_file(path, attempts - 1)
        )
  end

  defp await_state(id, expected, opts, attempts \\ 200)
  defp await_state(_id, _expected, _opts, 0), do: flunk("process did not terminalize")

  defp await_state(id, expected, opts, attempts) do
    case get(id, opts) do
      {:ok, %{"state" => ^expected} = receipt} ->
        receipt

      _ ->
        Process.sleep(10)
        await_state(id, expected, opts, attempts - 1)
    end
  end
end
