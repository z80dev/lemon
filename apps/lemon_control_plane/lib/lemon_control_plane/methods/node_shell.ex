defmodule LemonControlPlane.Methods.NodeShellOpen do
  @moduledoc "Opens a real destination PTY owned by the authenticated operator connection."
  @behaviour LemonControlPlane.Method
  def name, do: "node.shell.open"
  def scopes, do: [:admin]
  def dispatch_mode, do: :async
  def handle(params, ctx), do: LemonControlPlane.NodeShells.open(params, ctx)
end

defmodule LemonControlPlane.Methods.NodeShellInput do
  @moduledoc "Writes bounded input to the opening connection's destination PTY."
  @behaviour LemonControlPlane.Method
  def name, do: "node.shell.input"
  def scopes, do: [:admin]
  def dispatch_mode, do: :async
  def handle(params, ctx), do: LemonControlPlane.NodeShells.command("input", params, ctx)
end

defmodule LemonControlPlane.Methods.NodeShellResize do
  @moduledoc "Resizes the opening connection's destination PTY."
  @behaviour LemonControlPlane.Method
  def name, do: "node.shell.resize"
  def scopes, do: [:admin]
  def dispatch_mode, do: :async
  def handle(params, ctx), do: LemonControlPlane.NodeShells.command("resize", params, ctx)
end

defmodule LemonControlPlane.Methods.NodeShellClose do
  @moduledoc "Closes the opening connection's destination PTY."
  @behaviour LemonControlPlane.Method
  def name, do: "node.shell.close"
  def scopes, do: [:admin]
  def dispatch_mode, do: :async
  def handle(params, ctx), do: LemonControlPlane.NodeShells.command("close", params, ctx)
end

defmodule LemonControlPlane.Methods.NodeShellEvent do
  @moduledoc "Authenticated worker-only PTY frames, pinned to the live open invocation."
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Protocol.Errors
  def name, do: "node.shell.event"
  def scopes, do: [:invoke]

  def handle(params, ctx) do
    auth = ctx[:auth] || %{}
    identity = auth[:identity] || %{}
    generation = identity[:sessionGeneration] || identity["sessionGeneration"] || 0
    payload = params["payload"]

    with true <- auth[:role] == :node and is_pid(ctx[:conn_pid]),
         true <- valid_frame?(payload),
         :ok <-
           LemonCore.NodeRegistry.shell_event_session(
             auth[:client_id],
             ctx[:conn_pid],
             generation,
             params["invokeId"],
             payload
           ) do
      {:ok, %{"received" => true}}
    else
      _ ->
        {:error,
         Errors.forbidden("Shell frame does not belong to a live authenticated invocation")}
    end
  end

  defp valid_frame?(%{"type" => "ready"} = p), do: map_size(p) == 1

  defp valid_frame?(%{"type" => "exit", "code" => code} = p),
    do: is_integer(code) and map_size(p) == 2

  defp valid_frame?(%{"type" => "output", "seq" => seq, "dataBase64" => data} = p)
       when is_integer(seq) and seq > 0 and is_binary(data) and byte_size(data) <= 21_848 do
    map_size(p) == 3 and match?({:ok, _}, Base.decode64(data))
  end

  defp valid_frame?(_), do: false
end
