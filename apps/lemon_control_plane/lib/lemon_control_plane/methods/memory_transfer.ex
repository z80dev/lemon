defmodule LemonControlPlane.Methods.MemoryTransfer do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "memory.transfer"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx), do: LemonControlPlane.MemoryTransfer.execute(params, ctx)
end

defmodule LemonControlPlane.Methods.MemoryTransferStatus do
  @moduledoc false
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "memory.transfer.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx), do: LemonControlPlane.MemoryTransfer.status(params, ctx)
end
