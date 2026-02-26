defmodule LemonControlPlane.Methods.Send do
  @moduledoc """
  Handler for the send method.

  Sends a message to a channel without starting an agent run.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    channel_id = params["channelId"]
    account_id = params["accountId"]
    peer_id = params["peerId"]
    content = params["content"]
    idempotency_key = params["idempotencyKey"]

    cond do
      is_nil(channel_id) ->
        {:error, {:invalid_request, "channelId is required", nil}}

      is_nil(content) ->
        {:error, {:invalid_request, "content is required", nil}}

      true ->
        case send_message(channel_id, account_id, peer_id, content, idempotency_key) do
          {:ok, delivery_ref} ->
            {:ok, %{"success" => true, "deliveryRef" => delivery_ref}}

          {:error, reason} ->
            {:error, {:internal_error, "Failed to send message", reason}}
        end
    end
  end

  defp send_message(channel_id, account_id, peer_id, content, idempotency_key) do
    # Check idempotency
    if idempotency_key do
      case LemonCore.Idempotency.get(:send, idempotency_key) do
        {:ok, result} -> {:ok, result}
        :miss -> do_send(channel_id, account_id, peer_id, content, idempotency_key)
      end
    else
      do_send(channel_id, account_id, peer_id, content, nil)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp do_send(channel_id, account_id, peer_id, content, idempotency_key) do
    # Try LemonChannels.Outbox first
    if Code.ensure_loaded?(LemonChannels.Outbox) do
      payload = %LemonChannels.OutboundPayload{
        channel_id: channel_id,
        account_id: account_id,
        peer: %{id: peer_id},
        kind: :text,
        content: content,
        idempotency_key: idempotency_key
      }

      case LemonChannels.Outbox.enqueue(payload) do
        {:ok, ref} ->
          if idempotency_key do
            LemonCore.Idempotency.put(:send, idempotency_key, ref)
          end
          {:ok, ref}

        error ->
          error
      end
    else
      {:error, :channels_not_available}
    end
  rescue
    _ -> {:error, :channels_not_available}
  end
end
