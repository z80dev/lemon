defmodule LemonControlPlane.Methods.MemoryTransferTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{MemoryTransfer, MemoryTransferStatus, Registry}
  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.{NodeRegistry, ProfileStore, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    state = Path.join(tmp_dir, "state")
    File.mkdir_p!(state)
    old_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(:lemon_core, :paths,
      home_state_dir: state,
      global_config: Path.join(state, "config.toml")
    )

    on_exit(fn ->
      if old_paths,
        do: Application.put_env(:lemon_core, :paths, old_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    if Process.whereis(NodeRegistry) == nil, do: start_supervised!(NodeRegistry)
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    suffix = System.unique_integer([:positive])
    source = "memory-source-#{suffix}"
    target = "memory-target-#{suffix}"
    source_name = "source-worker-#{suffix}"
    target_name = "target-worker-#{suffix}"

    capabilities =
      Map.new(
        ~w(prepare snapshot validate preview apply status inspect),
        &{"memory.transfer." <> &1, %{"version" => 1, "contextVersion" => 1}}
      )

    :ok = NodeRegistry.register(source, source_name, self(), %{capabilities: capabilities})
    :ok = NodeRegistry.register(target, target_name, self(), %{capabilities: capabilities})
    {:ok, _} = ProfileStore.create(%{"id" => "transfer-profile", "node" => source_name})

    params = %{
      "profileId" => "transfer-profile",
      "nodeId" => target,
      "mutationId" => "move-#{suffix}"
    }

    identity = Map.put(params, "sourceNodeId", source)

    snapshot = %{
      "version" => 1,
      "profileId" => "transfer-profile",
      "documents" => [],
      "preferences" => %{"memory" => "private complete memory"}
    }

    envelope =
      Map.merge(identity, %{"snapshotDigest" => String.duplicate("a", 64), "snapshot" => snapshot})

    receipt = Map.drop(envelope, ["snapshot"]) |> Map.put("copied", true)

    %{
      params: params,
      source: source,
      target: target,
      source_name: source_name,
      tmp_dir: tmp_dir,
      target_name: target_name,
      envelope: envelope,
      receipt: receipt
    }
  end

  test "copy is acknowledged, placement stays on source, and replay returns exact receipt", ctx do
    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    prepare = request(ctx.source, "prepare")
    assert prepare["args"] == Map.drop(ctx.envelope, ["snapshot", "snapshotDigest"])
    reply(prepare, ctx.envelope)
    validate = request(ctx.source, "validate")
    assert validate["args"] == ctx.envelope
    reply(validate, %{"valid" => true})
    apply = request(ctx.target, "apply")
    assert apply["args"] == ctx.envelope
    assert {:ok, _} = LemonCore.JSONPayload.validate(apply["args"])
    reply(apply, ctx.receipt)
    assert Task.await(task) == {:ok, ctx.receipt}
    assert {:ok, %{"node" => source_name}} = ProfileStore.get("transfer-profile")
    assert source_name == ctx.source_name
    assert MemoryTransfer.handle(ctx.params, %{}) == {:ok, ctx.receipt}
    refute_receive {:node_event, "node.invoke.request", _}

    journal = Store.get(:control_memory_transfers, ctx.params["mutationId"])
    assert journal["state"] == "completed"
    refute inspect(journal) =~ "private complete memory"

    assert {:error, {:conflict, _, _}} =
             MemoryTransfer.handle(Map.put(ctx.params, "profileId", "another-profile"), %{})

    assert {:error, {:conflict, _, _}} =
             MemoryTransfer.handle(
               Map.put(ctx.params, "snapshotDigest", String.duplicate("b", 64)),
               %{}
             )
  end

  test "uncertain apply reconciles only destination status and never replays", ctx do
    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.source, "prepare"), ctx.envelope)
    reply(request(ctx.source, "validate"), %{"valid" => true})
    apply = request(ctx.target, "apply")
    :ok = NodeRegistry.complete(ctx.target, apply["invokeId"], nil, "connection lost")
    assert {:error, {:unavailable, _, details}} = Task.await(task)
    assert details["mutationId"] == ctx.params["mutationId"]
    assert details["retrySafe"] == false

    pending = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    status = request(ctx.target, "status")
    service_error(status, "transfer_pending")
    assert {:error, {:unavailable, _, _}} = Task.await(pending)
    refute_receive {:node_event, "node.invoke.request", _}

    recovered = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.target, "status"), ctx.receipt)
    assert Task.await(recovered) == {:ok, ctx.receipt}
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "overwrite preview exposes counts/digests only and apply binds exact confirmation", ctx do
    params = Map.put(ctx.params, "action", "preview")

    preview =
      Map.drop(ctx.receipt, ["copied"])
      |> Map.merge(%{
        "destinationDigest" => String.duplicate("b", 64),
        "confirmationToken" => "opaque-token",
        "sourceCounts" => %{"documents" => 2, "preferences" => 1},
        "destinationCounts" => %{"documents" => 1, "preferences" => 2},
        "overwrite" => true
      })

    task = Task.async(fn -> MemoryTransfer.handle(params, %{}) end)
    reply(request(ctx.source, "prepare"), ctx.envelope)
    reply(request(ctx.source, "validate"), %{"valid" => true})
    reply(request(ctx.target, "preview"), Map.put(preview, "rawMemory", "must never escape"))
    assert Task.await(task) == {:ok, preview}

    refute inspect(Store.get(:control_memory_transfers, ctx.params["mutationId"])) =~
             "must never escape"

    refute_receive {:node_event, "node.invoke.request", _}

    confirmed =
      ctx.params
      |> Map.merge(
        Map.take(
          preview,
          ~w(snapshotDigest destinationDigest confirmationToken)
        )
      )

    apply_task = Task.async(fn -> MemoryTransfer.handle(confirmed, %{}) end)
    reply(request(ctx.source, "snapshot"), ctx.envelope)
    reply(request(ctx.source, "validate"), %{"valid" => true})
    apply = request(ctx.target, "apply")
    assert apply["args"]["destinationDigest"] == preview["destinationDigest"]
    assert apply["args"]["confirmationToken"] == preview["confirmationToken"]
    assert apply["args"]["snapshotDigest"] == preview["snapshotDigest"]
    reply(apply, ctx.receipt)
    assert Task.await(apply_task) == {:ok, ctx.receipt}
  end

  test "source revision change prevents apply before any destination mutation", ctx do
    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.source, "prepare"), ctx.envelope)
    service_error(request(ctx.source, "validate"), "stale_source")
    assert {:error, {:conflict, _, %{"code" => "STALE_SOURCE"}}} = Task.await(task)
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "an uncertain source freeze is read back without replaying prepare", ctx do
    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    prepare = request(ctx.source, "prepare")
    :ok = NodeRegistry.complete(ctx.source, prepare["invokeId"], nil, "connection lost")
    assert {:error, {:unavailable, _, %{"retrySafe" => false}}} = Task.await(task)

    resumed = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.source, "snapshot"), ctx.envelope)
    reply(request(ctx.source, "validate"), %{"valid" => true})
    reply(request(ctx.target, "apply"), ctx.receipt)
    assert Task.await(resumed) == {:ok, ctx.receipt}
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "a foreign source envelope is rejected before dispatch to the target", ctx do
    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.source, "prepare"), Map.put(ctx.envelope, "profileId", "lb-foreign"))
    assert {:error, {:conflict, _, _}} = Task.await(task)
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "a destination acknowledgement must bind the exact source snapshot digest", ctx do
    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.source, "prepare"), ctx.envelope)
    reply(request(ctx.source, "validate"), %{"valid" => true})

    reply(
      request(ctx.target, "apply"),
      Map.put(ctx.receipt, "snapshotDigest", String.duplicate("c", 64))
    )

    assert {:error, {:unavailable, _, %{"retrySafe" => false}}} = Task.await(task)

    resumed = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.target, "status"), ctx.receipt)
    assert Task.await(resumed) == {:ok, ctx.receipt}
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "a local source uses full owning-service snapshot data, not management previews", ctx do
    store = :"local_transfer_#{System.unique_integer([:positive])}"

    start_supervised!(
      {LemonMemory.Store, name: store, path: Path.join(ctx.tmp_dir, "local-memory")}
    )

    {:ok, _} = ProfileStore.create(%{"id" => "transfer-local"})
    text = String.duplicate("界", 800) <> " complete-tail"

    assert {:ok, %{"item" => item}} =
             LemonSkills.ProfileMemory.execute("add", "transfer-local", %{"text" => text},
               store: store
             )

    refute item["text"] =~ "complete-tail"

    params = ctx.params |> Map.put("profileId", "transfer-local")

    task =
      Task.async(fn ->
        MemoryTransfer.handle(params, %{memory_transfer_opts: [store: store]})
      end)

    apply = request(ctx.target, "apply")
    assert apply["args"]["sourceNodeId"] == "local"
    assert Jason.encode!(apply["args"]["snapshot"]) =~ "complete-tail"
    assert apply["args"]["snapshotDigest"] =~ ~r/\A[a-f0-9]{64}\z/

    receipt =
      apply["args"]
      |> Map.take(~w(profileId mutationId sourceNodeId nodeId snapshotDigest))
      |> Map.put("copied", true)

    reply(apply, receipt)
    assert Task.await(task) == {:ok, receipt}
    assert {:ok, %{"node" => "local"}} = ProfileStore.get("transfer-local")
    refute inspect(Store.get(:control_memory_transfers, params["mutationId"])) =~ "complete-tail"
  end

  test "explicit read-only status without controller intent never starts a transfer", ctx do
    assert MemoryTransferStatus.scopes() == [:read]
    assert Registry.dispatch_mode("memory.transfer.status") == :async
    assert :ok = Schemas.validate("memory.transfer.status", ctx.params)
    assert Store.get(:control_memory_transfers, ctx.params["mutationId"]) == nil

    task =
      Task.async(fn ->
        Registry.dispatch("memory.transfer.status", ctx.params, %{
          auth: %{role: :operator, scopes: [:read]}
        })
      end)

    inspect_request = request(ctx.target, "inspect")
    assert inspect_request["args"] == ctx.params

    unknown =
      Map.merge(ctx.params, %{
        "status" => "unknown",
        "sourceNodeId" => nil,
        "snapshotDigest" => nil,
        "receipt" => nil
      })

    reply(inspect_request, unknown)
    assert Task.await(task) == {:ok, unknown}
    assert Store.get(:control_memory_transfers, ctx.params["mutationId"]) == nil
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "status reads pending and completed target receipts without applying or journaling", ctx do
    intent = ctx.envelope |> Map.drop(["snapshot"]) |> Map.put("state", "prepared")
    :ok = Store.put(:control_memory_transfers, ctx.params["mutationId"], intent)

    pending =
      Map.merge(Map.drop(ctx.receipt, ["copied"]), %{"status" => "pending", "receipt" => nil})

    task = Task.async(fn -> MemoryTransferStatus.handle(ctx.params, %{}) end)
    reply(request(ctx.target, "inspect"), pending)
    assert Task.await(task) == {:ok, pending}
    assert Store.get(:control_memory_transfers, ctx.params["mutationId"]) == intent

    completed = Map.merge(pending, %{"status" => "completed", "receipt" => ctx.receipt})
    task = Task.async(fn -> MemoryTransferStatus.handle(ctx.params, %{}) end)
    reply(request(ctx.target, "inspect"), completed)
    assert Task.await(task) == {:ok, completed}
    assert Store.get(:control_memory_transfers, ctx.params["mutationId"]) == intent
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "read-only status rejects a target receipt for a different source digest", ctx do
    intent = ctx.envelope |> Map.drop(["snapshot"]) |> Map.put("state", "outcome_unknown")
    :ok = Store.put(:control_memory_transfers, ctx.params["mutationId"], intent)
    changed = Map.put(ctx.receipt, "snapshotDigest", String.duplicate("b", 64))

    result =
      Map.merge(Map.drop(changed, ["copied"]), %{"status" => "completed", "receipt" => changed})

    task = Task.async(fn -> MemoryTransferStatus.handle(ctx.params, %{}) end)
    reply(request(ctx.target, "inspect"), result)
    assert {:error, {:conflict, _, _}} = Task.await(task)
    assert Store.get(:control_memory_transfers, ctx.params["mutationId"]) == intent
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "source and destination durable IDs cannot be shadowed after snapshot preparation", ctx do
    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    prepare = request(ctx.source, "prepare")
    shadow_id(ctx.source)
    shadow_id(ctx.target)
    reply(prepare, ctx.envelope)
    reply(request(ctx.source, "validate"), %{"valid" => true})
    reply(request(ctx.target, "apply"), ctx.receipt)
    assert Task.await(task) == {:ok, ctx.receipt}
    refute_received {:alias_event, _}
  end

  test "read-only status targets an exact online ID and never falls back when it is offline",
       ctx do
    shadow_id(ctx.target)
    task = Task.async(fn -> MemoryTransferStatus.handle(ctx.params, %{}) end)

    unknown =
      Map.merge(ctx.params, %{
        "status" => "unknown",
        "sourceNodeId" => nil,
        "snapshotDigest" => nil,
        "receipt" => nil
      })

    reply(request(ctx.target, "inspect"), unknown)
    assert Task.await(task) == {:ok, unknown}
    :ok = NodeRegistry.unregister(ctx.target, self())

    assert {:error, {:unavailable, _, %{"code" => "MEMORY_TRANSFER_STATUS_UNAVAILABLE"}}} =
             MemoryTransferStatus.handle(ctx.params, %{})

    refute_received {:alias_event, _}
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "admin authorization, request types, and explicit durable target are enforced", ctx do
    assert MemoryTransfer.scopes() == [:admin]
    assert Registry.dispatch_mode("memory.transfer") == :async
    assert :ok = Schemas.validate("memory.transfer", ctx.params)
    assert {:error, _} = Schemas.validate("memory.transfer", Map.delete(ctx.params, "mutationId"))

    assert {:error, _} =
             Registry.dispatch("memory.transfer", ctx.params, %{
               auth: %{role: :operator, scopes: [:read, :write]}
             })

    assert {:error, {:unavailable, _}} =
             MemoryTransfer.handle(Map.put(ctx.params, "nodeId", ctx.target_name), %{})

    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "old source workers cannot snapshot newer private ownership into a legacy transfer", ctx do
    :ok =
      NodeRegistry.register(ctx.source, ctx.source_name, self(), %{
        capabilities: %{"memory.transfer.prepare" => %{"version" => 1}}
      })

    assert {:error, {:unavailable, _}} = MemoryTransfer.handle(ctx.params, %{})
    refute_receive {:node_event, "node.invoke.request", _}
  end

  test "old destinations cannot apply scoped snapshots or attest a scoped transfer receipt",
       ctx do
    :ok =
      NodeRegistry.register(ctx.target, ctx.target_name, self(), %{
        capabilities: %{
          "memory.transfer.apply" => %{"version" => 1},
          "memory.transfer.inspect" => %{"version" => 1}
        }
      })

    task = Task.async(fn -> MemoryTransfer.handle(ctx.params, %{}) end)
    reply(request(ctx.source, "prepare"), ctx.envelope)
    reply(request(ctx.source, "validate"), %{"valid" => true})
    assert {:error, {:unavailable, _}} = Task.await(task)
    refute_receive {:node_event, "node.invoke.request", _}

    assert {:error, {:unavailable, _, %{"code" => "MEMORY_TRANSFER_STATUS_UNAVAILABLE"}}} =
             MemoryTransferStatus.handle(ctx.params, %{})

    refute_receive {:node_event, "node.invoke.request", _}
  end

  defp shadow_id(node_id) do
    owner = self()

    pid =
      spawn(fn ->
        receive do
          event -> send(owner, {:alias_event, event})
        end

        Process.sleep(:infinity)
      end)

    shadow = node_id <> "-shadow"
    :ok = NodeRegistry.register(shadow, node_id, pid)

    on_exit(fn ->
      NodeRegistry.unregister(shadow, pid)
      Process.exit(pid, :kill)
    end)

    pid
  end

  defp request(node_id, operation) do
    assert_receive {:node_event, "node.invoke.request", payload}, 1_000
    assert payload["nodeId"] == node_id
    assert payload["method"] == "memory.transfer." <> operation
    payload
  end

  defp reply(payload, result) do
    :ok =
      NodeRegistry.complete(payload["nodeId"], payload["invokeId"], %{
        "ok" => true,
        "payload" => result
      })
  end

  defp service_error(payload, reason) do
    :ok =
      NodeRegistry.complete(payload["nodeId"], payload["invokeId"], %{
        "ok" => false,
        "error" => reason
      })
  end
end
