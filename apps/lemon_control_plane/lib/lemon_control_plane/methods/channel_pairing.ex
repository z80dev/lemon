defmodule LemonControlPlane.Methods.ChannelPairing do
  @moduledoc """
  Local operator-only access to channel pairing requests and the live allowlist.

  `activate` and `revoke` apply a chat to the running transport so approval and
  revocation take effect on the next inbound message; the caller persists the
  same change in the canonical gateway config first, and the config cache is
  reloaded so a supervised transport restart reads the persisted allowlist.
  """
  @behaviour LemonControlPlane.Method

  alias LemonChannels.Pairing

  @impl true
  def name, do: "channels.pairing"
  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(params, %{local?: true, auth: %{role: :operator}}) when is_map(params) do
    dispatch(params)
  catch
    :exit, _ -> {:error, :unavailable, "Channel pairing is unavailable", nil}
  end

  def handle(_params, _ctx), do: {:error, :forbidden, "Local operator access required", nil}

  defp dispatch(%{"action" => "list"}) do
    case Pairing.list() do
      {:ok, requests} -> {:ok, %{"requests" => requests}}
      _ -> {:error, :unavailable, "Channel pairing is unavailable", nil}
    end
  end

  defp dispatch(%{"action" => "consume", "platform" => platform, "pairing_code" => code})
       when platform in ["telegram", "discord"] and is_binary(code) and byte_size(code) == 8 do
    case Pairing.consume(platform, code) do
      {:ok, row} -> {:ok, %{"request" => Map.take(row, [:platform, :chat_id, :user_id])}}
      _ -> {:error, :not_found, "Pairing request not found or expired", nil}
    end
  end

  defp dispatch(%{"action" => action, "platform" => platform, "chat_id" => chat_id})
       when action in ["activate", "revoke"] and platform in ["telegram", "discord"] and
              (is_binary(chat_id) or is_integer(chat_id)) do
    with {id, ""} <- Integer.parse(to_string(chat_id)),
         live when live in [:ok, :not_running] <- apply_live(action, platform, id) do
      {:ok, %{"live" => live == :ok}}
    else
      _ -> {:error, :unavailable, "Live allowlist update failed", nil}
    end
  end

  defp dispatch(_params), do: {:error, :invalid_request, "Invalid pairing command", nil}

  # The operator CLI persisted the change moments ago; refresh the cache so a
  # transport restarted by its supervisor reads the same allowlist.
  defp apply_live(action, platform, id) do
    _ = LemonCore.Config.reload()
    live(action, platform, id)
  rescue
    _ -> {:error, :unavailable}
  end

  defp live("activate", platform, id), do: Pairing.allow(platform, id)
  defp live("revoke", platform, id), do: Pairing.revoke(platform, id)
end
