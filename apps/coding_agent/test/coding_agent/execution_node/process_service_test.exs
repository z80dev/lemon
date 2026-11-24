Code.require_file("../../support/process_service_case.ex", __DIR__)

defmodule CodingAgent.ExecutionNode.ProcessServiceTest do
  use CodingAgent.ExecutionNode.ProcessServiceCase, async: true

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
             Store.fetch(ctx.store, :node_process_receipts, {"process-node", "literal"})

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
    start_service(ctx)
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
    start_service(ctx)
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

    assert {:ok, %{"state" => "failed", "exitCode" => nil}} = get("no-exe", ctx.opts)

    assert {:error, :store_unavailable} =
             ProcessService.handle(
               "node.process.get",
               %{"nodeId" => "process-node", "processId" => "missing"},
               Keyword.put(ctx.opts, :server, start_unavailable_service(ctx))
             )
  end

  test "unresolved receipt capacity fails closed, without evicting uncertain IDs", ctx do
    seed_unknown(ctx, 1..1_000)
    start_service(ctx)
    assert {:error, :process_receipt_limit} = run(args(ctx, "over-limit", ["report"]), ctx.opts)
    assert {:error, :process_receipt_limit} = cancel("over-limit", ctx.opts)
    assert {:ok, %{"state" => "outcome_unknown"}} = get("reserved-1", ctx.opts)
  end

  test "more than 1,000 admissions keep admitting while unresolved receipts are preserved", ctx do
    seed_unknown(ctx, 1..999)
    start_service(ctx)

    for index <- 1..1_001 do
      assert {:ok, %{"state" => "cancelled"}} = cancel("tombstone-#{index}", ctx.opts)
    end

    assert {:ok, %{"state" => "completed", "exitCode" => 17}} =
             run(args(ctx, "after-1001", ["report"]), ctx.opts)

    assert map_size(:sys.get_state(ctx.server).receipts) == 999 + 1_001 + 1

    for index <- [1, 500, 999] do
      assert {:ok, %{"state" => "outcome_unknown"}} = get("reserved-#{index}", ctx.opts)
    end

    # A terminal ID still fences within its TTL.
    marker = Path.join(ctx.root, "tombstone-ran")

    assert {:ok, %{"state" => "cancelled"}} =
             run(args(ctx, "tombstone-1", ["touch", marker]), ctx.opts)

    refute File.exists?(marker)
  end

  test "a pre-exec spawn failure is failed, not unknown, and consumes no capacity", ctx do
    seed_unknown(ctx, 1..999)
    start_service(ctx)
    missing = ["lemon-process-executable-that-does-not-exist"]

    for index <- 1..3 do
      id = "no-exe-#{index}"

      assert {:error, :executable_not_found} =
               run(Map.put(args(ctx, id, []), "argv", missing), ctx.opts)

      assert {:ok, failed} = get(id, ctx.opts)
      assert failed == unavailable(id, "failed")
      # The fixed ID stays fenced: the same intent reads back, never relaunches.
      assert {:ok, ^failed} = run(Map.put(args(ctx, id, []), "argv", missing), ctx.opts)
    end

    assert {:ok, %{state: "failed", exit_code: nil}} =
             Store.fetch(ctx.store, :node_process_receipts, {"process-node", "no-exe-1"})

    # 999 unresolved receipts plus three failures still leave one slot.
    assert {:ok, %{"state" => "completed"}} = run(args(ctx, "still-room", ["report"]), ctx.opts)

    stop_supervised!(ProcessService)
    start_service(ctx)
    assert {:ok, %{"state" => "failed"}} = get("no-exe-1", ctx.opts)
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
    assert :ok = ProcessService.cancel_owner(self(), ctx.server)
    for task <- tasks, do: assert({:ok, %{"state" => "cancelled"}} = Task.await(task, 5_000))
    newer = Keyword.put(ctx.opts, :session_generation, 12)
    assert {:ok, _} = cancel("new-generation", newer)
    assert {:error, :stale_generation} = run(args(ctx, "old-generation", ["report"]), ctx.opts)
    assert {:error, :stale_generation} = cancel("old-generation", ctx.opts)
    assert {:ok, _} = get("cap-1", newer)
  end

  test "terminal fences retire after 24 hours; unknown outcomes and generation floors persist",
       ctx do
    for index <- 1..17 do
      assert {:ok, %{"state" => "completed", "exitCode" => 17}} =
               run(args(ctx, "cached-#{index}", ["report"]), ctx.opts)
    end

    assert map_size(:sys.get_state(ctx.server).cache) == 16

    assert {:ok,
            %{
              "state" => "completed",
              "exitCode" => 17,
              "stdoutBase64" => nil,
              "stderrBase64" => nil,
              "outputTruncated" => true
            }} = get("cached-1", ctx.opts)

    old = System.system_time(:millisecond) - 86_400_001
    key = {"process-node", "cached-17"}
    assert {:ok, receipt} = Store.fetch(ctx.store, :node_process_receipts, key)

    # Age alone does not retire: a completed fence counts from when it finished.
    assert :ok = Store.put(ctx.store, :node_process_receipts, key, %{receipt | created_at: old})
    stop_supervised!(ProcessService)
    start_service(ctx)
    assert {:ok, %{"state" => "completed", "exitCode" => 17}} = get("cached-17", ctx.opts)

    seed_unknown(ctx, 1..1)
    assert {:ok, _} = Store.fetch(ctx.store, :node_process_receipts, key)

    assert :ok =
             Store.put(ctx.store, :node_process_receipts, key, %{
               receipt
               | created_at: old,
                 finished_at: old
             })

    start_service(ctx)
    assert {:ok, tombstone} = cancel("old-tombstone", ctx.opts)
    tombstone_key = {"process-node", "old-tombstone"}
    assert {:ok, cancelled} = Store.fetch(ctx.store, :node_process_receipts, tombstone_key)
    marker = Path.join(ctx.root, "must-not-run-fresh-tombstone")
    assert {:ok, ^tombstone} = run(args(ctx, "old-tombstone", ["touch", marker]), ctx.opts)
    refute File.exists?(marker)

    assert :ok =
             Store.put(ctx.store, :node_process_receipts, tombstone_key, %{
               cancelled
               | created_at: old
             })

    # A newer generation raised the durable floor; its only receipt is old.
    newer = Keyword.put(ctx.opts, :session_generation, 12)
    assert {:ok, _} = cancel("newer-generation", newer)
    newer_key = {"process-node", "newer-generation"}
    assert {:ok, newer_receipt} = Store.fetch(ctx.store, :node_process_receipts, newer_key)

    assert :ok =
             Store.put(ctx.store, :node_process_receipts, newer_key, %{
               newer_receipt
               | created_at: old
             })

    stop_supervised!(ProcessService)
    start_service(ctx)

    # Retired terminal fences are gone from memory and the Store...
    assert {:ok, %{"state" => "not_found"}} = get("cached-17", ctx.opts)
    assert {:ok, nil} = Store.fetch(ctx.store, :node_process_receipts, key)
    assert {:ok, %{"state" => "not_found"}} = get("old-tombstone", newer)
    assert {:ok, %{"state" => "not_found"}} = get("newer-generation", newer)
    # ...while an equally old unresolved receipt is never retired automatically.
    assert {:ok, %{"state" => "outcome_unknown"}} = get("reserved-1", ctx.opts)
    # Recent terminal fences still hold.
    assert {:ok, %{"state" => "completed"}} = get("cached-16", ctx.opts)
    # The superseded generation stays refused after its newer receipts retired.
    assert {:error, :stale_generation} = run(args(ctx, "stale", ["report"]), ctx.opts)
    assert {:ok, %{"state" => "completed"}} = run(args(ctx, "cache-expiry", ["report"]), newer)

    :sys.replace_state(ctx.server, fn state ->
      cache =
        Map.new(state.cache, fn {key, {time, output}} -> {key, {time - 86_400_001, output}} end)

      %{state | cache: cache}
    end)

    send(Process.whereis(ctx.server), :sweep)
    assert map_size(:sys.get_state(ctx.server).cache) == 0
  end

  test "operator prune previews, refuses without confirmation, then deletes exactly the preview",
       ctx do
    seed_unknown(ctx, 1..3)
    start_service(ctx)
    assert {:ok, _} = cancel("recent-tombstone", ctx.opts)
    server = ctx.server

    assert {:error, :invalid_older_than_ms} = ProcessService.prune([], server)

    assert {:error, :invalid_states} =
             ProcessService.prune([older_than_ms: 1, states: ["running"]], server)

    assert {:ok, preview} = ProcessService.prune([older_than_ms: 60_000], server)
    assert preview.count == 3
    assert preview.truncated == false
    assert is_binary(preview.token)

    assert Enum.map(preview.process_ids, & &1["processId"]) ==
             ~w(reserved-1 reserved-2 reserved-3)

    # The preview, a missing token, a wrong token and a different filter delete nothing.
    assert {:error, :confirmation_required} =
             ProcessService.prune([older_than_ms: 60_000, dry_run: false], server)

    assert {:error, :confirmation_mismatch} =
             ProcessService.prune(
               [older_than_ms: 60_000, dry_run: false, confirm_token: "forged"],
               server
             )

    for index <- 1..3 do
      assert {:ok, %{"state" => "outcome_unknown"}} = get("reserved-#{index}", ctx.opts)
    end

    assert {:ok, _} =
             Store.fetch(ctx.store, :node_process_receipts, {"process-node", "reserved-1"})

    assert {:error, :confirmation_mismatch} =
             ProcessService.prune(
               [older_than_ms: 1, dry_run: false, confirm_token: preview.token],
               server
             )

    # Tokens are single use, so the mismatched attempt consumed this one.
    assert {:ok, preview} = ProcessService.prune([older_than_ms: 60_000], server)
    # A receipt that changes after the preview is skipped, not deleted.
    :sys.replace_state(server, fn state ->
      update_in(state.receipts[{"process-node", "reserved-3"}], &%{&1 | created_at: 1})
    end)

    assert {:ok, %{deleted: deleted, skipped: skipped}} =
             ProcessService.prune(
               [older_than_ms: 60_000, dry_run: false, confirm_token: preview.token],
               server
             )

    assert Enum.map(deleted, & &1["processId"]) == ~w(reserved-1 reserved-2)
    assert Enum.map(skipped, & &1["processId"]) == ~w(reserved-3)
    assert {:ok, %{"state" => "not_found"}} = get("reserved-1", ctx.opts)

    assert {:ok, nil} =
             Store.fetch(ctx.store, :node_process_receipts, {"process-node", "reserved-1"})

    assert {:ok, %{"state" => "outcome_unknown"}} = get("reserved-3", ctx.opts)
    assert {:ok, %{"state" => "cancelled"}} = get("recent-tombstone", ctx.opts)

    assert {:error, :confirmation_mismatch} =
             ProcessService.prune(
               [older_than_ms: 60_000, dry_run: false, confirm_token: preview.token],
               server
             )
  end

  test "real SQLite backend reload preserves intent, terminal exit and missing-cancel fences",
       ctx do
    store = scoped_name(ctx.test, :sqlite_store)
    service = scoped_name(ctx.test, :sqlite_service)

    store_spec =
      Supervisor.child_spec(
        {Store,
         name: store,
         backend: LemonCore.Store.SqliteBackend,
         backend_opts: [path: Path.join(ctx.root, "receipts.sqlite3")]},
        id: store
      )

    service_spec =
      Supervisor.child_spec({ProcessService, name: service, store: store}, id: service)

    start_supervised!(store_spec)
    start_supervised!(service_spec)

    try do
      opts = Keyword.put(ctx.opts, :server, service)
      literal = args(ctx, "sqlite-run", ["report", "雪 literal"])
      assert {:ok, %{"exitCode" => 17}} = run(literal, opts)
      assert {:ok, tombstone} = cancel("sqlite-tombstone", opts)
      stop_supervised!(service)
      assert :ok = LemonCore.Store.SqliteBackend.close(:sys.get_state(store).backend_state)
      stop_supervised!(store)
      start_supervised!(store_spec)
      start_supervised!(service_spec)
      assert {:ok, restored} = run(literal, opts)
      assert restored == Map.put(unavailable("sqlite-run", "completed"), "exitCode", 17)

      assert {:error, :process_intent_conflict} =
               run(Map.put(literal, "stdinBase64", Base.encode64("different")), opts)

      marker = Path.join(ctx.root, "sqlite-must-not-run")
      assert {:ok, ^tombstone} = run(args(ctx, "sqlite-tombstone", ["touch", marker]), opts)
      refute File.exists?(marker)
    after
      stop_supervised(service)

      if pid = Process.whereis(store) do
        :ok = LemonCore.Store.SqliteBackend.close(:sys.get_state(pid).backend_state)
        stop_supervised!(store)
      end
    end
  end

  test "string-key receipts normalize, while malformed or contradictory proof fails closed",
       ctx do
    assert {:ok, tombstone} = cancel("string-map", ctx.opts)
    key = {"process-node", "string-map"}
    assert {:ok, receipt} = Store.fetch(ctx.store, :node_process_receipts, key)
    strings = Map.new(receipt, fn {key, value} -> {Atom.to_string(key), value} end)
    assert :ok = Store.put(ctx.store, :node_process_receipts, key, strings)
    stop_supervised!(ProcessService)
    start_service(ctx)
    assert {:ok, ^tombstone} = get("string-map", ctx.opts)
    assert {:ok, ^tombstone} = run(args(ctx, "string-map", ["report"]), ctx.opts)
    invalid = Map.put(strings, "state", "completed")
    assert :ok = Store.put(ctx.store, :node_process_receipts, key, invalid)
    assert {:error, :store_unavailable} = get("string-map", ctx.opts)
    assert {:error, :store_unavailable} = run(args(ctx, "string-map", ["report"]), ctx.opts)
    assert Process.alive?(Process.whereis(ctx.server))
    stop_supervised!(ProcessService)
    start_service(ctx)

    assert {:error, :store_unavailable} =
             run(args(ctx, "new-untrusted-store", ["report"]), ctx.opts)

    assert {:ok, ^invalid} = Store.fetch(ctx.store, :node_process_receipts, key)
  end

  test "completed helper packets without an observed OS exit are never accepted", ctx do
    ready = Path.join(ctx.root, "invalid-packet-ready")
    task = Task.async(fn -> run(args(ctx, "invalid-packet", ["hold", ready]), ctx.opts) end)
    await_file(ready)
    job = :sys.get_state(ctx.server).jobs[{"process-node", "invalid-packet"}]

    packet =
      unavailable("invalid-packet", "completed")
      |> Map.merge(%{"stdoutBase64" => "", "stderrBase64" => "", "outputTruncated" => false})

    send(Process.whereis(ctx.server), {job.port, {:data, Jason.encode!(%{"ok" => packet})}})
    assert {:error, :process_outcome_unknown} = Task.await(task, 5_000)
    assert {:ok, unknown} = get("invalid-packet", ctx.opts)
    assert unknown == unavailable("invalid-packet", "outcome_unknown")
  end

  defp seed_unknown(ctx, range) do
    stop_supervised!(ProcessService)

    for index <- range do
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
                 ctx.store,
                 :node_process_receipts,
                 {"process-node", receipt.process_id},
                 receipt
               )
    end
  end
end

defmodule CodingAgent.ExecutionNode.ProcessServiceCancellationTest do
  use CodingAgent.ExecutionNode.ProcessServiceCase, async: true

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
          assert :ok = ProcessService.cancel_invocation(self(), "original-invocation", ctx.server)
      end

      assert {:ok, result} = Task.await(task, 5_000)
      assert result["state"] == "cancelled"
      assert is_integer(result["exitCode"])
      Process.sleep(2_100)
      refute File.exists?(survived)
    end
  end
end

defmodule CodingAgent.ExecutionNode.ProcessServiceOwnerDeathTest do
  use CodingAgent.ExecutionNode.ProcessServiceCase, async: true

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
end
