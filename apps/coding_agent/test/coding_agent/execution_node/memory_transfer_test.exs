defmodule CodingAgent.ExecutionNode.MemoryTransferTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.MemoryTransfer

  test "source snapshot methods are bound to the receiving source node" do
    args = %{"profileId" => "lb-alice", "mutationId" => "move-1",
      "sourceNodeId" => "source-node", "nodeId" => "destination-node"}
    for method <- ~w(prepare snapshot validate) do
      assert {:error, :transfer_conflict} =
        MemoryTransfer.execute("memory.transfer." <> method, args, "different-source")
      assert {:error, :transfer_conflict} =
        MemoryTransfer.execute("memory.transfer." <> method, args, "destination-node")
    end
  end

  test "preview, apply and receipt queries bind the destination node" do
    args = %{"profileId" => "lb-alice", "mutationId" => "move-1",
      "sourceNodeId" => "source-node", "nodeId" => "destination-node"}
    for method <- ~w(preview apply status inspect) do
      assert {:error, :transfer_conflict} =
        MemoryTransfer.execute("memory.transfer." <> method, args, "different-destination")
      assert {:error, :transfer_conflict} =
        MemoryTransfer.execute("memory.transfer." <> method, args, "source-node")
    end
    assert {:error, :transfer_conflict} =
      MemoryTransfer.execute("memory.transfer.apply", Map.delete(args, "nodeId"), nil)
  end

  test "only explicit private transfer methods are advertised" do
    assert MemoryTransfer.methods() == ~w(memory.transfer.prepare memory.transfer.snapshot memory.transfer.validate memory.transfer.preview memory.transfer.apply memory.transfer.status memory.transfer.inspect)
    assert {:error, :invalid_operation} = MemoryTransfer.execute("memory.transfer.unknown",
      %{"nodeId" => "destination-node"}, "destination-node")
    assert {:error, :invalid_params} = MemoryTransfer.execute("memory.transfer.apply", nil, "destination-node")
  end
end
