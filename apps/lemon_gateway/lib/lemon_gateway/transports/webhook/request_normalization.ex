defmodule LemonGateway.Transports.Webhook.RequestNormalization do
  @moduledoc """
  Request payload normalization and callback metadata helpers for webhook requests.
  """

  alias LemonGateway.Transports.Webhook.Request

  @spec normalize_payload(map()) :: {:ok, map()} | {:error, term()}
  def normalize_payload(payload), do: Request.normalize_payload(payload)

  @spec validate_callback_url(term(), boolean(), keyword()) :: :ok | {:error, term()}
  def validate_callback_url(callback_url, allow_private_hosts, opts \\ []) do
    Request.validate_callback_url(callback_url, allow_private_hosts, opts)
  end

  @spec request_metadata(Plug.Conn.t()) :: map()
  def request_metadata(conn), do: Request.request_metadata(conn)

  @spec secure_compare(binary(), binary()) :: boolean()
  def secure_compare(expected, provided), do: Request.secure_compare(expected, provided)
end
