defmodule LemonControlPlane.Methods.ChannelPairing do
  @moduledoc "Local operator-only access to pending channel pairing requests."
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

  defp dispatch(_params), do: {:error, :invalid_request, "Invalid pairing command", nil}
end
