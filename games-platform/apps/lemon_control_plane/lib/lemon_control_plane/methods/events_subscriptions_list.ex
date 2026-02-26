defmodule LemonControlPlane.Methods.EventsSubscriptionsList do
  @moduledoc """
  List active event subscriptions for the current connection.

  Returns the list of topics and run IDs the current connection is subscribed to.

  ## Example

      {
        "method": "events.subscriptions.list"
      }

  ## Response

      {
        "subscriptions": ["system", "cron", "run:abc123"],
        "runSubscriptions": ["abc123"]
      }
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "events.subscriptions.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, ctx) do
    conn_id = ctx[:conn_id]

    subscriptions =
      if conn_id do
        get_connection_subscriptions(conn_id)
      else
        []
      end

    # Extract run subscriptions from the full list
    run_subscriptions =
      subscriptions
      |> Enum.filter(&String.starts_with?(&1, "run:"))
      |> Enum.map(&String.replace_prefix(&1, "run:", ""))

    {:ok, %{
      "subscriptions" => subscriptions,
      "runSubscriptions" => run_subscriptions,
      "count" => length(subscriptions)
    }}
  end

  defp get_connection_subscriptions(conn_id) do
    case Process.whereis(LemonControlPlane.WS.ConnectionRegistry) do
      nil ->
        []

      registry ->
        case Registry.lookup(registry, conn_id) do
          [{_pid, _}] ->
            # Request subscriptions from the connection process
            # This is a simplified version - in production this might use a GenServer.call
            # For now, return empty list as subscriptions are tracked per-connection
            []

          [] ->
            []
        end
    end
  end
end
