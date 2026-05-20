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
      cond do
        ctx[:subscription_mode] == :all ->
          ["all"]

        match?(%MapSet{}, ctx[:subscriptions]) ->
          ctx[:subscriptions]
          |> MapSet.to_list()
          |> Enum.sort()

        conn_id ->
          get_connection_subscriptions(conn_id)

        true ->
          []
      end

    # Extract run subscriptions from the full list
    run_subscriptions =
      subscriptions
      |> Enum.filter(&String.starts_with?(&1, "run:"))
      |> Enum.map(&String.replace_prefix(&1, "run:", ""))

    {:ok,
     %{
       "subscriptions" => subscriptions,
       "runSubscriptions" => run_subscriptions,
       "count" => length(subscriptions),
       "summary" => summary(subscriptions, run_subscriptions, conn_id)
     }}
  end

  defp get_connection_subscriptions(conn_id) do
    case Process.whereis(LemonControlPlane.ConnectionRegistry) do
      nil ->
        []

      registry ->
        case Registry.lookup(registry, conn_id) do
          [{_pid, _}] ->
            []

          [] ->
            []
        end
    end
  end

  defp summary(subscriptions, run_subscriptions, conn_id) do
    %{
      "topicCount" => length(subscriptions),
      "runSubscriptionCount" => length(run_subscriptions),
      "sessionSubscriptionCount" =>
        Enum.count(subscriptions, &String.starts_with?(&1, "session:")),
      "hasConnection" => is_binary(conn_id) and conn_id != "",
      "cleanup" => %{
        "includesPayloads" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end
end
