defmodule LemonControlPlane.Methods.SessionsWatch do
  @moduledoc "Selects the single live session stream of an operator WebSocket."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.NativeSessions

  @impl true
  def name, do: "sessions.watch"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, %{auth: %{role: :operator}, conn_pid: pid, transport: :websocket})
      when pid == self() do
    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024) do
      {:ok, %{"sessionKey" => key}}
    end
  end

  def handle(_, _), do: NativeSessions.invalid("sessions.watch requires an operator WebSocket")
end
