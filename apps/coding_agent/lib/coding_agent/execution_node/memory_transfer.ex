defmodule CodingAgent.ExecutionNode.MemoryTransfer do
  @moduledoc false

  alias LemonSkills.ProfileMemoryTransfer

  @methods ~w(memory.transfer.prepare memory.transfer.snapshot memory.transfer.validate memory.transfer.preview memory.transfer.apply memory.transfer.status memory.transfer.inspect)

  def methods, do: @methods

  @spec execute(String.t(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def execute("memory.transfer." <> operation, args, node_id) when is_map(args) do
    expected_node =
      if operation in ["prepare", "snapshot", "validate"],
        do: args["sourceNodeId"],
        else: args["nodeId"]

    if is_binary(node_id) and expected_node == node_id do
      dispatch(operation, args, node_id)
    else
      {:error, :transfer_conflict}
    end
  rescue
    _ -> {:error, :transfer_pending}
  catch
    _, _ -> {:error, :transfer_pending}
  end

  def execute(_, _, _), do: {:error, :invalid_params}

  defp dispatch("prepare", args, _node_id),
    do:
      ProfileMemoryTransfer.prepare(
        args["profileId"],
        args["mutationId"],
        args["sourceNodeId"],
        args["nodeId"]
      )

  defp dispatch("snapshot", args, _node_id),
    do:
      ProfileMemoryTransfer.snapshot(
        args["profileId"],
        args["mutationId"],
        args["sourceNodeId"],
        args["nodeId"]
      )

  defp dispatch("validate", args, _node_id) do
    case ProfileMemoryTransfer.validate(args) do
      :ok -> {:ok, %{"valid" => true}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch("preview", args, node_id),
    do: ProfileMemoryTransfer.preview(args, node_id: node_id)

  defp dispatch("apply", args, node_id),
    do: ProfileMemoryTransfer.apply_transfer(args, node_id: node_id)

  defp dispatch("status", args, node_id),
    do:
      ProfileMemoryTransfer.status(
        args["profileId"],
        args["mutationId"],
        args["sourceNodeId"],
        args["nodeId"],
        node_id: node_id
      )

  defp dispatch("inspect", args, node_id),
    do:
      ProfileMemoryTransfer.inspect_status(args["profileId"], args["mutationId"], args["nodeId"],
        node_id: node_id
      )

  defp dispatch(_, _, _), do: {:error, :invalid_operation}
end
